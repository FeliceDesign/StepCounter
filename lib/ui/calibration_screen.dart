import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_scope.dart';
import '../detection/activity.dart';
import '../services/native_bridge.dart';
import '../detection/activity_optimizer.dart';
import '../detection/calibration_optimizer.dart';
import '../detection/calibration_params.dart';
import '../detection/sensor_sample.dart';
import '../detection/motion_pipeline.dart';

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

  Recording? _recorded;
  int _detected = 0;

  /// Android's own count over the same recording, when it can be had. See
  /// StepSensorService.recordingHardwareDelta for why it is not always
  /// available at the moment recording stops.
  int? _hardwareSteps;

  /// Row id of the walk just saved, so it can be taken back out again. The
  /// recording is persisted before the result screen renders — it has to be,
  /// because the tuning proposal is computed from the whole corpus including
  /// it — so "delete" here is a real deletion rather than a decision not to
  /// save.
  int? _sessionId;
  final _actualController = TextEditingController();

  /// What the user says they are about to do. Stored with the recording so the
  /// optimiser can tune the activity thresholds against a real label, not just
  /// the step count.
  Activity _declared = Activity.walking;

  CalibrationOutcome? _outcome;
  ActivityOutcome? _activityOutcome;
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
    final recording = await scope.bridge.stopRecording();

    if (recording.isEmpty) {
      setState(() {
        _stage = _Stage.intro;
        _error = 'No motion data was recorded. Is counting switched on?';
      });
      return;
    }

    final detected = MotionPipeline.replayTotal(
      SensorSample.unpack(recording.samples),
      pressure: recording.pressureSamples == null
          ? const []
          : PressureSample.unpack(recording.pressureSamples!),
      params: scope.repository.params,
      activityParams: scope.repository.activityParams,
    );

    setState(() {
      _recorded = recording;
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

    final scope = AppScope.of(context);
    final repo = scope.repository;

    // Asked now rather than at stopRecording: the hardware counter reports
    // late, and the seconds the user spent typing their own count are exactly
    // the settling time it needed.
    final hardware = await scope.bridge.recordingHardwareDelta();

    final sessionId = await repo.saveManualSession(
      samples: _recorded!.samples,
      pressureSamples: _recorded!.pressureSamples,
      actualSteps: actual,
      // Measured by the service across the whole recording. The visible timer
      // excluded the warm-up countdown and was therefore always short.
      durationMs: _recorded!.durationMs > 0
          ? _recorded!.durationMs
          : _elapsedSeconds * 1000,
      declaredActivity: _declared,
      hardwareSteps: hardware,
    );

    final outcome = await repo.runCalibration();
    final activityOutcome = await repo.runActivityCalibration();

    if (!mounted) return;
    setState(() {
      _busy = false;
      _sessionId = sessionId;
      _hardwareSteps = hardware;
      _outcome = outcome;
      _activityOutcome = activityOutcome;
      _stage = _Stage.result;
    });
  }

  Future<void> _accept() async {
    final outcome = _outcome;
    if (outcome == null) return;
    setState(() => _busy = true);

    final activity = _activityOutcome;
    await AppScope.of(context).repository.adoptParams(
          outcome.params,
          source: 'manual',
          activityParams: (activity != null && activity.accepted)
              ? activity.params
              : null,
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
        Text('What will you be doing?', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<Activity>(
          segments: const [
            ButtonSegment(value: Activity.walking, label: Text('Walking')),
            ButtonSegment(value: Activity.running, label: Text('Running')),
            ButtonSegment(value: Activity.stairsUp, label: Text('Stairs')),
          ],
          selected: {_declared},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _declared = s.first),
        ),
        const SizedBox(height: 8),
        if (_declared == Activity.stairsUp)
          Text(
            'Climb rather than descend if you can — going up is the clearer '
            'signal. Needs a barometer; without one the app can still learn '
            'your step count from this, just not the stairs part.',
            style: theme.textTheme.bodySmall,
          ),
        const SizedBox(height: 12),
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

  /// The test result, with retuning as a genuinely optional aside.
  ///
  /// The previous version stacked three full sections — the walk, a proposed
  /// change, and activity recognition — above a Discard/Apply pair, which read
  /// as a screen built to talk you into recalibrating. It also offered "Apply"
  /// whenever the search had *moved*, which is not the same as having found
  /// something worth adopting, so the button could sit enabled directly under
  /// a note saying no change was worth making.
  ///
  /// Now the result is the subject. A tuning suggestion appears only when the
  /// optimiser actually accepted one, and declining is the ordinary path
  /// rather than the discouraged one.
  Widget _buildResult() {
    final theme = Theme.of(context);
    final entered = int.tryParse(_actualController.text.trim()) ?? 0;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Test result', style: theme.textTheme.titleLarge),
          const SizedBox(height: 16),
          _ComparisonRow(
            label: 'This app counted',
            value: '$_detected',
            emphasised: true,
          ),
          _ComparisonRow(
            label: 'You counted',
            value: '$entered',
            delta: _deltaText(_detected, entered),
          ),
          _ComparisonRow(
            label: 'Android counted',
            value: _hardwareSteps?.toString() ?? 'not available',
            delta: _deltaText(_detected, _hardwareSteps),
          ),
          const SizedBox(height: 12),
          Text(
            _hardwareSteps == null
                ? 'Saved with your other results. Android’s own count was not '
                    'available for this walk — its step sensor reports late, '
                    'and it had not caught up.'
                : 'Saved with your other results.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          _tuningSection(theme),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: _canApply
                ? OutlinedButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                    child: const Text('Keep current settings'),
                  )
                : FilledButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Done'),
                  ),
          ),
          if (_canApply) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _accept,
                child: const Text('Apply retuning'),
              ),
            ),
          ],
          const SizedBox(height: 8),
          // The moment you know a walk was bad — you lost count, the phone
          // slipped, someone stopped you halfway — is right now, looking at
          // the number. Making you find it again in a list later is how bad
          // data ends up training the detector.
          Center(
            child: TextButton.icon(
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Delete this test'),
              onPressed: _busy ? null : _deleteThisTest,
            ),
          ),
        ],
      ),
    );
  }

  /// Removes the walk just recorded, and with it the tuning proposal.
  ///
  /// Dropping the proposal matters and is not tidiness: calibration has
  /// already run across the whole corpus *including* this walk by the time
  /// this screen appears, so the suggested change was partly derived from the
  /// data being deleted. Leaving Apply available would let a walk the user
  /// just rejected tune the detector anyway.
  Future<void> _deleteThisTest() async {
    final id = _sessionId;
    if (id == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this test?'),
        content: const Text(
          'The recording and its counts are removed, and the app will not '
          'learn from this walk. Any tuning suggested from it is dropped too.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    await AppScope.of(context).repository.deleteSession(id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _sessionId = null;
      _outcome = null;
      _activityOutcome = null;
    });
    navigator.pop(false);
  }

  /// One of four states, only one of which offers to change anything.
  Widget _tuningSection(ThemeData theme) {
    final outcome = _outcome;
    final activity = _activityOutcome;

    if (outcome == null) {
      return Text(
        'This walk will be used the next time the app retunes.',
        style: theme.textTheme.bodyMedium,
      );
    }

    if (!_canApply) {
      // Deliberately two different sentences. "Nothing worth changing" and
      // "not enough evidence to say" are different facts, and telling a user
      // the first when the second is true is how an app loses their trust.
      return Text(
        outcome.validated
            ? 'No retuning needed — your current settings already handle your '
                'walking well.'
            : 'Not enough saved walks yet to check a retune against data it '
                'was not tuned on, so nothing will be changed on the strength '
                'of this one. ${outcome.sessionCount} stored so far; '
                '${CalibrationOptimizer.minSessionsForHoldout} needed.',
        style: theme.textTheme.bodyMedium,
      );
    }

    final improvement = <String>[
      if (outcome.accepted)
        'cut the app’s average error from '
            '${_pct(outcome.baselineHoldoutError)} to '
            '${_pct(outcome.holdoutError)}',
      if (activity != null && activity.accepted)
        'improve telling walking, running and stairs apart from '
            '${(activity.baselineAccuracy * 100).round()}% to '
            '${(activity.accuracy * 100).round()}% correct',
    ].join(', and ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Tuning', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        Text(
          'Retuning would $improvement, measured across '
          '${outcome.sessionCount} saved walks — including ones it was not '
          'tuned on.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 4),
        // Collapsed by default. The raw before/after numbers are diagnostics,
        // not a decision aid, and putting them in front of the buttons was
        // most of what made this screen feel like a pitch.
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('See what would change',
              style: theme.textTheme.bodyMedium),
          children: [
            _ParamDiff(
              before: outcome.baselineParams,
              after: outcome.params,
            ),
          ],
        ),
      ],
    );
  }

  /// Signed difference from a reference, with a percentage only when the
  /// reference is large enough for one to mean anything — the same
  /// hundred-step floor the home screen uses.
  static String? _deltaText(int detected, int? reference) {
    if (reference == null || reference <= 0) return null;
    final diff = detected - reference;
    if (diff == 0) return 'exact match';
    final magnitude = diff.abs();
    final direction = diff > 0 ? 'more' : 'fewer';
    if (reference < 100) return '$magnitude $direction';
    final pct = (magnitude / reference) * 100;
    return '$magnitude $direction · ${pct.toStringAsFixed(1)}%';
  }

  /// True only when the optimiser accepted something.
  ///
  /// Gating on `params != baselineParams` — which is what this used to do —
  /// asks whether the search moved, not whether it found anything worth
  /// adopting. CalibrationOutcome.accepted is the predicate that already
  /// answers the right question.
  bool get _canApply =>
      (_outcome?.accepted ?? false) || (_activityOutcome?.accepted ?? false);

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
        'thresholdSigma' => 'Adaptive threshold',
        'minMotionSigma' => 'Minimum movement',
        'minAmplitude' => 'Minimum step strength',
        'minStepIntervalMs' => 'Fastest step (ms)',
        'maxStepIntervalMs' => 'Slowest step (ms)',
        'regularityRunLength' => 'Steps before counting starts',
        'gyroMinLevel' => 'Minimum rotation',
        'gyroMaxLevel' => 'Maximum rotation',
        _ => key,
      };
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

/// One row of the test comparison: a reference, its count, and how far the
/// app's count sat from it.
///
/// A row rather than the old three-across metric strip. Three numbers side by
/// side with a bare "off by 1.7%" underneath hid the one thing worth knowing —
/// whether the app counted too many or too few.
class _ComparisonRow extends StatelessWidget {
  const _ComparisonRow({
    required this.label,
    required this.value,
    this.delta,
    this.emphasised = false,
  });

  final String label;
  final String value;
  final String? delta;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyLarge)),
          Text(
            value,
            style: (emphasised
                    ? theme.textTheme.headlineSmall
                    : theme.textTheme.titleLarge)
                ?.copyWith(
              fontWeight: emphasised ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
          if (delta != null) ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 110,
              child: Text(
                delta!,
                textAlign: TextAlign.right,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          ] else
            const SizedBox(width: 122),
        ],
      ),
    );
  }
}
