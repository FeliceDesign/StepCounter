import 'dart:async';
import 'dart:typed_data';

import 'package:stepcounter/data/database.dart';
import 'package:stepcounter/detection/activity.dart';
import 'package:stepcounter/detection/calibration_params.dart';
import 'package:stepcounter/services/native_bridge.dart';

/// In-memory stand-in for the Android service.
///
/// Mirrors the one behaviour that matters most for correctness: draining is
/// destructive. The fake forgets buckets and windows as it hands them over,
/// exactly as the real service does, so a test can catch a repository that
/// drops them before committing.
class FakeNativeBridge extends NativeBridge {
  FakeNativeBridge();

  final _events = StreamController<Map<String, dynamic>>.broadcast();

  List<StepBucket> pendingBuckets = [];

  /// Convenience for tests that do not care about activity.
  void queueSteps(int minuteEpoch, int steps,
          [Activity activity = Activity.walking]) =>
      pendingBuckets.add(StepBucket(
          minuteEpoch: minuteEpoch, activity: activity, steps: steps));
  List<AutoWindow> pendingWindows = [];
  Uint8List recordingResult = Uint8List(0);
  Uint8List? recordingPressureResult;

  bool serviceRunning = false;
  bool recording = false;
  bool detectorReset = false;
  bool autoWindowsCleared = false;
  CalibrationParams? lastParamsPushed;
  ActivityParams? lastActivityParamsPushed;
  Map<String, dynamic> diagnosticsPayload = const {};

  int drainCallCount = 0;
  int? todayTotalPushed;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  void emit(Map<String, dynamic> event) => _events.add(event);

  Future<void> close() => _events.close();

  @override
  Future<bool> startService() async => serviceRunning = true;

  @override
  Future<bool> stopService() async {
    serviceRunning = false;
    return true;
  }

  @override
  Future<bool> get isRunning async => serviceRunning;

  @override
  Future<List<StepBucket>> drainBuckets() async {
    drainCallCount++;
    final out = pendingBuckets;
    pendingBuckets = [];
    return out;
  }

  @override
  Future<List<AutoWindow>> drainAutoWindows() async {
    final out = pendingWindows;
    pendingWindows = [];
    return out;
  }

  @override
  Future<int> autoWindowCount() async => pendingWindows.length;

  @override
  Future<void> setParams(CalibrationParams params) async {
    lastParamsPushed = params;
  }

  @override
  Future<void> setActivityParams(ActivityParams params) async {
    lastActivityParamsPushed = params;
  }

  @override
  Future<void> setAutoCalibration(bool enabled) async {}

  @override
  Future<void> startRecording() async => recording = true;

  @override
  Future<Recording> stopRecording() async {
    recording = false;
    return Recording(
      samples: recordingResult,
      pressureSamples: recordingPressureResult,
    );
  }

  @override
  Future<void> setTodayTotal(int total) async => todayTotalPushed = total;

  @override
  Future<void> resetDetector() async => detectorReset = true;

  @override
  Future<void> clearAutoWindows() async => autoWindowsCleared = true;

  @override
  Future<Diagnostics> diagnostics() async => Diagnostics(diagnosticsPayload);

  @override
  Future<bool> isIgnoringBatteryOptimizations() async => true;

  @override
  Future<void> requestIgnoreBatteryOptimizations() async {}
}
