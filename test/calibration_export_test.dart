import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stepcounter/data/calibration_export.dart';
import 'package:stepcounter/data/database.dart';
import 'package:stepcounter/detection/activity.dart';
import 'package:stepcounter/detection/calibration_params.dart';
import 'package:stepcounter/detection/sensor_sample.dart';
import 'package:stepcounter/detection/step_detector.dart';

import 'fixtures/gait_fixtures.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(NativeDatabase.memory()));
  tearDown(() => db.close());

  Future<int> addSession({
    required String source,
    required List<SensorSample> samples,
    int? userSteps,
    int? hardwareSteps,
    String? activity,
  }) =>
      db.insertSession(CalibrationSessionsCompanion.insert(
        recordedAt: DateTime.now().millisecondsSinceEpoch,
        durationMs: 40000,
        actualSteps: userSteps ?? hardwareSteps ?? 0,
        detectedSteps: StepDetector.countSteps(samples),
        source: source,
        samples: SensorSample.pack(samples),
        userSteps: Value(userSteps),
        hardwareSteps: Value(hardwareSteps),
        declaredActivity: Value(activity),
      ));

  Future<Map<String, Object?>> exportAll({bool includeSamples = true}) async =>
      CalibrationExport.build(
        sessions: await db.allSessions(),
        versions: await db.versionHistory(),
        activeParams: CalibrationParams.factory,
        activeActivityParams: ActivityParams.factory,
        includeSamples: includeSamples,
      );

  test('carries both references and says which is missing', () async {
    await addSession(
      source: 'manual',
      samples: GaitFixtures.walk(steps: 40),
      userSteps: 40,
      hardwareSteps: 41,
      activity: 'walking',
    );
    await addSession(
      source: 'automatic',
      samples: GaitFixtures.walk(steps: 30),
      hardwareSteps: 30,
    );

    final data = await exportAll();
    final sessions = (data['sessions']! as List).cast<Map<String, Object?>>();

    final manual = sessions.firstWhere((s) => s['source'] == 'manual');
    expect(manual['userSteps'], 40);
    expect(manual['hardwareSteps'], 41);
    expect(manual['declaredActivity'], 'walking');

    // An automatic window has no user count, and the export says so rather
    // than filling in a zero that would read as "counted nothing".
    final auto = sessions.firstWhere((s) => s['source'] == 'automatic');
    expect(auto['userSteps'], isNull);
    expect(auto['hardwareSteps'], 30);
  });

  test('the raw samples round-trip back into the detector', () async {
    // The whole point of including recordings is that someone else can re-run
    // the detector on them. If base64 in the file does not reconstruct the
    // exact bytes the detector saw, the export is decorative.
    final walk = GaitFixtures.walk(steps: 60);
    await addSession(source: 'manual', samples: walk, userSteps: 60);

    final data = await exportAll();
    final session = (data['sessions']! as List).first as Map<String, Object?>;
    final blob = (session['samples']! as Map)['data']! as String;

    final restored = SensorSample.unpack(base64Decode(blob));
    expect(restored.length, walk.length);
    expect(
      StepDetector.countSteps(restored),
      StepDetector.countSteps(walk),
      reason: 'a reader of the export must reach the same count we did',
    );
  });

  test('replayedSteps re-scores under the current parameters', () async {
    // detectedSteps is frozen at record time; replayedSteps answers "what
    // would today's detector make of this walk", which is the question an
    // analysis actually asks after a calibration change.
    final jiggle = GaitFixtures.handJiggle(durationSeconds: 60);
    final id = await db.insertSession(CalibrationSessionsCompanion.insert(
      recordedAt: DateTime.now().millisecondsSinceEpoch,
      durationMs: 60000,
      actualSteps: 0,
      // A deliberately stale count, as if recorded before the jiggle work.
      detectedSteps: 93,
      source: 'automatic',
      samples: SensorSample.pack(jiggle),
      hardwareSteps: const Value(0),
    ));
    expect(id, greaterThan(0));

    final data = await exportAll(includeSamples: false);
    final session = (data['sessions']! as List).first as Map<String, Object?>;

    expect(session['detectedSteps'], 93);
    expect(session['replayedSteps'], lessThan(15));
  });

  test('leaving recordings out makes the file small enough to paste', () async {
    for (var i = 0; i < 5; i++) {
      await addSession(
        source: 'manual',
        samples: GaitFixtures.walk(steps: 60),
        userSteps: 60,
      );
    }

    final withSamples = CalibrationExport.encode(await exportAll());
    final withoutSamples =
        CalibrationExport.encode(await exportAll(includeSamples: false));

    expect(withoutSamples.length, lessThan(8 * 1024));
    expect(withSamples.length, greaterThan(100 * 1024));

    // The counts survive either way; only the signal is dropped.
    final lean = jsonDecode(withoutSamples) as Map<String, Object?>;
    final session = (lean['sessions']! as List).first as Map<String, Object?>;
    expect(session.containsKey('samples'), isFalse);
    expect(session['userSteps'], 60);
    expect(session['sampleCount'], greaterThan(0));
  });

  test('the size estimate is close enough to warn on', () async {
    for (var i = 0; i < 3; i++) {
      await addSession(
        source: 'manual',
        samples: GaitFixtures.walk(steps: 40),
        userSteps: 40,
      );
    }
    final sessions = await db.allSessions();
    final actual = CalibrationExport.encode(await exportAll()).length;
    final estimate = CalibrationExport.estimatedBytes(
      sessions: sessions,
      includeSamples: true,
    );
    // Within a factor of two is plenty to choose between "a few KB" and
    // "several MB", which is the only decision it informs.
    expect(estimate, greaterThan(actual ~/ 2));
    expect(estimate, lessThan(actual * 2));
  });

  test('is valid JSON and describes its own layout', () async {
    await addSession(
      source: 'manual',
      samples: GaitFixtures.walk(steps: 20),
      userSteps: 20,
    );

    final decoded =
        jsonDecode(CalibrationExport.encode(await exportAll()))
            as Map<String, Object?>;

    expect(decoded['schema'], CalibrationExport.schemaVersion);
    expect(decoded['activeParams'], isA<Map<String, Object?>>());
    // A reader who has never seen this repository has to be able to interpret
    // the columns, so the meanings travel with the data.
    expect((decoded['about']! as Map)['replayedSteps'], isA<String>());
    final session = (decoded['sessions']! as List).first as Map<String, Object?>;
    expect((session['samples']! as Map)['layout'],
        ['t_ms', 'ax', 'ay', 'az', 'gx', 'gy', 'gz']);
    expect((session['samples']! as Map)['encoding'], 'base64:float32le');
  });

  test('an unparseable stored parameter blob is surfaced, not dropped',
      () async {
    await db.activateVersion(CalibrationVersionsCompanion.insert(
      createdAt: DateTime.now().millisecondsSinceEpoch,
      paramsJson: 'not json at all',
      source: 'manual',
    ));

    final data = await exportAll();
    final version = (data['versions']! as List).first as Map<String, Object?>;
    expect((version['params']! as Map)['unparseable'], 'not json at all');
  });
}
