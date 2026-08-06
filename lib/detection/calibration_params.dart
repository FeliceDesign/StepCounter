import 'dart:convert';

/// The tunable parameter vector for [StepDetector] — "theta" in the plan.
///
/// Every field is clamped to a physiologically plausible range by [clamped].
/// The calibration optimiser is free to search, but it can never hand the
/// detector a value that would make it nonsensical (e.g. a 10 ms minimum step
/// interval, which would count vibration as sprinting).
class CalibrationParams {
  const CalibrationParams({
    this.thresholdSigma = 0.6,
    this.minMotionSigma = 0.35,
    this.minAmplitude = 1.0,
    this.minStepIntervalMs = 250,
    this.maxStepIntervalMs = 2000,
    this.regularityRunLength = 4,
    this.offRhythmTolerance = 0.35,
    this.maxIntervalCv = 0.15,
    this.minVerticalShare = 0.45,
    this.gyroMinLevel = 0.03,
    this.gyroMaxLevel = 5.0,
  });

  /// `k` in the adaptive threshold `T = mean + k * stddev`.
  ///
  /// Note what this can and cannot do. Because the threshold is derived from
  /// the signal's own deviation, it *scales with whatever motion is present* —
  /// so it adapts beautifully between a shuffle and a jog, but it cannot reject
  /// small motion, because it shrinks to match. Raising it from 0.7 to its
  /// maximum only takes 144 phantom steps down to 32 on a fidget recording.
  /// [minMotionSigma] is the parameter that does that job.
  final double thresholdSigma;

  /// Absolute floor, in m/s², on the band-passed signal's standard deviation
  /// before any step may be counted.
  ///
  /// This is the "is there enough movement here at all" gate, and the detector
  /// was wrong to ship without one: without it the adaptive threshold collapses
  /// toward zero on a near-still phone and fires on desk vibration.
  ///
  /// It handles the quiet end, and only that. Measured over the detector's own
  /// 2.5 s window: a still or lightly disturbed phone sits at 0.13-0.33,
  /// ordinary walking at 1.28, jogging at 1.89, so a floor at 0.35 removes the
  /// former without touching the latter.
  ///
  /// It cannot do more. Sustained non-gait motion reaches 0.52 while genuinely
  /// damped walking (phone loose in a bag) sits at 0.57 — they overlap, and no
  /// floor separates them. Motion that is rhythmic at gait frequency and gait
  /// amplitude is not distinguishable from walking by these means; that case
  /// needs per-user calibration against a reference count, not a constant.
  ///
  /// Unlike [thresholdSigma] this is an absolute quantity, which is why it
  /// works at all where the adaptive threshold cannot.
  final double minMotionSigma;

  /// Minimum valley-to-peak amplitude of the band-passed signal, in m/s².
  final double minAmplitude;

  /// Faster than this between two steps is not human gait — it is a bounce in
  /// the signal from a single footfall.
  final int minStepIntervalMs;

  /// Slower than this and we treat the rhythm as broken rather than as a very
  /// slow step, so the regularity streak restarts.
  final int maxStepIntervalMs;

  /// How many consecutive rhythmic candidates are required before any of them
  /// are counted, and how many recent intervals the rhythm-quality gates judge.
  ///
  /// This used to be described as the primary false-positive defence, and it
  /// was not one. It gated *entry* into a counting run and nothing else: four
  /// candidates flipped the run to confirmed, after which every further peak
  /// counted unconditionally, forever. Three minutes of fidgeting with a phone
  /// in hand scored 278 steps that way. It is now one of three rhythm gates,
  /// and the only one that is re-checked on every single candidate is the
  /// interval CV below.
  final int regularityRunLength;

  /// How far a step interval may sit from the running cadence estimate, as a
  /// fraction of it: an interval is on-rhythm when it lies within
  /// `[(1 - t) * cadence, (1 + t) * cadence]`.
  ///
  /// This replaces a hardcoded `0.5x .. 2.0x` window, which was a *four-fold*
  /// range. Once cadence settled near 500 ms it accepted everything from 250 ms
  /// to 1000 ms — that is, the entire plausible span of hand fidgeting — so in
  /// practice it never rejected anything but a complete stop.
  ///
  /// The default of 0.35 admits real cadence changes (accelerating from a
  /// stroll to a brisk walk moves the interval by at most ~20% per step) while
  /// excluding the half- and double-tempo intervals that irregular motion
  /// produces. At the upper bound of 1.0 the gate reproduces the old ceiling
  /// and is effectively off.
  final double offRhythmTolerance;

