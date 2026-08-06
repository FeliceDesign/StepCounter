import 'package:flutter_test/flutter_test.dart';
import 'package:stepcounter/detection/calibration_params.dart';
import 'package:stepcounter/detection/sensor_sample.dart';
import 'package:stepcounter/detection/step_detector.dart';

import 'fixtures/gait_fixtures.dart';

void main() {
  group('counts real gait', () {
    test('normal walk lands within 5%', () {
      final samples = GaitFixtures.walk(steps: 100);
      final counted = StepDetector.countSteps(samples);
      expect(counted, closeTo(100, 5));
    });

    test('slow shuffle', () {
      final samples =
          GaitFixtures.walk(steps: 60, stepFrequencyHz: 1.1, amplitude: 1.2);
      expect(StepDetector.countSteps(samples), closeTo(60, 4));
    });

    test('jogging', () {
      final samples =
          GaitFixtures.walk(steps: 120, stepFrequencyHz: 2.8, amplitude: 4.0);
      expect(StepDetector.countSteps(samples), closeTo(120, 6));
    });

    test('phone in a bag damps the signal but steps still register', () {
      final samples = GaitFixtures.walk(
        steps: 80,
        amplitude: 0.9,
        gyroAmplitude: 0.3,
      );
      expect(StepDetector.countSteps(samples), closeTo(80, 6));
    });

    test('accuracy holds without a gyroscope', () {
      final withGyro = GaitFixtures.walk(steps: 100);
      final noGyro = withGyro
          .map((s) => SensorSample(
                tNs: s.tNs,
                ax: s.ax,
                ay: s.ay,
                az: s.az,
                hasGyro: false,
              ))
          .toList();
      expect(StepDetector.countSteps(noGyro), closeTo(100, 5));
    });
  });

  group('rejects non-gait motion', () {
    test('vehicle vibration counts zero', () {
      expect(StepDetector.countSteps(GaitFixtures.vehicle()), 0);
    });

    test('sitting still counts zero', () {
      expect(StepDetector.countSteps(GaitFixtures.still()), 0);
    });

    test('isolated bursts never build a streak', () {
      expect(StepDetector.countSteps(GaitFixtures.isolatedBursts()), 0);
    });

    test('shaking is rejected by the gyro upper bound', () {
      expect(StepDetector.countSteps(GaitFixtures.shaking()), 0);
    });

    // Regression: reported as "even the smallest movements are counted". The
    // adaptive threshold is derived from the signal's own deviation, so on a
    // near-still phone it collapses toward zero and fires on desk vibration.
    // Ten minutes of this used to produce dozens of steps; over a day it added
    // roughly 1,600.
    test('sustained small movement counts nothing', () {
      for (final amp in [0.2, 0.35, 0.5]) {
        expect(
          StepDetector.countSteps(
            GaitFixtures.lowAmplitudeMotion(amplitude: amp),
          ),
          0,
          reason: 'amplitude $amp should be below the motion floor',
        );
      }
    });

    test('the motion floor is what rejects it, not the adaptive threshold', () {
      final samples = GaitFixtures.lowAmplitudeMotion(amplitude: 0.5);

      // The adaptive threshold is derived from the signal's own deviation, so
      // it shrinks along with the noise. At the setting a user would plausibly
      // choose it does nothing useful here.
      expect(
        StepDetector.countSteps(
          samples,
          params: const CalibrationParams(
            thresholdSigma: 0.7,
            minMotionSigma: 0.05,
            minAmplitude: 0.6,
          ),
        ),
        greaterThan(0),
      );

      // The absolute floor rejects it outright, at any threshold setting.
      expect(
        StepDetector.countSteps(
          samples,
          params: const CalibrationParams(
            thresholdSigma: 0.7,
            minMotionSigma: 0.35,
          ),
        ),
        0,
      );
    });

    test('the floor does not touch genuinely damped walking', () {
      // A phone loose in a bag is the weakest real signal the detector has to
      // handle, and sits just above the floor.
      expect(
        StepDetector.countSteps(
          GaitFixtures.walk(steps: 80, amplitude: 0.9, gyroAmplitude: 0.3),
        ),
        closeTo(80, 5),
      );
    });
  });

  group('detector mechanics', () {
    test('is deterministic across runs — required for calibration replay', () {
      final samples = GaitFixtures.walk(steps: 50);
      final a = StepDetector.countSteps(samples);
      final b = StepDetector.countSteps(samples);
      final c = StepDetector.countSteps(samples);
      expect(a, b);
      expect(b, c);
    });

    test('a gap in the stream resets state instead of emitting a burst', () {
      final first = GaitFixtures.walk(steps: 40);
      final second = GaitFixtures.walk(steps: 40, seed: 99);
      // Second block starts 10 minutes later, as if the service had restarted.
      const offset = 600 * 1000000000;
      final joined = [
        ...first,
        ...second.map((s) => SensorSample(
              tNs: s.tNs + offset,
              ax: s.ax,
              ay: s.ay,
              az: s.az,
              gx: s.gx,
              gy: s.gy,
              gz: s.gz,
              hasGyro: s.hasGyro,
            )),
      ];
      expect(StepDetector.countSteps(joined), closeTo(80, 8));
    });

    test('steps are released only once the regularity streak completes', () {
      final d = StepDetector();
      final samples = GaitFixtures.walk(steps: 30);
      var firstEmissionSize = 0;
      for (final s in samples) {
        final emitted = d.addSample(s);
        if (emitted.isNotEmpty) {
          firstEmissionSize = emitted.length;
          break;
        }
      }
      // The streak flushes as a batch, so the first emission is the whole run.
      expect(firstEmissionSize, CalibrationParams.factory.regularityRunLength);
    });

    test('emitted timestamps are monotonic and within the sample range', () {
      final d = StepDetector();
      final samples = GaitFixtures.walk(steps: 40);
      final stamps = <int>[];
      for (final s in samples) {
        stamps.addAll(d.addSample(s));
      }
      expect(stamps, isNotEmpty);
      for (var i = 1; i < stamps.length; i++) {
        expect(stamps[i], greaterThan(stamps[i - 1]));
      }
      expect(stamps.first, greaterThanOrEqualTo(samples.first.tNs));
      expect(stamps.last, lessThanOrEqualTo(samples.last.tNs));
    });

    test('totalSteps agrees with the number of emitted timestamps', () {
      final d = StepDetector();
      var emitted = 0;
      for (final s in GaitFixtures.walk(steps: 70)) {
        emitted += d.addSample(s).length;
      }
      expect(d.totalSteps, emitted);
    });

    test('a longer required run length is strictly more conservative', () {
      final samples = GaitFixtures.isolatedBursts(peaksPerBurst: 5);
      final lenient = StepDetector.countSteps(
        samples,
        params: const CalibrationParams(regularityRunLength: 2),
      );
      final strict = StepDetector.countSteps(
        samples,
        params: const CalibrationParams(regularityRunLength: 8),
      );
      expect(strict, lessThanOrEqualTo(lenient));
    });
  });

  group('CalibrationParams', () {
    test('clamps out-of-range values into the search bounds', () {
      const wild = CalibrationParams(
        thresholdSigma: 99,
        minAmplitude: -5,
        minStepIntervalMs: 1,
        regularityRunLength: 500,
      );
      final c = wild.clamped();
      expect(c.thresholdSigma, CalibrationParams.bounds['thresholdSigma']!.$2);
      expect(c.minAmplitude, CalibrationParams.bounds['minAmplitude']!.$1);
      expect(c.minStepIntervalMs, CalibrationParams.bounds['minStepIntervalMs']!.$1);
      expect(c.regularityRunLength, CalibrationParams.bounds['regularityRunLength']!.$2);
    });

    test('survives a JSON round trip', () {
      const p = CalibrationParams(
        thresholdSigma: 0.83,
        minAmplitude: 1.1,
        minStepIntervalMs: 275,
        maxStepIntervalMs: 1800,
        regularityRunLength: 5,
        gyroMinLevel: 0.12,
        gyroMaxLevel: 5.5,
      );
      expect(CalibrationParams.fromJson(p.toJson()), p);
    });

    test('every tunable key is readable and writable', () {
      var p = CalibrationParams.factory;
      for (final key in CalibrationParams.tunableKeys) {
        final before = p[key];
        p = p.withField(key, before);
        expect(p[key], before, reason: 'round trip failed for $key');
      }
    });

    test('withField clamps rather than accepting a wild value', () {
      final p = CalibrationParams.factory.withField('thresholdSigma', 1000);
      expect(p.thresholdSigma, CalibrationParams.bounds['thresholdSigma']!.$2);
    });
  });

  group('SensorSample packing', () {
    test('round trips through the stored blob format', () {
      final original = GaitFixtures.walk(steps: 10);
      final restored = SensorSample.unpack(SensorSample.pack(original));

      expect(restored.length, original.length);
      for (var i = 0; i < original.length; i++) {
        expect(restored[i].ax, closeTo(original[i].ax, 1e-3));
        expect(restored[i].az, closeTo(original[i].az, 1e-3));
        expect(restored[i].gx, closeTo(original[i].gx, 1e-3));
        // Timestamps are stored relative to the first sample.
        expect(restored[i].tNs - restored.first.tNs,
            closeTo(original[i].tNs - original.first.tNs, 1e6));
      }
    });

    test('a packed and restored session yields the same count', () {
      final original = GaitFixtures.walk(steps: 60);
      final restored = SensorSample.unpack(SensorSample.pack(original));
      expect(
        StepDetector.countSteps(restored),
        StepDetector.countSteps(original),
      );
    });
  });

  group('rejects hand jiggle', () {
    // The complaint this group exists for: during real walking the detector
    // tracked Android's own counter closely, but small movements of a phone
    // held in the hand counted up while Android understood they were not
    // walking. Three minutes of fidgeting scored 278 steps.
    //
    // The fixture is built so that no *earlier* gate can be what rejects it:
    // it is above the motion floor, above the amplitude floor, inside the gait
    // frequency band and inside the gyroscope band. Only the rhythm-quality
    // and vertical-share gates can act on it.

    test('three minutes of hand jiggle counts almost nothing', () {
      expect(
        StepDetector.countSteps(GaitFixtures.handJiggle(durationSeconds: 180)),
        lessThanOrEqualTo(15),
      );
    });

    test('a confirmed walk does not license counting through jiggle', () {
      // The direct regression test for the confirmed-run latch. The old
      // detector flipped to "confirmed" during the walk and then counted every
      // peak of the jiggle without re-checking anything, turning 60 real steps
      // into 204.
      final samples = GaitFixtures.concat([
        GaitFixtures.walk(steps: 60),
        GaitFixtures.handJiggle(durationSeconds: 90),
      ]);
      expect(StepDetector.countSteps(samples), inInclusiveRange(55, 80));
    });

    test('the vertical-share gate is what rejects it', () {
      // The mechanism check. After the autocorrelation episode recorded in the
      // README — a gate that worked, but not for the reason claimed — a new
      // gate has to demonstrate that it is the thing doing the work.
      final jiggle = GaitFixtures.handJiggle(durationSeconds: 180);

      final withoutGate = StepDetector.countSteps(
        jiggle,
        params: CalibrationParams.factory.copyWith(minVerticalShare: 0),
      );
      final withGate = StepDetector.countSteps(jiggle);

      expect(withoutGate, greaterThan(100));
      expect(withGate, lessThanOrEqualTo(15));
    });

    test('the interval-CV gate rejects most of it on its own', () {
      // The fallback, and why it is kept even though the vertical-share gate
      // dominates: the vertical gate stands aside whenever the gravity
      // estimate stops looking like gravity, and this is what remains.
      final jiggle = GaitFixtures.handJiggle(durationSeconds: 180);
      final noGates = CalibrationParams.factory
          .copyWith(minVerticalShare: 0, maxIntervalCv: 1.0, offRhythmTolerance: 1.0);

      expect(
        StepDetector.countSteps(jiggle, params: noGates),
        greaterThan(250),
      );
      expect(
        StepDetector.countSteps(
          jiggle,
          params: noGates.copyWith(maxIntervalCv: 0.15),
        ),
        lessThan(160),
      );
    });

    test('counted steps are never retracted when a run degrades', () {
      // Dropping out of a confirmed run must not claw back steps already
      // counted. A total that goes backwards is worse than one slightly too
      // high, and the daily history has already been written by then.
      final d = StepDetector();
      var previous = 0;
      for (final s in GaitFixtures.concat([
        GaitFixtures.walk(steps: 60),
        GaitFixtures.handJiggle(durationSeconds: 60),
      ])) {
        d.addSample(s);
        expect(d.totalSteps, greaterThanOrEqualTo(previous));
        previous = d.totalSteps;
      }
    });

    test('walking with the phone in a swinging hand is still counted', () {
      // The constraint that keeps minVerticalShare at 0.45. An arm swings once
      // per stride, adding a large horizontal component at half the step
      // frequency; at 0.55 this case collapses to zero steps.
      expect(
        StepDetector.countSteps(GaitFixtures.walkWithArmSwing(steps: 60)),
        inInclusiveRange(50, 62),
      );
      expect(
        StepDetector.countSteps(
          GaitFixtures.walkWithArmSwing(steps: 60, swingAmplitude: 5.0),
        ),
        greaterThanOrEqualTo(45),
      );
    });

    test('ordinary walking is untouched by any of it', () {
      // The guard against over-fixing. Every gate added here is subtractive,
      // so the only way to know they did not cost real steps is to say so.
      expect(StepDetector.countSteps(GaitFixtures.walk(steps: 60)),
          inInclusiveRange(58, 62));
      expect(
          StepDetector.countSteps(
              GaitFixtures.walk(steps: 40, stepFrequencyHz: 1.1, amplitude: 1.2)),
          inInclusiveRange(38, 42));
      expect(StepDetector.countSteps(GaitFixtures.run(steps: 60)),
          inInclusiveRange(58, 62));
    });
  });

}
