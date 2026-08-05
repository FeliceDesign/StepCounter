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

import 'package:stepcounter/detection/golden_fixture.dart';
import 'package:stepcounter/detection/sensor_sample.dart';
import 'package:stepcounter/detection/step_detector.dart';

import '../test/fixtures/gait_fixtures.dart';

const outputDir = 'android/app/src/test/resources/goldens';

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
  };

  final dir = Directory(outputDir)..createSync(recursive: true);
  final index = StringBuffer('# name,expected_steps\n');

  for (final entry in cases.entries) {
    final rows = StringBuffer('t_ms,accel_mag,gyro_mag\n');
    final t0 = entry.value.first.tNs;
    for (final s in entry.value) {
      rows.writeln('${((s.tNs - t0) / 1e6).toStringAsFixed(2)},'
          '${s.accelMagnitude.toStringAsFixed(4)},'
          '${s.gyroMagnitude.toStringAsFixed(4)}');
    }

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

  File('${dir.path}/index.csv').writeAsStringSync(index.toString());
  stdout.writeln('\nWrote ${cases.length} goldens to $outputDir');
}