  /// Maximum coefficient of variation (sigma/mean) of the last
  /// `regularityRunLength - 1` step intervals.
  ///
  /// This is the "periodicity" feature from the pedometer literature, measured
  /// directly rather than by autocorrelation. An autocorrelation gate was tried
  /// here before and removed (see the README): it cost a quarter of every run,
  /// and its effect came from instability in the cadence estimate rather than
  /// from measuring periodicity at all. A coefficient of variation over a
  /// handful of intervals is O(1), needs no extra state beyond the intervals
  /// themselves, and measures exactly what it claims to.
  ///
  /// Steady human gait sits at 2-6% CV. The lower bound of 0.08 is therefore
  /// tighter than any real walk, which guarantees the optimiser can never tune
  /// this into rejecting genuine walking. The default of 0.30 is loose enough
  /// to survive a kerb or a turn. Ablated on the fixture corpus it takes three
  /// minutes of fidgeting from 285 phantom steps to 133 on its own. Most of
  /// that ground is also covered by [minVerticalShare], which is far more
  /// decisive — but this gate is what remains when the gravity estimate stops
  /// being trustworthy and that one stands aside, so it earns its place as the
  /// fallback rather than as the primary defence.
  final double maxIntervalCv;


  /// Minimum share of recent movement that must lie *along* gravity rather
  /// than across it, between 0 and 1.
  ///
  /// The only gate that looks at direction. Everything else in this vector
  /// judges the acceleration magnitude, and taking a magnitude is precisely
  /// the step that discards the difference between a body rising and falling
  /// on each footfall and a hand swinging a phone sideways. Walking is a
  /// vertical oscillation whatever pocket the phone is in; fidgeting is not.
  ///
  /// Measured over the detector's 2.5 s window, this is the widest separation
  /// of any single feature the detector has: walking sits at 0.98, hand jiggle
  /// never gets above 0.46. On its own this gate takes three minutes of
  /// fidgeting from 285 phantom steps to 6.
  ///
  /// The default is 0.45 and not higher, which matters. Walking with the phone
  /// held in a swinging hand puts a large horizontal component at half the step
  /// frequency on top of the gait signal, dragging the share down to ~0.45. At
  /// 0.50 that case stops being counted *entirely* — 60 real steps become 0 —
  /// so the tempting extra margin costs far more than it buys. 0.45 keeps a
  /// hard swing at 54 of 60 steps while still rejecting essentially all
  /// fidgeting.
  ///
  /// Set to 0 to disable, which is the right setting for a device whose
  /// accelerometer axes cannot be trusted; the detector also skips the gate on
  /// its own whenever the gravity estimate stops looking like gravity.
  final double minVerticalShare;

  /// Mean raw gyroscope magnitude, in rad/s, averaged over the analysis window.
  ///
  /// Deliberately measured on the raw signal rather than the band-passed one.
  /// Rotation about a single axis makes |omega| a *rectified* sine at twice the
  /// gait frequency, so band-passing it to 0.5-3 Hz destroys exactly the signal
  /// we want — and destroys more of it the faster you walk, which would make
  /// the gate reject jogging while accepting strolling.
  ///
  /// Below this there is no rotation, so the oscillation is vibration
  /// transmitted through a vehicle seat rather than gait.
  final double gyroMinLevel;

  /// Above this the device is being shaken or swung, not walked with.
  final double gyroMaxLevel;

  static const CalibrationParams factory = CalibrationParams();

  /// Inclusive search bounds used by both [clamped] and the optimiser.
  static const Map<String, (double, double)> bounds = {
    'thresholdSigma': (0.2, 2.0),
    'minMotionSigma': (0.05, 1.5),
    'minAmplitude': (0.1, 4.0),
    'minStepIntervalMs': (180, 400),
    'maxStepIntervalMs': (1000, 2500),
    'regularityRunLength': (2, 8),
    'offRhythmTolerance': (0.15, 1.0),
    'maxIntervalCv': (0.08, 1.0),
    'minVerticalShare': (0.0, 0.9),
    'gyroMinLevel': (0.0, 0.5),
    'gyroMaxLevel': (1.0, 8.0),
  };

