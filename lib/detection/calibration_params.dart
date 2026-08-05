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
    this.minAmplitude = 0.6,
    this.minStepIntervalMs = 250,
    this.maxStepIntervalMs = 2000,
    this.regularityRunLength = 4,
    this.gyroMinLevel = 0.03,
    this.gyroMaxLevel = 5.0,
  });

  /// `k` in the adaptive threshold `T = mean + k * stddev`.
  final double thresholdSigma;

  /// Minimum valley-to-peak amplitude of the band-passed signal, in m/s².
  final double minAmplitude;

  /// Faster than this between two steps is not human gait — it is a bounce in
  /// the signal from a single footfall.
  final int minStepIntervalMs;

  /// Slower than this and we treat the rhythm as broken rather than as a very
  /// slow step, so the regularity streak restarts.
  final int maxStepIntervalMs;

  /// How many consecutive rhythmic candidates are required before any of them
  /// are counted. This is the primary false-positive defence.
  final int regularityRunLength;

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
    'minAmplitude': (0.1, 3.0),
    'minStepIntervalMs': (180, 400),
    'maxStepIntervalMs': (1000, 2500),
    'regularityRunLength': (2, 8),
    'gyroMinLevel': (0.0, 0.5),
    'gyroMaxLevel': (1.0, 8.0),
  };

  static double _clamp(String key, double v) {
    final b = bounds[key]!;
    return v.clamp(b.$1, b.$2).toDouble();
  }

  CalibrationParams clamped() => CalibrationParams(
        thresholdSigma: _clamp('thresholdSigma', thresholdSigma),
        minAmplitude: _clamp('minAmplitude', minAmplitude),
        minStepIntervalMs: _clamp('minStepIntervalMs', minStepIntervalMs.toDouble()).round(),
        maxStepIntervalMs: _clamp('maxStepIntervalMs', maxStepIntervalMs.toDouble()).round(),
        regularityRunLength: _clamp('regularityRunLength', regularityRunLength.toDouble()).round(),
        gyroMinLevel: _clamp('gyroMinLevel', gyroMinLevel),
        gyroMaxLevel: _clamp('gyroMaxLevel', gyroMaxLevel),
      );

  CalibrationParams copyWith({
    double? thresholdSigma,
    double? minAmplitude,
    int? minStepIntervalMs,
    int? maxStepIntervalMs,
    int? regularityRunLength,
    double? gyroMinLevel,
    double? gyroMaxLevel,
  }) =>
      CalibrationParams(
        thresholdSigma: thresholdSigma ?? this.thresholdSigma,
        minAmplitude: minAmplitude ?? this.minAmplitude,
        minStepIntervalMs: minStepIntervalMs ?? this.minStepIntervalMs,
        maxStepIntervalMs: maxStepIntervalMs ?? this.maxStepIntervalMs,
        regularityRunLength: regularityRunLength ?? this.regularityRunLength,
        gyroMinLevel: gyroMinLevel ?? this.gyroMinLevel,
        gyroMaxLevel: gyroMaxLevel ?? this.gyroMaxLevel,
      );

  /// Reads/writes a named field as a double so the optimiser can sweep fields
  /// generically without a switch at every call site.
  double operator [](String key) => switch (key) {
        'thresholdSigma' => thresholdSigma,
        'minAmplitude' => minAmplitude,
        'minStepIntervalMs' => minStepIntervalMs.toDouble(),
        'maxStepIntervalMs' => maxStepIntervalMs.toDouble(),
        'regularityRunLength' => regularityRunLength.toDouble(),
        'gyroMinLevel' => gyroMinLevel,
        'gyroMaxLevel' => gyroMaxLevel,
        _ => throw ArgumentError('unknown parameter: $key'),
      };

  CalibrationParams withField(String key, double value) => switch (key) {
        'thresholdSigma' => copyWith(thresholdSigma: value),
        'minAmplitude' => copyWith(minAmplitude: value),
        'minStepIntervalMs' => copyWith(minStepIntervalMs: value.round()),
        'maxStepIntervalMs' => copyWith(maxStepIntervalMs: value.round()),
        'regularityRunLength' => copyWith(regularityRunLength: value.round()),
        'gyroMinLevel' => copyWith(gyroMinLevel: value),
        'gyroMaxLevel' => copyWith(gyroMaxLevel: value),
        _ => throw ArgumentError('unknown parameter: $key'),
      }
          .clamped();

  Map<String, dynamic> toMap() => {
        'thresholdSigma': thresholdSigma,
        'minAmplitude': minAmplitude,
        'minStepIntervalMs': minStepIntervalMs,
        'maxStepIntervalMs': maxStepIntervalMs,
        'regularityRunLength': regularityRunLength,
        'gyroMinLevel': gyroMinLevel,
        'gyroMaxLevel': gyroMaxLevel,
      };

  factory CalibrationParams.fromMap(Map<String, dynamic> m) => CalibrationParams(
        thresholdSigma: (m['thresholdSigma'] as num?)?.toDouble() ?? factory.thresholdSigma,
        minAmplitude: (m['minAmplitude'] as num?)?.toDouble() ?? factory.minAmplitude,
        minStepIntervalMs: (m['minStepIntervalMs'] as num?)?.toInt() ?? factory.minStepIntervalMs,
        maxStepIntervalMs: (m['maxStepIntervalMs'] as num?)?.toInt() ?? factory.maxStepIntervalMs,
        regularityRunLength:
            (m['regularityRunLength'] as num?)?.toInt() ?? factory.regularityRunLength,
        gyroMinLevel: (m['gyroMinLevel'] as num?)?.toDouble() ?? factory.gyroMinLevel,
        gyroMaxLevel: (m['gyroMaxLevel'] as num?)?.toDouble() ?? factory.gyroMaxLevel,
      ).clamped();

  String toJson() => jsonEncode(toMap());

  factory CalibrationParams.fromJson(String s) =>
      CalibrationParams.fromMap(jsonDecode(s) as Map<String, dynamic>);

  /// Field names the optimiser is allowed to sweep, in the order it sweeps them.
  /// Ordered most- to least-influential so coordinate descent converges fast.
  static const List<String> tunableKeys = [
    'thresholdSigma',
    'minAmplitude',
    'regularityRunLength',
    'minStepIntervalMs',
    'gyroMinLevel',
    'maxStepIntervalMs',
    'gyroMaxLevel',
  ];

  @override
  bool operator ==(Object other) =>
      other is CalibrationParams &&
      other.thresholdSigma == thresholdSigma &&
      other.minAmplitude == minAmplitude &&
      other.minStepIntervalMs == minStepIntervalMs &&
      other.maxStepIntervalMs == maxStepIntervalMs &&
      other.regularityRunLength == regularityRunLength &&
      other.gyroMinLevel == gyroMinLevel &&
      other.gyroMaxLevel == gyroMaxLevel;

  @override
  int get hashCode => Object.hash(thresholdSigma, minAmplitude, minStepIntervalMs,
      maxStepIntervalMs, regularityRunLength, gyroMinLevel, gyroMaxLevel);

  @override
  String toString() => 'CalibrationParams(${toMap()})';
}
