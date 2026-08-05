import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stepcounter/app_scope.dart';
import 'package:stepcounter/data/database.dart';
import 'package:stepcounter/data/settings.dart';
import 'package:stepcounter/data/step_repository.dart';
import 'package:stepcounter/detection/calibration_params.dart';
import 'package:stepcounter/detection/sensor_sample.dart';
import 'package:stepcounter/ui/home_screen.dart';
import 'package:stepcounter/ui/reset_sheet.dart';

import 'fake_bridge.dart';
import 'fixtures/gait_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late FakeNativeBridge bridge;
  late StepRepository repo;
  late Settings settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    bridge = FakeNativeBridge();
    repo = StepRepository(db: db, bridge: bridge, drainInterval: null);
    settings = await Settings.load();
  });

  tearDown(() async {
    repo.dispose();
    await bridge.close();
    await db.close();
  });

  Widget wrap(Widget child) => AppScope(
        repository: repo,
        settings: settings,
        bridge: bridge,
        child: MaterialApp(home: child),
      );

  int minuteOf(DateTime t) => t.millisecondsSinceEpoch ~/ 60000;

  /// Tears the tree down inside the test rather than at teardown.
  ///
  /// Cancelling a drift query stream schedules a zero-duration timer, and the
  /// test framework asserts if any timer is still pending once the tree is
  /// disposed. Unmounting and pumping lets that timer run first.
  /// Pumped with a real duration, not `pump()`: a bare pump does not advance
  /// the fake clock, so a zero-duration timer would still be pending.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  group('home screen', () {
    testWidgets('shows zero before anything is recorded', (tester) async {
      await repo.initialise();
      await tester.pumpWidget(wrap(const HomeScreen()));
      await tester.pumpAndSettle();

      expect(find.text('0'), findsOneWidget);
      expect(find.text('steps'), findsOneWidget);
      expect(find.text('Last 7 days'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('shows the count with thousands separators', (tester) async {
      bridge.pendingBuckets = {minuteOf(DateTime.now()): 4321};
      await repo.initialise();

      await tester.pumpWidget(wrap(const HomeScreen()));
      await tester.pumpAndSettle();

      expect(find.text('4,321'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('reports remaining steps against the goal', (tester) async {
      await settings.setDailyGoal(5000);
      bridge.pendingBuckets = {minuteOf(DateTime.now()): 1000};
      await repo.initialise();

      await tester.pumpWidget(wrap(const HomeScreen()));
      await tester.pumpAndSettle();

      expect(find.text('4,000 to go'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('announces a reached goal instead of a negative remainder',
        (tester) async {
      await settings.setDailyGoal(1000);
      bridge.pendingBuckets = {minuteOf(DateTime.now()): 2500};
      await repo.initialise();

      await tester.pumpWidget(wrap(const HomeScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Daily goal reached'), findsOneWidget);

      await unmount(tester);
    });
  });

  group('reset sheet', () {
    Future<void> openSheet(WidgetTester tester) async {
      await tester.pumpWidget(wrap(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showResetSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('nothing is preselected and Reset starts disabled',
        (tester) async {
      await repo.initialise();
      await openSheet(tester);

      for (final cb in tester.widgetList<CheckboxListTile>(
          find.byType(CheckboxListTile))) {
        expect(cb.value, isFalse);
      }

      final reset = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Reset'),
      );
      expect(reset.onPressed, isNull);
    });

    testWidgets('selecting a scope enables Reset', (tester) async {
      await repo.initialise();
      await openSheet(tester);

      await tester.tap(find.text('Learned settings'));
      await tester.pumpAndSettle();

      final reset = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Reset'),
      );
      expect(reset.onPressed, isNotNull);
    });

    testWidgets('resetting learned settings leaves step history alone',
        (tester) async {
      bridge.pendingBuckets = {minuteOf(DateTime.now()): 900};
      await repo.initialise();
      await repo.adoptParams(
        const CalibrationParams(thresholdSigma: 1.7),
        source: 'manual',
      );

      await openSheet(tester);
      await tester.tap(find.text('Learned settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
      await tester.pumpAndSettle();

      expect(repo.params, CalibrationParams.factory);
      expect(await repo.stepsToday(), 900);
    });

    testWidgets('deleting step history demands a second confirmation',
        (tester) async {
      bridge.pendingBuckets = {minuteOf(DateTime.now()): 900};
      await repo.initialise();

      await openSheet(tester);
      await tester.tap(find.text('Step history'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
      await tester.pumpAndSettle();

      expect(find.text('Delete step history?'), findsOneWidget);

      // Backing out must leave the data untouched.
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(await repo.stepsToday(), 900);
    });

    testWidgets('confirming the second prompt does delete the history',
        (tester) async {
      bridge.pendingBuckets = {minuteOf(DateTime.now()): 900};
      await repo.initialise();

      await openSheet(tester);
      await tester.tap(find.text('Step history'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(await repo.stepsToday(), 0);
    });

    testWidgets('sessions survive a history-only reset', (tester) async {
      await repo.initialise();
      await repo.saveManualSession(
        samples: SensorSample.pack(GaitFixtures.walk(steps: 20)),
        actualSteps: 20,
        durationMs: 15000,
      );

      await openSheet(tester);
      await tester.tap(find.text('Step history'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect((await repo.allSessions()).length, 1);
    });
  });
}
