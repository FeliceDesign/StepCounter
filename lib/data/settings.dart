import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-facing preferences.
///
/// Detector parameters deliberately do NOT live here — they are versioned rows
/// in the database so a bad calibration can always be traced and reverted.
class Settings extends ChangeNotifier {
  Settings(this._prefs);

  final SharedPreferences _prefs;

  static Future<Settings> load() async =>
      Settings(await SharedPreferences.getInstance());

  static const _kAutoCalibration = 'auto_calibration';
  static const _kDailyGoal = 'daily_goal';
  static const _kCountingEnabled = 'counting_enabled';

  bool get autoCalibrationEnabled => _prefs.getBool(_kAutoCalibration) ?? true;

  Future<void> setAutoCalibrationEnabled(bool v) async {
    await _prefs.setBool(_kAutoCalibration, v);
    notifyListeners();
  }

  int get dailyGoal => _prefs.getInt(_kDailyGoal) ?? 10000;

  Future<void> setDailyGoal(int v) async {
    await _prefs.setInt(_kDailyGoal, v.clamp(100, 100000));
    notifyListeners();
  }

  bool get countingEnabled => _prefs.getBool(_kCountingEnabled) ?? true;

  Future<void> setCountingEnabled(bool v) async {
    await _prefs.setBool(_kCountingEnabled, v);
    notifyListeners();
  }

  Future<void> resetToDefaults() async {
    await _prefs.remove(_kAutoCalibration);
    await _prefs.remove(_kDailyGoal);
    notifyListeners();
  }
}
