import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'data/database.dart';
import 'data/settings.dart';
import 'data/step_repository.dart';
import 'services/native_bridge.dart';
import 'services/permissions.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = AppDatabase();
  final bridge = NativeBridge();
  final settings = await Settings.load();
  final repository = StepRepository(db: db, bridge: bridge);

  // Pulls across anything the service counted while the UI was gone, and
  // pushes the active calibration down to the detector.
  await repository.initialise();

  if (settings.countingEnabled) {
    await Permissions.requestAll();
    await bridge.setAutoCalibration(settings.autoCalibrationEnabled);
    await bridge.startService();
  }

  runApp(StepCounterApp(
    repository: repository,
    settings: settings,
    bridge: bridge,
  ));
}

class StepCounterApp extends StatelessWidget {
  const StepCounterApp({
    super.key,
    required this.repository,
    required this.settings,
    required this.bridge,
  });

  final StepRepository repository;
  final Settings settings;
  final NativeBridge bridge;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      repository: repository,
      settings: settings,
      bridge: bridge,
      child: MaterialApp(
        title: 'Step Counter',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: const HomeScreen(),
      ),
    );
  }

  ThemeData _theme(Brightness brightness) => ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3D7A5A),
          brightness: brightness,
        ),
        useMaterial3: true,
      );
}
