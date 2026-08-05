import 'sensor_sample.dart';

/// Parser for the shared golden fixture format in
/// android/app/src/test/resources/goldens.
///
/// Lives in lib/ rather than test/ so the Dart test and the tooling that
/// generates the files agree on one parser, and so the Kotlin port in
/// DetectionGoldenTest.kt has a single specification to mirror.
class GoldenFixture {
  const GoldenFixture({
    required this.name,
    required this.expectedSteps,
    required this.samples,
  });

  final String name;
  final int expectedSteps;
  final List<SensorSample> samples;

  /// Rebuilds samples from stored magnitudes.
  ///
  /// The magnitudes are placed on a single axis each. The detector only ever
  /// looks at sqrt(x^2+y^2+z^2), so this is exactly equivalent to the original
  /// three-axis data as far as the algorithm is concerned.
  static GoldenFixture parse(String name, String contents) {
    final lines = contents.split('\n');
    var expected = -1;
    final samples = <SensorSample>[];

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#')) {
        final m = RegExp(r'expected=(\d+)').firstMatch(line);
        if (m != null) expected = int.parse(m.group(1)!);
        continue;
      }
      if (line.startsWith('t_ms')) continue;

      final parts = line.split(',');
      if (parts.length < 3) continue;
      samples.add(SensorSample(
        tNs: (double.parse(parts[0]) * 1e6).round(),
        ax: double.parse(parts[1]),
        ay: 0,
        az: 0,
        gx: double.parse(parts[2]),
        gy: 0,
        gz: 0,
        hasGyro: true,
      ));
    }

    if (expected < 0) {
      throw FormatException('golden "$name" has no `expected=` header');
    }
    return GoldenFixture(name: name, expectedSteps: expected, samples: samples);
  }
}
