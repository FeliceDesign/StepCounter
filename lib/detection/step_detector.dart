import 'dart:math' as math;

import 'biquad.dart';
import 'calibration_params.dart';
import 'sensor_sample.dart';

/// Live snapshot of detector internals, for the diagnostics panel in Settings
/// and for understanding why a calibration run scored the way it did.
class DetectorDebug {
  const DetectorDebug({
    required this.threshold,
    required this.sigma,
    required this.gyroLevel,
    required this.cadenceMs,
    required this.pendingCandidates,
    required this.inConfirmedRun,
    required this.warmedUp,
    required this.intervalCv,
    required this.verticalShare,
  });

  final double threshold;
  final double sigma;
  final double gyroLevel;
  final double? cadenceMs;
  final int pendingCandidates;
  final bool inConfirmedRun;
  final bool warmedUp;

  /// Coefficient of variation of the recent step intervals. Surfaced so the
  /// rhythm gate can be watched on a real device rather than taken on trust —
  /// after the autocorrelation episode (see the README) a gate whose mechanism
  /// cannot be observed is not worth shipping.
  final double intervalCv;

  /// Share of recent movement lying along gravity, or null while the gravity
  /// estimate is not trustworthy and the gate is standing aside.
  final double? verticalShare;
}

/// Streaming step detector.
///
/// Fully deterministic and driven only by sample timestamps — no wall clock, no
/// randomness, no ambient state. That is a hard requirement, not a nicety: the
/// calibration optimiser replays stored raw sessions through this exact class
/// thousands of times, and a before/after comparison only means something if
/// the same bytes always produce the same count.
///
/// Pipeline (see README):
///   magnitude -> band-pass 0.5-3 Hz -> smooth -> adaptive threshold
///   -> peak/valley pairing -> vertical-share gate -> gyro gate
///   -> temporal gates -> rhythm-quality gate
///
/// The last of those is re-checked on every candidate, not once per walk. An
/// earlier version confirmed a run after four rhythmic peaks and then counted
/// every peak thereafter without further question, which is why a phone
/// fidgeted with in the hand scored steps by the hundred.
class StepDetector {
  StepDetector({
    CalibrationParams params = CalibrationParams.factory,
    this.sampleRateHz = 50.0,
  }) : _params = params.clamped() {
    _buildFilters();
  }

  final double sampleRateHz;
  CalibrationParams _params;

  CalibrationParams get params => _params;

  /// Swapping parameters mid-stream resets filter and streak state, because a
  /// half-built regularity streak judged under the old thresholds says nothing
  /// about the new ones.
  set params(CalibrationParams p) {
    _params = p.clamped();
    reset();
  }

  static const double _bandLowHz = 0.5;
  static const double _bandHighHz = 3.0;
  static const double _statsWindowSeconds = 2.5;
  static const double _warmupSeconds = 0.5;
  static const int _smoothingSamples = 5;

  /// How many recent intervals the coefficient-of-variation gate judges, once
  /// that many exist.
  ///
  /// Deliberately larger than `regularityRunLength - 1`, and deliberately not
  /// tunable. These are two different questions and conflating them was why an
  /// earlier attempt at this gate barely helped:
  ///
  ///   * `regularityRunLength` decides how soon counting may *start*. Short is
  ///     good — it is the latency a user feels at the beginning of a walk.
  ///   * this decides how much evidence "still walking" requires. Long is good
  ///     — over three intervals a coefficient of variation is a weak statistic
  ///     that four accidentally-similar fidgets can satisfy, and hand movement
  ///     produces such runs constantly. Over eight it is a strong one, and
  ///     nothing but real gait sustains it.
  ///
  /// So a run may still begin after four candidates, but it can only *continue*
  /// while the last eight intervals hold together. Measured on the fixtures:
  /// real gait sits at CV 0.010-0.027 over this window, hand jiggle at
  /// 0.04-0.16 — and, more to the point, jiggle cannot hold a low value for
  /// eight consecutive intervals the way it can for three.
  static const int _rhythmWindowIntervals = 8;

