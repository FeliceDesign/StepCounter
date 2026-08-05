import 'package:flutter_test/flutter_test.dart';
import 'package:stepcounter/detection/calibration_optimizer.dart';
import 'package:stepcounter/detection/calibration_params.dart';
import 'package:stepcounter/detection/sensor_sample.dart';
import 'package:stepcounter/detection/step_detector.dart';

import 'fixtures/gait_fixtures.dart';

/// Parameters far stricter than anyone should ship, used as a starting point so
/// the optimiser has a real improvement to find.
///
/// The corpus below is genuine walking, so the factory settings already handle
/// it; without a deliberately bad baseline there would be nothing to recover
/// and the guardrails would correctly refuse to change anything.
const overStrict = CalibrationParams(minAmplitude: 3.2, minMotionSigma: 1.2);

/// Real but quiet walking: a light-footed walker, or a phone in a loose coat
/// pocket. Weak enough that over-strict thresholds miss it, strong enough that
/// counting it is unambiguously correct.
List<LabelledSession> weakGaitCorpus({int count = 9, int steps = 20}) {
  return List.generate(count, (i) {
    return LabelledSession(
      id: i,
      actualSteps: steps,
      samples: GaitFixtures.walk(
        steps: steps,
        amplitude: 0.9,
        gyroAmplitude: 0.3,
        stepFrequencyHz: 1.6 + (i % 3) * 0.15,
        seed: 100 + i,
      ),
    );
  });
}

/// Walks the factory parameters already handle well.
List<LabelledSession> healthyCorpus({int count = 9, int steps = 25}) {
  return List.generate(count, (i) {
    final samples = GaitFixtures.walk(
      steps: steps,
      stepFrequencyHz: 1.7 + (i % 3) * 0.2,
      seed: 200 + i,
    );
    return LabelledSession(
      id: i,
      // Label with what the factory detector actually sees, so the corpus is
      // genuinely already-solved rather than merely close.
      actualSteps: StepDetector.countSteps(samples),
      samples: samples,
    );
  });
}

