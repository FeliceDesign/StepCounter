import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stepcounter/data/database.dart';
import 'package:stepcounter/data/step_repository.dart';
import 'package:stepcounter/detection/calibration_params.dart';
import 'package:stepcounter/detection/sensor_sample.dart';
import 'package:stepcounter/services/native_bridge.dart';

import 'fake_bridge.dart';
import 'fixtures/gait_fixtures.dart';

void main() {
  late AppDatabase db;
  late FakeNativeBridge bridge;
  late StepRepository repo;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    bridge = FakeNativeBridge();
    repo = StepRepository(db: db, bridge: bridge);
  });

  tearDown(() async {
    repo.dispose();
    await bridge.close();
    await db.close();
  });

  int minuteOf(DateTime t) => t.millisecondsSinceEpoch ~/ 60000;

  group('draining from the service', () {
    test('commits drained buckets to the database', () async {
      final m = minuteOf(DateTime.now());
      bridge.queueSteps(m - 1, 10);
      bridge.queueSteps(m, 15);

      await repo.drainFromService();

      expect(await repo.stepsToday(), 25);
    });

    test('a second drain does not double count', () async {
      final m = minuteOf(DateTime.now());
      bridge.queueSteps(m, 30);

      await repo.drainFromService();
      await repo.drainFromService();

      expect(await repo.stepsToday(), 30);
    });

    test('an empty drain is harmless', () async {
      await repo.drainFromService();
      expect(await repo.stepsToday(), 0);
    });

    test('hands the authoritative daily total back to the service', () async {
      // The service only counts from when it started, so it cannot know the
      // total for a day that began before it did.
      bridge.queueSteps(minuteOf(DateTime.now()), 120);
      await repo.drainFromService();
      expect(bridge.todayTotalPushed, 120);

      bridge.queueSteps(minuteOf(DateTime.now()), 30);
      await repo.drainFromService();
      expect(bridge.todayTotalPushed, 150);
    });

    test('initialise pulls across what the service counted while away',
        () async {
      bridge.queueSteps(minuteOf(DateTime.now()), 42);
      await repo.initialise();
      expect(await repo.stepsToday(), 42);
    });
  });

  group('calibration parameters', () {
    test('start at factory defaults and are pushed to the detector', () async {
      await repo.initialise();
      expect(repo.params, CalibrationParams.factory);
      expect(bridge.lastParamsPushed, CalibrationParams.factory);
    });

    test('adopting records a version and pushes it down', () async {
      await repo.initialise();
      const tuned = CalibrationParams(thresholdSigma: 0.85, minAmplitude: 0.4);

      await repo.adoptParams(tuned, source: 'manual');

      expect(repo.params, tuned);
      expect(bridge.lastParamsPushed, tuned);
      final history = await repo.versionHistory();
      expect(history.length, 1);
      expect(history.first.source, 'manual');
    });

    test('adopted parameters are clamped before being stored', () async {
      await repo.initialise();
      await repo.adoptParams(
        const CalibrationParams(thresholdSigma: 99),
        source: 'manual',
      );
      expect(repo.params.thresholdSigma,
          CalibrationParams.bounds['thresholdSigma']!.$2);
    });

    test('a restart reloads the active version rather than the factory one',
        () async {
      await repo.initialise();
      await repo.adoptParams(
        const CalibrationParams(thresholdSigma: 1.4),
        source: 'manual',
      );

      final reopened = StepRepository(db: db, bridge: bridge);
      await reopened.initialise();
      expect(reopened.params.thresholdSigma, 1.4);
      reopened.dispose();
    });
  });

  group('sessions', () {
    test('a manual session stores what the detector saw at the time', () async {
      await repo.initialise();
      final samples = SensorSample.pack(GaitFixtures.walk(steps: 30));

      await repo.saveManualSession(
        samples: samples,
        actualSteps: 30,
        durationMs: 20000,
      );

      final sessions = await repo.allSessions();
      expect(sessions.length, 1);
      expect(sessions.first.actualSteps, 30);
      expect(sessions.first.source, 'manual');
      expect(sessions.first.detectedSteps, closeTo(30, 4));
    });

    test('automatic windows become sessions labelled by the hardware count',
        () async {
      await repo.initialise();
      bridge.pendingWindows = [
        AutoWindow(
          recordedAt: DateTime.now().millisecondsSinceEpoch,
          ourCount: 28,
          hardwareCount: 31,
          samples: SensorSample.pack(GaitFixtures.walk(steps: 31)),
        ),
      ];

      final ingested = await repo.ingestAutoWindows();

      expect(ingested, 1);
      final sessions = await repo.allSessions();
      expect(sessions.single.actualSteps, 31);
      expect(sessions.single.source, 'automatic');
    });

    test('windows without a hardware label are discarded', () async {
      await repo.initialise();
      bridge.pendingWindows = [
        AutoWindow(
          recordedAt: 1,
          ourCount: 10,
          hardwareCount: 0,
          samples: SensorSample.pack(GaitFixtures.walk(steps: 10)),
        ),
        AutoWindow(
          recordedAt: 2,
          ourCount: 10,
          hardwareCount: 12,
          samples: Uint8List(0),
        ),
      ];

      await repo.ingestAutoWindows();
      expect(await repo.allSessions(), isEmpty);
    });

    test('a step event from the service triggers a drain', () async {
      await repo.initialise();
      bridge.queueSteps(minuteOf(DateTime.now()), 7);

      bridge.emit({'type': 'steps', 'count': 7});
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(await repo.stepsToday(), 7);
    });
  });

  group('running calibration', () {
    test('returns null when there is nothing to learn from', () async {
      await repo.initialise();
      expect(await repo.runCalibration(), isNull);
    });

    test('automatic calibration refuses to adopt below the window floor',
        () async {
      await repo.initialise();
      for (var i = 0; i < 3; i++) {
        await repo.saveManualSession(
          samples: SensorSample.pack(
              GaitFixtures.walk(steps: 20, amplitude: 0.9, gyroAmplitude: 0.3, seed: i)),
          actualSteps: 20,
          durationMs: 15000,
        );
      }

      final before = repo.params;
      final outcome = await repo.runAutomaticCalibration();

      expect(outcome, isNotNull);
      expect(outcome!.accepted, isFalse);
      expect(repo.params, before, reason: 'params must not change');
    });

    test('automatic calibration adopts once the evidence is sufficient',
        () async {
      await repo.initialise();
      for (var i = 0; i < 9; i++) {
        await repo.saveManualSession(
          samples: SensorSample.pack(
              GaitFixtures.walk(steps: 20, amplitude: 0.9, gyroAmplitude: 0.3, seed: 100 + i)),
          actualSteps: 20,
          durationMs: 15000,
        );
      }

      // Start from thresholds far too strict for this corpus, so there is a
      // genuine improvement available for the optimiser to find.
      await repo.adoptParams(
        const CalibrationParams(minAmplitude: 3.2, minMotionSigma: 1.2),
        source: 'manual',
      );

      final outcome = await repo.runAutomaticCalibration();

      expect(outcome!.accepted, isTrue);
      expect(repo.params, outcome.params);
      expect(bridge.lastParamsPushed, outcome.params);

      final history = await repo.versionHistory();
      expect(history.first.source, 'automatic');
    });
  });

  group('scoped reset', () {
    Future<void> seed() async {
      await repo.initialise();
      bridge.queueSteps(minuteOf(DateTime.now()), 500);
      await repo.drainFromService();
      await repo.saveManualSession(
        samples: SensorSample.pack(GaitFixtures.walk(steps: 20)),
        actualSteps: 20,
        durationMs: 15000,
      );
      await repo.adoptParams(
        const CalibrationParams(thresholdSigma: 1.3),
        source: 'manual',
      );
    }

    test('resetting parameters keeps sessions and history', () async {
      await seed();
      await repo.reset(parameters: true);

      expect(repo.params, CalibrationParams.factory);
      expect(bridge.detectorReset, isTrue);
      expect((await repo.allSessions()).length, 1);
      expect(await repo.stepsToday(), 500);
    });

    test('resetting sessions keeps parameters and history', () async {
      await seed();
      await repo.reset(sessions: true);

      expect(repo.params.thresholdSigma, 1.3);
      expect(await repo.allSessions(), isEmpty);
      expect(bridge.autoWindowsCleared, isTrue);
      expect(await repo.stepsToday(), 500);
    });

    test('resetting history keeps parameters and sessions', () async {
      await seed();
      await repo.reset(history: true);

      expect(repo.params.thresholdSigma, 1.3);
      expect((await repo.allSessions()).length, 1);
      expect(await repo.stepsToday(), 0);
    });

    test('resetting nothing changes nothing', () async {
      await seed();
      await repo.reset();

      expect(repo.params.thresholdSigma, 1.3);
      expect((await repo.allSessions()).length, 1);
      expect(await repo.stepsToday(), 500);
    });

    test('all three scopes together clear everything', () async {
      await seed();
      await repo.reset(parameters: true, sessions: true, history: true);

      expect(repo.params, CalibrationParams.factory);
      expect(await repo.allSessions(), isEmpty);
      expect(await repo.stepsToday(), 0);
    });
  });
}
