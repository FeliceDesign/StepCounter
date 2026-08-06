import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_scope.dart';
import '../data/database.dart';
import '../detection/activity.dart';
import '../detection/calibration_optimizer.dart';
import 'calibration_screen.dart';

/// Every recorded walk, with what the app counted and what each reference said.
///
/// The data for this screen existed from the beginning — `watchSessions()` was
/// written, tested, and then never called by anything. Without it the only
/// feedback a test ever gave was a single screen shown once and then lost, so
/// there was no way to tell a detector that had drifted from one bad walk, or
/// to see whether calibration had helped.
class CalibrationHistoryScreen extends StatelessWidget {
  const CalibrationHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Calibration')),
      body: StreamBuilder<List<CalibrationSession>>(
        stream: scope.repository.watchSessions(),
        builder: (context, snapshot) {
          final sessions = snapshot.data ?? const <CalibrationSession>[];
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _Summary(sessions: sessions),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: FilledButton.icon(
                  icon: const Icon(Icons.directions_walk),
                  label: const Text('Run a test walk'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const CalibrationScreen()),
                  ),
                ),
              ),
              const _WhatGetsCollected(),
              const Divider(height: 32),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Results',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 4),
              if (sessions.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Text(
                    'Nothing recorded yet. Run a test walk, or turn on '
                    'automatic calibration and the app will collect its own.',
                  ),
                )
              else
                for (final s in sessions) _SessionTile(session: s),
            ],
          );
        },
      ),
    );
  }
}

/// Counts and average deviations across everything stored.
class _Summary extends StatelessWidget {
  const _Summary({required this.sessions});

  final List<CalibrationSession> sessions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final manual = sessions.where((s) => s.source == 'manual').length;
    final automatic = sessions.length - manual;

    final vsUser = _meanDeviation(sessions, (s) => s.userSteps);
    final vsAndroid = _meanDeviation(sessions, (s) => s.hardwareSteps);

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              sessions.isEmpty
                  ? 'No saved walks yet'
                  : '${sessions.length} saved '
                      '${sessions.length == 1 ? 'walk' : 'walks'}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '$manual ${manual == 1 ? 'test' : 'tests'} you ran, '
              '$automatic collected automatically',
              style: theme.textTheme.bodySmall,
            ),
            if (vsUser != null || vsAndroid != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  if (vsUser != null)
                    Expanded(
                      child: _Stat(
                        label: 'Average miss vs your count',
                        value: '${vsUser.toStringAsFixed(1)}%',
                      ),
                    ),
                  if (vsAndroid != null)
                    Expanded(
                      child: _Stat(
                        label: 'Average miss vs Android',
                        value: '${vsAndroid.toStringAsFixed(1)}%',
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Mean absolute deviation as a percentage, over the sessions that carry the
  /// reference at all. Returns null when none of them do, so the caller can
  /// leave the figure out rather than print a confident zero.
  static double? _meanDeviation(
    List<CalibrationSession> sessions,
    int? Function(CalibrationSession) reference,
  ) {
    var sum = 0.0;
    var n = 0;
    for (final s in sessions) {
      final r = reference(s);
      if (r == null || r <= 0) continue;
      sum += ((s.detectedSteps - r).abs() / r) * 100;
      n++;
    }
    return n == 0 ? null : sum / n;
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w600)),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

/// One recorded walk: what the app counted, and how far that was from each
/// reference it has.
class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session});

  final CalibrationSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final manual = session.source == 'manual';
    final when = DateTime.fromMillisecondsSinceEpoch(session.recordedAt);

    final subtitle = [
      DateFormat('d MMM, HH:mm').format(when),
      if (session.durationMs > 0) _duration(session.durationMs),
      if (session.declaredActivity != null)
        Activity.fromId(session.declaredActivity!).label,
    ].join(' · ');

    return ListTile(
      leading: Icon(
        manual ? Icons.directions_walk : Icons.auto_awesome,
        color: manual ? theme.colorScheme.primary : theme.colorScheme.outline,
      ),
      title: Row(
        children: [
          _Count(label: 'App', value: '${session.detectedSteps}', bold: true),
          _Count(
            label: 'You',
            value: _reference(session.userSteps),
            delta: _delta(session.detectedSteps, session.userSteps),
          ),
          _Count(
            label: 'Android',
            value: _reference(session.hardwareSteps),
            delta: _delta(session.detectedSteps, session.hardwareSteps),
          ),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(subtitle, style: theme.textTheme.bodySmall),
      ),
      onLongPress: () => _confirmDelete(context),
    );
  }

  static String _reference(int? v) => v == null ? '—' : '$v';

  /// Signed difference, plus a percentage only when the reference is big
  /// enough for one to mean anything.
  ///
  /// The hundred-step floor matches the home screen's: a percentage of a
  /// handful of steps is noise dressed up as information.
  static String? _delta(int detected, int? reference) {
    if (reference == null || reference == 0) return null;
    final diff = detected - reference;
    if (diff == 0) return 'exact';
    final sign = diff > 0 ? '+' : '';
    if (reference < 100) return '$sign$diff';
    final pct = (diff / reference) * 100;
    return '$sign$diff · $sign${pct.toStringAsFixed(1)}%';
  }

  static String _duration(int ms) {
    final total = ms ~/ 1000;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final repo = AppScope.of(context).repository;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this result?'),
        content: const Text(
          'The recording and its counts are removed, and the app stops '
          'learning from it.',
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
    if (ok == true) await repo.deleteSession(session.id);
  }
}

class _Count extends StatelessWidget {
  const _Count({
    required this.label,
    required this.value,
    this.delta,
    this.bold = false,
  });

  final String label;
  final String value;
  final String? delta;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelSmall),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
          Text(
            delta ?? ' ',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }
}

/// Answers "what are these, and where did they come from" in the app rather
/// than only in the source.
///
/// The word "window" is deliberately absent from the copy. It is an
/// implementation term, and a user asking what their windows are is the
/// evidence that it never belonged in the interface.
class _WhatGetsCollected extends StatelessWidget {
  const _WhatGetsCollected();

  @override
  Widget build(BuildContext context) {
    return const ExpansionTile(
      leading: Icon(Icons.help_outline),
      title: Text('What gets collected automatically?'),
      childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        Text(
          'With automatic calibration on, the app saves a short stretch of raw '
          'motion each time you walk and then stop. Once you have been still '
          'for twenty seconds it asks your phone’s own step sensor how '
          'many steps it counted over exactly that stretch, and stores the two '
          'numbers side by side.\n\n'
          'That gives the app graded homework without asking you for anything. '
          'The wait for a real pause matters: your phone’s step sensor '
          'reports up to ten seconds late, so a number read mid-walk would be '
          'wrong. A walk that never pauses is thrown away rather than labelled '
          'badly.\n\n'
          'Nothing leaves your phone. Turn the switch off to stop collecting, '
          'or clear everything under Settings → Reset.',
        ),
      ],
    );
  }
}

/// How many saved walks the optimiser needs before it will change anything.
String retuneRequirement(int sessions) => sessions >=
        CalibrationOptimizer.minSessionsForHoldout
    ? ''
    : 'Needs ${CalibrationOptimizer.minSessionsForHoldout} saved walks to '
        'check a retune against data it was not tuned on; there '
        '${sessions == 1 ? 'is' : 'are'} $sessions.';
