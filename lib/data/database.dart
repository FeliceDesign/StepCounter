import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart';

import '../detection/activity.dart';

part 'database.g.dart';

/// Step counts bucketed by minute.
///
/// A minute is the right granularity: fine enough to draw any range the app
/// offers, coarse enough that a year costs ~500k rows, which SQLite does not
/// notice. Storing individual step timestamps would be 100x the rows for
/// resolution nothing in the UI can display.
class StepMinutes extends Table {
  /// Minutes since the Unix epoch, in local wall-clock terms.
  IntColumn get minuteEpoch => integer()();

  /// What the user was doing, as [Activity.id].
  ///
  /// Part of the primary key, so one minute can hold several rows — a minute
  /// spent walking to a staircase and then climbing it genuinely contains two
  /// kinds of step, and collapsing them would lose exactly what the coloured
  /// chart is meant to show.
  TextColumn get activity =>
      text().withLength(min: 1, max: 16).withDefault(const Constant('unknown'))();

  IntColumn get steps => integer()();

  @override
  Set<Column> get primaryKey => {minuteEpoch, activity};
}

/// A recorded motion session with a user- or hardware-supplied step count.
class CalibrationSessions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get recordedAt => integer()();
  IntColumn get durationMs => integer()();

  /// Ground truth. From the user in the manual flow, from the hardware
  /// pedometer in the automatic one.
  IntColumn get actualSteps => integer()();

  /// What the detector counted at the time of recording, kept for display.
  IntColumn get detectedSteps => integer()();

  /// 'manual' or 'automatic'.
  TextColumn get source => text().withLength(min: 1, max: 16)();

  /// Packed float32 samples, the same layout SensorSample.pack produces.
  BlobColumn get samples => blob()();

  /// Packed barometer readings, or null for sessions recorded before stairs
  /// existed. Kept in its own column rather than widened into [samples]: a
  /// barometer reports a few times a second against the accelerometer's fifty,
  /// and adding an eighth float would have made old blobs ambiguous by length.
  BlobColumn get pressureSamples => blob().nullable()();

  /// What the user said they were doing, as [Activity.id]. Null when they did
  /// not say, which is every automatically captured window.
  TextColumn get declaredActivity =>
      text().withLength(min: 1, max: 16).nullable()();
}

/// Every parameter vector the app has ever adopted, newest last.
///
/// Kept as history rather than a single row so a bad calibration is always
/// recoverable and the user can see what actually changed.
class CalibrationVersions extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get createdAt => integer()();
  TextColumn get paramsJson => text()();

  /// Activity-classifier thresholds adopted at the same time. Null for versions
  /// recorded before activity detection existed.
  TextColumn get activityParamsJson => text().nullable()();

  /// 'factory', 'manual', 'automatic', or 'manual-slider'.
  TextColumn get source => text().withLength(min: 1, max: 16)();

  RealColumn get holdoutError => real().nullable()();
  RealColumn get baselineError => real().nullable()();
  IntColumn get sessionCount => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(false))();
}

