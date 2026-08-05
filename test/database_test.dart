import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stepcounter/data/database.dart';
import 'package:stepcounter/detection/calibration_params.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  int minuteOf(DateTime t) => t.millisecondsSinceEpoch ~/ 60000;

  group('step buckets', () {
    test('writes to the same minute accumulate rather than replace', () async {
      final m = minuteOf(DateTime.now());
      await db.addSteps(m, 5);
      await db.addSteps(m, 7);

      final start = DateUtils.dayStart(DateTime.now());
      expect(await db.stepsBetween(start, DateUtils.nextDay(start)), 12);
    });

    test('ignores non-positive counts', () async {
      final m = minuteOf(DateTime.now());
      await db.addSteps(m, 0);
      await db.addSteps(m, -3);
      final start = DateUtils.dayStart(DateTime.now());
      expect(await db.stepsBetween(start, DateUtils.nextDay(start)), 0);
    });

    test('a drained batch commits every bucket', () async {
      final base = minuteOf(DateTime.now());
      await db.addStepBatch({base - 2: 3, base - 1: 4, base: 5});
      final start = DateUtils.dayStart(DateTime.now());
      expect(await db.stepsBetween(start, DateUtils.nextDay(start)), 12);
    });

    test('range query excludes its end bound', () async {
      final now = DateTime.now();
      final start = DateUtils.dayStart(now);
      await db.addSteps(minuteOf(start), 10);
      await db.addSteps(minuteOf(DateUtils.nextDay(start)), 99);

      expect(await db.stepsBetween(start, DateUtils.nextDay(start)), 10);
    });

    test('steps land in the day they happened, not the day they were written',
        () async {
      final today = DateUtils.dayStart(DateTime.now());
      final threeDaysAgo = DateUtils.addDays(today, -3);
      await db.addSteps(minuteOf(threeDaysAgo.add(const Duration(hours: 9))), 250);

      final totals = await db.dailyTotals(
        DateUtils.addDays(today, -6),
        DateUtils.nextDay(today),
      );
      final match = totals.firstWhere((t) => t.day == threeDaysAgo);
      expect(match.steps, 250);
      expect(totals.where((t) => t.steps > 0).length, 1);
    });
  });

  group('daily totals', () {
    test('returns one entry per day including empty ones', () async {
      final today = DateUtils.dayStart(DateTime.now());
      final totals = await db.dailyTotals(
        DateUtils.addDays(today, -6),
        DateUtils.nextDay(today),
      );
      expect(totals.length, 7);
      expect(totals.every((t) => t.steps == 0), isTrue);
    });

    test('is ordered oldest first', () async {
      final today = DateUtils.dayStart(DateTime.now());
      final totals = await db.dailyTotals(
        DateUtils.addDays(today, -6),
        DateUtils.nextDay(today),
      );
      for (var i = 1; i < totals.length; i++) {
        expect(totals[i].day.isAfter(totals[i - 1].day), isTrue);
      }
    });

    test('firstRecordedDay is null until something is recorded', () async {
      expect(await db.firstRecordedDay(), isNull);
      final today = DateUtils.dayStart(DateTime.now());
      await db.addSteps(minuteOf(today.add(const Duration(hours: 2))), 5);
      expect(await db.firstRecordedDay(), today);
    });
  });

  group('day arithmetic', () {
    test('addDays crosses month and year boundaries', () {
      expect(DateUtils.addDays(DateTime(2026, 1, 1), -1), DateTime(2025, 12, 31));
      expect(DateUtils.addDays(DateTime(2026, 2, 28), 1), DateTime(2026, 3, 1));
    });

    test('dayStart strips the time component', () {
      expect(
        DateUtils.dayStart(DateTime(2026, 5, 4, 23, 59, 59)),
        DateTime(2026, 5, 4),
      );
    });
  });

  group('calibration sessions', () {
    Future<int> addSession(int actual, {String source = 'manual'}) =>
        db.insertSession(CalibrationSessionsCompanion.insert(
          recordedAt: DateTime.now().millisecondsSinceEpoch + actual,
          durationMs: 30000,
          actualSteps: actual,
          detectedSteps: actual - 1,
          source: source,
          samples: Uint8List.fromList([1, 2, 3, 4]),
        ));

    test('round trips', () async {
      await addSession(50);
      final all = await db.allSessions();
      expect(all.length, 1);
      expect(all.first.actualSteps, 50);
      expect(all.first.samples, [1, 2, 3, 4]);
    });

    test('trimming keeps the newest and drops the rest', () async {
      for (var i = 1; i <= 25; i++) {
        await addSession(i);
      }
      await db.trimSessions(keep: 20);

      final all = await db.allSessions();
      expect(all.length, 20);
      // recordedAt increases with `actual`, so the five smallest are gone.
      expect(all.map((s) => s.actualSteps).reduce((a, b) => a < b ? a : b), 6);
    });

    test('trimming is a no-op below the cap', () async {
      await addSession(1);
      await addSession(2);
      await db.trimSessions(keep: 20);
      expect((await db.allSessions()).length, 2);
    });
  });

  group('calibration versions', () {
    Future<void> activate(CalibrationParams p, String source) =>
        db.activateVersion(CalibrationVersionsCompanion.insert(
          createdAt: DateTime.now().microsecondsSinceEpoch,
          paramsJson: p.toJson(),
          source: source,
        ));

    test('only one version is active at a time', () async {
      await activate(CalibrationParams.factory, 'factory');
      await activate(const CalibrationParams(thresholdSigma: 0.9), 'manual');
      await activate(const CalibrationParams(thresholdSigma: 1.1), 'automatic');

      final active = await db.activeVersion();
      expect(active, isNotNull);
      expect(CalibrationParams.fromJson(active!.paramsJson).thresholdSigma, 1.1);
      expect((await db.versionHistory()).length, 3);
    });

    test('history is retained so a bad calibration can be traced', () async {
      await activate(const CalibrationParams(thresholdSigma: 0.5), 'manual');
      await activate(const CalibrationParams(thresholdSigma: 1.5), 'automatic');

      final history = await db.versionHistory();
      expect(history.map((v) => v.source), containsAll(['manual', 'automatic']));
    });

    test('there is no active version before any calibration', () async {
      expect(await db.activeVersion(), isNull);
    });
  });

  group('scoped reset', () {
    test('clearing history leaves calibration data intact', () async {
      await db.addSteps(minuteOf(DateTime.now()), 100);
      await db.insertSession(CalibrationSessionsCompanion.insert(
        recordedAt: 1,
        durationMs: 1,
        actualSteps: 10,
        detectedSteps: 10,
        source: 'manual',
        samples: Uint8List(0),
      ));
      await db.activateVersion(CalibrationVersionsCompanion.insert(
        createdAt: 1,
        paramsJson: CalibrationParams.factory.toJson(),
        source: 'manual',
      ));

      await db.clearStepHistory();

      final start = DateUtils.dayStart(DateTime.now());
      expect(await db.stepsBetween(start, DateUtils.nextDay(start)), 0);
      expect((await db.allSessions()).length, 1);
      expect(await db.activeVersion(), isNotNull);
    });

    test('clearing calibration leaves step history intact', () async {
      await db.addSteps(minuteOf(DateTime.now()), 100);
      await db.insertSession(CalibrationSessionsCompanion.insert(
        recordedAt: 1,
        durationMs: 1,
        actualSteps: 10,
        detectedSteps: 10,
        source: 'manual',
        samples: Uint8List(0),
      ));

      await db.clearCalibrationSessions();
      await db.clearCalibrationVersions();

      final start = DateUtils.dayStart(DateTime.now());
      expect(await db.stepsBetween(start, DateUtils.nextDay(start)), 100);
      expect((await db.allSessions()), isEmpty);
    });
  });
}
