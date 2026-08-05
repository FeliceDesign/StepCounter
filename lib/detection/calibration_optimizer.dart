import 'dart:isolate';
import 'dart:typed_data';

import 'calibration_params.dart';
import 'activity.dart';
import 'motion_pipeline.dart';
import 'sensor_sample.dart';

/// A recorded motion session with a known step count.
///
/// Labels come from two places: the user typing what they actually walked in
/// the Test & Recalibrate flow, and the device's hardware step counter grading
/// us automatically in the background. Both produce the same shape, so the
/// optimiser does not care which it is looking at.
class LabelledSession {
  const LabelledSession({
    required this.samples,
    required this.actualSteps,
    this.pressure = const [],
    this.id,
  });

  final List<SensorSample> samples;
  final int actualSteps;

  /// Empty when the recording device had no barometer.
  final List<PressureSample> pressure;

  final int? id;
}

/// Result of scoring one parameter vector against a set of sessions.
class CalibrationEvaluation {
  const CalibrationEvaluation({
    required this.error,
    required this.detected,
    required this.actual,
  });

  /// Mean normalised absolute error. 0 is perfect.
  final double error;
  final List<int> detected;
  final List<int> actual;

  int get totalDetected => detected.fold(0, (a, b) => a + b);
  int get totalActual => actual.fold(0, (a, b) => a + b);
}

/// Outcome of a full optimisation run, including everything the UI needs to
/// explain to the user what changed and why it was or was not adopted.
class CalibrationOutcome {
  const CalibrationOutcome({
    required this.params,
    required this.baselineParams,
    required this.trainError,
    required this.holdoutError,
    required this.baselineHoldoutError,
    required this.accepted,
    required this.validated,
    required this.sessionCount,
  });

  final CalibrationParams params;
  final CalibrationParams baselineParams;
  final double trainError;

  /// Error of the tuned parameters on sessions the optimiser never saw.
  final double holdoutError;

  /// Error of the *previous* parameters on those same held-out sessions.
  /// The comparison between these two is the entire basis for adoption.
  final double baselineHoldoutError;

  final bool accepted;

  /// False when there were too few sessions to hold any back, so the reported
  /// improvement is measured on data the optimiser fitted to. The manual flow
  /// surfaces this to the user rather than hiding it.
  final bool validated;

  final int sessionCount;

  double get improvementPercent => baselineHoldoutError <= 0
      ? 0
      : ((baselineHoldoutError - holdoutError) / baselineHoldoutError) * 100;
}

class CalibrationOptimizer {
  /// Minimum sessions before a train/holdout split is meaningful.
  static const int minSessionsForHoldout = 3;

  /// Automatic calibration will not adopt anything below this many labelled
  /// windows, regardless of how good the error looks.
  static const int minSessionsForAutoAdopt = 6;

  /// Required relative improvement on held-out data before new parameters are
  /// adopted. Small wins are usually noise, and churning the detector's
  /// behaviour for noise makes the app feel unpredictable.
  static const double minRelativeImprovement = 0.02;

  /// Normalised per-session error.
  ///
  /// Dividing by the actual count would make a 2-step error on a 10-step test
  /// dominate a 20-step error on a 2000-step walk, and dividing by nothing
  /// would do the reverse. The floor of 10 keeps short sessions meaningful
  /// without letting them overwhelm the objective, and keeps a zero-step
  /// window (which the automatic labeller does produce) from dividing by zero.
  static double sessionError(int detected, int actual) =>
      (detected - actual).abs() / (actual < 10 ? 10 : actual);

  static CalibrationEvaluation evaluate(
    CalibrationParams params,
    List<LabelledSession> sessions, {
    ActivityParams activityParams = ActivityParams.factory,
  }) {
    if (sessions.isEmpty) {
      return const CalibrationEvaluation(error: 0, detected: [], actual: []);
    }
    final detected = <int>[];
    final actual = <int>[];
    var sum = 0.0;
    for (final s in sessions) {
      final d = MotionPipeline.replayTotal(
        s.samples,
        pressure: s.pressure,
        params: params,
        activityParams: activityParams,
      );
      detected.add(d);
      actual.add(s.actualSteps);
      sum += sessionError(d, s.actualSteps);
    }
    return CalibrationEvaluation(
      error: sum / sessions.length,
      detected: detected,
      actual: actual,
    );
  }

  /// Deterministic train/holdout split.
  ///
  /// Every third session is held out. Deliberately index-based rather than
  /// randomly shuffled so that re-running calibration on the same corpus gives
  /// the same answer — a user who taps "recalibrate" twice should not see two
  /// different results.
  static (List<LabelledSession> train, List<LabelledSession> holdout) split(
    List<LabelledSession> sessions,
  ) {
    if (sessions.length < minSessionsForHoldout) {
      return (sessions, const []);
    }
    final train = <LabelledSession>[];
    final holdout = <LabelledSession>[];
    for (var i = 0; i < sessions.length; i++) {
      (i % 3 == 2 ? holdout : train).add(sessions[i]);
    }
    return (train, holdout);
  }

