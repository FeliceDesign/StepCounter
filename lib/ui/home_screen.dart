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
      AppScope.of(context).repository.drainFromService();
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
                        child: _TodayPanel(onRefreshed: _refresh),
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
  const _TodayPanel({required this.onRefreshed});

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
              stream: scope.repository.watchToday(),
              builder: (context, snapshot) {
                final steps = snapshot.data ?? 0;
                return _BigCount(steps: steps, goal: goal);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _BigCount extends StatelessWidget {
  const _BigCount({required this.steps, required this.goal});

  final int steps;
  final int goal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = goal <= 0 ? 0.0 : (steps / goal).clamp(0.0, 1.0);

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        FittedBox(
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
        const SizedBox(height: 4),
        Text('steps', style: theme.textTheme.titleMedium),
        const SizedBox(height: 20),
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
