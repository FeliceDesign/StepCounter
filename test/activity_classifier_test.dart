import 'package:flutter_test/flutter_test.dart';
import 'package:stepcounter/detection/activity.dart';
import 'package:stepcounter/detection/activity_classifier.dart';
import 'package:stepcounter/detection/motion_pipeline.dart';
import 'package:stepcounter/detection/sensor_sample.dart';

import 'fixtures/gait_fixtures.dart';

/// The activity that most steps in a replay were attributed to.
Activity dominant(Map<Activity, int> counts) {
  if (counts.isEmpty) return Activity.unknown;
  return counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
}

void main() {
  group('barometric altitude', () {
    test('pressure converts to altitude with the expected gradient', () {
      final a = altitudeFromPressure(1013.25);
      final b = altitudeFromPressure(1012.25);
      // ~8.3 m per hPa near sea level.
      expect(b - a, closeTo(8.3, 0.6));
    });

    test('a flight of stairs is far above barometer noise', () {
      // Three metres is about 0.36 hPa; sensor noise is ~0.03 hPa.
      final drop = altitudeFromPressure(1013.25 - 0.36) -
          altitudeFromPressure(1013.25);
      expect(drop, closeTo(3.0, 0.3));
    });
  });

  group('walking versus running', () {
    test('a normal walk classifies as walking', () {
      final counts = MotionPipeline.replay(GaitFixtures.walk(steps: 80));
      expect(dominant(counts), Activity.walking);
    });

    test('running classifies as running', () {
      final counts = MotionPipeline.replay(GaitFixtures.run(steps: 100));
      expect(dominant(counts), Activity.running);
    });

    test('a brisk walk is not mistaken for running', () {
      // 150 spm is above the cadence threshold, so only the absent flight phase
      // and modest impact keep this from being called a run.
      final counts = MotionPipeline.replay(
        GaitFixtures.walk(steps: 90, stepFrequencyHz: 2.5, amplitude: 2.2),
      );
      expect(dominant(counts), Activity.walking);
    });

    test('a slow shuffle is walking', () {
      final counts = MotionPipeline.replay(
        GaitFixtures.walk(steps: 40, stepFrequencyHz: 1.1, amplitude: 1.2),
      );
      expect(dominant(counts), Activity.walking);
    });

    test('running still counts roughly the right number of steps', () {
      final total = MotionPipeline.replayTotal(GaitFixtures.run(steps: 100));
      expect(total, closeTo(100, 8));
    });
  });

  group('stairs', () {
    test('climbing while stepping is stairs up', () {
      final samples = GaitFixtures.walk(steps: 40, stepFrequencyHz: 1.5);
      final counts = MotionPipeline.replay(
        samples,
        pressure: GaitFixtures.pressureRamp(
          durationSeconds: samples.last.tNs / 1e9,
          verticalSpeed: 0.25,
        ),
      );
      expect(dominant(counts), Activity.stairsUp);
    });

    test('descending while stepping is stairs down', () {
      final samples = GaitFixtures.walk(steps: 40, stepFrequencyHz: 1.7);
      final counts = MotionPipeline.replay(
        samples,
        pressure: GaitFixtures.pressureRamp(
          durationSeconds: samples.last.tNs / 1e9,
          verticalSpeed: -0.3,
        ),
      );
      expect(dominant(counts), Activity.stairsDown);
    });

    test('level walking with a barometer stays walking', () {
      final samples = GaitFixtures.walk(steps: 60);
      final counts = MotionPipeline.replay(
        samples,
        pressure: GaitFixtures.pressureFlat(
          durationSeconds: samples.last.tNs / 1e9,
        ),
      );
      expect(dominant(counts), Activity.walking);
    });

    test('realistic barometer noise never produces stairs', () {
      final samples = GaitFixtures.walk(steps: 60);
      // 0.05 hPa is already about double what a phone barometer actually does.
      final counts = MotionPipeline.replay(
        samples,
        pressure: GaitFixtures.pressureRamp(
          durationSeconds: samples.last.tNs / 1e9,
          verticalSpeed: 0,
          noiseHPa: 0.05,
          flatLeadInSeconds: 0,
        ),
      );
      expect(counts[Activity.stairsUp] ?? 0, 0);
      expect(counts[Activity.stairsDown] ?? 0, 0);
    });

    test('even an absurdly noisy barometer cannot dominate the label', () {
      final samples = GaitFixtures.walk(steps: 60);
      // 0.3 hPa is ten times realistic — 2.5 m of altitude noise. Some stair
      // frames are unavoidable at that point; what matters is that the walk is
      // still overwhelmingly reported as walking.
      final counts = MotionPipeline.replay(
        samples,
        pressure: GaitFixtures.pressureRamp(
          durationSeconds: samples.last.tNs / 1e9,
          verticalSpeed: 0,
          noiseHPa: 0.3,
          flatLeadInSeconds: 0,
        ),
      );
      final total = counts.values.fold<int>(0, (a, b) => a + b);
      final stairs = counts.entries
          .where((e) => e.key.isStairs)
          .fold<int>(0, (a, e) => a + e.value);
      expect(dominant(counts), Activity.walking);
      expect(stairs / total, lessThan(0.15));
    });

    test('weather drift is orders of magnitude too slow to register', () {
      final samples = GaitFixtures.walk(steps: 60);
      // 3 hPa over six hours is a brisk weather change; as a vertical speed it
      // is about 1e-5 m/s against a 0.08 m/s threshold.
      final counts = MotionPipeline.replay(
        samples,
        pressure: GaitFixtures.pressureRamp(
          durationSeconds: samples.last.tNs / 1e9,
          verticalSpeed: 0.00001,
          flatLeadInSeconds: 0,
        ),
      );
      expect(counts[Activity.stairsUp] ?? 0, 0);
    });

    test('without a barometer stairs are never claimed', () {
      final counts = MotionPipeline.replay(GaitFixtures.walk(steps: 60));
      expect(counts.keys.any((a) => a.isStairs), isFalse);
      expect(dominant(counts), Activity.walking);
    });

    test('a lift is not stairs, because there are no steps', () {
      final samples = GaitFixtures.still(durationSeconds: 40);
      final counts = MotionPipeline.replay(
        samples,
        pressure: GaitFixtures.pressureRamp(
          durationSeconds: 40,
          verticalSpeed: 1.0,
          flatLeadInSeconds: 0,
        ),
      );
      expect(counts.values.fold<int>(0, (a, b) => a + b), 0);
    });
  });

  group('non-stepping states', () {
    ActivityClassifier runTo(List<SensorSample> samples) {
      final pipeline = MotionPipeline();
      for (final s in samples) {
        pipeline.addSample(s);
      }
      return pipeline.classifier;
    }

    test('a stationary phone is still', () {
      expect(runTo(GaitFixtures.still(durationSeconds: 30)).current,
          Activity.still);
    });

    test('vehicle vibration is recognised rather than discarded', () {
      expect(runTo(GaitFixtures.vehicle(durationSeconds: 60)).current,
          Activity.vehicle);
    });

    test('no steps are attributed to still or vehicle', () {
      for (final samples in [
        GaitFixtures.still(durationSeconds: 30),
        GaitFixtures.vehicle(durationSeconds: 60),
      ]) {
        final counts = MotionPipeline.replay(samples);
        expect(counts.values.fold<int>(0, (a, b) => a + b), 0);
      }
    });
  });

  group('classifier mechanics', () {
    test('is deterministic across replays', () {
      final samples = GaitFixtures.run(steps: 60);
      final a = MotionPipeline.replay(samples);
      final b = MotionPipeline.replay(samples);
      expect(a, b);
    });

    test('step totals match the detector regardless of classification', () {
      final samples = GaitFixtures.walk(steps: 70);
      final counts = MotionPipeline.replay(samples);
      final pipeline = MotionPipeline();
      for (final s in samples) {
        pipeline.addSample(s);
      }
      expect(counts.values.fold<int>(0, (a, b) => a + b), pipeline.totalSteps);
    });

    test('a gap in the stream resets classifier state', () {
      final pipeline = MotionPipeline();
      for (final s in GaitFixtures.run(steps: 40)) {
        pipeline.addSample(s);
      }
      expect(pipeline.activity, Activity.running);

      const offset = 600 * 1000000000;
      for (final s in GaitFixtures.still(durationSeconds: 20)) {
        pipeline.addSample(SensorSample(
          tNs: s.tNs + offset,
          ax: s.ax,
          ay: s.ay,
          az: s.az,
          gx: s.gx,
          gy: s.gy,
          gz: s.gz,
          hasGyro: true,
        ));
      }
      expect(pipeline.activity, Activity.still);
    });

    test('walking starts being counted immediately, not after hysteresis', () {
      final pipeline = MotionPipeline();
      var firstStepActivity = Activity.unknown;
      for (final s in GaitFixtures.walk(steps: 40)) {
        final e = pipeline.addSample(s);
        if (e.hasSteps) {
          firstStepActivity = e.activity;
          break;
        }
      }
      expect(firstStepActivity, Activity.walking);
    });
  });

  group('ActivityParams', () {
    test('clamps out-of-range values', () {
      const wild = ActivityParams(
        stairsAltitudeRateMin: 99,
        runningCadenceMin: 1,
        stairsMinDurationMs: 999999,
      );
      final c = wild.clamped();
      expect(c.stairsAltitudeRateMin,
          ActivityParams.bounds['stairsAltitudeRateMin']!.$2);
      expect(c.runningCadenceMin,
          ActivityParams.bounds['runningCadenceMin']!.$1);
      expect(c.stairsMinDurationMs,
          ActivityParams.bounds['stairsMinDurationMs']!.$2);
    });

    test('survives a JSON round trip', () {
      const p = ActivityParams(
        stillAccelSigmaMax: 0.2,
        vehicleGyroMax: 0.04,
        runningCadenceMin: 155,
        runningFlightMax: 4.2,
        runningAmplitudeMin: 3.5,
        stairsAltitudeRateMin: 0.11,
        stairsMinDurationMs: 3000,
      );
      expect(ActivityParams.fromJson(p.toJson()), p);
    });

    test('every tunable key round trips through generic access', () {
      var p = ActivityParams.factory;
      for (final key in ActivityParams.tunableKeys) {
        final before = p[key];
        p = p.withField(key, before);
        expect(p[key], before, reason: 'round trip failed for $key');
      }
    });
  });

  group('Activity identifiers', () {
    test('ids are stable and reversible', () {
      for (final a in Activity.values) {
        expect(Activity.fromId(a.id), a);
      }
    });

    test('an unrecognised id degrades to unknown rather than throwing', () {
      expect(Activity.fromId('nonsense'), Activity.unknown);
    });

    test('only movement activities count steps', () {
      expect(Activity.walking.countsSteps, isTrue);
      expect(Activity.running.countsSteps, isTrue);
      expect(Activity.stairsUp.countsSteps, isTrue);
      expect(Activity.still.countsSteps, isFalse);
      expect(Activity.vehicle.countsSteps, isFalse);
    });
  });

  group('PressureSample packing', () {
    test('round trips through the stored blob format', () {
      final original = GaitFixtures.pressureRamp(
        durationSeconds: 20,
        verticalSpeed: 0.25,
      );
      final restored = PressureSample.unpack(PressureSample.pack(original));

      expect(restored.length, original.length);
      for (var i = 0; i < original.length; i++) {
        expect(restored[i].hPa, closeTo(original[i].hPa, 0.01));
      }
    });

    test('an empty blob unpacks to nothing', () {
      expect(PressureSample.unpack(PressureSample.pack(const [])), isEmpty);
    });
  });
}