  /// Smoothing factor of the single-pole gravity estimate, per sample.
  ///
  /// A literal, and never derived from [sampleRateHz]: a constant computed
  /// from the sample rate is exactly the kind of thing the Dart and Kotlin
  /// ports would round differently and drift apart on. At the 50 Hz both ports
  /// run, 0.03 is roughly a 0.24 Hz corner — well below the 0.5 Hz bottom of
  /// the gait band, so walking passes through the estimate untouched, yet fast
  /// enough to follow a phone moving from a pocket to a hand in about two
  /// seconds.
  static const double _gravityAlpha = 0.03;

  /// The estimate is only trusted while its magnitude looks like gravity.
  /// Sustained hard dynamics (running with the phone swinging in a hand) drag
  /// a single-pole estimate away from 9.81, and a gate fed a corrupt input is
  /// worse than no gate at all — so outside this band the vertical-share test
  /// is *skipped*, exactly as the gyro gate is skipped on a device with no
  /// gyroscope.
  static const double _gravityMin = 8.0;
  static const double _gravityMax = 11.5;

  /// A gap longer than this means the sensor stream was interrupted (service
  /// restart, doze, batching hiccup). Filter state across a gap is meaningless,
  /// so we start clean rather than emit a burst of phantom steps.
  static const int _maxGapMs = 200;

  late BandPass _accelBand;
  late RollingStats _stats;
  late RollingStats _gyroStats;

  /// Deviation of the acceleration resolved along, and across, the estimated
  /// gravity direction. See [_gravityAlpha] and [verticalShare].
  late RollingStats _verticalStats;
  late RollingStats _horizontalStats;

  double _gx = 0, _gy = 0, _gz = 0;
  bool _hasGravity = false;

  final List<double> _smoothBuf = [];
  double _smoothSum = 0;

  // Last three smoothed samples, for three-point local extremum detection.
  double? _v0, _v1, _v2;
  int? _t1;

  double? _lastValleyValue;

  int? _lastCandidateNs;
  double? _cadenceMs;

  /// The recent accepted step intervals — the run's *quality*, as opposed to
  /// its mere existence, re-judged by [_runIsRhythmic] on every candidate.
  ///
  /// Note the off-by-one: `regularityRunLength` consecutive candidates yield
  /// one fewer interval than that, because the first candidate of a streak
  /// arrives with no predecessor to measure against.
  final List<double> _recentIntervalsMs = [];

  final List<int> _pending = [];
  bool _inConfirmedRun = false;

  int? _lastSampleNs;
  int _totalSteps = 0;

  int get totalSteps => _totalSteps;

  double _lastRawMagnitude = 0;
  double _lastFilteredMagnitude = 0;

  /// Acceleration magnitude including gravity, from the most recent sample.
  /// The activity classifier reads this rather than recomputing it — and needs
  /// the raw value, since the flight phase of running is a dip toward freefall
  /// that the band-pass removes.
  double get lastRawMagnitude => _lastRawMagnitude;

  /// Band-passed magnitude from the most recent sample.
  double get lastFilteredMagnitude => _lastFilteredMagnitude;

  void _buildFilters() {
    _accelBand = BandPass(lowHz: _bandLowHz, highHz: _bandHighHz, sampleRateHz: sampleRateHz);
    final window = (sampleRateHz * _statsWindowSeconds).round();
    _stats = RollingStats(window);
    _gyroStats = RollingStats(window);
    _verticalStats = RollingStats(window);
    _horizontalStats = RollingStats(window);
  }

  void reset() {
    _accelBand.reset();
    _stats.reset();
    _gyroStats.reset();
    _verticalStats.reset();
    _horizontalStats.reset();
    _gx = _gy = _gz = 0;
    _hasGravity = false;
    _smoothBuf.clear();
    _smoothSum = 0;
    _v0 = _v1 = _v2 = null;
    _t1 = null;
    _lastValleyValue = null;
    _lastCandidateNs = null;
    _cadenceMs = null;
    _recentIntervalsMs.clear();
    _pending.clear();
    _inConfirmedRun = false;
    _lastSampleNs = null;
  }

