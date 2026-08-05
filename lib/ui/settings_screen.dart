import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../detection/calibration_params.dart';
import '../services/native_bridge.dart';
import '../services/permissions.dart';
import 'calibration_screen.dart';
import 'reset_sheet.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Diagnostics? _diagnostics;
  bool _running = false;
  bool _loadedOnce = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reads AppScope, so it cannot run from initState.
    if (_loadedOnce) return;
    _loadedOnce = true;
    _loadDiagnostics();
  }

  Future<void> _loadDiagnostics() async {
    final d = await AppScope.of(context).bridge.diagnostics();
    if (mounted) setState(() => _diagnostics = d);
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: Listenable.merge([scope.settings, scope.repository]),
        builder: (context, _) => ListView(
          children: [
            _Section('Counting'),
            SwitchListTile(
              title: const Text('Count steps'),
              subtitle: const Text(
                'Keeps counting with the screen off. Shows a silent '
                'notification, which Android requires.',
              ),
              value: scope.settings.countingEnabled,
              onChanged: (v) async {
                await scope.settings.setCountingEnabled(v);
                if (v) {
                  await Permissions.requestAll();
                  await scope.bridge.startService();
                } else {
                  await scope.bridge.stopService();
                }
                await _loadDiagnostics();
              },
            ),
            ListTile(
              title: const Text('Daily goal'),
              subtitle: Text('${scope.settings.dailyGoal} steps'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _editGoal(scope.settings.dailyGoal),
            ),

            _Section('Calibration'),
            SwitchListTile(
              title: const Text('Automatic calibration'),
              subtitle: Text(
                _diagnostics?.hasHardwareCounter == false
                    ? 'Unavailable — this device has no built-in step sensor '
                        'to compare against.'
                    : 'Quietly grades the detector against the phone’s '
                        'built-in step sensor and retunes when it finds a real '
                        'improvement.',
              ),
              value: scope.settings.autoCalibrationEnabled,
              onChanged: _diagnostics?.hasHardwareCounter == false
                  ? null
                  : (v) async {
                      await scope.settings.setAutoCalibrationEnabled(v);
                      await scope.bridge.setAutoCalibration(v);
                      if (v) await Permissions.requestActivityRecognition();
                      await _loadDiagnostics();
                    },
            ),
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('Test & Recalibrate'),
              subtitle: const Text(
                'Walk a known number of steps and compare.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                // The builder's context is not this State's, so both are
                // resolved up front rather than reached for after the await.
                final navigator = Navigator.of(context);
                final messenger = ScaffoldMessenger.of(context);
                final applied = await navigator.push<bool>(
                  MaterialPageRoute(builder: (_) => const CalibrationScreen()),
                );
                if (applied == true) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Calibration applied')),
                  );
                }
                await _loadDiagnostics();
              },
            ),
            ListTile(
              leading: const Icon(Icons.auto_fix_high),
              title: const Text('Recalibrate now'),
              subtitle: Text(
                'Uses the ${_diagnostics?.autoWindowCount ?? 0} windows '
                'collected automatically plus your saved tests.',
              ),
              onTap: _running ? null : _runAutomatic,
            ),
            _SensitivityTile(onChanged: _loadDiagnostics),

            _Section('Reliability'),
            if (_diagnostics?.ignoringBatteryOptimizations == false)
              ListTile(
                leading: Icon(Icons.battery_alert,
                    color: Theme.of(context).colorScheme.error),
                title: const Text('Battery optimisation is on'),
                subtitle: const Text(
                  'Android may stop counting in the background. Tap to allow '
                  'this app to keep running.',
                ),
                onTap: () async {
                  await AppScope.of(context)
                      .bridge
                      .requestIgnoreBatteryOptimizations();
                  await _loadDiagnostics();
                },
              ),
            _DiagnosticsTile(
              diagnostics: _diagnostics,
              onRefresh: _loadDiagnostics,
            ),

            _Section('Data'),
            ListTile(
              leading: Icon(Icons.restart_alt,
                  color: Theme.of(context).colorScheme.error),
              title: const Text('Reset'),
              subtitle: const Text(
                'Choose exactly what to clear — learned settings, saved tests, '
                'or step history.',
              ),
              onTap: () async {
                await showResetSheet(context);
                await _loadDiagnostics();
              },
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Future<void> _runAutomatic() async {
    setState(() => _running = true);
    final repo = AppScope.of(context).repository;
    final outcome = await repo.runAutomaticCalibration();
    if (!mounted) return;
    setState(() => _running = false);

    final message = switch (outcome) {
      null => 'No recorded walks to calibrate from yet.',
      final o when o.accepted =>
        'Retuned — error improved by ${o.improvementPercent.toStringAsFixed(0)}%.',
      final o when o.sessionCount < 6 =>
        'Needs at least 6 recorded walks; there are ${o.sessionCount}.',
      _ => 'No change — the current settings are already the best of those tried.',
    };

    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
    await _loadDiagnostics();
  }

  Future<void> _editGoal(int current) async {
    final controller = TextEditingController(text: current.toString());
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Daily goal'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(suffixText: 'steps'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, int.tryParse(controller.text.trim())),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null && mounted) {
      await AppScope.of(context).settings.setDailyGoal(result);
    }
  }
}

