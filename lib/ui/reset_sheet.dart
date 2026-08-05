import 'package:flutter/material.dart';

import '../app_scope.dart';

/// Reset, with the three scopes independently selectable.
///
/// Deliberately not one "reset everything" button. Wanting a fresh calibration
/// is not the same as wanting to lose a year of step history, and a single
/// destructive button forces that choice on people who only meant the first.
/// Nothing is preselected, and the confirm button stays disabled until at least
/// one scope is chosen.
Future<bool> showResetSheet(BuildContext context) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _ResetSheet(),
  );
  return result ?? false;
}

class _ResetSheet extends StatefulWidget {
  const _ResetSheet();

  @override
  State<_ResetSheet> createState() => _ResetSheetState();
}

class _ResetSheetState extends State<_ResetSheet> {
  bool _parameters = false;
  bool _sessions = false;
  bool _history = false;
  bool _busy = false;

  bool get _anySelected => _parameters || _sessions || _history;

  Future<void> _confirm() async {
    // Step history is the only irreplaceable one, so it gets a second prompt.
    if (_history) {
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete step history?'),
          content: const Text(
            'Every recorded step, for every day, will be permanently deleted. '
            'This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (sure != true) return;
    }

    if (!mounted) return;
    setState(() => _busy = true);

    await AppScope.of(context).repository.reset(
          parameters: _parameters,
          sessions: _sessions,
          history: _history,
        );

    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('Reset', style: theme.textTheme.headlineSmall),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Choose what to clear. Nothing is selected by default.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              value: _parameters,
              onChanged: (v) => setState(() => _parameters = v ?? false),
              title: const Text('Learned settings'),
              subtitle: const Text(
                'Return the detector to factory defaults. Your saved tests and '
                'step history are kept.',
              ),
            ),
            CheckboxListTile(
              value: _sessions,
              onChanged: (v) => setState(() => _sessions = v ?? false),
              title: const Text('Saved calibration tests'),
              subtitle: const Text(
                'Delete recorded walks, including the ones collected '
                'automatically. Calibration starts gathering evidence again '
                'from scratch.',
              ),
            ),
            CheckboxListTile(
              value: _history,
              onChanged: (v) => setState(() => _history = v ?? false),
              title: Text(
                'Step history',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              subtitle: const Text(
                'Permanently delete every step ever recorded.',
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed:
                          _busy ? null : () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                        foregroundColor: theme.colorScheme.onError,
                      ),
                      onPressed: (!_anySelected || _busy) ? null : _confirm,
                      child: _busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Reset'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