  static double _clamp(String key, double v) {
    final b = bounds[key]!;
    return v.clamp(b.$1, b.$2).toDouble();
  }

  CalibrationParams clamped() => CalibrationParams(
        thresholdSigma: _clamp('thresholdSigma', thresholdSigma),
        minMotionSigma: _clamp('minMotionSigma', minMotionSigma),
        minAmplitude: _clamp('minAmplitude', minAmplitude),
        minStepIntervalMs: _clamp('minStepIntervalMs', minStepIntervalMs.toDouble()).round(),
        maxStepIntervalMs: _clamp('maxStepIntervalMs', maxStepIntervalMs.toDouble()).round(),
        regularityRunLength: _clamp('regularityRunLength', regularityRunLength.toDouble()).round(),
        offRhythmTolerance: _clamp('offRhythmTolerance', offRhythmTolerance),
        maxIntervalCv: _clamp('maxIntervalCv', maxIntervalCv),
        minVerticalShare: _clamp('minVerticalShare', minVerticalShare),
        gyroMinLevel: _clamp('gyroMinLevel', gyroMinLevel),
        gyroMaxLevel: _clamp('gyroMaxLevel', gyroMaxLevel),
      );

  CalibrationParams copyWith({
    double? thresholdSigma,
    double? minMotionSigma,
    double? minAmplitude,
    int? minStepIntervalMs,
    int? maxStepIntervalMs,
    int? regularityRunLength,
    double? offRhythmTolerance,
    double? maxIntervalCv,
    double? minVerticalShare,
    double? gyroMinLevel,
    double? gyroMaxLevel,
  }) =>
      CalibrationParams(
        thresholdSigma: thresholdSigma ?? this.thresholdSigma,
        minMotionSigma: minMotionSigma ?? this.minMotionSigma,
        minAmplitude: minAmplitude ?? this.minAmplitude,
        minStepIntervalMs: minStepIntervalMs ?? this.minStepIntervalMs,
        maxStepIntervalMs: maxStepIntervalMs ?? this.maxStepIntervalMs,
        regularityRunLength: regularityRunLength ?? this.regularityRunLength,
        offRhythmTolerance: offRhythmTolerance ?? this.offRhythmTolerance,
        maxIntervalCv: maxIntervalCv ?? this.maxIntervalCv,
        minVerticalShare: minVerticalShare ?? this.minVerticalShare,
        gyroMinLevel: gyroMinLevel ?? this.gyroMinLevel,
        gyroMaxLevel: gyroMaxLevel ?? this.gyroMaxLevel,
      );

  /// Reads/writes a named field as a double so the optimiser can sweep fields
  /// generically without a switch at every call site.
  double operator [](String key) => switch (key) {
        'thresholdSigma' => thresholdSigma,
        'minMotionSigma' => minMotionSigma,
        'minAmplitude' => minAmplitude,
        'minStepIntervalMs' => minStepIntervalMs.toDouble(),
        'maxStepIntervalMs' => maxStepIntervalMs.toDouble(),
        'regularityRunLength' => regularityRunLength.toDouble(),
        'offRhythmTolerance' => offRhythmTolerance,
        'maxIntervalCv' => maxIntervalCv,
        'minVerticalShare' => minVerticalShare,
        'gyroMinLevel' => gyroMinLevel,
        'gyroMaxLevel' => gyroMaxLevel,
        _ => throw ArgumentError('unknown parameter: $key'),
      };

  CalibrationParams withField(String key, double value) => switch (key) {
        'thresholdSigma' => copyWith(thresholdSigma: value),
        'minMotionSigma' => copyWith(minMotionSigma: value),
        'minAmplitude' => copyWith(minAmplitude: value),
        'minStepIntervalMs' => copyWith(minStepIntervalMs: value.round()),
        'maxStepIntervalMs' => copyWith(maxStepIntervalMs: value.round()),
        'regularityRunLength' => copyWith(regularityRunLength: value.round()),
        'offRhythmTolerance' => copyWith(offRhythmTolerance: value),
        'maxIntervalCv' => copyWith(maxIntervalCv: value),
        'minVerticalShare' => copyWith(minVerticalShare: value),
        'gyroMinLevel' => copyWith(gyroMinLevel: value),
        'gyroMaxLevel' => copyWith(gyroMaxLevel: value),
        _ => throw ArgumentError('unknown parameter: $key'),
      }
          .clamped();

