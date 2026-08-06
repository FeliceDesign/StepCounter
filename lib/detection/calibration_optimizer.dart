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

  /// How far one calibration may move a parameter, as a fraction of that
  /// parameter's full legal range, measured from where the search started.
  ///
  /// Without this, round 0 swept the entire legal range of every parameter, so
  /// a corpus of a few short walks could move the motion floor from 0.35 to
  /// 1.5 in a single adoption. That is what made proposed changes look wild,
  /// and wild changes are exactly the ones a user cannot judge.
  ///
  /// It bounds the size of one step, not what is reachable overall: parameters
  /// keep moving across successive calibrations, each of which the user sees
  /// and can decline.
  static const double trustRegionFraction = 0.35;

  /// Weight on distance from the anchor parameters, in units of normalised
  /// error.
  ///
  /// A tie-breaker toward the status quo. A candidate has to beat the
  /// incumbent by more than this times how far it moved, so a 0.1% error win
  /// cannot buy halving a threshold. Small enough that a genuine improvement
  /// still wins easily.
  static const double regularisationLambda = 0.02;

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
  /// Mean absolute distance between two parameter vectors, with each field
  /// normalised by its own legal range so they are commensurable.
  static double paramDistance(CalibrationParams a, CalibrationParams b) {
    var sum = 0.0;
    for (final key in CalibrationParams.tunableKeys) {
      final (lo, hi) = CalibrationParams.bounds[key]!;
      final span = hi - lo;
      if (span <= 0) continue;
      sum += (a[key] - b[key]).abs() / span;
    }
    return sum / CalibrationParams.tunableKeys.length;
  }

  static CalibrationOutcome optimize({
    required List<LabelledSession> sessions,
    CalibrationParams start = CalibrationParams.factory,
    int rounds = 3,
    int candidatesPerRound = 7,
    bool requireHoldout = false,
    int minSessions = 0,
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

    // Descent is run from the current parameters and again from the factory
    // ones, keeping whichever ends up better.
    //
    // Coordinate descent moves one parameter at a time, so it cannot escape a
    // corner where two parameters are jointly wrong: if the motion floor and
    // the amplitude floor are both too strict, relaxing either alone still
    // detects nothing, no single move improves the score, and the search sits
    // there forever. Restarting from a known-sane point costs one extra pass
    // and makes a badly calibrated device recoverable.
    // Each seed carries its own anchor, and that is what keeps the trust
    // region from trapping a badly calibrated device.
    //
    // The current-seeded pass is bounded around wherever the user is now, so
    // one adoption cannot fling a parameter across its range. The
    // factory-seeded pass is bounded around the factory vector instead — so
    // the neighbourhood of the defaults is always reachable in a single
    // adoption, however far the incumbent has drifted. What is bounded is
    // large moves toward nowhere in particular, never the route home.
    var best = start.clamped();

    for (final seed in <CalibrationParams>{
      start.clamped(),
      CalibrationParams.factory,
    }) {
      final anchor = seed;
      var current = seed;
      var currentScore = _score(current, train, anchor);

      for (var round = 0; round < rounds; round++) {
        for (final key in CalibrationParams.tunableKeys) {
          for (final v in _candidates(
              key, current[key], anchor[key], round, candidatesPerRound)) {
            final trial = current.withField(key, v);
            if (trial == current) continue;
            final e = _score(trial, train, anchor);
            if (e < currentScore) {
              currentScore = e;
              current = trial;
            }
          }
        }
      }

      // Compared on unregularised error, because the two seeds have different
      // anchors and their penalties are therefore not comparable.
      if (evaluate(current, train).error < evaluate(best, train).error) {
        best = current;
      }
    }
    final bestError = evaluate(best, train).error;

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
    final enoughSessions = sessions.length >= minSessions;
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

  /// The training error, plus a small penalty for how far the candidate has
  /// moved from [anchor].
  ///
  /// Only the *search* is regularised. The errors reported to the user, and
  /// the ones the adoption decision is made on, stay pure — see [optimize].
  /// A number labelled "how wrong will the app be" must mean that and nothing
  /// else.
  static double _score(
    CalibrationParams p,
    List<LabelledSession> train,
    CalibrationParams anchor,
  ) =>
      evaluate(p, train).error +
      regularisationLambda * paramDistance(p, anchor);

  /// Candidate values for one parameter.
  ///
  /// Round 0 sweeps the whole trust region around [anchor] so the search
  /// cannot get stuck beside its starting point; later rounds narrow around
  /// the current best to refine it. Every round is clipped to the trust
  /// region, so no sequence of rounds can escape it.
  static List<double> _candidates(
    String key,
    double current,
    double anchor,
    int round,
    int count,
  ) {
    final (lo, hi) = CalibrationParams.bounds[key]!;
    final reach = (hi - lo) * trustRegionFraction;
    final trustLo = (anchor - reach).clamp(lo, hi).toDouble();
    final trustHi = (anchor + reach).clamp(lo, hi).toDouble();

    double from, to;
    if (round == 0) {
      from = trustLo;
      to = trustHi;
    } else {
      final width = (hi - lo) / (3 * round + 1);
      from = (current - width).clamp(trustLo, trustHi).toDouble();
      to = (current + width).clamp(trustLo, trustHi).toDouble();
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
    this.minSessions = 0,
  });

  final List<Uint8List> packedSessions;
  final List<int> actualSteps;

  /// Parallel to [packedSessions]; entries are null for sessions recorded on a
  /// device without a barometer.
  final List<Uint8List?> packedPressure;

  final String startParamsJson;
  final bool requireHoldout;

  /// Smallest corpus this job may adopt from. See [CalibrationOptimizer.optimize].
  final int minSessions;
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
      minSessions: job.minSessions,
    );
  });
}
