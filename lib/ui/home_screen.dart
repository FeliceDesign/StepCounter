import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_scope.dart';
import '../data/database.dart';
import '../detection/activity.dart';
import 'activity_palette.dart';
import 'history_screen.dart';
import 'settings_screen.dart';
import 'step_chart.dart';

/// Today's count in the top half, the last seven days in the bottom half.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  List<DayTotal> _week = const [];
  bool _loadedOnce = false;

  /// Held rather than rebuilt inline. Creating the stream in `build` would
  /// resubscribe on every frame, and the window it queries is fixed at
  /// creation — so a session left open past midnight would keep reporting
  /// yesterday until the widget happened to rebuild.
  Stream<int>? _todayStream;
  DateTime? _streamDay;

  void _ensureTodayStream() {
    final today = DayMath.dayStart(DateTime.now());
    if (_streamDay == today && _todayStream != null) return;
    _streamDay = today;
    _todayStream = AppScope.of(context).repository.watchToday();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Not initState: reading an InheritedWidget before initState returns is an
    // error, because a later change to it could not rebuild this widget.
    _ensureTodayStream();
    if (_loadedOnce) return;
    _loadedOnce = true;
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the app is the moment the on-screen number is most likely
    // to be stale, since the service has been counting the whole time.
    if (state == AppLifecycleState.resumed) {
      final repo = AppScope.of(context).repository;
      repo.drainFromService();
      repo.refreshHardwareCount();
      // Rebuilds the stream if the day rolled over while we were away.
      setState(_ensureTodayStream);
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final week = await AppScope.of(context).repository.lastDays(7);
    if (mounted) setState(() => _week = week);
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);

    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await scope.repository.drainFromService();
            await scope.repository.refreshHardwareCount();
            await _refresh();
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    children: [
                      SizedBox(
                        height: constraints.maxHeight * 0.5,
                        child: _TodayPanel(
                          todaySteps: _todayStream,
                          onRefreshed: _refresh,
                        ),
                      ),
                      SizedBox(
                        height: constraints.maxHeight * 0.5,
                        child: _WeekPanel(week: _week),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TodayPanel extends StatelessWidget {
  const _TodayPanel({required this.todaySteps, required this.onRefreshed});

  final Stream<int>? todaySteps;
  final VoidCallback onRefreshed;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final theme = Theme.of(context);
    final goal = scope.settings.dailyGoal;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        children: [
          Row(
            children: [
              Text('Today', style: theme.textTheme.titleMedium),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Settings',
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  );
                  onRefreshed();
                },
              ),
            ],
          ),
          Expanded(
            child: StreamBuilder<int>(
              stream: todaySteps,
              builder: (context, snapshot) {
                final steps = snapshot.data ?? 0;
                return ListenableBuilder(
                  listenable: scope.repository,
                  builder: (context, _) => _BigCount(
                    steps: steps,
                    goal: goal,
                    androidSteps: scope.repository.hardwareToday,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _BigCount extends StatelessWidget {
  const _BigCount({
    required this.steps,
    required this.goal,
    this.androidSteps,
  });

  final int steps;
  final int goal;

  /// Android's own count for today. Null when the device has no pedometer or
  /// it has not reported yet.
  final int? androidSteps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = goal <= 0 ? 0.0 : (steps / goal).clamp(0.0, 1.0);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Flexible, not a bare FittedBox: the panel is a fixed half of the
        // screen, so on a short device a rigid 96pt number pushes everything
        // below it off the bottom. This lets the number give up height first.
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              NumberFormat.decimalPattern().format(steps),
              style: theme.textTheme.displayLarge?.copyWith(
                fontWeight: FontWeight.w700,
                fontSize: 96,
                height: 1.0,
                letterSpacing: -2,
                color: theme.colorScheme.onSurface,
                // Tabular figures stop the number jittering sideways as digits
                // change while you are watching it.
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text('steps', style: theme.textTheme.titleMedium),
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Column(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 8,
                  backgroundColor:
                      theme.colorScheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                steps >= goal
                    ? 'Daily goal reached'
                    : '${NumberFormat.decimalPattern().format(goal - steps)} to go',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _AndroidComparison(ours: steps, theirs: androidSteps),
      ],
    );
  }
}

/// Our count beside Android's, so the two can be compared directly.
///
/// Android's figure is deliberately never the one shown large: it is a
/// reference, and the app's own detector is the point. Showing both makes any
/// disagreement visible instead of leaving it to be wondered about.
class _AndroidComparison extends StatelessWidget {
  const _AndroidComparison({required this.ours, required this.theirs});

  final int ours;
  final int? theirs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final other = theirs;

    if (other == null) {
      return Text(
        'Android step sensor unavailable',
        style:
            theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      );
    }

    final diff = ours - other;
    // A percentage of a handful of steps is noise dressed up as information.
    final showPercent = other >= 100;
    final percent = showPercent ? (diff / other * 100) : 0.0;
    final sign = diff > 0 ? '+' : '';

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _CountCell(label: 'This app', value: ours, emphasised: true),
              Container(
                width: 1,
                height: 32,
                color: scheme.outlineVariant.withValues(alpha: 0.6),
              ),
              _CountCell(label: 'Android', value: other),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            diff == 0
                ? 'Exact match'
                : showPercent
                    ? '$sign$diff  ·  $sign${percent.toStringAsFixed(1)}%'
                    : '$sign$diff',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _CountCell extends StatelessWidget {
  const _CountCell({
    required this.label,
    required this.value,
    this.emphasised = false,
  });

  final String label;
  final int value;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          NumberFormat.decimalPattern().format(value),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: emphasised ? FontWeight.w700 : FontWeight.w500,
            color: emphasised
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Text(label, style: theme.textTheme.labelSmall),
      ],
    );
  }
}

class _WeekPanel extends StatelessWidget {
  const _WeekPanel({required this.week});

  final List<DayTotal> week;

  static Set<Activity> _presentActivities(List<DayTotal> days) => {
        for (final d in days)
          for (final e in d.byActivity.entries)
            if (e.value > 0) e.key,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = AppScope.of(context);
    final total = week.fold<int>(0, (a, d) => a + d.steps);
    final average = week.isEmpty ? 0 : total ~/ week.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Row(
              children: [
                Text('Last 7 days', style: theme.textTheme.titleMedium),
                const SizedBox(width: 12),
                Text(
                  'avg ${NumberFormat.decimalPattern().format(average)}',
                  style: theme.textTheme.bodySmall,
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.history, size: 18),
                  label: const Text('History'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const HistoryScreen()),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: StepChart(
              days: week,
              goal: scope.settings.dailyGoal,
              onBarTapped: (_) => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const HistoryScreen()),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 8),
            child: ActivityLegend(present: _presentActivities(week)),
          ),
        ],
      ),
    );
  }
}