  Map<String, dynamic> toMap() => {
        'thresholdSigma': thresholdSigma,
        'minMotionSigma': minMotionSigma,
        'minAmplitude': minAmplitude,
        'minStepIntervalMs': minStepIntervalMs,
        'maxStepIntervalMs': maxStepIntervalMs,
        'regularityRunLength': regularityRunLength,
        'offRhythmTolerance': offRhythmTolerance,
        'maxIntervalCv': maxIntervalCv,
        'minVerticalShare': minVerticalShare,
        'gyroMinLevel': gyroMinLevel,
        'gyroMaxLevel': gyroMaxLevel,
      };

  factory CalibrationParams.fromMap(Map<String, dynamic> m) => CalibrationParams(
        thresholdSigma: (m['thresholdSigma'] as num?)?.toDouble() ?? factory.thresholdSigma,
        minMotionSigma:
            (m['minMotionSigma'] as num?)?.toDouble() ?? factory.minMotionSigma,
        minAmplitude: (m['minAmplitude'] as num?)?.toDouble() ?? factory.minAmplitude,
        minStepIntervalMs: (m['minStepIntervalMs'] as num?)?.toInt() ?? factory.minStepIntervalMs,
        maxStepIntervalMs: (m['maxStepIntervalMs'] as num?)?.toInt() ?? factory.maxStepIntervalMs,
        regularityRunLength:
            (m['regularityRunLength'] as num?)?.toInt() ?? factory.regularityRunLength,
        offRhythmTolerance:
            (m['offRhythmTolerance'] as num?)?.toDouble() ?? factory.offRhythmTolerance,
        maxIntervalCv: (m['maxIntervalCv'] as num?)?.toDouble() ?? factory.maxIntervalCv,
        minVerticalShare:
            (m['minVerticalShare'] as num?)?.toDouble() ?? factory.minVerticalShare,
        gyroMinLevel: (m['gyroMinLevel'] as num?)?.toDouble() ?? factory.gyroMinLevel,
        gyroMaxLevel: (m['gyroMaxLevel'] as num?)?.toDouble() ?? factory.gyroMaxLevel,
      ).clamped();

  String toJson() => jsonEncode(toMap());

  factory CalibrationParams.fromJson(String s) =>
      CalibrationParams.fromMap(jsonDecode(s) as Map<String, dynamic>);

  /// Field names the optimiser is allowed to sweep, in the order it sweeps them.
  /// Ordered most- to least-influential so coordinate descent converges fast.
  static const List<String> tunableKeys = [
    'minMotionSigma',
    'thresholdSigma',
    'minAmplitude',
    'regularityRunLength',
    'minVerticalShare',
    'maxIntervalCv',
    'offRhythmTolerance',
    'minStepIntervalMs',
    'gyroMinLevel',
    'maxStepIntervalMs',
    'gyroMaxLevel',
  ];

  @override
  bool operator ==(Object other) =>
      other is CalibrationParams &&
      other.thresholdSigma == thresholdSigma &&
      other.minMotionSigma == minMotionSigma &&
      other.minAmplitude == minAmplitude &&
      other.minStepIntervalMs == minStepIntervalMs &&
      other.maxStepIntervalMs == maxStepIntervalMs &&
      other.regularityRunLength == regularityRunLength &&
      other.offRhythmTolerance == offRhythmTolerance &&
      other.maxIntervalCv == maxIntervalCv &&
      other.minVerticalShare == minVerticalShare &&
      other.gyroMinLevel == gyroMinLevel &&
      other.gyroMaxLevel == gyroMaxLevel;

  @override
  int get hashCode => Object.hash(thresholdSigma, minMotionSigma, minAmplitude,
      minStepIntervalMs, maxStepIntervalMs, regularityRunLength,
      offRhythmTolerance, maxIntervalCv, minVerticalShare,
      gyroMinLevel, gyroMaxLevel);

  @override
  String toString() => 'CalibrationParams(${toMap()})';
}