void main() {
  group('error metric', () {
    test('is zero on an exact match', () {
      expect(CalibrationOptimizer.sessionError(50, 50), 0);
    });

    test('normalises by the actual count', () {
      expect(CalibrationOptimizer.sessionError(55, 50), closeTo(0.1, 1e-9));
      expect(CalibrationOptimizer.sessionError(550, 500), closeTo(0.1, 1e-9));
    });

    test('a zero-step window does not divide by zero', () {
      expect(CalibrationOptimizer.sessionError(3, 0), closeTo(0.3, 1e-9));
      expect(CalibrationOptimizer.sessionError(0, 0), 0);
    });
  });

  group('holdout split', () {
    test('holds back roughly a third', () {
      final sessions = weakGaitCorpus(count: 9);
      final (train, holdout) = CalibrationOptimizer.split(sessions);
      expect(train.length, 6);
      expect(holdout.length, 3);
    });

    test('is deterministic — recalibrating twice gives the same split', () {
      final sessions = weakGaitCorpus(count: 9);
      final a = CalibrationOptimizer.split(sessions).$2.map((s) => s.id).toList();
      final b = CalibrationOptimizer.split(sessions).$2.map((s) => s.id).toList();
      expect(a, b);
    });

    test('train and holdout do not overlap', () {
      final sessions = weakGaitCorpus(count: 9);
      final (train, holdout) = CalibrationOptimizer.split(sessions);
      final trainIds = train.map((s) => s.id).toSet();
      for (final h in holdout) {
        expect(trainIds.contains(h.id), isFalse);
      }
    });

    test('too few sessions means no holdout at all', () {
      final (train, holdout) = CalibrationOptimizer.split(weakGaitCorpus(count: 2));
      expect(train.length, 2);
      expect(holdout, isEmpty);
    });
  });

  group('optimisation', () {
    test('recovers steps the factory parameters miss', () {
      final corpus = weakGaitCorpus();

      final before = CalibrationOptimizer.evaluate(overStrict, corpus);
      expect(before.totalDetected, lessThan(before.totalActual ~/ 2),
          reason: 'fixture should genuinely defeat the factory parameters');

      final outcome =
          CalibrationOptimizer.optimize(sessions: corpus, start: overStrict);

      expect(outcome.accepted, isTrue);
      expect(outcome.validated, isTrue);
      expect(outcome.holdoutError, lessThan(outcome.baselineHoldoutError));
      expect(outcome.improvementPercent, greaterThan(0));

      final after = CalibrationOptimizer.evaluate(outcome.params, corpus);
      expect(after.totalDetected, greaterThan(before.totalDetected));
      expect(after.error, lessThan(before.error));
    });

    test('leaves already-good parameters alone', () {
      final outcome = CalibrationOptimizer.optimize(sessions: healthyCorpus());
      // Nothing meaningful to gain, so the guardrail should refuse to churn.
      expect(outcome.accepted, isFalse);
    });

    test('never returns parameters outside the legal bounds', () {
      final outcome = CalibrationOptimizer.optimize(
          sessions: weakGaitCorpus(), start: overStrict);
      final p = outcome.params;
      for (final key in CalibrationParams.tunableKeys) {
        final (lo, hi) = CalibrationParams.bounds[key]!;
        expect(p[key], greaterThanOrEqualTo(lo), reason: '$key below bound');
        expect(p[key], lessThanOrEqualTo(hi), reason: '$key above bound');
      }
      expect(p, p.clamped());
    });

    test('is deterministic', () {
      final corpus = weakGaitCorpus();
      final a = CalibrationOptimizer.optimize(sessions: corpus, start: overStrict);
      final b = CalibrationOptimizer.optimize(sessions: corpus, start: overStrict);
      expect(a.params, b.params);
      expect(a.holdoutError, b.holdoutError);
      expect(a.accepted, b.accepted);
    });

    test('an empty corpus is a no-op rather than an error', () {
      final outcome = CalibrationOptimizer.optimize(sessions: const []);
      expect(outcome.accepted, isFalse);
      expect(outcome.params, CalibrationParams.factory);
    });

    test('escapes a corner where two parameters are jointly wrong', () {
      // Coordinate descent moves one parameter at a time. With both the motion
      // floor and the amplitude floor set too high, relaxing either alone still
      // detects nothing, so no single move improves the score and a naive
      // search would sit there forever. The restart from factory defaults is
      // what makes this recoverable.
      const stuck = CalibrationParams(minAmplitude: 3.8, minMotionSigma: 1.4);
      final corpus = weakGaitCorpus();

      expect(CalibrationOptimizer.evaluate(stuck, corpus).totalDetected, 0,
          reason: 'no single relaxation helps from here');

      final outcome =
          CalibrationOptimizer.optimize(sessions: corpus, start: stuck);

      expect(outcome.accepted, isTrue);
      expect(CalibrationOptimizer.evaluate(outcome.params, corpus).totalDetected,
          greaterThan(0));
    });

    test('marks a single-session run as unvalidated', () {
      final outcome = CalibrationOptimizer.optimize(
        sessions: weakGaitCorpus(count: 1),
        start: overStrict,
      );
      expect(outcome.validated, isFalse,
          reason: 'one session cannot be held out from itself');
      expect(outcome.sessionCount, 1);
    });
  });

  group('automatic-calibration guardrails', () {
    test('refuses to adopt from too few windows', () {
      final outcome = CalibrationOptimizer.optimize(
        sessions: weakGaitCorpus(count: 4),
        start: overStrict,
        requireHoldout: true,
      );
      expect(outcome.sessionCount, lessThan(CalibrationOptimizer.minSessionsForAutoAdopt));
      expect(outcome.accepted, isFalse);
    });

    test('adopts once there are enough windows and a real improvement', () {
      final outcome = CalibrationOptimizer.optimize(
        sessions: weakGaitCorpus(count: 9),
        start: overStrict,
        requireHoldout: true,
      );
      expect(outcome.accepted, isTrue);
      expect(outcome.validated, isTrue);
    });

    test('an unvalidated run is never auto-adopted', () {
      final outcome = CalibrationOptimizer.optimize(
        sessions: weakGaitCorpus(count: 2),
        start: overStrict,
        requireHoldout: true,
      );
      expect(outcome.accepted, isFalse);
    });

    test('improvement is measured against the previous params, not the factory',
        () {
      const previous = CalibrationParams(minAmplitude: 3.0, minMotionSigma: 1.1);
      final outcome = CalibrationOptimizer.optimize(
        sessions: weakGaitCorpus(),
        start: previous,
      );
      expect(outcome.baselineParams, previous);
      expect(outcome.baselineHoldoutError, greaterThan(0));
      expect(outcome.accepted, isTrue);
    });
  });

  group('isolate execution', () {
    test('produces the same outcome as running inline', () async {
      final corpus = weakGaitCorpus(count: 6);
      final inline = CalibrationOptimizer.optimize(sessions: corpus);

      final outcome = await runCalibrationInIsolate(CalibrationJob(
        packedSessions:
            corpus.map((s) => SensorSample.pack(s.samples)).toList(),
        actualSteps: corpus.map((s) => s.actualSteps).toList(),
        startParamsJson: CalibrationParams.factory.toJson(),
      ));

      expect(outcome.params, inline.params);
      expect(outcome.accepted, inline.accepted);
    });
  });
}