  /// Coordinate descent over the tunable parameters.
  ///
  /// Deliberately not a learned model. A handful of interpretable numbers can
  /// be clamped to physiological ranges, shown to the user, diffed against the
  /// previous version, and reverted — none of which is true of an opaque set of
  /// weights. It also converges in well under a second on a phone.
  static CalibrationOutcome optimize({
    required List<LabelledSession> sessions,
    CalibrationParams start = CalibrationParams.factory,
    int rounds = 3,
    int candidatesPerRound = 7,
    bool requireHoldout = false,
  }) {
    if (sessions.isEmpty) {
      return CalibrationOutcome(
        params: start,
        baselineParams: start,
        trainError: 0,
        holdoutError: 0,
        baselineHoldoutError: 0,
        accepted: false,
        validated: false,
        sessionCount: 0,
      );
    }

    final (train, holdout) = split(sessions);
    final validated = holdout.isNotEmpty;

    var best = start.clamped();
    var bestError = evaluate(best, train).error;

    for (var round = 0; round < rounds; round++) {
      for (final key in CalibrationParams.tunableKeys) {
        for (final v in _candidates(key, best[key], round, candidatesPerRound)) {
          final trial = best.withField(key, v);
          if (trial == best) continue;
          final e = evaluate(trial, train).error;
          if (e < bestError) {
            bestError = e;
            best = trial;
          }
        }
      }
    }

    // Score both old and new on data the optimiser never touched.
    final scoringSet = validated ? holdout : train;
    final holdoutError = evaluate(best, scoringSet).error;
    final baselineHoldoutError = evaluate(start, scoringSet).error;

    // All three conditions matter. Without the first, a search that converged
    // back to the starting point reports itself as an improvement; without the
    // second, an already-perfect baseline satisfies `0 <= 0 * 0.98` and the app
    // proudly adopts an identical parameter set.
    final improved = best != start &&
        baselineHoldoutError > 0 &&
        holdoutError <= baselineHoldoutError * (1 - minRelativeImprovement);
    final enoughSessions =
        !requireHoldout || sessions.length >= minSessionsForAutoAdopt;
    final accepted = improved && enoughSessions && (validated || !requireHoldout);

    return CalibrationOutcome(
      params: best,
      baselineParams: start,
      trainError: bestError,
      holdoutError: holdoutError,
      baselineHoldoutError: baselineHoldoutError,
      accepted: accepted,
      validated: validated,
      sessionCount: sessions.length,
    );
  }

  /// Candidate values for one parameter.
  ///
  /// Round 0 sweeps the full legal range so the search cannot get stuck in a
  /// local minimum near the starting point; later rounds narrow around the
  /// current best to refine it.
  static List<double> _candidates(
    String key,
    double current,
    int round,
    int count,
  ) {
    final (lo, hi) = CalibrationParams.bounds[key]!;
    double from, to;
    if (round == 0) {
      from = lo;
      to = hi;
    } else {
      final width = (hi - lo) / (3 * round + 1);
      from = (current - width).clamp(lo, hi);
      to = (current + width).clamp(lo, hi);
    }
    if (to <= from) return [current];

    final step = (to - from) / (count - 1);
    final out = <double>[];
    for (var i = 0; i < count; i++) {
      final v = from + step * i;
      if (!out.any((x) => (x - v).abs() < 1e-9)) out.add(v);
    }
    return out;
  }
}

/// Serialisable payload for running optimisation off the UI thread.
///
/// Sessions are shipped as packed float32 blobs rather than as object lists so
/// the isolate hop copies a few hundred KB of bytes instead of walking hundreds
/// of thousands of Dart objects.
class CalibrationJob {
  const CalibrationJob({
    required this.packedSessions,
    required this.actualSteps,
    required this.startParamsJson,
    this.packedPressure = const [],
    this.requireHoldout = false,
  });

  final List<Uint8List> packedSessions;
  final List<int> actualSteps;

  /// Parallel to [packedSessions]; entries are null for sessions recorded on a
  /// device without a barometer.
  final List<Uint8List?> packedPressure;

  final String startParamsJson;
  final bool requireHoldout;
}

/// Runs [CalibrationOptimizer.optimize] in a background isolate.
///
/// Replaying tens of sessions across ~150 parameter combinations is hundreds of
/// milliseconds of solid CPU. On the UI isolate that is a visible stutter right
/// at the moment the user is watching for their result.
Future<CalibrationOutcome> runCalibrationInIsolate(CalibrationJob job) {
  return Isolate.run(() {
    final sessions = <LabelledSession>[];
    for (var i = 0; i < job.packedSessions.length; i++) {
      final packedPressure =
          i < job.packedPressure.length ? job.packedPressure[i] : null;
      sessions.add(LabelledSession(
        samples: SensorSample.unpack(job.packedSessions[i]),
        actualSteps: job.actualSteps[i],
        pressure: packedPressure == null
            ? const []
            : PressureSample.unpack(packedPressure),
      ));
    }
    return CalibrationOptimizer.optimize(
      sessions: sessions,
      start: CalibrationParams.fromJson(job.startParamsJson),
      requireHoldout: job.requireHoldout,
    );
  });
}