  /// Clears the running total without disturbing detection state.
  void resetCount() => _totalSteps = 0;

  int get _warmupSamples => (sampleRateHz * _warmupSeconds).round();

  /// Feeds one sample. Returns the hardware timestamps (ns) of any steps
  /// confirmed by this sample — usually empty, but the sample that completes a
  /// regularity streak releases the whole buffered run at once.
  List<int> addSample(SensorSample s) {
    final prev = _lastSampleNs;
    if (prev != null) {
      final gapMs = (s.tNs - prev) / 1e6;
      if (gapMs > _maxGapMs || gapMs < 0) {
        reset();
      }
    }
    _lastSampleNs = s.tNs;

    // 1-2. Magnitude, then band-pass to strip gravity and high-frequency noise.
    final raw = s.accelMagnitude;
    final filtered = _accelBand.process(raw);
    _lastRawMagnitude = raw;
    _lastFilteredMagnitude = filtered;

    // Gravity estimate, and the split of acceleration along versus across it.
    //
    // This is the one place the detector looks at direction rather than at the
    // orientation-free magnitude, and it is what separates walking from a hand
    // fidgeting with the phone: walking drives the body up and down, so its
    // oscillation lies along gravity, while hand movement is mostly sideways
    // and rotational. The magnitude channel cannot see the difference because
    // taking |a| is exactly the step that throws the direction away.
    //
    // Orientation independence survives. The detector still never needs to
    // know the phone's pose — it estimates gravity from the data and works in
    // whatever frame that estimate defines. What it newly requires is that
    // gravity be *estimable*, which the magnitude check below enforces.
    if (_hasGravity) {
      _gx += _gravityAlpha * (s.ax - _gx);
      _gy += _gravityAlpha * (s.ay - _gy);
      _gz += _gravityAlpha * (s.az - _gz);
    } else {
      // Seed from the first sample rather than from zero, which would take
      // several seconds to converge and mislabel the start of every session.
      _gx = s.ax;
      _gy = s.ay;
      _gz = s.az;
      _hasGravity = true;
    }
    final gMag = math.sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
    if (gMag > 0) {
      final ux = _gx / gMag, uy = _gy / gMag, uz = _gz / gMag;
      final along = s.ax * ux + s.ay * uy + s.az * uz;
      final hx = s.ax - ux * along;
      final hy = s.ay - uy * along;
      final hz = s.az - uz * along;
      _verticalStats.add(along);
      _horizontalStats.add(math.sqrt(hx * hx + hy * hy + hz * hz));
    }

    // Gyroscope is tracked as a raw magnitude level, NOT band-passed. Rotation
    // about one axis makes |omega| a rectified sine at twice the gait
    // frequency, so a 0.5-3 Hz band-pass would attenuate it more the faster you
    // walk — rejecting a jog while accepting a stroll. The mean level separates
    // the cases cleanly on its own: ~0.004 rad/s riding in a car, ~0.2-0.5
    // walking, ~10 shaking the device.
    if (s.hasGyro) _gyroStats.add(s.gyroMagnitude);

    // 3. Smooth.
    _smoothBuf.add(filtered);
    _smoothSum += filtered;
    if (_smoothBuf.length > _smoothingSamples) {
      _smoothSum -= _smoothBuf.removeAt(0);
    }
    final smoothed = _smoothSum / _smoothBuf.length;

    // 4. Adaptive threshold statistics.
    _stats.add(smoothed);

    // Shift the three-point window.
    _v0 = _v1;
    _v1 = _v2;
    _v2 = smoothed;
    final tPrev = _t1;
    _t1 = s.tNs;

    final v0 = _v0, v1 = _v1, v2 = _v2;
    if (v0 == null || v1 == null || v2 == null || tPrev == null) {
      return const [];
    }

    // The extremum sits at the middle sample, so it carries that timestamp.
    final isLocalMin = v1 < v0 && v1 <= v2;
    final isLocalMax = v1 > v0 && v1 >= v2;

    if (isLocalMin) {
      _lastValleyValue = v1;
      return const [];
    }
    if (!isLocalMax) return const [];

    if (_stats.count < _warmupSamples) return const [];

    return _evaluatePeak(v1, tPrev, s.hasGyro);
  }

