import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:stepcounter/data/database.dart';
import 'package:stepcounter/detection/activity.dart';

/// Verifies the v1 -> v2 upgrade against a real v1 database.
///
/// Worth testing properly rather than trusting: the step table gained a column
/// that is part of its primary key, which SQLite cannot do in place, so the
/// migration rebuilds the table. A mistake there silently destroys every step
/// the user has ever recorded — and anyone who installed the first build has a
/// v1 database on their phone right now.
void main() {
  late File file;

  setUp(() {
    file = File(
      '${Directory.systemTemp.path}/stepcounter_mig_'
      '${DateTime.now().microsecondsSinceEpoch}.sqlite',
    );
    if (file.existsSync()) file.deleteSync();
  });

  tearDown(() {
    if (file.existsSync()) file.deleteSync();
  });

  /// Builds the schema exactly as version 1 shipped it.
  void createV1({required List<(int minute, int steps)> rows}) {
    final db = sqlite3.open(file.path);
    db.execute('''
      CREATE TABLE step_minutes (
        minute_epoch INTEGER NOT NULL,
        steps INTEGER NOT NULL,
        PRIMARY KEY (minute_epoch)
      );
    ''');
    db.execute('''
      CREATE TABLE calibration_sessions (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        recorded_at INTEGER NOT NULL,
        duration_ms INTEGER NOT NULL,
        actual_steps INTEGER NOT NULL,
        detected_steps INTEGER NOT NULL,
        source TEXT NOT NULL,
        samples BLOB NOT NULL
      );
    ''');
    db.execute('''
      CREATE TABLE calibration_versions (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        created_at INTEGER NOT NULL,
        params_json TEXT NOT NULL,
        source TEXT NOT NULL,
        holdout_error REAL,
        baseline_error REAL,
        session_count INTEGER NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 0
      );
    ''');

    for (final (minute, steps) in rows) {
      db.execute('INSERT INTO step_minutes (minute_epoch, steps) VALUES (?, ?)',
          [minute, steps]);
    }
    db.execute(
      "INSERT INTO calibration_sessions "
      "(recorded_at, duration_ms, actual_steps, detected_steps, source, samples) "
      "VALUES (1000, 20000, 50, 48, 'manual', ?)",
      [
        [1, 2, 3, 4]
      ],
    );
    db.execute(
      "INSERT INTO calibration_versions "
      "(created_at, params_json, source, session_count, is_active) "
      "VALUES (2000, '{\"thresholdSigma\":0.9}', 'manual', 4, 1)",
    );

    db.execute('PRAGMA user_version = 1;');
    db.dispose();
  }

  test('upgrades and keeps every recorded step', () async {
    final today = DayMath.dayStart(DateTime.now());
    final base = today.millisecondsSinceEpoch ~/ 60000;
    createV1(rows: [(base + 10, 120), (base + 11, 80), (base + 600, 45)]);

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final total = await db.stepsBetween(today, DayMath.nextDay(today));
    expect(total, 245, reason: 'no steps may be lost in the rebuild');
  });

  test('labels pre-existing steps unknown rather than guessing', () async {
    final today = DayMath.dayStart(DateTime.now());
    final base = today.millisecondsSinceEpoch ~/ 60000;
    createV1(rows: [(base + 5, 300)]);

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final totals = await db.activityTotals(today, DayMath.nextDay(today));
    expect(totals[Activity.unknown], 300);
    expect(totals[Activity.walking], isNull,
        reason: 'old rows have no activity, so claiming one would be a lie');
  });

  test('keeps calibration sessions and versions', () async {
    createV1(rows: const []);

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final sessions = await db.allSessions();
    expect(sessions.length, 1);
    expect(sessions.single.actualSteps, 50);
    expect(sessions.single.samples, [1, 2, 3, 4]);
    // Columns added by the upgrade start empty on migrated rows.
    expect(sessions.single.pressureSamples, isNull);
    expect(sessions.single.declaredActivity, isNull);

    final active = await db.activeVersion();
    expect(active, isNotNull);
    expect(active!.source, 'manual');
    expect(active.activityParamsJson, isNull);
  });

  test('the upgraded database accepts per-activity writes', () async {
    createV1(rows: const []);

    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final today = DayMath.dayStart(DateTime.now());
    final minute = today.millisecondsSinceEpoch ~/ 60000 + 30;

    // The whole point of the rebuild: one minute now holds several activities.
    await db.addSteps(minute, Activity.walking, 40);
    await db.addSteps(minute, Activity.stairsUp, 15);
    await db.addSteps(minute, Activity.walking, 5);

    final totals = await db.activityTotals(today, DayMath.nextDay(today));
    expect(totals[Activity.walking], 45);
    expect(totals[Activity.stairsUp], 15);
  });

  test('a fresh database is created at the current version, not migrated',
      () async {
    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final today = DayMath.dayStart(DateTime.now());
    await db.addSteps(
      today.millisecondsSinceEpoch ~/ 60000 + 1,
      Activity.running,
      10,
    );
    expect(
      (await db.activityTotals(today, DayMath.nextDay(today)))[Activity.running],
      10,
    );
  });

  /// A v2 database: the v1 schema plus the three columns v2 added, holding one
  /// manual session and one automatic window.
  ///
  /// Needed separately from [createV1] because the v2 -> v3 step backfills
  /// `actual_steps` into two new columns depending on `source`, and a v1
  /// fixture would exercise both migrations at once and hide which one did it.
  void createV2() {
    final db = sqlite3.open(file.path);
    db.execute('''
      CREATE TABLE step_minutes (
        minute_epoch INTEGER NOT NULL,
        activity TEXT NOT NULL DEFAULT 'unknown',
        steps INTEGER NOT NULL,
        PRIMARY KEY (minute_epoch, activity)
      );
    ''');
    db.execute('''
      CREATE TABLE calibration_sessions (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        recorded_at INTEGER NOT NULL,
        duration_ms INTEGER NOT NULL,
        actual_steps INTEGER NOT NULL,
        detected_steps INTEGER NOT NULL,
        source TEXT NOT NULL,
        samples BLOB NOT NULL,
        pressure_samples BLOB,
        declared_activity TEXT
      );
    ''');
    db.execute('''
      CREATE TABLE calibration_versions (
        id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
        created_at INTEGER NOT NULL,
        params_json TEXT NOT NULL,
        activity_params_json TEXT,
        source TEXT NOT NULL,
        holdout_error REAL,
        baseline_error REAL,
        session_count INTEGER NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 0
      );
    ''');
    db.execute(
      "INSERT INTO calibration_sessions "
      "(recorded_at, duration_ms, actual_steps, detected_steps, source, samples) "
      "VALUES (1000, 20000, 120, 118, 'manual', ?)",
      [
        [1, 2, 3, 4]
      ],
    );
    db.execute(
      "INSERT INTO calibration_sessions "
      "(recorded_at, duration_ms, actual_steps, detected_steps, source, samples) "
      "VALUES (2000, 30000, 46, 44, 'automatic', ?)",
      [
        [5, 6, 7, 8]
      ],
    );
    db.execute('PRAGMA user_version = 2;');
    db.dispose();
  }

  test('v2 to v3 sends each ground truth to the column that means it', () async {
    createV2();
    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final sessions = await db.allSessions();
    final manual = sessions.firstWhere((s) => s.source == 'manual');
    final auto = sessions.firstWhere((s) => s.source == 'automatic');

    // actual_steps meant the user's count on one row and the pedometer's on
    // the other. Without the backfill every historical test would show as
    // unlabelled in the results list.
    expect(manual.userSteps, 120);
    expect(manual.hardwareSteps, isNull);
    expect(auto.hardwareSteps, 46);
    expect(auto.userSteps, isNull);

    // The optimiser's label is untouched by the split.
    expect(manual.actualSteps, 120);
    expect(auto.actualSteps, 46);

    // A walk the user made and counted is protected from trimming; a free
    // background window is not.
    expect(manual.pinned, isTrue);
    expect(auto.pinned, isFalse);
  });

  test('v1 upgrades all the way to v3 in one hop', () async {
    createV1(rows: const []);
    final db = AppDatabase(NativeDatabase(file));
    addTearDown(db.close);

    final sessions = await db.allSessions();
    expect(sessions.single.userSteps, 50);
    expect(sessions.single.pinned, isTrue);
  });

}
