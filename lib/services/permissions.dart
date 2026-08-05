import 'package:permission_handler/permission_handler.dart';

/// Runtime permission requests, each tied to the feature that needs it.
///
/// Nothing here is fatal. Activity recognition only powers automatic
/// calibration, and notifications only affect whether the service's own
/// notification is visible — the app keeps counting either way, and Settings
/// explains what is degraded rather than nagging.
class Permissions {
  /// Needed to read the hardware pedometer, which grades our detector during
  /// automatic calibration. Without it, calibration falls back to manual
  /// sessions only.
  static Future<bool> requestActivityRecognition() async {
    final status = await Permission.activityRecognition.request();
    return status.isGranted;
  }

  static Future<bool> hasActivityRecognition() =>
      Permission.activityRecognition.isGranted;

  /// From Android 13 the foreground service notification is itself a runtime
  /// permission. Denying it does not stop the service.
  static Future<bool> requestNotifications() async {
    final status = await Permission.notification.request();
    return status.isGranted;
  }

  static Future<bool> hasNotifications() => Permission.notification.isGranted;

  /// Requested together at first launch so the user sees one burst of prompts
  /// rather than being interrupted again later.
  static Future<void> requestAll() async {
    await requestNotifications();
    await requestActivityRecognition();
  }
}
