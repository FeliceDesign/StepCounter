import 'dart:convert';

import '../detection/activity.dart';
import '../detection/calibration_params.dart';
import '../detection/motion_pipeline.dart';
import '../detection/sensor_sample.dart';
import 'database.dart';

/// Builds a self-describing JSON dump of everything the app has learned.
///
/// The point is offline analysis: the app can say a walk was 5% out, but it
/// cannot say *why*, and answering that needs the raw signal rather than the
/// counts derived from it. So the export is written to be readable by someone
/// who has never seen this codebase — units, layouts and the meaning of each
/// count are stated in the file itself rather than assumed.
class CalibrationExport {
  /// Bumped whenever the shape changes, so an old dump is still interpretable.
  static const int schemaVersion = 1;

  /// Sample layout, repeated inside the file next to the data it describes.
  static const List<String> sampleLayout = [
    't_ms',
    'ax',
    'ay',
    'az',
    'gx',
    'gy',
    'gz',
  ];

  static const List<String> pressureLayout = ['t_ms', 'hPa'];

  /// [includeSamples] controls the difference between a file you can paste
  /// into a message and one you cannot.
  ///
  /// Without it a dump is a few kilobytes of counts. With it every session
  /// carries its full 50 Hz six-axis recording — around 110 KB of base64 per
  /// minute of walking — which is what makes the detector re-runnable offline,
  /// and what makes the file too large to do anything with but attach.
  static Map<String, Object?> build({
    required List<CalibrationSession> sessions,
    required List<CalibrationVersion> versions,
    required CalibrationParams activeParams,
    required ActivityParams activeActivityParams,
    Map<String, Object?> device = const {},
    String? appVersion,
    bool includeSamples = true,
  }) {
    return {
      'schema': schemaVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'appVersion': appVersion,
      'includesRawSamples': includeSamples,
      'about': {
        'detectedSteps': 'What this app counted for the session, recorded at '
            'the time under whatever parameters were then active.',
        'replayedSteps': 'What the CURRENT parameters count when the stored '
            'raw signal is replayed through the detector now. Differs from '
            'detectedSteps exactly when calibration has changed since.',
        'userSteps': 'Counted by the user during a test walk. Null for '
            'sessions the app collected on its own.',
        'hardwareSteps': "Android's own TYPE_STEP_COUNTER delta over the same "
            'interval. Null when the device has no pedometer or its reading '
            'had not settled in time to be trusted.',
        'accelUnits': 'm/s^2, gravity included',
        'gyroUnits': 'rad/s',
        'sampleRateHz': 50,
      },
      'activeParams': activeParams.toMap(),
      'activeActivityParams': activeActivityParams.toMap(),
      'device': device,
      'versions': [
        for (final v in versions)
          {
            'createdAt': v.createdAt,
            'source': v.source,
            'isActive': v.isActive,
            'sessionCount': v.sessionCount,
            'holdoutError': v.holdoutError,
            'baselineError': v.baselineError,
            'params': _decode(v.paramsJson),
            'activityParams': _decode(v.activityParamsJson),
          },
      ],
      'sessions': [
        for (final s in sessions) _session(s, activeParams, includeSamples),
      ],
    };
  }

  static Map<String, Object?> _session(
    CalibrationSession s,
    CalibrationParams activeParams,
    bool includeSamples,
  ) {
    final samples = SensorSample.unpack(s.samples);
    final pressure = s.pressureSamples == null
        ? const <PressureSample>[]
        : PressureSample.unpack(s.pressureSamples!);

    // Re-scored here rather than in the UI. The results list deliberately shows
    // the count as it stood at the time; an analysis dump wants both, so the
    // effect of a calibration change is visible without re-deriving it.
    final replayed = MotionPipeline.replayTotal(
      samples,
      pressure: pressure,
      params: activeParams,
    );

    return {
      'id': s.id,
      'recordedAt': s.recordedAt,
      'source': s.source,
      'durationMs': s.durationMs,
      'declaredActivity': s.declaredActivity,
      'detectedSteps': s.detectedSteps,
      'replayedSteps': replayed,
      'userSteps': s.userSteps,
      'hardwareSteps': s.hardwareSteps,
      'sampleCount': samples.length,
      'pressureSampleCount': pressure.length,
      if (includeSamples) ...{
        'samples': {
          'encoding': 'base64:float32le',
          'layout': sampleLayout,
          'data': base64Encode(s.samples),
        },
        if (s.pressureSamples != null && s.pressureSamples!.isNotEmpty)
          'pressure': {
            'encoding': 'base64:float32le',
            'layout': pressureLayout,
            'data': base64Encode(s.pressureSamples!),
          },
      },
    };
  }

  static Object? _decode(String? json) {
    if (json == null) return null;
    // A stored parameter blob that will not parse is worth surfacing rather
    // than dropping — it would explain a device behaving oddly.
    try {
      return jsonDecode(json);
    } on FormatException {
      return {'unparseable': json};
    }
  }

  /// Pretty-printed, because these files are read by people and by models, and
  /// neither benefits from one enormous line.
  static String encode(Map<String, Object?> data) =>
      const JsonEncoder.withIndent('  ').convert(data);

  /// Rough size of the eventual file, for warning before a multi-megabyte
  /// share. Base64 costs four bytes for every three.
  static int estimatedBytes({
    required List<CalibrationSession> sessions,
    required bool includeSamples,
  }) {
    var total = 2048; // headers, params, versions
    for (final s in sessions) {
      total += 512;
      if (includeSamples) {
        total += (s.samples.length * 4 / 3).round();
        total += ((s.pressureSamples?.length ?? 0) * 4 / 3).round();
      }
    }
    return total;
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
