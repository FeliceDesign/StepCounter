import 'package:flutter/material.dart';

import '../detection/activity.dart';

/// Colours for the activity breakdown in the charts.
///
/// Chosen to stay distinguishable under the common forms of colour blindness:
/// the four categories differ in lightness as well as hue, so they remain
/// readable as a greyscale ramp if hue is lost entirely. Each has a light and a
/// dark variant because a single set cannot hold contrast against both a white
/// and a near-black surface.
class ActivityPalette {
  const ActivityPalette._();

  static const _lightColours = <Activity, Color>{
    Activity.walking: Color(0xFF2E7D5B),
    Activity.running: Color(0xFFD98324),
    Activity.stairsUp: Color(0xFF5B4B9E),
    Activity.stairsDown: Color(0xFF8478C4),
    Activity.unknown: Color(0xFF9AA0A6),
  };

  static const _darkColours = <Activity, Color>{
    Activity.walking: Color(0xFF57C08A),
    Activity.running: Color(0xFFF0A94E),
    Activity.stairsUp: Color(0xFF9C8CE8),
    Activity.stairsDown: Color(0xFFBFB4F2),
    Activity.unknown: Color(0xFF8A9096),
  };

  static Color of(BuildContext context, Activity activity) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final table = dark ? _darkColours : _lightColours;
    return table[activity] ?? table[Activity.unknown]!;
  }

  /// Stacking order, bottom of the bar first.
  ///
  /// Walking is the bulk of a normal day so it sits at the base, where the
  /// bar's height is easiest to read; unknown goes on top so migrated or
  /// unclassified data never displaces the categories that mean something.
  static const List<Activity> stackOrder = [
    Activity.walking,
    Activity.running,
    Activity.stairsUp,
    Activity.stairsDown,
    Activity.unknown,
  ];

  /// Categories shown in the legend. Stairs up and down share a single entry —
  /// the split matters to calibration, not to someone reading a bar chart.
  static const List<Activity> legendOrder = [
    Activity.walking,
    Activity.running,
    Activity.stairsUp,
    Activity.unknown,
  ];

  static String legendLabel(Activity a) =>
      a == Activity.stairsUp ? 'Stairs' : a.label;
}

/// Key for the activity colours, shown under the charts.
class ActivityLegend extends StatelessWidget {
  const ActivityLegend({super.key, required this.present});

  /// Which activities actually appear in the data. Categories with no steps are
  /// hidden rather than shown at zero, so the legend stays short for the many
  /// users whose phone has no barometer and who never run.
  final Set<Activity> present;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = ActivityPalette.legendOrder.where((a) {
      if (a == Activity.stairsUp) {
        return present.contains(Activity.stairsUp) ||
            present.contains(Activity.stairsDown);
      }
      return present.contains(a);
    }).toList();

    if (shown.length < 2) return const SizedBox.shrink();

    return Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        for (final a in shown)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: ActivityPalette.of(context, a),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                ActivityPalette.legendLabel(a),
                style: theme.textTheme.labelSmall,
              ),
            ],
          ),
      ],
    );
  }
}
