import 'package:flutter_test/flutter_test.dart';
import 'package:stepcounter/detection/activity.dart';
import 'package:stepcounter/detection/activity_optimizer.dart';
import 'package:stepcounter/detection/calibration_params.dart';
import 'package:stepcounter/detection/sensor_sample.dart';

import 'fixtures/gait_fixtures.dart';

/// Stair walks recorded on a user who climbs unusually slowly.
///
/// At 0.05 m/s the vertical motion is real but sits below the factory
/// threshold of 0.08, so the classifier calls these level walking. A working
/// optimiser should notice the labels disagree and lower the threshold.
List<ActivityLabelledSession> slowClimberCorpus({int count = 9}) {
  return List.generate(count, (i) {
    final samples = GaitFixtures.walk(
      steps: 30,
      stepFrequencyHz: 1.4 + (i % 3) * 0.1,
      seed: 300 + i,
    );
    return ActivityLabelledSession(
      id: i,
      samples: samples,
      declared: Activity.stairsUp,
      pressure: GaitFixtures.pressureRamp(
        durationSeconds: samples.last.tNs / 1e9,
        verticalSpeed: 0.05,
        seed: 400 + i,
      ),
    );
  });
}

/// Ordinary walks the factory thresholds already label correctly.
List<ActivityLabelledSession> healthyCorpus({int count = 9}) {
  return List.generate(count, (i) {
    return ActivityLabelledSession(
      id: i,
      samples: GaitFixtures.walk(steps: 30, seed: 500 + i),
      declared: Activity.walking,
    );
  });
}

void main() {
  group('accuracy', () {
    test('is 1.0 when every step is labelled as declared', () {
      final a = ActivityOptimizer.accuracy(
        ActivityParams.factory,
        healthyCorpus(count: 3),
      );
      expect(a, closeTo(1.0, 0.001));
    });

    test('is low when the classifier disagrees with the label', () {
      final a = ActivityOptimizer.accuracy(
        ActivityParams.factory,
        slowClimberCorpus(count: 3),
      );
      expect(a, lessThan(0.5));
    });

    test('an empty corpus scores zero rather than dividing by zero', () {
      expect(ActivityOptimizer.accuracy(ActivityParams.factory, const []), 0);
    });

    test('either stair direction satisfies a stairs label', () {
      const up = ActivityLabelledSession(
        samples: [],
        declared: Activity.stairsUp,
      );
      expect(up.matches(Activity.stairsUp), isTrue);
      expect(up.matches(Activity.stairsDown), isTrue);
      expect(up.matches(Activity.walking), isFalse);
    });

    test('a walking label is not satisfied by running', () {
      const walking = ActivityLabelledSession(
        samples: [],
        declared: Activity.walking,
      );
      expect(walking.matches(Activity.walking), isTrue);
      expect(walking.matches(Activity.running), isFalse);
    });
  });

  group('optimisation', () {
    test('learns a slower climber than the factory threshold assumes', () {
      final corpus = slowClimberCorpus();
      final outcome = ActivityOptimizer.optimize(sessions: corpus);

      expect(outcome.accepted, isTrue);
      expect(outcome.validated, isTrue);
      expect(outcome.accuracy, greaterThan(outcome.baselineAccuracy));
      expect(
        outcome.params.stairsAltitudeRateMin,
        lessThan(ActivityParams.factory.stairsAltitudeRateMin),
        reason: 'the fix for a slow climber is a lower vertical-speed floor',
      );
    });

    test('leaves already-correct thresholds alone', () {
      final outcome = ActivityOptimizer.optimize(sessions: healthyCorpus());
      expect(outcome.accepted, isFalse);
    });

    test('never returns parameters outside the legal bounds', () {
      final outcome = ActivityOptimizer.optimize(sessions: slowClimberCorpus());
      for (final key in ActivityParams.tunableKeys) {
        final (lo, hi) = ActivityParams.bounds[key]!;
        expect(outcome.params[key], greaterThanOrEqualTo(lo));
        expect(outcome.params[key], lessThanOrEqualTo(hi));
      }
      expect(outcome.params, outcome.params.clamped());
    });

    test('is deterministic', () {
      final corpus = slowClimberCorpus();
      final a = ActivityOptimizer.optimize(sessions: corpus);
      final b = ActivityOptimizer.optimize(sessions: corpus);
      expect(a.params, b.params);
      expect(a.accuracy, b.accuracy);
    });

    test('an empty corpus is a no-op', () {
      final outcome = ActivityOptimizer.optimize(sessions: const []);
      expect(outcome.accepted, isFalse);
      expect(outcome.params, ActivityParams.factory);
    });

    test('holds back every third session', () {
      final (train, holdout) = ActivityOptimizer.split(slowClimberCorpus());
      expect(train.length, 6);
      expect(holdout.length, 3);
      final trainIds = train.map((s) => s.id).toSet();
      expect(holdout.every((s) => !trainIds.contains(s.id)), isTrue);
    });
  });

  group('guardrails', () {
    test('refuses automatic adoption below the session floor', () {
      final outcome = ActivityOptimizer.optimize(
        sessions: slowClimberCorpus(count: 3),
        requireHoldout: true,
      );
      expect(outcome.sessionCount,
          lessThan(ActivityOptimizer.minSessionsForAutoAdopt));
      expect(outcome.accepted, isFalse);
    });

    test('an unvalidated run is never auto-adopted', () {
      final outcome = ActivityOptimizer.optimize(
        sessions: slowClimberCorpus(count: 2),
        requireHoldout: true,
      );
      expect(outcome.validated, isFalse);
      expect(outcome.accepted, isFalse);
    });

    test('adopts once there is enough labelled evidence', () {
      final outcome = ActivityOptimizer.optimize(
        sessions: slowClimberCorpus(count: 9),
        requireHoldout: true,
      );
      expect(outcome.accepted, isTrue);
    });

    test('improvement is measured against the previous thresholds', () {
      const previous = ActivityParams(stairsAltitudeRateMin: 0.28);
      final outcome = ActivityOptimizer.optimize(
        sessions: slowClimberCorpus(),
        start: previous,
      );
      expect(outcome.baselineParams, previous);
      expect(outcome.accepted, isTrue);
    });
  });

  group('isolate execution', () {
    test('produces the same outcome as running inline', () async {
      final corpus = slowClimberCorpus(count: 6);
      final inline = ActivityOptimizer.optimize(sessions: corpus);

      final outcome =
          await runActivityCalibrationInIsolate(ActivityCalibrationJob(
        packedSessions:
            corpus.map((s) => SensorSample.pack(s.samples)).toList(),
        packedPressure:
            corpus.map((s) => PressureSample.pack(s.pressure)).toList(),
        declaredActivities: corpus.map((s) => s.declared.id).toList(),
        startParamsJson: ActivityParams.factory.toJson(),
        stepParamsJson: const CalibrationParams().toJson(),
      ));

      expect(outcome.params, inline.params);
      expect(outcome.accepted, inline.accepted);
    });
  });
}