  /// 5-8. Everything a local maximum has to survive to become a step.
  List<int> _evaluatePeak(double peakValue, int peakNs, bool hasGyro) {
    // Absolute motion floor, checked before anything relative.
    //
    // The adaptive threshold below scales with the signal, so on a nearly still
    // phone it collapses toward zero and happily fires on desk vibration or
    // shifting in a chair. Without this gate the detector produced on the order
    // of 1,600 phantom steps a day, and no setting of thresholdSigma could stop
    // it, because that parameter shrinks along with the noise it is meant to
    // reject.
    if (_stats.stdDev < _params.minMotionSigma) {
      _breakStreak();
      return const [];
    }

    // Vertical share. Placed directly after the motion floor because it, too,
    // asks whether this is the right *kind* of movement, before any question
    // of how big or how well timed it is.
    if (_gravityTrusted && _verticalStats.count >= _warmupSamples) {
      if (verticalShare < _params.minVerticalShare) {
        _breakStreak();
        return const [];
      }
    }

    final threshold = _stats.mean + _params.thresholdSigma * _stats.stdDev;
    if (peakValue <= threshold) return const [];

    final valley = _lastValleyValue;
    if (valley == null) return const [];
    if (peakValue - valley < _params.minAmplitude) return const [];

    // Gyro gate. Absent a gyroscope this is skipped rather than failed, so the
    // detector degrades to accelerometer-only instead of counting nothing.
    if (hasGyro && _gyroStats.count >= _warmupSamples) {
      final gs = _gyroStats.mean;
      if (gs < _params.gyroMinLevel || gs > _params.gyroMaxLevel) {
        _breakStreak();
        return const [];
      }
    }

    final last = _lastCandidateNs;
    if (last == null) {
      return _acceptCandidate(peakNs, null);
    }

    final dtMs = (peakNs - last) / 1e6;

    // Too fast to be a separate footfall — this is a bounce within one step.
    // Deliberately does not touch the streak or _lastCandidateNs.
    if (dtMs < _params.minStepIntervalMs) return const [];

    // Too slow, or off-rhythm relative to the established cadence: the walk
    // stopped. Drop anything unconfirmed and begin a fresh streak here.
    final cadence = _cadenceMs;
    final tolerance = _params.offRhythmTolerance;
    final offRhythm = cadence != null &&
        (dtMs < (1 - tolerance) * cadence || dtMs > (1 + tolerance) * cadence);
    if (dtMs > _params.maxStepIntervalMs || offRhythm) {
      _breakStreak();
      return _acceptCandidate(peakNs, null);
    }

    return _acceptCandidate(peakNs, dtMs);
  }

  List<int> _acceptCandidate(int peakNs, double? dtMs) {
    _lastCandidateNs = peakNs;
    if (dtMs != null) {
      final c = _cadenceMs;
      _cadenceMs = c == null ? dtMs : 0.7 * c + 0.3 * dtMs;

      _recentIntervalsMs.add(dtMs);
      final cap = math.max(_params.regularityRunLength - 1, _rhythmWindowIntervals);
      while (_recentIntervalsMs.length > cap) {
        _recentIntervalsMs.removeAt(0);
      }
    }
    final rhythmic = _runIsRhythmic;

    // A confirmed run is re-examined here on every candidate, which is the
    // whole point. The previous version latched `_inConfirmedRun` true after
    // `regularityRunLength` candidates and never looked again, so anything
    // that could open the gate for two seconds counted freely thereafter —
    // three minutes of fidgeting scored 278 steps.
    if (_inConfirmedRun) {
      if (rhythmic) {
        _totalSteps++;
        return [peakNs];
      }
      // Fall back out of the run. Steps already counted are never retracted:
      // they were counted on evidence that was good at the time, and a number
      // that goes backwards is worse than one that is slightly too high.
      _inConfirmedRun = false;
      _pending
        ..clear()
        ..add(peakNs);
      return const [];
    }

    _pending.add(peakNs);
    if (_pending.length >= _params.regularityRunLength && rhythmic) {
      final released = List<int>.of(_pending);
      _pending.clear();
      _inConfirmedRun = true;
      _totalSteps += released.length;
      return released;
    }
    return const [];
  }

