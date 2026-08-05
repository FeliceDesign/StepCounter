import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../detection/calibration_optimizer.dart';
import '../detection/calibration_params.dart';
import '../detection/sensor_sample.dart';
import '../detection/step_detector.dart';
import '../services/native_bridge.dart';
import 'database.dart';

/// Coordinates the three halves of the app: the native counting service, the
/// database, and the calibration optimiser.
///
/// Widgets talk only to this. Nothing else in lib/ knows that steps arrive over
/// a method channel or that the optimiser wants packed float32 blobs.
class StepRepository extends ChangeNotifier {
  StepRepository({
    required this.db,
    required this.bridge,
    this.drainInterval = const Duration(seconds: 30),
  });

  final AppDatabase db;
  final NativeBridge bridge;

  /// How often to poll the service for counted steps, or null to poll never.
  ///
  /// Widget tests pass null: a periodic timer makes `pumpAndSettle` loop
  /// forever, because there is always more scheduled work to run.
  final Duration? drainInterval;

  StreamSubscription<Map<String, dynamic>>? _eventSub;
  Timer? _drainTimer;

  CalibrationParams _params = CalibrationParams.factory;
  CalibrationParams get params => _params;

  bool _initialised = false;
  bool get initialised => _initialised;

  Future<void> initialise() async {
    await _loadActiveParams();

    // Anything the service counted while the UI was gone.
    await drainFromService();

    _eventSub = bridge.events.listen(_onNativeEvent);

    // A periodic drain keeps the on-screen number honest even if an event is
    // dropped, and bounds how much sits in service storage at any moment.
    final interval = drainInterval;
    if (interval != null) {
      _drainTimer = Timer.periodic(interval, (_) => drainFromService());
    }

    _initialised = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _drainTimer?.cancel();
    super.dispose();
  }

  Future<void> _onNativeEvent(Map<String, dynamic> event) async {
    switch (event['type']) {
      case 'steps':
        // The service already persisted these; pulling them across keeps the
        // visible count live rather than waiting for the periodic drain.
        await drainFromService();
      case 'autoWindow':
        await _ingestAutoWindows();
    }
  }

  // ---- Steps -------------------------------------------------------------

  /// Moves counted steps from service storage into the database.
  ///
  /// The native side deletes its copy as it hands them over, so the write here
  /// must succeed or the steps are lost. It runs as a single transaction for
  /// exactly that reason.
  Future<void> drainFromService() async {
    final buckets = await bridge.drainBuckets();
    if (buckets.isEmpty) return;
    await db.addStepBatch(buckets);
    notifyListeners();
  }

  Stream<int> watchToday() {
    final start = DayMath.dayStart(DateTime.now());
    return db.watchStepsBetween(start, DayMath.nextDay(start));
  }

  Future<int> stepsToday() {
    final start = DayMath.dayStart(DateTime.now());
    return db.stepsBetween(start, DayMath.nextDay(start));
  }

  /// Daily totals for the last [days] days, oldest first, including today.
  Future<List<DayTotal>> lastDays(int days) {
    final today = DayMath.dayStart(DateTime.now());
    return db.dailyTotals(
      DayMath.addDays(today, -(days - 1)),
      DayMath.nextDay(today),
    );
  }

  Future<List<DayTotal>> range(DateTime start, DateTime end) =>
      db.dailyTotals(start, end);

  Future<DateTime?> firstRecordedDay() => db.firstRecordedDay();

  // ---- Calibration parameters -------------------------------------------

  Future<void> _loadActiveParams() async {
    final active = await db.activeVersion();
    _params = active == null
        ? CalibrationParams.factory
        : CalibrationParams.fromJson(active.paramsJson);
    await bridge.setParams(_params);
  }

  /// Adopts a parameter set, recording it as a new version and pushing it to
  /// the running detector.
  Future<void> adoptParams(
    CalibrationParams params, {
    required String source,
    double? holdoutError,
    double? baselineError,
    int sessionCount = 0,
  }) async {
    final clamped = params.clamped();
    await db.activateVersion(CalibrationVersionsCompanion.insert(
      createdAt: DateTime.now().millisecondsSinceEpoch,
      paramsJson: clamped.toJson(),
      source: source,
      holdoutError: Value(holdoutError),
      baselineError: Value(baselineError),
      sessionCount: Value(sessionCount),
    ));
    _params = clamped;
    await bridge.setParams(clamped);
    notifyListeners();
  }

