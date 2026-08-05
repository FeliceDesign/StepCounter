import 'dart:async';

import 'package:flutter/services.dart';

import '../data/database.dart';
import '../detection/activity.dart';
import '../detection/calibration_params.dart';

/// A labelled window the service captured on its own, graded by the hardware
/// pedometer.
class AutoWindow {
  const AutoWindow({
    required this.recordedAt,
    required this.ourCount,
    required this.hardwareCount,
    required this.samples,
    this.pressureSamples,
  });

  final int recordedAt;
  final int ourCount;
  final int hardwareCount;
  final Uint8List samples;

  /// Null when the device has no barometer, so stairs can never be inferred
  /// from this window.
  final Uint8List? pressureSamples;
}

/// Everything Settings shows about the health of the counting pipeline.
class Diagnostics {
  const Diagnostics(this.raw);
  final Map<String, dynamic> raw;

  bool get serviceRunning => raw['serviceRunning'] == true;
  bool get hasAccelerometer => raw['hasAccelerometer'] == true;
  bool get hasGyroscope => raw['hasGyroscope'] == true;
  bool get hasHardwareCounter => raw['hasHardwareCounter'] == true;
  bool get hasBarometer => raw['hasBarometer'] == true;
  bool get autoCalibrationEnabled => raw['autoCalibrationEnabled'] == true;
  bool get ignoringBatteryOptimizations =>
      raw['ignoringBatteryOptimizations'] == true;

  int get autoWindowCount => (raw['autoWindowCount'] as num?)?.toInt() ?? 0;
  int get pendingSteps => (raw['pendingSteps'] as num?)?.toInt() ?? 0;
  int get todaySteps => (raw['todaySteps'] as num?)?.toInt() ?? 0;

  double? get cadenceMs => (raw['cadenceMs'] as num?)?.toDouble();
  double get gyroLevel => (raw['gyroLevel'] as num?)?.toDouble() ?? 0;
  double get threshold => (raw['threshold'] as num?)?.toDouble() ?? 0;
  bool get inConfirmedRun => raw['inConfirmedRun'] == true;

  Activity get activity => Activity.fromId(raw['activity'] as String? ?? 'unknown');
  double get altitudeRate => (raw['altitudeRate'] as num?)?.toDouble() ?? 0;
}

/// Dart's only route to the sensors.
///
/// The counting loop lives in the Android foreground service so it can outlive
/// the UI; this class is the command channel to it. Every method is a no-op
/// that reports failure rather than throwing on non-Android platforms, so
/// widget tests and the analyzer never need a device.
class NativeBridge {
  NativeBridge({
    MethodChannel? control,
    EventChannel? events,
  })  : _control = control ?? const MethodChannel(_controlChannel),
        _events = events ?? const EventChannel(_eventChannel);

  static const _controlChannel = 'stepcounter/control';
  static const _eventChannel = 'stepcounter/events';

  final MethodChannel _control;
  final EventChannel _events;

  Stream<Map<String, dynamic>>? _eventStream;

  /// Step and calibration events pushed up from the service.
  Stream<Map<String, dynamic>> get events => _eventStream ??= _events
      .receiveBroadcastStream()
      .map((e) => Map<String, dynamic>.from(e as Map))
      .asBroadcastStream();

  Future<bool> startService() async => await _call<bool>('startService') ?? false;

  Future<bool> stopService() async => await _call<bool>('stopService') ?? false;

  Future<bool> get isRunning async => await _call<bool>('isRunning') ?? false;

  /// Moves accumulated step buckets out of service storage.
  ///
  /// Destructive on the native side, so the caller must commit the result to
  /// the database before doing anything else with it.
  ///
  /// Keys arrive as `minuteEpoch:activityId`. A composite string key keeps the
  /// native side to one flat JSON map while still carrying the activity, which
  /// a nested structure in SharedPreferences would not do cheaply.
  Future<List<StepBucket>> drainBuckets() async {
    final raw = await _call<Map<Object?, Object?>>('drainBuckets');
    if (raw == null) return const [];

    final out = <StepBucket>[];
    raw.forEach((k, v) {
      final steps = (v as num?)?.toInt() ?? 0;
      if (steps <= 0) return;

      final key = k.toString();
      final sep = key.indexOf(':');
      final minute = int.tryParse(sep < 0 ? key : key.substring(0, sep));
      if (minute == null) return;

      out.add(StepBucket(
        minuteEpoch: minute,
        // A key without a separator predates activity detection.
        activity: sep < 0
            ? Activity.unknown
            : Activity.fromId(key.substring(sep + 1)),
        steps: steps,
      ));
    });
    return out;
  }

  /// Same contract as [drainBuckets]: the native side forgets these once
  /// handed over.
  Future<List<AutoWindow>> drainAutoWindows() async {
    final raw = await _call<List<Object?>>('drainAutoWindows');
    if (raw == null) return [];
    return raw.whereType<Map<Object?, Object?>>().map((m) {
      return AutoWindow(
        recordedAt: (m['recordedAt'] as num?)?.toInt() ?? 0,
        ourCount: (m['ourCount'] as num?)?.toInt() ?? 0,
        hardwareCount: (m['hardwareCount'] as num?)?.toInt() ?? 0,
        samples: m['samples'] as Uint8List? ?? Uint8List(0),
        pressureSamples: m['pressureSamples'] as Uint8List?,
      );
    }).toList();
  }

  Future<int> autoWindowCount() async =>
      await _call<int>('autoWindowCount') ?? 0;

  Future<void> setParams(CalibrationParams params) =>
      _call<bool>('setParams', params.toJson());

  Future<void> setActivityParams(ActivityParams params) =>
      _call<bool>('setActivityParams', params.toJson());

  Future<void> setAutoCalibration(bool enabled) =>
      _call<bool>('setAutoCalibration', enabled);

  Future<void> startRecording() => _call<bool>('startRecording');

  Future<Uint8List> stopRecording() async =>
      await _call<Uint8List>('stopRecording') ?? Uint8List(0);

  /// Tells the service today's authoritative total so its notification is
  /// right even though it counted only part of the day itself.
  Future<void> setTodayTotal(int total) =>
      _call<bool>('setTodayTotal', total);

  Future<void> resetDetector() => _call<bool>('resetDetector');

  Future<void> clearAutoWindows() => _call<bool>('clearAutoWindows');

  Future<Diagnostics> diagnostics() async {
    final raw = await _call<Map<Object?, Object?>>('diagnostics');
    return Diagnostics(
      raw == null ? {} : raw.map((k, v) => MapEntry(k.toString(), v)),
    );
  }

  Future<bool> isIgnoringBatteryOptimizations() async =>
      await _call<bool>('isIgnoringBatteryOptimizations') ?? false;

  Future<void> requestIgnoreBatteryOptimizations() =>
      _call<bool>('requestIgnoreBatteryOptimizations');

  Future<T?> _call<T>(String method, [Object? args]) async {
    try {
      return await _control.invokeMethod<T>(method, args);
    } on MissingPluginException {
      // Not running on Android (tests, analyzer). Silent by design.
      return null;
    } on PlatformException catch (e) {
      lastError = e.message;
      return null;
    }
  }

  /// Surfaced by the calibration screens when the service refuses a command,
  /// so failures explain themselves instead of appearing as a dead button.
  String? lastError;
}
