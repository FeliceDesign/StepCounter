import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:stepcounter/detection/golden_fixture.dart';
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
      .where((f) => f.path.endsWith('.csv') && !f.path.endsWith('index.csv'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('golden corpus is present', () {
    expect(files, isNotEmpty, reason: 'run: dart tool/generate_goldens.dart');
    expect(files.length, greaterThanOrEqualTo(8));
  });

  for (final file in files) {
    final name = file.uri.pathSegments.last.replaceAll('.csv', '');

    test('golden $name', () {
      final golden = GoldenFixture.parse(name, file.readAsStringSync());
      expect(golden.samples, isNotEmpty);
      expect(
        StepDetector.countSteps(golden.samples),
        golden.expectedSteps,
        reason: 'Dart detector no longer matches golden $name. If the algorithm '
            'changed on purpose, regenerate with tool/generate_goldens.dart and '
            'review the diff in expected counts.',
      );
    });
  }

  test('rejection goldens really do expect zero', () {
    for (final file in files.where((f) => f.path.contains('reject_'))) {
      final name = file.uri.pathSegments.last.replaceAll('.csv', '');
      final golden = GoldenFixture.parse(name, file.readAsStringSync());
      expect(golden.expectedSteps, 0, reason: '$name should count nothing');
    }
  });
}