  Future<List<CalibrationVersion>> versionHistory() => db.versionHistory();

  // ---- Sessions ----------------------------------------------------------

  Future<void> saveManualSession({
    required Uint8List samples,
    required int actualSteps,
    required int durationMs,
  }) async {
    final detected = StepDetector.countSteps(
      SensorSample.unpack(samples),
      params: _params,
    );
    await db.insertSession(CalibrationSessionsCompanion.insert(
      recordedAt: DateTime.now().millisecondsSinceEpoch,
      durationMs: durationMs,
      actualSteps: actualSteps,
      detectedSteps: detected,
      source: 'manual',
      samples: samples,
    ));
    await db.trimSessions();
    notifyListeners();
  }

  /// Pulls hardware-graded windows out of the service and stores them as
  /// ordinary sessions.
  ///
  /// Automatic and manual labels land in the same table on purpose: the
  /// optimiser should learn from every piece of evidence available, and a
  /// hardware-graded window is not worth less than a hand-counted one.
  Future<int> _ingestAutoWindows() async {
    final windows = await bridge.drainAutoWindows();
    if (windows.isEmpty) return 0;

    for (final w in windows) {
      if (w.samples.isEmpty || w.hardwareCount <= 0) continue;
      await db.insertSession(CalibrationSessionsCompanion.insert(
        recordedAt: w.recordedAt,
        durationMs: 0,
        actualSteps: w.hardwareCount,
        detectedSteps: w.ourCount,
        source: 'automatic',
        samples: w.samples,
      ));
    }
    await db.trimSessions();
    notifyListeners();
    return windows.length;
  }

  Future<int> ingestAutoWindows() => _ingestAutoWindows();

  Future<List<CalibrationSession>> allSessions() => db.allSessions();

  Stream<List<CalibrationSession>> watchSessions() => db.watchSessions();

  // ---- Running the optimiser --------------------------------------------

  /// Tunes against every stored session.
  ///
  /// Deliberately uses the whole corpus rather than only the newest recording:
  /// tuning to a single walk produces parameters that are excellent for that
  /// walk and worse for every other, which is precisely the failure the holdout
  /// check exists to catch.
  Future<CalibrationOutcome?> runCalibration({bool automatic = false}) async {
    final sessions = await db.allSessions();
    if (sessions.isEmpty) return null;

    return runCalibrationInIsolate(CalibrationJob(
      packedSessions: sessions.map((s) => Uint8List.fromList(s.samples)).toList(),
      actualSteps: sessions.map((s) => s.actualSteps).toList(),
      startParamsJson: _params.toJson(),
      requireHoldout: automatic,
    ));
  }

  /// Runs automatic calibration and adopts the result only if every guardrail
  /// in [CalibrationOptimizer] passes.
  Future<CalibrationOutcome?> runAutomaticCalibration() async {
    await _ingestAutoWindows();
    final outcome = await runCalibration(automatic: true);
    if (outcome != null && outcome.accepted) {
      await adoptParams(
        outcome.params,
        source: 'automatic',
        holdoutError: outcome.holdoutError,
        baselineError: outcome.baselineHoldoutError,
        sessionCount: outcome.sessionCount,
      );
    }
    return outcome;
  }

  // ---- Scoped reset ------------------------------------------------------

  /// Each scope is independent on purpose — see the Settings sheet.
  Future<void> reset({
    bool parameters = false,
    bool sessions = false,
    bool history = false,
  }) async {
    if (parameters) {
      await db.clearCalibrationVersions();
      _params = CalibrationParams.factory;
      await bridge.setParams(_params);
      await bridge.resetDetector();
    }
    if (sessions) {
      await db.clearCalibrationSessions();
      await bridge.clearAutoWindows();
    }
    if (history) {
      await db.clearStepHistory();
    }
    notifyListeners();
  }
}
