import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_scope.dart';
import '../data/database.dart';
import 'step_chart.dart';

enum HistoryRange {
  week('Week', 7),
  month('Month', 30),
  quarter('3 months', 90),
  year('Year', 365);

  const HistoryRange(this.label, this.days);
  final String label;
  final int days;
}

/// The whole recorded history, scrollable back to the first recorded day.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  HistoryRange _range = HistoryRange.week;

  /// How many whole ranges back from today the view is scrolled.
  int _offset = 0;

  List<DayTotal> _days = const [];
  DateTime? _firstDay;
  bool _loading = true;
  bool _loadedOnce = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reads AppScope, so it cannot run from initState.
    if (_loadedOnce) return;
    _loadedOnce = true;
    _load();
  }

  DateTime get _end {
    final today = DayMath.dayStart(DateTime.now());
    return DayMath.addDays(DayMath.nextDay(today), -_offset * _range.days);
  }

  DateTime get _start => DayMath.addDays(_end, -_range.days);

  Future<void> _load() async {
    setState(() => _loading = true);
    final repo = AppScope.of(context).repository;
    final days = await repo.range(_start, _end);
    final first = await repo.firstRecordedDay();
    if (!mounted) return;
    setState(() {
      _days = days;
      _firstDay = first;
      _loading = false;
    });
  }

  /// True once the visible window has scrolled past the earliest data.
  bool get _atEarliest {
    final first = _firstDay;
    if (first == null) return true;
    return !_start.isAfter(first);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _days.fold<int>(0, (a, d) => a + d.steps);
    final active = _days.where((d) => d.steps > 0).length;
    final average = active == 0 ? 0 : total ~/ active;
    final best = _days.isEmpty
        ? null
        : _days.reduce((a, b) => a.steps >= b.steps ? a : b);

    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SegmentedButton<HistoryRange>(
              segments: [
                for (final r in HistoryRange.values)
                  ButtonSegment(value: r, label: Text(r.label)),
              ],
              selected: {_range},
              showSelectedIcon: false,
              onSelectionChanged: (s) {
                setState(() {
                  _range = s.first;
                  _offset = 0;
                });
                _load();
              },
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                tooltip: 'Earlier',
                onPressed: _atEarliest
                    ? null
                    : () {
                        setState(() => _offset++);
                        _load();
                      },
              ),
              Text(
                _rangeLabel(),
                style: theme.textTheme.titleSmall,
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                tooltip: 'Later',
                onPressed: _offset == 0
                    ? null
                    : () {
                        setState(() => _offset--);
                        _load();
                      },
              ),
            ],
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 20, 8),
                    child: StepChart(
                      days: _days,
                      goal: AppScope.of(context).settings.dailyGoal,
                      highlightLast: _offset == 0,
                    ),
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _Stat(label: 'Total', value: total),
                _Stat(label: 'Daily average', value: average),
                _Stat(label: 'Best day', value: best?.steps ?? 0),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _rangeLabel() {
    final last = DayMath.addDays(_end, -1);
    final fmt = _range == HistoryRange.year ? DateFormat.yMMM() : DateFormat.MMMd();
    return '${fmt.format(_start)} — ${fmt.format(last)}';
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(
          NumberFormat.decimalPattern().format(value),
          style: theme.textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}
