import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stepcounter/app_scope.dart';
import 'package:stepcounter/data/database.dart';
import 'package:stepcounter/data/settings.dart';
import 'package:stepcounter/data/step_repository.dart';
import 'package:stepcounter/detection/activity.dart';
import 'package:stepcounter/detection/calibration_params.dart';
import 'package:stepcounter/detection/sensor_sample.dart';
import 'package:stepcounter/ui/home_screen.dart';
import 'package:stepcounter/ui/activity_palette.dart';
import 'package:stepcounter/ui/calibration_history_screen.dart';
import 'package:stepcounter/ui/reset_sheet.dart';
import 'package:stepcounter/ui/settings_screen.dart';

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
      bridge.queueSteps(minuteOf(DateTime.now()), 4321);
      await repo.initialise();

      await tester.pumpWidget(wrap(const HomeScreen()));
      await tester.pumpAndSettle();

      expect(find.text('4,321'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('reports remaining steps against the goal', (tester) async {
      await settings.setDailyGoal(5000);
      bridge.queueSteps(minuteOf(DateTime.now()), 1000);
      await repo.initialise();

      await tester.pumpWidget(wrap(const HomeScreen()));
      await tester.pumpAndSettle();

      expect(find.text('4,000 to go'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('announces a reached goal instead of a negative remainder',
        (tester) async {
      await settings.setDailyGoal(1000);
      bridge.queueSteps(minuteOf(DateTime.now()), 2500);
      await repo.initialise();

      await tester.pumpWidget(wrap(const HomeScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Daily goal reached'), findsOneWidget);

      await unmount(tester);
    });
  });

  group('live updates', () {
    // The reported bug: the main screen number only changed on app restart.
    // addSteps writes through a raw statement, which drift cannot associate
    // with a table, so nothing watching step_minutes was ever woken.
    testWidgets('the count updates without rebuilding the screen',
        (tester) async {
      await repo.initialise();
      await tester.pumpWidget(wrap(const HomeScreen()));
      await tester.pumpAndSettle();
      expect(find.text('0'), findsOneWidget);

      // Exactly what a step event from the service triggers.
      bridge.queueSteps(minuteOf(DateTime.now()), 27);
      await repo.drainFromService();
      await tester.pumpAndSettle();

      expect(find.text('27'), findsOneWidget);

      bridge.queueSteps(minuteOf(DateTime.now()), 13);
      await repo.drainFromService();
      await tester.pumpAndSettle();

      expect(find.text('40'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a step event from the service refreshes the display',
        (tester) async {
      await repo.initialise();
      await tester.pumpWidget(wrap(const HomeScreen()));
      await tester.pumpAndSettle();

      bridge.queueSteps(minuteOf(DateTime.now()), 55);
      bridge.emit({'type': 'steps', 'count': 55});
      await tester.pumpAndSettle();

      expect(find.text('55'), findsOneWidget);

      await unmount(tester);
    });
  });

  group('Android comparison', () {
    testWidgets('shows both counts and the difference', (tester) async {
      bridge.hardwareToday = 4180;
      bridge.queueSteps(minuteOf(DateTime.now()), 4321);
      await repo.initialise();

      await tester.pumpWidget(wrap(const HomeScreen()));
      await tester.pumpAndSettle();

      expect(find.text('This app'), findsOneWidget);
      expect(find.text('Android'), findsOneWidget);
      expect(find.text('4,180'), findsOneWidget);
      // 141 more than Android, which is +3.4%.
      expect(find.textContaining('+141'), findsOneWidget);
      expect(find.textContaining('3.4%'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('says so when the Android sensor is unavailable',
        (tester) async {
      bridge.hardwareToday = null;
      bridge.queueSteps(minuteOf(DateTime.now()), 500);
      await repo.initialise();

      await tester.pumpWidget(wrap(const HomeScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Android step sensor unavailable'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('reports an exact match rather than a zero difference',
        (tester) async {
      bridge.hardwareToday = 1000;
      bridge.queueSteps(minuteOf(DateTime.now()), 1000);
      await repo.initialise();

      await tester.pumpWidget(wrap(const HomeScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Exact match'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('suppresses a percentage when the sample is tiny',
        (tester) async {
      // 3 out of 12 is 25%, which reads as alarming and means nothing.
      bridge.hardwareToday = 12;
      bridge.queueSteps(minuteOf(DateTime.now()), 15);
      await repo.initialise();

      await tester.pumpWidget(wrap(const HomeScreen()));
      await tester.pumpAndSettle();

      expect(find.text('+3'), findsOneWidget);
      expect(find.textContaining('%'), findsNothing);

      await unmount(tester);
    });

    testWidgets('a negative difference is shown without a plus sign',
        (tester) async {
      bridge.hardwareToday = 2000;
      bridge.queueSteps(minuteOf(DateTime.now()), 1800);
      await repo.initialise();

      await tester.pumpWidget(wrap(const HomeScreen()));
      await tester.pumpAndSettle();

      expect(find.textContaining('-200'), findsOneWidget);

      await unmount(tester);
    });
  });

  group('activity colouring', () {
    testWidgets('the legend appears once there is more than one activity',
        (tester) async {
      final m = minuteOf(DateTime.now());
      bridge.queueSteps(m, 900, Activity.walking);
      bridge.queueSteps(m, 300, Activity.running);
      bridge.queueSteps(m, 60, Activity.stairsUp);
      await repo.initialise();

      await tester.pumpWidget(wrap(const HomeScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Walking'), findsOneWidget);
      expect(find.text('Running'), findsOneWidget);
      expect(find.text('Stairs'), findsOneWidget);
      // The total still reads as the sum of every activity.
      expect(find.text('1,260'), findsOneWidget);

      await unmount(tester);
    });

    testWidgets('a plain walking day shows no legend at all', (tester) async {
      bridge.queueSteps(minuteOf(DateTime.now()), 500, Activity.walking);
      await repo.initialise();

      await tester.pumpWidget(wrap(const HomeScreen()));
      await tester.pumpAndSettle();

      // One category is not a breakdown, so a key would be pure clutter.
      expect(find.text('Walking'), findsNothing);

      await unmount(tester);
    });

    testWidgets('stairs up and down share one legend entry', (tester) async {
      final m = minuteOf(DateTime.now());
      bridge.queueSteps(m, 400, Activity.walking);
      bridge.queueSteps(m, 40, Activity.stairsUp);
      bridge.queueSteps(m, 35, Activity.stairsDown);
      await repo.initialise();

      await tester.pumpWidget(wrap(const HomeScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Stairs'), findsOneWidget);
      expect(find.text('Stairs up'), findsNothing);

      await unmount(tester);
    });

    testWidgets('every activity has a distinct colour in both themes',
        (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        late BuildContext ctx;
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Builder(builder: (context) {
            ctx = context;
            return const SizedBox();
          }),
        ));
        final colours = {
          for (final a in ActivityPalette.stackOrder)
            ActivityPalette.of(ctx, a)
        };
        expect(colours.length, ActivityPalette.stackOrder.length,
            reason: 'colours collide in \$brightness');
      }
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
      bridge.queueSteps(minuteOf(DateTime.now()), 900);
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
      bridge.queueSteps(minuteOf(DateTime.now()), 900);
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
      bridge.queueSteps(minuteOf(DateTime.now()), 900);
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

  group('calibration results', () {
    Future<int> addSession(
      String source, {
      required int detected,
      int? userSteps,
      int? hardwareSteps,
    }) =>
        db.insertSession(CalibrationSessionsCompanion.insert(
          recordedAt: DateTime.now().millisecondsSinceEpoch,
          durationMs: 64000,
          actualSteps: userSteps ?? hardwareSteps ?? detected,
          detectedSteps: detected,
          source: source,
          samples: Uint8List.fromList([1, 2, 3, 4]),
          userSteps: Value(userSteps),
          hardwareSteps: Value(hardwareSteps),
        ));

    testWidgets('a manual test shows both deviations', (tester) async {
      await addSession('manual', detected: 118, userSteps: 120, hardwareSteps: 121);

      await tester.pumpWidget(wrap(const CalibrationHistoryScreen()));
      // Not pumpAndSettle: the screen holds an open drift query stream, which
      // never reaches a quiescent state for it to settle into.
      await tester.pump(const Duration(milliseconds: 10));

      expect(find.text('118'), findsOneWidget); // what the app counted
      expect(find.text('120'), findsOneWidget); // what the user counted
      expect(find.text('121'), findsOneWidget); // what Android counted
      // Signed, and with a percentage because both references clear the
      // hundred-step floor below which a percentage is just noise.
      expect(find.textContaining('-2 ·'), findsOneWidget);
      expect(find.textContaining('-3 ·'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('a missing reference reads as absent, never as zero',
        (tester) async {
      // An automatic window has no user count. Rendering that as "0" would
      // claim the user counted nothing, and a 100% deviation with it.
      await addSession('automatic', detected: 44, hardwareSteps: 46);

      await tester.pumpWidget(wrap(const CalibrationHistoryScreen()));
      await tester.pump(const Duration(milliseconds: 10));

      expect(find.text('—'), findsOneWidget);
      expect(find.text('44'), findsOneWidget);
      expect(find.text('46'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('the saved-walk count comes from the database, not the '
        'native staging directory', (tester) async {
      // The direct regression test for "0 collected windows". The native
      // directory is drained as soon as the UI attaches, so a count read from
      // it was always zero however many walks had been collected.
      bridge.diagnosticsPayload = const {
        // The staging directory is empty, as it almost always is.
        'autoWindowCount': 0,
        'hasHardwareCounter': true,
      };
      for (var i = 0; i < 3; i++) {
        await addSession('automatic', detected: 40 + i, hardwareSteps: 41 + i);
      }

      await tester.pumpWidget(wrap(const SettingsScreen()));
      await tester.pump(const Duration(milliseconds: 10));

      expect(find.textContaining('3 collected automatically'), findsWidgets);
      await unmount(tester);
    });
  });

}