/// Manual override for people who would rather nudge the counter than run a
/// calibration walk. Writes a version like any other calibration, so it shows
/// up in history and is undone by the same reset.
class _SensitivityTile extends StatelessWidget {
  const _SensitivityTile({required this.onChanged});

  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repository;
    final (lo, hi) = CalibrationParams.bounds['thresholdSigma']!;
    final value = repo.params.thresholdSigma.clamp(lo, hi);

    return ListTile(
      title: const Text('Sensitivity'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Lower counts more movement as steps.'),
          Slider(
            value: value,
            min: lo,
            max: hi,
            divisions: 18,
            label: value.toStringAsFixed(2),
            onChanged: (v) {},
            onChangeEnd: (v) async {
              await repo.adoptParams(
                repo.params.copyWith(thresholdSigma: v),
                source: 'manual-slider',
              );
              onChanged();
            },
          ),
        ],
      ),
    );
  }
}

class _DiagnosticsTile extends StatelessWidget {
  const _DiagnosticsTile({required this.diagnostics, required this.onRefresh});

  final Diagnostics? diagnostics;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final d = diagnostics;
    return ExpansionTile(
      leading: const Icon(Icons.monitor_heart_outlined),
      title: const Text('Sensor diagnostics'),
      subtitle: Text(
        d == null
            ? 'Loading…'
            : d.serviceRunning
                ? 'Counting service is running'
                : 'Counting service is stopped',
      ),
      onExpansionChanged: (open) {
        if (open) onRefresh();
      },
      children: [
        if (d == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No data'),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Row('Accelerometer', d.hasAccelerometer ? 'present' : 'MISSING'),
                _Row('Gyroscope',
                    d.hasGyroscope ? 'present' : 'absent (reduced accuracy)'),
                _Row('Built-in step sensor',
                    d.hasHardwareCounter ? 'present' : 'absent'),
                _Row('Battery exemption',
                    d.ignoringBatteryOptimizations ? 'granted' : 'not granted'),
                const Divider(),
                _Row('Auto-calibration windows', '${d.autoWindowCount}'),
                _Row('Steps awaiting sync', '${d.pendingSteps}'),
                _Row('Currently walking', d.inConfirmedRun ? 'yes' : 'no'),
                _Row(
                  'Cadence',
                  d.cadenceMs == null
                      ? '—'
                      : '${(60000 / d.cadenceMs!).round()} steps/min',
                ),
                _Row('Rotation level', d.gyroLevel.toStringAsFixed(3)),
              ],
            ),
          ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          Text(value,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.1,
        ),
      ),
    );
  }
}