  /// Whether the gravity estimate currently looks like gravity.
  bool get _gravityTrusted {
    if (!_hasGravity) return false;
    final m = math.sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
    return m >= _gravityMin && m <= _gravityMax;
  }

  /// Fraction of the recent movement that lies along gravity rather than
  /// across it, between 0 and 1.
  ///
  /// Ratio of standard deviations rather than of raw values, because the
  /// vertical channel carries gravity itself as a large constant offset that
  /// says nothing about movement. Walking sits high; a hand waving the phone
  /// about sits low.
  double get verticalShare {
    final v = _verticalStats.stdDev;
    final h = _horizontalStats.stdDev;
    final total = v + h;
    return total <= 0 ? 0 : v / total;
  }

  /// Whether the recent intervals look like walking rather than like motion
  /// that merely happens to be repetitive.
  ///
  /// At the minimum legal `regularityRunLength` of 2 there is only ever one
  /// interval, a coefficient of variation over which is meaningless, so the
  /// gate stands aside and `regularityRunLength` alone governs. That is the
  /// correct degradation: the parameter's floor is what a user picks when they
  /// want the loosest possible detector.
  bool get _runIsRhythmic {
    final needed = _params.regularityRunLength - 1;
    if (_recentIntervalsMs.length < needed) return false;
    if (_recentIntervalsMs.length < 2) return true;
    return _intervalCv(_recentIntervalsMs) <= _params.maxIntervalCv;
  }

  /// Coefficient of variation, computed in two passes.
  ///
  /// Two passes rather than the `sqrt(E[x^2] - mean^2)` shortcut used by
  /// [RollingStats]: this buffer holds at most seven elements, so the cost is
  /// irrelevant, and the shortcut can produce a small negative variance from
  /// floating-point cancellation when the intervals are nearly identical —
  /// which is precisely the case for real walking. Dart and Kotlin must agree
  /// here to the last bit or the goldens diverge.
  static double _intervalCv(List<double> xs) {
    if (xs.length < 2) return 0;
    var sum = 0.0;
    for (final x in xs) {
      sum += x;
    }
    final mean = sum / xs.length;
    if (mean <= 0) return 0;
    var sq = 0.0;
    for (final x in xs) {
      final d = x - mean;
      sq += d * d;
    }
    return math.sqrt(sq / xs.length) / mean;
  }

  /// Unconfirmed candidates are discarded, never counted. A couple of peaks
  /// from gesturing or pulling the phone out of a pocket die here.
  void _breakStreak() {
    _pending.clear();
    _inConfirmedRun = false;
    _cadenceMs = null;
    _recentIntervalsMs.clear();
  }

  DetectorDebug get debug => DetectorDebug(
        threshold: _stats.mean + _params.thresholdSigma * _stats.stdDev,
        sigma: _stats.stdDev,
        gyroLevel: _gyroStats.mean,
        cadenceMs: _cadenceMs,
        pendingCandidates: _pending.length,
        inConfirmedRun: _inConfirmedRun,
        warmedUp: _stats.count >= _warmupSamples,
        intervalCv: _intervalCv(_recentIntervalsMs),
        verticalShare: _gravityTrusted ? verticalShare : null,
      );

  /// Replays a complete recorded session and returns the step count.
  ///
  /// This is the single entry point used by both the manual Test & Recalibrate
  /// flow and the automatic optimiser, so the number a user is shown is
  /// produced by exactly the same code path that counts their steps live.
  static int countSteps(
    List<SensorSample> samples, {
    CalibrationParams params = CalibrationParams.factory,
    double sampleRateHz = 50.0,
  }) {
    final d = StepDetector(params: params, sampleRateHz: sampleRateHz);
    for (final s in samples) {
      d.addSample(s);
    }
    return d.totalSteps;
  }
}