@DriftDatabase(tables: [StepMinutes, CalibrationSessions, CalibrationVersions])
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor])
      : super(executor ?? driftDatabase(name: 'stepcounter'));

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) => m.createAll(),
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            // Existing rows predate activity detection, so they are honestly
            // labelled 'unknown' rather than guessed at as walking. SQLite
            // cannot alter a primary key in place, hence the table rebuild.
            await m.database
                .customStatement('ALTER TABLE step_minutes RENAME TO _step_minutes_v1');
            await m.createTable(stepMinutes);
            await m.database.customStatement(
              "INSERT INTO step_minutes (minute_epoch, activity, steps) "
              "SELECT minute_epoch, 'unknown', steps FROM _step_minutes_v1",
            );
            await m.database.customStatement('DROP TABLE _step_minutes_v1');

            await m.addColumn(calibrationSessions, calibrationSessions.pressureSamples);
            await m.addColumn(calibrationSessions, calibrationSessions.declaredActivity);
            await m.addColumn(calibrationVersions, calibrationVersions.activityParamsJson);
          }
        },
      );

  // ---- Steps ------------------------------------------------------------

  /// Adds steps to a minute/activity bucket, summing with what is there.
  ///
  /// Additive rather than replacing because the same bucket legitimately
  /// receives more than one write: the service drains a partial minute when the
  /// UI opens, then keeps counting into that same minute.
  Future<void> addSteps(int minuteEpoch, Activity activity, int steps) async {
    if (steps <= 0) return;
    await customStatement(
      'INSERT INTO step_minutes (minute_epoch, activity, steps) VALUES (?, ?, ?) '
      'ON CONFLICT(minute_epoch, activity) DO UPDATE SET steps = steps + excluded.steps',
      [minuteEpoch, activity.id, steps],
    );
  }

  /// Commits a drained batch from the foreground service in one transaction, so
  /// a crash mid-drain cannot leave half the steps recorded.
  Future<void> addStepBatch(List<StepBucket> buckets) async {
    if (buckets.isEmpty) return;
    await transaction(() async {
      for (final b in buckets) {
        await addSteps(b.minuteEpoch, b.activity, b.steps);
      }
    });
  }

  Future<int> stepsBetween(DateTime start, DateTime end) async {
    final from = start.millisecondsSinceEpoch ~/ 60000;
    final to = end.millisecondsSinceEpoch ~/ 60000;
    final row = await customSelect(
      'SELECT COALESCE(SUM(steps), 0) AS total FROM step_minutes '
      'WHERE minute_epoch >= ? AND minute_epoch < ?',
      variables: [Variable.withInt(from), Variable.withInt(to)],
      readsFrom: {stepMinutes},
    ).getSingle();
    return row.read<int>('total');
  }

  Stream<int> watchStepsBetween(DateTime start, DateTime end) {
    final from = start.millisecondsSinceEpoch ~/ 60000;
    final to = end.millisecondsSinceEpoch ~/ 60000;
    return customSelect(
      'SELECT COALESCE(SUM(steps), 0) AS total FROM step_minutes '
      'WHERE minute_epoch >= ? AND minute_epoch < ?',
      variables: [Variable.withInt(from), Variable.withInt(to)],
      readsFrom: {stepMinutes},
    ).map((r) => r.read<int>('total')).watchSingle();
  }

  /// Daily totals for [start, end), including days with no steps.
  ///
  /// Bucketing happens in Dart rather than SQL because local-time day
  /// boundaries move with DST, and SQLite's date functions would need the
  /// zone rules to get that right.
  Future<List<DayTotal>> dailyTotals(DateTime start, DateTime end) async {
    final from = start.millisecondsSinceEpoch ~/ 60000;
    final to = end.millisecondsSinceEpoch ~/ 60000;
    final rows = await customSelect(
      'SELECT minute_epoch, activity, steps FROM step_minutes '
      'WHERE minute_epoch >= ? AND minute_epoch < ? ORDER BY minute_epoch',
      variables: [Variable.withInt(from), Variable.withInt(to)],
      readsFrom: {stepMinutes},
    ).get();

    final totals = <DateTime, Map<Activity, int>>{};
    for (var d = DayMath.dayStart(start);
        d.isBefore(end);
        d = DayMath.nextDay(d)) {
      totals[d] = <Activity, int>{};
    }
    for (final r in rows) {
      final ts = DateTime.fromMillisecondsSinceEpoch(
          r.read<int>('minute_epoch') * 60000);
      final day = DayMath.dayStart(ts);
      final activity = Activity.fromId(r.read<String>('activity'));
      final bucket = totals.putIfAbsent(day, () => <Activity, int>{});
      bucket[activity] = (bucket[activity] ?? 0) + r.read<int>('steps');
    }

    final out = totals.entries.map((e) => DayTotal(e.key, e.value)).toList()
      ..sort((a, b) => a.day.compareTo(b.day));
    return out;
  }

  /// Step totals per activity across a range, for the history summary.
  Future<Map<Activity, int>> activityTotals(DateTime start, DateTime end) async {
    final from = start.millisecondsSinceEpoch ~/ 60000;
    final to = end.millisecondsSinceEpoch ~/ 60000;
    final rows = await customSelect(
      'SELECT activity, SUM(steps) AS total FROM step_minutes '
      'WHERE minute_epoch >= ? AND minute_epoch < ? GROUP BY activity',
      variables: [Variable.withInt(from), Variable.withInt(to)],
      readsFrom: {stepMinutes},
    ).get();

    return {
      for (final r in rows)
        Activity.fromId(r.read<String>('activity')): r.read<int>('total'),
    };
  }

  /// Earliest recorded day, or null when there is no history yet.
  Future<DateTime?> firstRecordedDay() async {
    final row = await customSelect(
      'SELECT MIN(minute_epoch) AS m FROM step_minutes',
      readsFrom: {stepMinutes},
    ).getSingle();
    final m = row.read<int?>('m');
    if (m == null) return null;
    return DayMath.dayStart(DateTime.fromMillisecondsSinceEpoch(m * 60000));
  }

  // ---- Calibration sessions ---------------------------------------------

  Future<int> insertSession(CalibrationSessionsCompanion session) =>
      into(calibrationSessions).insert(session);

  Future<List<CalibrationSession>> allSessions() =>
      (select(calibrationSessions)
            ..orderBy([(t) => OrderingTerm.asc(t.recordedAt)]))
          .get();

  Stream<List<CalibrationSession>> watchSessions() =>
      (select(calibrationSessions)
            ..orderBy([(t) => OrderingTerm.desc(t.recordedAt)]))
          .watch();

  Future<void> deleteSession(int id) =>
      (delete(calibrationSessions)..where((t) => t.id.equals(id))).go();

  /// Keeps the newest [keep] sessions so the corpus cannot grow without bound.
  ///
  /// Recalibration replays every stored session, so an uncapped corpus would
  /// make calibration slower every time it ran.
  Future<void> trimSessions({int keep = 20}) async {
    final all = await (select(calibrationSessions)
          ..orderBy([(t) => OrderingTerm.desc(t.recordedAt)]))
        .get();
    if (all.length <= keep) return;
    for (final s in all.skip(keep)) {
      await deleteSession(s.id);
    }
  }

  // ---- Calibration versions ---------------------------------------------

  Future<CalibrationVersion?> activeVersion() =>
      (select(calibrationVersions)..where((t) => t.isActive.equals(true)))
          .getSingleOrNull();

  Stream<CalibrationVersion?> watchActiveVersion() =>
      (select(calibrationVersions)..where((t) => t.isActive.equals(true)))
          .watchSingleOrNull();

  Future<List<CalibrationVersion>> versionHistory({int limit = 20}) =>
      (select(calibrationVersions)
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
            ..limit(limit))
          .get();

  /// Activates a parameter set, deactivating whatever was active before.
  Future<void> activateVersion(CalibrationVersionsCompanion version) async {
    await transaction(() async {
      await (update(calibrationVersions)
            ..where((t) => t.isActive.equals(true)))
          .write(const CalibrationVersionsCompanion(isActive: Value(false)));
      await into(calibrationVersions)
          .insert(version.copyWith(isActive: const Value(true)));
    });
  }

  // ---- Scoped reset ------------------------------------------------------

  /// Deliberately three independent operations rather than one "reset
  /// everything" button. Wanting a fresh calibration is not the same as wanting
  /// to lose a year of step history.
  Future<void> clearStepHistory() => delete(stepMinutes).go();

  Future<void> clearCalibrationSessions() => delete(calibrationSessions).go();

  Future<void> clearCalibrationVersions() => delete(calibrationVersions).go();
}

