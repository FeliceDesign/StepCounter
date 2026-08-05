import 'dart:isolate';
import 'dart:typed_data';

import 'activity.dart';
import 'calibration_params.dart';
import 'motion_pipeline.dart';
import 'sensor_sample.dart';

/// A recording the user labelled with what they were actually doing.
///
/// Only the manual flow produces these. Automatic windows are graded by the
/// hardware pedometer, which counts steps but has no opinion about stairs.
class ActivityLabelledSession {
  const ActivityLabelledSession({
    required this.samples,
    required this.declared,
    this.pressure = const [],
    this.id,
  });

  final List<SensorSample> samples;
  final List<PressureSample> pressure;
  final Activity declared;
  final int? id;

  /// Whether a classification counts as correct for this label.
  ///
  /// Up and down are one category to the user — the picker offers "Stairs" —
  /// so either direction satisfies a stairs label. The split still matters
  /// internally, which is why the classifier keeps it.
  bool matches(Activity actual) =>
      declared.isStairs ? actual.isStairs : actual == declared;
}

class ActivityOutcome {
  const ActivityOutcome({
    required this.params,
    required this.baselineParams,
    required this.accuracy,
    required this.baselineAccuracy,
    required this.accepted,
    required this.validated,
    required this.sessionCount,
  });

  final ActivityParams params;
  final ActivityParams baselineParams;

  /// Share of steps filed under the activity the user declared, on sessions the
  /// search never saw. 1.0 is perfect.
  final double accuracy;
  final double baselineAccuracy;

  final bool accepted;
  final bool validated;
  final int sessionCount;

  double get improvementPoints => (accuracy - baselineAccuracy) * 100;
}

/// Tunes the activity thresholds against sessions the user has labelled.
///
/// Same shape as [CalibrationOptimizer]: coordinate descent over named,
/// clamped parameters, validated on held-out sessions before anything is
/// adopted. The objective differs — share of steps classified correctly rather
/// than step-count error — because the thing being judged is a label, not a
/// number.
class ActivityOptimizer {
  static const int minSessionsForHoldout = 3;
  static const int minSessionsForAutoAdopt = 4;

  /// Required gain in percentage points before new thresholds are adopted.
  /// Below this, a change is as likely to be noise as improvement.
  static const double minImprovement = 0.03;

  /// Weighted by steps, so a long walk counts for more than a brief one.
  ///
  /// Sessions where nothing at all was detected are skipped rather than scored
  /// zero: they say something is wrong with step detection, which is the other
  /// optimiser's job, and letting them in here would push the activity
  /// thresholds around to compensate for a problem they cannot fix.
  static double accuracy(
    ActivityParams params,
    List<ActivityLabelledSession> sessions, {
    CalibrationParams stepParams = CalibrationParams.factory,
  }) {
    var correct = 0;
    var total = 0;

    for (final s in sessions) {
      final counts = MotionPipeline.replay(
        s.samples,
        pressure: s.pressure,
        params: stepParams,
        activityParams: params,
      );
      for (final e in counts.entries) {
        total += e.value;
        if (s.matches(e.key)) correct += e.value;
      }
    }
    if (total == 0) return 0;
    return correct / total;
  }

  static (List<ActivityLabelledSession>, List<ActivityLabelledSession>) split(
    List<ActivityLabelledSession> sessions,
  ) {
    if (sessions.length < minSessionsForHoldout) return (sessions, const []);
    final train = <ActivityLabelledSession>[];
    final holdout = <ActivityLabelledSession>[];
    for (var i = 0; i < sessions.length; i++) {
      (i % 3 == 2 ? holdout : train).add(sessions[i]);
    }
    return (train, holdout);
  }

  static ActivityOutcome optimize({
    required List<ActivityLabelledSession> sessions,
    ActivityParams start = ActivityParams.factory,
    CalibrationParams stepParams = CalibrationParams.factory,
    int rounds = 3,
    int candidatesPerRound = 7,
    bool requireHoldout = false,
  }) {
    if (sessions.isEmpty) {
      return ActivityOutcome(
        params: start,
        baselineParams: start,
        accuracy: 0,
        baselineAccuracy: 0,
        accepted: false,
        validated: false,
        sessionCount: 0,
      );
    }

    final (train, holdout) = split(sessions);
    final validated = holdout.isNotEmpty;

    var best = start.clamped();
    var bestAccuracy = accuracy(best, train, stepParams: stepParams);

    for (var round = 0; round < rounds; round++) {
      for (final key in ActivityParams.tunableKeys) {
        for (final v in _candidates(key, best[key], round, candidatesPerRound)) {
          final trial = best.withField(key, v);
          if (trial == best) continue;
          final a = accuracy(trial, train, stepParams: stepParams);
          if (a > bestAccuracy) {
            bestAccuracy = a;
            best = trial;
          }
        }
      }
    }

    final scoringSet = validated ? holdout : train;
    final finalAccuracy = accuracy(best, scoringSet, stepParams: stepParams);
    final baselineAccuracy = accuracy(start, scoringSet, stepParams: stepParams);

    // Mirrors the step optimiser's guardrails: the search must have moved, and
    // the gain must clear a floor. Without the first, a search that converged
    // back to its starting point reports itself as an improvement.
    final improved =
        best != start && finalAccuracy >= baselineAccuracy + minImprovement;
    final enough =
        !requireHoldout || sessions.length >= minSessionsForAutoAdopt;
    final accepted = improved && enough && (validated || !requireHoldout);

    return ActivityOutcome(
      params: best,
      baselineParams: start,
      accuracy: finalAccuracy,
      baselineAccuracy: baselineAccuracy,
      accepted: accepted,
      validated: validated,
      sessionCount: sessions.length,
    );
  }

  static List<double> _candidates(
    String key,
    double current,
    int round,
    int count,
  ) {
    final (lo, hi) = ActivityParams.bounds[key]!;
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
    return [for (var i = 0; i < count; i++) from + step * i];
  }
}

/// Serialisable payload for running activity calibration off the UI thread.
class ActivityCalibrationJob {
  const ActivityCalibrationJob({
    required this.packedSessions,
    required this.declaredActivities,
    required this.startParamsJson,
    required this.stepParamsJson,
    this.packedPressure = const [],
    this.requireHoldout = false,
  });

  final List<Uint8List> packedSessions;
  final List<Uint8List?> packedPressure;
  final List<String> declaredActivities;
  final String startParamsJson;
  final String stepParamsJson;
  final bool requireHoldout;
}

Future<ActivityOutcome> runActivityCalibrationInIsolate(
  ActivityCalibrationJob job,
) {
  return Isolate.run(() {
    final sessions = <ActivityLabelledSession>[];
    for (var i = 0; i < job.packedSessions.length; i++) {
      final pressure =
          i < job.packedPressure.length ? job.packedPressure[i] : null;
      sessions.add(ActivityLabelledSession(
        samples: SensorSample.unpack(job.packedSessions[i]),
        pressure:
            pressure == null ? const [] : PressureSample.unpack(pressure),
        declared: Activity.fromId(job.declaredActivities[i]),
      ));
    }
    return ActivityOptimizer.optimize(
      sessions: sessions,
      start: ActivityParams.fromJson(job.startParamsJson),
      stepParams: CalibrationParams.fromJson(job.stepParamsJson),
      requireHoldout: job.requireHoldout,
    );
  });
}
