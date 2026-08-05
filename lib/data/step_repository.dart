import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../detection/activity.dart';
import '../detection/activity_optimizer.dart';
import '../detection/calibration_optimizer.dart';
import '../detection/calibration_params.dart';
import '../detection/sensor_sample.dart';
import '../detection/motion_pipeline.dart';
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

  ActivityParams _activityParams = ActivityParams.factory;
  ActivityParams get activityParams => _activityParams;

  int? _hardwareToday;

  /// Android's own step count for today, for the side-by-side comparison.
  /// Null when the device has no pedometer or has not reported yet.
  int? get hardwareToday => _hardwareToday;

  bool _initialised = false;
  bool get initialised => _initialised;

  Future<void> initialise() async {
    await _loadActiveParams();

    // Anything the service counted while the UI was gone.
    await drainFromService();

    _eventSub = bridge.events.listen(_onNativeEvent);
    await refreshHardwareCount();

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
    final hw = (event['hardwareToday'] as num?)?.toInt();
    if (hw != null && hw >= 0 && hw != _hardwareToday) {
      _hardwareToday = hw;
      notifyListeners();
    }

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

    // The service only knows what it counted since it started, so its
    // notification would restart from zero partway through the day. We hold the
    // real total, so we hand it back.
    await bridge.setTodayTotal(await stepsToday());
    notifyListeners();
  }

  /// Refreshes Android's own count. Cheap, and only ever called while the UI
  /// is on screen.
  Future<void> refreshHardwareCount() async {
    final d = await bridge.diagnostics();
    if (d.hardwareToday != _hardwareToday) {
      _hardwareToday = d.hardwareToday;
      notifyListeners();
    }
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

  Future<Map<Activity, int>> activityTotals(DateTime start, DateTime end) =>
      db.activityTotals(start, end);

  Future<DateTime?> firstRecordedDay() => db.firstRecordedDay();

  // ---- Calibration parameters -------------------------------------------

  Future<void> _loadActiveParams() async {
    final active = await db.activeVersion();
    _params = active == null
        ? CalibrationParams.factory
        : CalibrationParams.fromJson(active.paramsJson);

    // Null for versions adopted before activity detection existed, which is
    // why this falls back rather than assuming the column is populated.
    final activityJson = active?.activityParamsJson;
    _activityParams = activityJson == null
        ? ActivityParams.factory
        : ActivityParams.fromJson(activityJson);

    await bridge.setParams(_params);
    await bridge.setActivityParams(_activityParams);
  }

  /// Adopts a parameter set, recording it as a new version and pushing it to
  /// the running detector.
  Future<void> adoptParams(
    CalibrationParams params, {
    required String source,
    ActivityParams? activityParams,
    double? holdoutError,
    double? baselineError,
    int sessionCount = 0,
  }) async {
    final clamped = params.clamped();
    final activityClamped = (activityParams ?? _activityParams).clamped();

    await db.activateVersion(CalibrationVersionsCompanion.insert(
      createdAt: DateTime.now().millisecondsSinceEpoch,
      paramsJson: clamped.toJson(),
      activityParamsJson: Value(activityClamped.toJson()),
      source: source,
      holdoutError: Value(holdoutError),
      baselineError: Value(baselineError),
      sessionCount: Value(sessionCount),
    ));

    _params = clamped;
    _activityParams = activityClamped;
    await bridge.setParams(clamped);
    await bridge.setActivityParams(activityClamped);
    notifyListeners();
  }

  Future<List<CalibrationVersion>> versionHistory() => db.versionHistory();

  // ---- Sessions ----------------------------------------------------------

  Future<void> saveManualSession({
    required Uint8List samples,
    required int actualSteps,
    required int durationMs,
    Uint8List? pressureSamples,
    Activity? declaredActivity,
  }) async {
    final detected = MotionPipeline.replayTotal(
      SensorSample.unpack(samples),
      pressure: pressureSamples == null
          ? const []
          : PressureSample.unpack(pressureSamples),
      params: _params,
      activityParams: _activityParams,
    );
    await db.insertSession(CalibrationSessionsCompanion.insert(
      recordedAt: DateTime.now().millisecondsSinceEpoch,
      durationMs: durationMs,
      actualSteps: actualSteps,
      detectedSteps: detected,
      source: 'manual',
      samples: samples,
      pressureSamples: Value(pressureSamples),
      declaredActivity: Value(declaredActivity?.id),
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
        pressureSamples: Value(w.pressureSamples),
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
      packedPressure: sessions
          .map((s) => s.pressureSamples == null
              ? null
              : Uint8List.fromList(s.pressureSamples!))
          .toList(),
      actualSteps: sessions.map((s) => s.actualSteps).toList(),
      startParamsJson: _params.toJson(),
      requireHoldout: automatic,
    ));
  }

  /// Tunes the activity thresholds against sessions the user labelled.
  ///
  /// Only manual sessions carry a declared activity — the hardware pedometer
  /// counts steps but has no opinion about stairs — so this returns null until
  /// a few labelled walks exist.
  Future<ActivityOutcome?> runActivityCalibration({
    bool automatic = false,
  }) async {
    final sessions = (await db.allSessions())
        .where((s) => s.declaredActivity != null)
        .toList();
    if (sessions.isEmpty) return null;

    return runActivityCalibrationInIsolate(ActivityCalibrationJob(
      packedSessions: sessions.map((s) => Uint8List.fromList(s.samples)).toList(),
      packedPressure: sessions
          .map((s) => s.pressureSamples == null
              ? null
              : Uint8List.fromList(s.pressureSamples!))
          .toList(),
      declaredActivities: sessions.map((s) => s.declaredActivity!).toList(),
      startParamsJson: _activityParams.toJson(),
      stepParamsJson: _params.toJson(),
      requireHoldout: automatic,
    ));
  }

  /// Runs automatic calibration and adopts the result only if every guardrail
  /// in [CalibrationOptimizer] passes.
  Future<CalibrationOutcome?> runAutomaticCalibration() async {
    await _ingestAutoWindows();

    // Activity thresholds are tuned first so the step optimiser scores
    // candidates through the same classifier the app will actually run.
    final activityOutcome = await runActivityCalibration(automatic: true);

    final outcome = await runCalibration(automatic: true);
    final adoptActivity = activityOutcome != null && activityOutcome.accepted;

    if (outcome != null && outcome.accepted) {
      await adoptParams(
        outcome.params,
        source: 'automatic',
        activityParams: adoptActivity ? activityOutcome.params : null,
        holdoutError: outcome.holdoutError,
        baselineError: outcome.baselineHoldoutError,
        sessionCount: outcome.sessionCount,
      );
    } else if (adoptActivity) {
      // The classifier improved even though step counting did not, which is a
      // perfectly ordinary outcome once stairs are involved.
      await adoptParams(
        _params,
        source: 'automatic',
        activityParams: activityOutcome.params,
        sessionCount: activityOutcome.sessionCount,
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
      _activityParams = ActivityParams.factory;
      await bridge.setParams(_params);
      await bridge.setActivityParams(_activityParams);
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
