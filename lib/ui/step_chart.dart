import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/database.dart';
import '../detection/activity.dart';
import 'activity_palette.dart';

/// Bar chart of daily step totals, shared by the home screen's 7-day view and
/// the full history screen.
class StepChart extends StatelessWidget {
  const StepChart({
    super.key,
    required this.days,
    this.goal,
    this.labelFormat,
    this.onBarTapped,
    this.highlightLast = true,
  });

  final List<DayTotal> days;
  final int? goal;
  final DateFormat? labelFormat;
  final ValueChanged<DayTotal>? onBarTapped;
  final bool highlightLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (days.isEmpty) {
      return Center(
        child: Text('No data yet', style: theme.textTheme.bodyMedium),
      );
    }

    final maxSteps = days.map((d) => d.steps).fold<int>(0, (a, b) => a > b ? a : b);
    // A flat zero axis would render as a single line with no sense of scale, so
    // empty ranges still get a nominal ceiling.
    final maxY = (maxSteps == 0 ? (goal ?? 1000) : maxSteps) * 1.25;

    // Past a couple of weeks there is no room for a label under every bar.
    final labelStride = (days.length / 8).ceil().clamp(1, 999);
    final format = labelFormat ?? (days.length <= 8 ? DateFormat.E() : DateFormat.Md());

    return BarChart(
      BarChartData(
        maxY: maxY,
        minY: 0,
        alignment: BarChartAlignment.spaceAround,
        barTouchData: BarTouchData(
          enabled: true,
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => scheme.inverseSurface,
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final day = days[group.x];
              final faint = TextStyle(
                color: scheme.onInverseSurface.withValues(alpha: 0.8),
                fontWeight: FontWeight.normal,
                fontSize: 12,
              );

              // Breakdown only when there is one — on a day of plain walking an
              // extra line saying "walking" is noise.
              final parts = <Activity, int>{
                for (final a in ActivityPalette.stackOrder)
                  if (day.stepsIn(a) > 0) a: day.stepsIn(a),
              };

              return BarTooltipItem(
                '${NumberFormat.decimalPattern().format(day.steps)}\n',
                TextStyle(
                  color: scheme.onInverseSurface,
                  fontWeight: FontWeight.bold,
                ),
                children: [
                  TextSpan(text: DateFormat.MMMEd().format(day.day), style: faint),
                  if (parts.length > 1)
                    for (final e in parts.entries)
                      TextSpan(
                        text: '\n${ActivityPalette.legendLabel(e.key)}  '
                            '${NumberFormat.decimalPattern().format(e.value)}',
                        style: faint,
                      ),
                ],
              );
            },
          ),
          touchCallback: (event, response) {
            if (!event.isInterestedForInteractions) return;
            final index = response?.spot?.touchedBarGroupIndex;
            if (index != null && index >= 0 && index < days.length) {
              onBarTapped?.call(days[index]);
            }
          },
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: maxY / 4,
          getDrawingHorizontalLine: (_) => FlLine(
            color: scheme.outlineVariant.withValues(alpha: 0.4),
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 42,
              interval: maxY / 4,
              getTitlesWidget: (value, meta) {
                if (value < 1) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(
                    NumberFormat.compact().format(value.round()),
                    style: theme.textTheme.labelSmall,
                  ),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              getTitlesWidget: (value, meta) {
                final i = value.round();
                if (i < 0 || i >= days.length) return const SizedBox.shrink();
                if (i % labelStride != 0 && i != days.length - 1) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    format.format(days[i].day),
                    style: theme.textTheme.labelSmall,
                  ),
                );
              },
            ),
          ),
        ),
        extraLinesData: goal == null
            ? const ExtraLinesData()
            : ExtraLinesData(horizontalLines: [
                HorizontalLine(
                  y: goal!.toDouble(),
                  color: scheme.tertiary.withValues(alpha: 0.7),
                  strokeWidth: 1.5,
                  dashArray: [6, 4],
                ),
              ]),
        barGroups: [
          for (var i = 0; i < days.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [_rod(context, days[i], i)],
            ),
        ],
      ),
    );
  }

  /// One bar, stacked by activity.
  ///
  /// Days before today are drawn slightly translucent so today still reads as
  /// the focus of the chart without needing a different hue, which would have
  /// collided with the activity colours.
  BarChartRodData _rod(BuildContext context, DayTotal day, int index) {
    final isLast = index == days.length - 1;
    final dim = highlightLast && !isLast;

    var from = 0.0;
    final stack = <BarChartRodStackItem>[];
    for (final activity in ActivityPalette.stackOrder) {
      final steps = day.stepsIn(activity);
      if (steps <= 0) continue;
      final to = from + steps;
      var colour = ActivityPalette.of(context, activity);
      if (dim) colour = colour.withValues(alpha: 0.55);
      stack.add(BarChartRodStackItem(from, to, colour));
      from = to;
    }

    return BarChartRodData(
      toY: day.steps.toDouble(),
      width: (220 / days.length).clamp(3.0, 22.0),
      borderRadius: BorderRadius.circular(4),
      // Shows through only when a bar is empty; every visible bar is covered
      // by its stack items.
      color: Colors.transparent,
      rodStackItems: stack,
    );
  }
}
