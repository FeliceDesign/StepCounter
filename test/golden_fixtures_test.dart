import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stepcounter/detection/golden_fixture.dart';
import 'package:stepcounter/detection/motion_pipeline.dart';
import 'package:stepcounter/detection/step_detector.dart';

/// The Dart half of the cross-implementation contract.
///
/// DetectionGoldenTest.kt asserts the same expectations against the same files
/// on the JVM. Together they are what stops the live Kotlin detector and the
/// Dart replay detector from drifting apart — a drift that would silently make
/// every calibration before/after number describe the wrong algorithm.
void main() {
  const dir = 'android/app/src/test/resources/goldens';

  final files = Directory(dir)
      .listSync()
      .whereType<File>()
      .where((f) =>
          f.path.endsWith('.csv') &&
          !f.path.endsWith('index.csv') &&
          // Barometer tracks are loaded alongside their motion file.
          !f.path.endsWith('.baro.csv'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  GoldenFixture load(File file) {
    final name = file.uri.pathSegments.last.replaceAll('.csv', '');
    final baro = File(file.path.replaceAll('.csv', '.baro.csv'));
    return GoldenFixture.parse(
      name,
      file.readAsStringSync(),
      pressureContents: baro.existsSync() ? baro.readAsStringSync() : null,
    );
  }

  test('golden corpus is present', () {
    expect(files, isNotEmpty, reason: 'run: dart tool/generate_goldens.dart');
    expect(files.length, greaterThanOrEqualTo(13));
  });

  for (final file in files) {
    final name = file.uri.pathSegments.last.replaceAll('.csv', '');

    test('golden $name', () {
      final golden = load(file);
      expect(golden.samples, isNotEmpty);

      const reason = 'Dart no longer matches this golden. If the algorithm '
          'changed on purpose, regenerate with tool/generate_goldens.dart and '
          'review the diff.';

      if (golden.expectedActivity == null) {
        expect(StepDetector.countSteps(golden.samples), golden.expectedSteps,
            reason: reason);
        return;
      }

      final counts = MotionPipeline.replay(
        golden.samples,
        pressure: golden.pressure,
      );
      expect(counts.values.fold<int>(0, (a, b) => a + b), golden.expectedSteps,
          reason: reason);

      final dominant = counts.entries
          .reduce((a, b) => a.value >= b.value ? a : b)
          .key;
      expect(dominant.id, golden.expectedActivity, reason: reason);
    });
  }

  test('the activity goldens cover every case worth pinning', () {
    final names = files.map((f) {
      return f.uri.pathSegments.last.replaceAll('.csv', '');
    }).toSet();
    expect(
      names,
      containsAll([
        'act_walk',
        'act_run',
        'act_stairs_up',
        'act_stairs_down',
        'act_level_with_baro',
      ]),
    );
  });

  test('rejection goldens really do expect zero', () {
    for (final file in files.where((f) => f.path.contains('reject_'))) {
      final name = file.uri.pathSegments.last.replaceAll('.csv', '');
      // Hand jiggle is the one negative that is not held to exactly zero; it
      // has its own budgeted test below.
      if (name == 'reject_jiggle') continue;
      final golden = GoldenFixture.parse(name, file.readAsStringSync());
      expect(golden.expectedSteps, 0, reason: '$name should count nothing');
    }
  });

  /// Sustained fidgeting with a phone in the hand is the hardest negative the
  /// detector faces, because it is genuine movement at genuine gait frequency
  /// and amplitude. It gets a budget rather than an equality — but a small one,
  /// and the point of the number is what it used to be. Before the
  /// rhythm-quality and vertical-share gates this fixture scored 278.
  test('three minutes of hand jiggle is almost entirely rejected', () {
    final golden = _load(files, 'reject_jiggle');
    expect(golden.expectedSteps, lessThanOrEqualTo(15));
    expect(
      StepDetector.countSteps(golden.samples),
      golden.expectedSteps,
      reason: 'the stored expectation must match a live replay',
    );
  });

  /// The regression test for the confirmed-run latch.
  ///
  /// The old detector counted straight through the second half of this
  /// fixture: the walk had already flipped the run to confirmed, and nothing
  /// ever re-checked it, so 60 real steps came out as 204.
  test('a confirmed walk does not license counting through jiggle', () {
    final golden = _load(files, 'walk_then_jiggle');
    expect(golden.expectedSteps, inInclusiveRange(55, 80));
  });

  /// The case that keeps [CalibrationParams.minVerticalShare] at 0.45 rather
  /// than the 0.55 the tidier fixtures would allow: walking with the phone in
  /// a swinging hand puts a large horizontal component on top of the gait
  /// signal, and at 0.55 this drops to zero steps.
  test('walking with the phone in a swinging hand is still counted', () {
    expect(_load(files, 'walk_arm_swing').expectedSteps, greaterThanOrEqualTo(50));
  });
}

GoldenFixture _load(List<File> files, String name) {
  final file = files.firstWhere((f) => f.path.endsWith('$name.csv'));
  return GoldenFixture.parse(name, file.readAsStringSync());
}