/// One bucket of steps handed over by the foreground service.
@immutable
class StepBucket {
  const StepBucket({
    required this.minuteEpoch,
    required this.activity,
    required this.steps,
  });

  final int minuteEpoch;
  final Activity activity;
  final int steps;
}

@immutable
class DayTotal {
  const DayTotal(this.day, this.byActivity);

  final DateTime day;
  final Map<Activity, int> byActivity;

  int get steps => byActivity.values.fold(0, (a, b) => a + b);

  int stepsIn(Activity a) => byActivity[a] ?? 0;

  /// Stairs up and down are counted separately but almost always shown
  /// together — the distinction matters for calibration, not for a bar chart.
  int get stairsSteps =>
      stepsIn(Activity.stairsUp) + stepsIn(Activity.stairsDown);
}

/// Local-time day arithmetic.
///
/// Constructing through DateTime(y, m, d) rather than adding 24 hours keeps
/// day boundaries correct across daylight-saving transitions, where a day is
/// 23 or 25 hours long.
class DayMath {
  static DateTime dayStart(DateTime t) => DateTime(t.year, t.month, t.day);

  static DateTime nextDay(DateTime t) => DateTime(t.year, t.month, t.day + 1);

  static DateTime addDays(DateTime t, int days) =>
      DateTime(t.year, t.month, t.day + days);
}
