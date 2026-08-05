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
  });

  final double threshold;
  final double sigma;
  final double gyroLevel;
  final double? cadenceMs;
  final int pendingCandidates;
  final bool inConfirmedRun;
  final bool warmedUp;
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
///   -> peak/valley pairing -> temporal gate -> regularity gate -> gyro gate
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

  /// A gap longer than this means the sensor stream was interrupted (service
  /// restart, doze, batching hiccup). Filter state across a gap is meaningless,
  /// so we start clean rather than emit a burst of phantom steps.
  static const int _maxGapMs = 200;

  late BandPass _accelBand;
  late RollingStats _stats;
  late RollingStats _gyroStats;

  final List<double> _smoothBuf = [];
  double _smoothSum = 0;

  // Last three smoothed samples, for three-point local extremum detection.
  double? _v0, _v1, _v2;
  int? _t1;

  double? _lastValleyValue;

  int? _lastCandidateNs;
  double? _cadenceMs;

  final List<int> _pending = [];
  bool _inConfirmedRun = false;

  int? _lastSampleNs;
  int _totalSteps = 0;

  int get totalSteps => _totalSteps;

  void _buildFilters() {
    _accelBand = BandPass(lowHz: _bandLowHz, highHz: _bandHighHz, sampleRateHz: sampleRateHz);
    final window = (sampleRateHz * _statsWindowSeconds).round();
    _stats = RollingStats(window);
    _gyroStats = RollingStats(window);
  }

  void reset() {
    _accelBand.reset();
    _stats.reset();
    _gyroStats.reset();
    _smoothBuf.clear();
    _smoothSum = 0;
    _v0 = _v1 = _v2 = null;
    _t1 = null;
    _lastValleyValue = null;
    _lastCandidateNs = null;
    _cadenceMs = null;
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
    final filtered = _accelBand.process(s.accelMagnitude);

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
    final offRhythm = cadence != null && (dtMs < 0.5 * cadence || dtMs > 2.0 * cadence);
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
    }

    // Once a streak is confirmed each further rhythmic peak counts immediately,
    // so a continuous walk pays the warm-up cost only once.
    if (_inConfirmedRun) {
      _totalSteps++;
      return [peakNs];
    }

    _pending.add(peakNs);
    if (_pending.length >= _params.regularityRunLength) {
      final released = List<int>.of(_pending);
      _pending.clear();
      _inConfirmedRun = true;
      _totalSteps += released.length;
      return released;
    }
    return const [];
  }

  /// Unconfirmed candidates are discarded, never counted. A couple of peaks
  /// from gesturing or pulling the phone out of a pocket die here.
  void _breakStreak() {
    _pending.clear();
    _inConfirmedRun = false;
    _cadenceMs = null;
  }

  DetectorDebug get debug => DetectorDebug(
        threshold: _stats.mean + _params.thresholdSigma * _stats.stdDev,
        sigma: _stats.stdDev,
        gyroLevel: _gyroStats.mean,
        cadenceMs: _cadenceMs,
        pendingCandidates: _pending.length,
        inConfirmedRun: _inConfirmedRun,
        warmedUp: _stats.count >= _warmupSamples,
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
