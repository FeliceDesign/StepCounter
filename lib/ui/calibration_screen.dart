import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../detection/calibration_optimizer.dart';
import '../detection/calibration_params.dart';
import '../detection/sensor_sample.dart';
import '../detection/step_detector.dart';

enum _Stage { intro, countdown, recording, entering, result }

/// Test & Recalibrate.
///
/// Records raw motion while the user walks a known number of steps, then
/// replays that recording — together with every previously stored session —
/// through the optimiser. Replaying stored sessions rather than tuning to the
/// newest one is deliberate: parameters fitted to a single walk are excellent
/// for that walk and worse everywhere else.
class CalibrationScreen extends StatefulWidget {
  const CalibrationScreen({super.key});

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  _Stage _stage = _Stage.intro;

  Timer? _ticker;
  int _countdown = 3;
  int _elapsedSeconds = 0;

  Uint8List? _recorded;
  int _detected = 0;
  final _actualController = TextEditingController();

  CalibrationOutcome? _outcome;
  bool _busy = false;
  String? _error;

  /// Filters need about two seconds to settle from a standing start, so
  /// recording begins before the countdown does. Steps taken during warm-up
  /// would otherwise be systematically missed and bias the calibration.
  static const _warmupSeconds = 3;

  @override
  void dispose() {
    _ticker?.cancel();
    _actualController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final bridge = AppScope.of(context).bridge;
    setState(() {
      _error = null;
      _busy = true;
    });

    await bridge.startRecording();
    if (bridge.lastError != null) {
      setState(() {
        _busy = false;
        _error = bridge.lastError;
      });
      return;
    }

    setState(() {
      _busy = false;
      _stage = _Stage.countdown;
      _countdown = _warmupSeconds;
      _elapsedSeconds = 0;
    });

    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() {
        if (_stage == _Stage.countdown) {
          _countdown--;
          if (_countdown <= 0) _stage = _Stage.recording;
        } else {
          _elapsedSeconds++;
        }
      });
    });
  }

  Future<void> _stop() async {
    _ticker?.cancel();
    // Captured before the await so nothing reaches for context afterwards.
    final scope = AppScope.of(context);
    final samples = await scope.bridge.stopRecording();

    if (samples.isEmpty) {
      setState(() {
        _stage = _Stage.intro;
        _error = 'No motion data was recorded. Is counting switched on?';
      });
      return;
    }

    final detected = StepDetector.countSteps(
      SensorSample.unpack(samples),
      params: scope.repository.params,
    );

    setState(() {
      _recorded = samples;
      _detected = detected;
      _stage = _Stage.entering;
    });
  }

  Future<void> _submit() async {
    final actual = int.tryParse(_actualController.text.trim());
    if (actual == null || actual <= 0) {
      setState(() => _error = 'Enter the number of steps you actually took.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final repo = AppScope.of(context).repository;
    await repo.saveManualSession(
      samples: _recorded!,
      actualSteps: actual,
      durationMs: _elapsedSeconds * 1000,
    );

    final outcome = await repo.runCalibration();

    if (!mounted) return;
    setState(() {
      _busy = false;
      _outcome = outcome;
      _stage = _Stage.result;
    });
  }

  Future<void> _accept() async {
    final outcome = _outcome;
    if (outcome == null) return;
    setState(() => _busy = true);

    await AppScope.of(context).repository.adoptParams(
          outcome.params,
          source: 'manual',
          holdoutError: outcome.holdoutError,
          baselineError: outcome.baselineHoldoutError,
          sessionCount: outcome.sessionCount,
        );

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Test & Recalibrate')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: switch (_stage) {
            _Stage.intro => _buildIntro(),
            _Stage.countdown => _buildCountdown(),
            _Stage.recording => _buildRecording(),
            _Stage.entering => _buildEntering(),
            _Stage.result => _buildResult(),
          },
        ),
      ),
    );
  }

  Widget _buildIntro() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('How this works', style: theme.textTheme.titleLarge),
        const SizedBox(height: 12),
        const _Bullet('Put your phone where you normally carry it.'),
        const _Bullet('Walk normally and count your steps as you go.'),
        const _Bullet('Fifty steps or more gives the best result.'),
        const _Bullet('Stop, then type in how many you actually took.'),
        const SizedBox(height: 20),
        Text(
          'Your recording is compared against every previous test, not just '
          'this one. Tuning to a single walk makes the counter better at that '
          'walk and worse at everything else.',
          style: theme.textTheme.bodySmall,
        ),
        const Spacer(),
        if (_error != null) _ErrorBanner(_error!),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start'),
            onPressed: _busy ? null : _start,
          ),
        ),
      ],
    );
  }

  Widget _buildCountdown() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('$_countdown', style: theme.textTheme.displayLarge),
          const SizedBox(height: 12),
          Text('Get ready to walk', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'Already recording, so the sensors settle before you start.',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildRecording() {
    final theme = Theme.of(context);
    final minutes = (_elapsedSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (_elapsedSeconds % 60).toString().padLeft(2, '0');

    return Column(
      children: [
        const Spacer(),
        Icon(Icons.directions_walk, size: 72, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text('Walk now', style: theme.textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text('$minutes:$seconds', style: theme.textTheme.displaySmall),
        const SizedBox(height: 8),
        Text('Counting your own steps as you go',
            style: theme.textTheme.bodySmall),
        const Spacer(),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            icon: const Icon(Icons.stop),
            label: const Text('Stop'),
            onPressed: _stop,
          ),
        ),
      ],
    );
  }

  Widget _buildEntering() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('How many steps did you take?', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'Enter your own count first — the app deliberately does not show '
          'its number yet, so it cannot anchor your answer.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _actualController,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'Steps taken',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 16),
        if (_error != null) _ErrorBanner(_error!),
        const Spacer(),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Compare'),
          ),
        ),
      ],
    );
  }

  Widget _buildResult() {
    final theme = Theme.of(context);
    final outcome = _outcome;
    final actual = int.tryParse(_actualController.text.trim()) ?? 0;
    final errorPercent =
        actual == 0 ? 0.0 : ((_detected - actual).abs() / actual) * 100;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('This walk', style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _Metric(label: 'You counted', value: '$actual'),
              _Metric(label: 'App counted', value: '$_detected'),
              _Metric(
                label: 'Off by',
                value: '${errorPercent.toStringAsFixed(1)}%',
              ),
            ],
          ),
          const Divider(height: 40),
          if (outcome == null)
            Text(
              'Not enough data to retune yet. The recording has been saved and '
              'will be used next time.',
              style: theme.textTheme.bodyMedium,
            )
          else ...[
            Text('Proposed change', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Measured across ${outcome.sessionCount} stored '
              '${outcome.sessionCount == 1 ? 'session' : 'sessions'}.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _Metric(
                  label: 'Error now',
                  value: _pct(outcome.baselineHoldoutError),
                ),
                _Metric(
                  label: 'Error after',
                  value: _pct(outcome.holdoutError),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (!outcome.validated)
              _Note(
                icon: Icons.info_outline,
                text: 'Only one or two sessions are stored, so this improvement '
                    'is measured on the same data it was tuned to. Record a few '
                    'more walks for an independent check.',
              ),
            if (!outcome.accepted && outcome.validated)
              const _Note(
                icon: Icons.check_circle_outline,
                text: 'No change worth making — the current settings already '
                    'handle your walking well.',
              ),
            const SizedBox(height: 12),
            _ParamDiff(
              before: outcome.baselineParams,
              after: outcome.params,
            ),
          ],
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Discard'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: (outcome == null ||
                          outcome.params == outcome.baselineParams ||
                          _busy)
                      ? null
                      : _accept,
                  child: const Text('Apply'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _pct(double normalisedError) =>
      '${(normalisedError * 100).toStringAsFixed(1)}%';
}

class _ParamDiff extends StatelessWidget {
  const _ParamDiff({required this.before, required this.after});

  final CalibrationParams before;
  final CalibrationParams after;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final changed = CalibrationParams.tunableKeys
        .where((k) => before[k] != after[k])
        .toList();

    if (changed.isEmpty) {
      return Text('No settings changed.', style: theme.textTheme.bodySmall);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('What changes', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        for (final key in changed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              '${_label(key)}:  ${_fmt(before[key])} → ${_fmt(after[key])}',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(2);

  static String _label(String key) => switch (key) {
        'thresholdSigma' => 'Sensitivity',
        'minAmplitude' => 'Minimum step strength',
        'minStepIntervalMs' => 'Fastest step (ms)',
        'maxStepIntervalMs' => 'Slowest step (ms)',
        'regularityRunLength' => 'Steps before counting starts',
        'gyroMinLevel' => 'Minimum rotation',
        'gyroMaxLevel' => 'Maximum rotation',
        _ => key,
      };
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(value,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('•  '),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        message,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onErrorContainer),
      ),
    );
  }
}
