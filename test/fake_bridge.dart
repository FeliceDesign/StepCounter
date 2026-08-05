import 'dart:async';
import 'dart:typed_data';

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

  Map<int, int> pendingBuckets = {};
  List<AutoWindow> pendingWindows = [];
  Uint8List recordingResult = Uint8List(0);

  bool serviceRunning = false;
  bool recording = false;
  bool detectorReset = false;
  bool autoWindowsCleared = false;
  CalibrationParams? lastParamsPushed;
  Map<String, dynamic> diagnosticsPayload = const {};

  int drainCallCount = 0;

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
  Future<Map<int, int>> drainBuckets() async {
    drainCallCount++;
    final out = pendingBuckets;
    pendingBuckets = {};
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
  Future<void> setAutoCalibration(bool enabled) async {}

  @override
  Future<void> startRecording() async => recording = true;

  @override
  Future<Uint8List> stopRecording() async {
    recording = false;
    return recordingResult;
  }

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
