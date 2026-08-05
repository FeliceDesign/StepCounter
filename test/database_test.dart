import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stepcounter/data/database.dart';
import 'package:stepcounter/detection/activity.dart';
import 'package:stepcounter/detection/calibration_params.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  int minuteOf(DateTime t) => t.millisecondsSinceEpoch ~/ 60000;

  group('step buckets', () {
    test('writes to the same minute accumulate rather than replace', () async {
      final m = minuteOf(DateTime.now());
      await db.addSteps(m, Activity.walking, 5);
      await db.addSteps(m, Activity.walking, 7);

      final start = DayMath.dayStart(DateTime.now());
      expect(await db.stepsBetween(start, DayMath.nextDay(start)), 12);
    });

    test('ignores non-positive counts', () async {
      final m = minuteOf(DateTime.now());
      await db.addSteps(m, Activity.walking, 0);
      await db.addSteps(m, Activity.walking, -3);
      final start = DayMath.dayStart(DateTime.now());
      expect(await db.stepsBetween(start, DayMath.nextDay(start)), 0);
    });

    test('a drained batch commits every bucket', () async {
      final base = minuteOf(DateTime.now());
      await db.addStepBatch([
        StepBucket(minuteEpoch: base - 2, activity: Activity.walking, steps: 3),
        StepBucket(minuteEpoch: base - 1, activity: Activity.running, steps: 4),
        StepBucket(minuteEpoch: base, activity: Activity.stairsUp, steps: 5),
      ]);
      final start = DayMath.dayStart(DateTime.now());
      expect(await db.stepsBetween(start, DayMath.nextDay(start)), 12);
    });

    test('range query excludes its end bound', () async {
      final now = DateTime.now();
      final start = DayMath.dayStart(now);
      await db.addSteps(minuteOf(start), Activity.walking, 10);
      await db.addSteps(minuteOf(DayMath.nextDay(start)), Activity.walking, 99);

      expect(await db.stepsBetween(start, DayMath.nextDay(start)), 10);
    });

    test('steps land in the day they happened, not the day they were written',
        () async {
      final today = DayMath.dayStart(DateTime.now());
      final threeDaysAgo = DayMath.addDays(today, -3);
      await db.addSteps(minuteOf(threeDaysAgo.add(const Duration(hours: 9))), Activity.walking, 250);

      final totals = await db.dailyTotals(
        DayMath.addDays(today, -6),
        DayMath.nextDay(today),
      );
      final match = totals.firstWhere((t) => t.day == threeDaysAgo);
      expect(match.steps, 250);
      expect(totals.where((t) => t.steps > 0).length, 1);
    });
  });

  group('live updates', () {
    // Regression: addSteps writes through customStatement, and drift cannot
    // infer which tables a raw statement touched. Without an explicit
    // notification the watch stream never re-emits, so the on-screen count only
    // refreshed when the app restarted and re-ran the initial query.
    test('the watch stream emits again after a write', () async {
      final start = DayMath.dayStart(DateTime.now());
      final stream = db.watchStepsBetween(start, DayMath.nextDay(start));

      final seen = <int>[];
      final sub = stream.listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      await db.addSteps(minuteOf(DateTime.now()), Activity.walking, 12);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      await sub.cancel();
      expect(seen.first, 0);
      expect(seen.last, 12, reason: 'the stream must observe the new steps');
    });

    test('a batched drain also wakes the stream', () async {
      final start = DayMath.dayStart(DateTime.now());
      final base = minuteOf(DateTime.now());
      final seen = <int>[];
      final sub =
          db.watchStepsBetween(start, DayMath.nextDay(start)).listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      await db.addStepBatch([
        StepBucket(minuteEpoch: base, activity: Activity.walking, steps: 7),
        StepBucket(minuteEpoch: base, activity: Activity.running, steps: 3),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      await sub.cancel();
      expect(seen.last, 10);
    });

    test('clearing history wakes the stream too', () async {
      final start = DayMath.dayStart(DateTime.now());
      await db.addSteps(minuteOf(DateTime.now()), Activity.walking, 50);

      final seen = <int>[];
      final sub =
          db.watchStepsBetween(start, DayMath.nextDay(start)).listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      await db.clearStepHistory();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      await sub.cancel();
      expect(seen.last, 0);
    });
  });

  group('daily totals', () {
    test('returns one entry per day including empty ones', () async {
      final today = DayMath.dayStart(DateTime.now());
      final totals = await db.dailyTotals(
        DayMath.addDays(today, -6),
        DayMath.nextDay(today),
      );
      expect(totals.length, 7);
      expect(totals.every((t) => t.steps == 0), isTrue);
    });

    test('is ordered oldest first', () async {
      final today = DayMath.dayStart(DateTime.now());
      final totals = await db.dailyTotals(
        DayMath.addDays(today, -6),
        DayMath.nextDay(today),
      );
      for (var i = 1; i < totals.length; i++) {
        expect(totals[i].day.isAfter(totals[i - 1].day), isTrue);
      }
    });

    test('firstRecordedDay is null until something is recorded', () async {
      expect(await db.firstRecordedDay(), isNull);
      final today = DayMath.dayStart(DateTime.now());
      await db.addSteps(minuteOf(today.add(const Duration(hours: 2))), Activity.walking, 5);
      expect(await db.firstRecordedDay(), today);
    });
  });

  group('day arithmetic', () {
    test('addDays crosses month and year boundaries', () {
      expect(DayMath.addDays(DateTime(2026, 1, 1), -1), DateTime(2025, 12, 31));
      expect(DayMath.addDays(DateTime(2026, 2, 28), 1), DateTime(2026, 3, 1));
    });

    test('dayStart strips the time component', () {
      expect(
        DayMath.dayStart(DateTime(2026, 5, 4, 23, 59, 59)),
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
      await db.addSteps(minuteOf(DateTime.now()), Activity.walking, 100);
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

      final start = DayMath.dayStart(DateTime.now());
      expect(await db.stepsBetween(start, DayMath.nextDay(start)), 0);
      expect((await db.allSessions()).length, 1);
      expect(await db.activeVersion(), isNotNull);
    });

    test('clearing calibration leaves step history intact', () async {
      await db.addSteps(minuteOf(DateTime.now()), Activity.walking, 100);
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

      final start = DayMath.dayStart(DateTime.now());
      expect(await db.stepsBetween(start, DayMath.nextDay(start)), 100);
      expect((await db.allSessions()), isEmpty);
    });
  });
}
