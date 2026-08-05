import 'dart:math' as math;

import 'activity.dart';
import 'biquad.dart';

/// Converts a barometric pressure reading to altitude in metres.
///
/// The absolute value is meaningless without a local sea-level reference, and
/// we never use it: only differences matter, and the reference cancels out.
double altitudeFromPressure(double hPa) =>
    44330.0 * (1 - math.pow(hPa / 1013.25, 0.1903));

/// Live view of the classifier's inputs, for the diagnostics panel.
class ActivityDebug {
  const ActivityDebug({
    required this.activity,
    required this.cadence,
    required this.accelSigma,
    required this.amplitude,
    required this.minRawMagnitude,
    required this.gyroLevel,
    required this.altitudeRate,
    required this.hasBarometer,
  });

  final Activity activity;
  final double cadence;
  final double accelSigma;
  final double amplitude;
  final double minRawMagnitude;
  final double gyroLevel;
  final double altitudeRate;
  final bool hasBarometer;
}

/// Classifies what the user is doing from the same sample stream the step
/// detector consumes, plus barometric pressure when the device has a sensor.
///
/// Rule-based rather than learned, for the same reasons as the step detector:
/// every threshold is a named number that can be clamped, displayed, tuned by
/// the existing optimiser, and reverted.
///
/// Deterministic and driven only by sample timestamps, so recorded sessions
/// replay identically.
class ActivityClassifier {
  ActivityClassifier({ActivityParams params = ActivityParams.factory})
      : _params = params.clamped();

  ActivityParams _params;
  ActivityParams get params => _params;
  set params(ActivityParams p) {
    _params = p.clamped();
    reset();
  }

  static const double sampleRateHz = 50.0;
  static const double _windowSeconds = 3.0;
  /// Slope noise falls off faster than linearly with window length, and stairs
  /// take ten seconds or more to climb, so a longer window costs nothing in
  /// responsiveness and buys real robustness against a noisy barometer.
  static const double _pressureWindowSeconds = 6.0;

  /// How long a new label must hold before it replaces the current one.
  /// Without this a single noisy window would recolour a minute of history.
  static const int _switchConfirmMs = 1000;

  /// A step older than this means the user has stopped.
  static const int _stepRecencyMs = 3000;

  static const int _maxGapMs = 200;

  static int get _windowSamples => (sampleRateHz * _windowSeconds).round();

  final RollingStats _filteredStats = RollingStats(_windowSamples);
  final RollingStats _gyroStats = RollingStats(_windowSamples);

  // Ring of raw magnitudes, for the running flight-phase dip.
  final List<double> _rawRing = List<double>.filled(_windowSamples, 9.81);
  int _rawHead = 0;
  int _rawCount = 0;

  // Ring of band-passed values, for peak-to-trough amplitude.
  final List<double> _filteredRing = List<double>.filled(_windowSamples, 0);
  int _filteredHead = 0;
  int _filteredCount = 0;

  // Barometric altitude samples, as (seconds, metres).
  final List<double> _pressureT = [];
  final List<double> _pressureAlt = [];
  bool _hasBarometer = false;

  final List<int> _stepTimes = [];
  int? _lastStepNs;
  int? _lastSampleNs;

  int? _stairsSinceNs;
  Activity _current = Activity.unknown;
  Activity? _candidate;
  int? _candidateSinceNs;

  int _samplesSinceClassify = 0;
  double _altitudeRate = 0;

  Activity get current => _current;
  bool get hasBarometer => _hasBarometer;

  void reset() {
    _filteredStats.reset();
    _gyroStats.reset();
    _rawRing.fillRange(0, _rawRing.length, 9.81);
    _rawHead = 0;
    _rawCount = 0;
    _filteredRing.fillRange(0, _filteredRing.length, 0);
    _filteredHead = 0;
    _filteredCount = 0;
    _pressureT.clear();
    _pressureAlt.clear();
    _stepTimes.clear();
    _lastStepNs = null;
    _lastSampleNs = null;
    _stairsSinceNs = null;
    _current = Activity.unknown;
    _candidate = null;
    _candidateSinceNs = null;
    _samplesSinceClassify = 0;
    _altitudeRate = 0;
  }

  /// Feeds a barometer reading in hectopascals.
  ///
  /// Barometers report at a few hertz at most, far slower than the
  /// accelerometer, so these arrive independently of [update].
  void addPressure(int tNs, double hPa) {
    if (hPa <= 0) return;
    _hasBarometer = true;
    _pressureT.add(tNs / 1e9);
    _pressureAlt.add(altitudeFromPressure(hPa));

    final cutoff = tNs / 1e9 - _pressureWindowSeconds;
    while (_pressureT.length > 2 && _pressureT.first < cutoff) {
      _pressureT.removeAt(0);
      _pressureAlt.removeAt(0);
    }
    _altitudeRate = _slope();
  }

  /// Least-squares slope of altitude against time, in m/s.
  ///
  /// A regression over the whole window rather than a difference between two
  /// readings: barometer noise is around 0.03 hPa (~0.25 m), which would swamp
  /// a two-point estimate of a 0.2 m/s climb.
  double _slope() {
    final n = _pressureT.length;
    if (n < 4) return 0;
    var sumT = 0.0, sumA = 0.0;
    for (var i = 0; i < n; i++) {
      sumT += _pressureT[i];
      sumA += _pressureAlt[i];
    }
    final meanT = sumT / n, meanA = sumA / n;
    var num = 0.0, den = 0.0;
    for (var i = 0; i < n; i++) {
      final dt = _pressureT[i] - meanT;
      num += dt * (_pressureAlt[i] - meanA);
      den += dt * dt;
    }
    if (den <= 0) return 0;
    return num / den;
  }

