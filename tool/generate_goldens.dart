// Regenerates the golden fixtures that pin the Dart and Kotlin detectors to
// the same behaviour.
//
//   dart tool/generate_goldens.dart
//
// Run this only when the algorithm is *intentionally* changed, and review the
// diff in expected counts as part of that change. If the goldens are quietly
// regenerated to make a failing test pass, they stop being worth anything.
//
// Only accelerometer and gyroscope magnitudes are stored, not the individual
// axes: the detector consumes nothing else, and two columns instead of six
// keeps the whole corpus around 100 KB.

import 'dart:io';

import 'package:stepcounter/detection/activity.dart';
import 'package:stepcounter/detection/golden_fixture.dart';
import 'package:stepcounter/detection/motion_pipeline.dart';
import 'package:stepcounter/detection/sensor_sample.dart';
import 'package:stepcounter/detection/step_detector.dart';

import '../test/fixtures/gait_fixtures.dart';

const outputDir = 'android/app/src/test/resources/goldens';

/// Fixtures whose whole point is the direction of the movement, not just its
/// size. These are written with all six axes; everything else keeps the
/// compact magnitude form. See GoldenFixture.parse.
const axisFixtures = {'reject_jiggle', 'walk_then_jiggle', 'walk_arm_swing'};

String motionCsv(String name, List<SensorSample> samples) {
  final t0 = samples.first.tNs;
  final withAxes = axisFixtures.contains(name);
  final rows = StringBuffer(
      withAxes ? 't_ms,ax,ay,az,gx,gy,gz\n' : 't_ms,accel_mag,gyro_mag\n');
  for (final s in samples) {
    final t = ((s.tNs - t0) / 1e6).toStringAsFixed(2);
    if (withAxes) {
      rows.writeln('$t,'
          '${s.ax.toStringAsFixed(4)},${s.ay.toStringAsFixed(4)},'
          '${s.az.toStringAsFixed(4)},${s.gx.toStringAsFixed(4)},'
          '${s.gy.toStringAsFixed(4)},${s.gz.toStringAsFixed(4)}');
    } else {
      rows.writeln('$t,${s.accelMagnitude.toStringAsFixed(4)},'
          '${s.gyroMagnitude.toStringAsFixed(4)}');
    }
  }
  return rows.toString();
}

void main() {
  final cases = <String, List<SensorSample>>{
    'walk_normal': GaitFixtures.walk(steps: 60),
    'walk_slow': GaitFixtures.walk(steps: 40, stepFrequencyHz: 1.1, amplitude: 1.2),
    'walk_jog': GaitFixtures.walk(steps: 60, stepFrequencyHz: 2.8, amplitude: 4.0),
    'walk_damped': GaitFixtures.walk(steps: 40, amplitude: 0.9, gyroAmplitude: 0.3),
    'reject_vehicle': GaitFixtures.vehicle(durationSeconds: 30),
    'reject_still': GaitFixtures.still(durationSeconds: 30),
    'reject_bursts': GaitFixtures.isolatedBursts(bursts: 8),
    'reject_shaking': GaitFixtures.shaking(durationSeconds: 20),
    // Small movements of a phone held in the hand. Passes the motion floor,
    // the amplitude floor and the gyro band by construction, so only the
    // rhythm-quality and vertical-share gates can reject it.
    'reject_jiggle': GaitFixtures.handJiggle(durationSeconds: 180),
    // A real walk followed straight into jiggling, with no pause between. The
    // regression test for the confirmed-run latch: the old detector counted
    // right through the second half because the run was already confirmed.
    'walk_then_jiggle': GaitFixtures.concat([
      GaitFixtures.walk(steps: 60),
      GaitFixtures.handJiggle(durationSeconds: 90),
    ]),
    // Walking with the phone in a swinging hand - the case that stops
    // minVerticalShare from being set any higher than it is.
    'walk_arm_swing': GaitFixtures.walkWithArmSwing(steps: 60),
  };

  // Activity goldens carry a barometer track, so they pin stairs detection as
  // well as the step count.
  final activityCases = <String, (List<SensorSample>, List<PressureSample>)>{
    'act_walk': (GaitFixtures.walk(steps: 50), const []),
    'act_run': (GaitFixtures.run(steps: 60), const []),
    'act_stairs_up': (
      GaitFixtures.walk(steps: 40, stepFrequencyHz: 1.5),
      GaitFixtures.pressureRamp(durationSeconds: 35, verticalSpeed: 0.25),
    ),
    'act_stairs_down': (
      GaitFixtures.walk(steps: 40, stepFrequencyHz: 1.7),
      GaitFixtures.pressureRamp(durationSeconds: 32, verticalSpeed: -0.3),
    ),
    'act_level_with_baro': (
      GaitFixtures.walk(steps: 50),
      GaitFixtures.pressureFlat(durationSeconds: 40),
    ),
  };

  final dir = Directory(outputDir)..createSync(recursive: true);
  final index = StringBuffer('# name,expected_steps\n');

  for (final entry in cases.entries) {
    final rows = motionCsv(entry.key, entry.value);

    // Count from the rounded values that actually land on disk, not from the
    // full-precision originals. Otherwise the stored expectation describes data
    // no implementation will ever read, and both sides fail against it.
    final parsed = GoldenFixture.parse(entry.key, '# expected=0\n$rows');
    final expected = StepDetector.countSteps(parsed.samples);

    File('${dir.path}/${entry.key}.csv')
        .writeAsStringSync('# ${entry.key} expected=$expected\n$rows');
    index.writeln('${entry.key},$expected');
    stdout.writeln('${entry.key}: $expected steps, ${entry.value.length} samples');
  }

  for (final entry in activityCases.entries) {
    final (samples, pressure) = entry.value;

    final motion = motionCsv(entry.key, samples);
    final t0 = samples.first.tNs;

    final baro = StringBuffer();
    for (final p in pressure) {
      baro.writeln('${((p.tNs - t0) / 1e6).toStringAsFixed(2)},'
          '${p.hPa.toStringAsFixed(4)}');
    }

    // Same discipline as above: score the rounded values that reach disk.
    final parsed = GoldenFixture.parse(entry.key, '# expected=0\n$motion');
    final restoredPressure = baro.isEmpty
        ? const <PressureSample>[]
        : baro.toString().trim().split('\n').map((line) {
            final p = line.split(',');
            return PressureSample(
              tNs: (double.parse(p[0]) * 1e6).round(),
              hPa: double.parse(p[1]),
            );
          }).toList();

    final counts = MotionPipeline.replay(
      parsed.samples,
      pressure: restoredPressure,
    );
    final total = counts.values.fold<int>(0, (a, b) => a + b);
    final dominant = counts.isEmpty
        ? Activity.unknown
        : counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;

    File('${dir.path}/${entry.key}.csv').writeAsStringSync(
      '# ${entry.key} expected=$total activity=${dominant.id}\n$motion',
    );
    if (baro.isNotEmpty) {
      File('${dir.path}/${entry.key}.baro.csv')
          .writeAsStringSync('t_ms,hpa\n$baro');
    }
    index.writeln('${entry.key},$total,${dominant.id}');
    stdout.writeln('${entry.key}: $total steps, dominant ${dominant.id}');
  }

  File('${dir.path}/index.csv').writeAsStringSync(index.toString());
  stdout.writeln('\nWrote ${cases.length + activityCases.length} goldens '
      'to $outputDir');
}
