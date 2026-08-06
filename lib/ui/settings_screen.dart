import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../detection/calibration_params.dart';
import '../services/native_bridge.dart';
import '../services/permissions.dart';
import 'calibration_history_screen.dart';
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
    _refresh();
  }

  ({int manual, int automatic})? _counts;

  int get _totalSessions =>
      (_counts?.manual ?? 0) + (_counts?.automatic ?? 0);

  Future<void> _refresh() async {
    final scope = AppScope.of(context);
    final d = await scope.bridge.diagnostics();
    // The corpus size comes from the database, never from
    // Diagnostics.autoWindowCount: that counts files in the native staging
    // directory, which Dart drains destructively as soon as the UI attaches.
    // It is a queue depth, and reading it as a corpus size showed "0 windows
    // collected" no matter how many walks had been collected.
    final counts = await scope.repository.sessionCountsBySource();
    if (mounted) {
      setState(() {
        _diagnostics = d;
        _counts = counts;
      });
    }
  }

  String _calibrationSummary() {
    final c = _counts;
    if (c == null) return 'Loading…';
    if (c.manual + c.automatic == 0) {
      return 'No saved walks yet — run a test to see how close the app is.';
    }
    final parts = <String>[
      '${c.manual} ${c.manual == 1 ? 'test' : 'tests'}',
      '${c.automatic} collected automatically',
    ];
    return parts.join(', ');
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
                await _refresh();
              },
            ),
            ListTile(
              title: const Text('Daily goal'),
              subtitle: Text('${scope.settings.dailyGoal} steps'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _editGoal(scope.settings.dailyGoal),
            ),

            _Section('Calibration'),
            // The two things a user actually wants — run a test, look at what
            // past tests said — sit at the top; the machinery goes under
            // Advanced. Before, a toggle, a wizard, a batch job and a raw
            // parameter slider sat as four peers at identical visual weight,
            // with nothing to say which to reach for or what state calibration
            // was even in.
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('Calibration and test results'),
              subtitle: Text(_calibrationSummary()),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                // The builder's context is not this State's, so it is resolved
                // up front rather than reached for after the await.
                final navigator = Navigator.of(context);
                await navigator.push(MaterialPageRoute(
                  builder: (_) => const CalibrationHistoryScreen(),
                ));
                await _refresh();
              },
            ),
            SwitchListTile(
              title: const Text('Automatic calibration'),
              subtitle: Text(
                _diagnostics?.hasHardwareCounter == false
                    ? 'Unavailable — this device has no built-in step sensor '
                        'to compare against.'
                    : scope.settings.autoCalibrationEnabled
                        ? 'Saves a short walk in the background now and then and '
                            'grades it against the phone’s own step sensor. '
                            '${_counts?.automatic ?? 0} collected so far.'
                        : 'Not collecting. Your saved tests are still used.',
              ),
              value: scope.settings.autoCalibrationEnabled,
              onChanged: _diagnostics?.hasHardwareCounter == false
                  ? null
                  : (v) async {
                      await scope.settings.setAutoCalibrationEnabled(v);
                      await scope.bridge.setAutoCalibration(v);
                      if (v) await Permissions.requestActivityRecognition();
                      await _refresh();
                    },
            ),
            ExpansionTile(
              leading: const Icon(Icons.settings_suggest_outlined),
              title: const Text('Advanced'),
              children: [
                ListTile(
                  leading: const Icon(Icons.auto_fix_high),
                  title: const Text('Retune from saved walks'),
                  subtitle: Text(
                    _totalSessions == 0
                        ? 'No saved walks yet.'
                        : 'Re-runs the optimiser over all $_totalSessions saved '
                            '${_totalSessions == 1 ? 'walk' : 'walks'}.',
                  ),
                  onTap: _running || _totalSessions == 0 ? null : _runAutomatic,
                ),
                _SensitivityTile(onChanged: _refresh),
              ],
            ),

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
                  await _refresh();
                },
              ),
            if (_diagnostics?.hasBarometer == false)
              const ListTile(
                leading: Icon(Icons.stairs_outlined),
                title: Text('No barometer on this device'),
                subtitle: Text(
                  'Stairs cannot be detected without one. Walking and running '
                  'are unaffected.',
                ),
              ),
            _DiagnosticsTile(
              diagnostics: _diagnostics,
              onRefresh: _refresh,
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
                await _refresh();
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
    await _refresh();
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
///
/// Drives minMotionSigma, not thresholdSigma. The old slider adjusted the
/// adaptive threshold, which is derived from the signal's own deviation and so
/// shrinks along with whatever noise it is meant to reject — moving it from 0.7
/// to its maximum only cut phantom steps from 144 to 32. This one is an
/// absolute floor on how much movement must be present at all, which is what
/// actually silences a phone sitting on a desk.
class _SensitivityTile extends StatefulWidget {
  const _SensitivityTile({required this.onChanged});

  final VoidCallback onChanged;

  @override
  State<_SensitivityTile> createState() => _SensitivityTileState();
}

class _SensitivityTileState extends State<_SensitivityTile> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).repository;
    final (lo, hi) = CalibrationParams.bounds['minMotionSigma']!;
    // While a drag is in progress the thumb follows the finger from local
    // state; the write happens once, on release. `onChanged` used to be empty,
    // so the thumb stayed put until the finger lifted and then jumped.
    final value = _dragValue ?? repo.params.minMotionSigma.clamp(lo, hi);

    return ListTile(
      title: const Text('Strictness'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value >= 0.7
                ? 'Very strict — only vigorous movement counts. May miss steps '
                    'if you carry your phone loosely.'
                : value >= 0.3
                    ? 'Balanced. Ignores desk vibration and small fidgeting.'
                    : 'Lenient — small movements may be counted as steps.',
          ),
          Slider(
            value: value,
            min: lo,
            max: hi,
            divisions: 18,
            label: value.toStringAsFixed(2),
            onChanged: (v) => setState(() => _dragValue = v),
            onChangeEnd: (v) async {
              setState(() => _dragValue = null);
              // A nudge that lands back where it started should not append a
              // calibration version; the history is meant to record decisions.
              if ((v - repo.params.minMotionSigma).abs() < 1e-6) return;
              await repo.adoptParams(
                repo.params.copyWith(minMotionSigma: v),
                source: 'manual-slider',
              );
              widget.onChanged();
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
                _Row('Barometer',
                    d.hasBarometer ? 'present' : 'absent (no stairs)'),
                _Row('Battery exemption',
                    d.ignoringBatteryOptimizations ? 'granted' : 'not granted'),
                const Divider(),
                _Row('Recordings awaiting import', '${d.autoWindowCount}'),
                _Row('Steps awaiting sync', '${d.pendingSteps}'),
                _Row('Currently walking', d.inConfirmedRun ? 'yes' : 'no'),
                _Row(
                  'Cadence',
                  d.cadenceMs == null
                      ? '—'
                      : '${(60000 / d.cadenceMs!).round()} steps/min',
                ),
                _Row('Rotation level', d.gyroLevel.toStringAsFixed(3)),
                // The two gates that reject hand movement, exposed so they can
                // be watched on a real phone rather than taken on trust.
                // Walking sits near 0.98 vertical and under 0.03 variation;
                // fidgeting sits under 0.46 and well above 0.04.
                _Row(
                  'Movement is vertical',
                  d.verticalShare == null
                      ? '— (gravity unclear)'
                      : d.verticalShare!.toStringAsFixed(2),
                ),
                _Row('Step rhythm variation', d.intervalCv.toStringAsFixed(3)),
                _Row('Activity', d.activity.label),
                _Row('Vertical speed',
                    '${d.altitudeRate.toStringAsFixed(2)} m/s'),
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