  /// Feeds one motion sample. [stepsEmitted] is how many steps the detector
  /// confirmed on this sample.
  Activity update({
    required int tNs,
    required double rawMagnitude,
    required double filteredMagnitude,
    required double gyroMagnitude,
    required bool hasGyro,
    required int stepsEmitted,
  }) {
    final prev = _lastSampleNs;
    if (prev != null) {
      final gapMs = (tNs - prev) / 1e6;
      if (gapMs > _maxGapMs || gapMs < 0) reset();
    }
    _lastSampleNs = tNs;

    _filteredStats.add(filteredMagnitude);
    if (hasGyro) _gyroStats.add(gyroMagnitude);

    _rawRing[_rawHead] = rawMagnitude;
    _rawHead = (_rawHead + 1) % _rawRing.length;
    if (_rawCount < _rawRing.length) _rawCount++;

    _filteredRing[_filteredHead] = filteredMagnitude;
    _filteredHead = (_filteredHead + 1) % _filteredRing.length;
    if (_filteredCount < _filteredRing.length) _filteredCount++;

    if (stepsEmitted > 0) {
      _lastStepNs = tNs;
      for (var i = 0; i < stepsEmitted; i++) {
        _stepTimes.add(tNs);
      }
      while (_stepTimes.length > 12) {
        _stepTimes.removeAt(0);
      }
    }

    // Classified at 5 Hz rather than 50: the underlying windows are seconds
    // long, so a per-sample decision would be ten times the work for a label
    // that cannot have changed.
    //
    // Steps force a classification regardless. The label returned here is what
    // those steps get filed under, so it has to be current — otherwise a step
    // flush landing between ticks is attributed to whatever came before it.
    _samplesSinceClassify++;
    if (stepsEmitted > 0 || _samplesSinceClassify >= 10) {
      _samplesSinceClassify = 0;
      _applyLabel(_classify(tNs, hasGyro), tNs);
    }
    return _current;
  }

  Activity _classify(int tNs, bool hasGyro) {
    final lastStep = _lastStepNs;
    final steppingNow =
        lastStep != null && (tNs - lastStep) / 1e6 <= _stepRecencyMs;

    if (steppingNow) {
      final stairs = _stairsLabel(tNs);
      if (stairs != null) return stairs;
      return _isRunning() ? Activity.running : Activity.walking;
    }

    _stairsSinceNs = null;

    if (_filteredStats.stdDev < _params.stillAccelSigmaMax) return Activity.still;

    // Acceleration without rotation, and without a gait rhythm the detector
    // would have counted: motion transmitted through a seat.
    if (hasGyro && _gyroStats.mean < _params.vehicleGyroMax) {
      return Activity.vehicle;
    }
    return Activity.unknown;
  }

  /// Stairs require sustained vertical motion, not a momentary reading.
  Activity? _stairsLabel(int tNs) {
    if (!_hasBarometer) return null;
    if (_altitudeRate.abs() < _params.stairsAltitudeRateMin) {
      _stairsSinceNs = null;
      return null;
    }
    _stairsSinceNs ??= tNs;
    final heldMs = (tNs - _stairsSinceNs!) / 1e6;
    if (heldMs < _params.stairsMinDurationMs) return null;
    return _altitudeRate > 0 ? Activity.stairsUp : Activity.stairsDown;
  }

  bool _isRunning() {
    if (cadence < _params.runningCadenceMin) return false;
    // Cadence alone cannot decide it — a brisk walk reaches 140 spm. Pair it
    // with either the flight-phase dip or a hard impact.
    return minRawMagnitude < _params.runningFlightMax ||
        amplitude >= _params.runningAmplitudeMin;
  }

  void _applyLabel(Activity next, int tNs) {
    if (next == _current) {
      _candidate = null;
      _candidateSinceNs = null;
      return;
    }
    // Starting to move is unambiguous — the detector only confirms steps after
    // four rhythmic ones — so it switches immediately. Without this, every
    // short walk would begin with a second of "unclassified" steps.
    if (next.countsSteps && !_current.countsSteps) {
      _current = next;
      _candidate = null;
      _candidateSinceNs = null;
      return;
    }

    if (_candidate != next) {
      _candidate = next;
      _candidateSinceNs = tNs;
      return;
    }
    if ((tNs - _candidateSinceNs!) / 1e6 >= _switchConfirmMs) {
      _current = next;
      _candidate = null;
      _candidateSinceNs = null;
    }
  }

  /// Steps per minute from the recent step rhythm.
  double get cadence {
    if (_stepTimes.length < 2) return 0;
    final span = (_stepTimes.last - _stepTimes.first) / 1e9;
    if (span <= 0) return 0;
    return (_stepTimes.length - 1) / span * 60.0;
  }

  double get minRawMagnitude {
    if (_rawCount == 0) return 9.81;
    var m = double.infinity;
    for (var i = 0; i < _rawCount; i++) {
      if (_rawRing[i] < m) m = _rawRing[i];
    }
    return m;
  }

  double get amplitude {
    if (_filteredCount == 0) return 0;
    var lo = double.infinity, hi = -double.infinity;
    for (var i = 0; i < _filteredCount; i++) {
      final v = _filteredRing[i];
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    return hi - lo;
  }

  double get altitudeRate => _altitudeRate;

  ActivityDebug get debug => ActivityDebug(
        activity: _current,
        cadence: cadence,
        accelSigma: _filteredStats.stdDev,
        amplitude: amplitude,
        minRawMagnitude: minRawMagnitude,
        gyroLevel: _gyroStats.mean,
        altitudeRate: _altitudeRate,
        hasBarometer: _hasBarometer,
      );
}
