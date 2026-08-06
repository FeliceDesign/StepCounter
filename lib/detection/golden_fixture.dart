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
    this.expectedActivity,
    this.pressure = const [],
  });

  final String name;
  final int expectedSteps;
  final List<SensorSample> samples;

  /// The activity most of the steps were attributed to, when the golden
  /// records one. Absent on the older step-only fixtures.
  final String? expectedActivity;

  final List<PressureSample> pressure;

  /// Rebuilds samples from a golden file.
  ///
  /// Two column layouts are accepted, and which one a fixture uses is a real
  /// decision rather than a historical accident:
  ///
  ///   `t_ms,accel_mag,gyro_mag`            - three columns
  ///   `t_ms,ax,ay,az,gx,gy,gz`             - seven columns
  ///
  /// The three-column form was the only one that existed while every gate read
  /// the orientation-free magnitude, and it is still what most fixtures need:
  /// it is a third of the size and the magnitudes are all the algorithm looked
  /// at. Its axes are reconstructed onto x alone.
  ///
  /// That reconstruction stopped being harmless once the detector gained the
  /// vertical-share gate. With everything on one axis the gravity estimate
  /// lines up with that axis and the vertical share is identically 1, so a
  /// three-column fixture cannot exercise the gate at all — it would pass
  /// trivially in both languages and pin nothing. Fixtures that exist to hold
  /// that gate in place therefore store all seven columns.
  static GoldenFixture parse(
    String name,
    String contents, {
    String? pressureContents,
  }) {
    final lines = contents.split('\n');
    var expected = -1;
    String? activity;
    final samples = <SensorSample>[];

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#')) {
        final m = RegExp(r'expected=(\d+)').firstMatch(line);
        if (m != null) expected = int.parse(m.group(1)!);
        final a = RegExp(r'activity=(\w+)').firstMatch(line);
        if (a != null) activity = a.group(1);
        continue;
      }
      if (line.startsWith('t_ms')) continue;

      final parts = line.split(',');
      if (parts.length >= 7) {
        samples.add(SensorSample(
          tNs: (double.parse(parts[0]) * 1e6).round(),
          ax: double.parse(parts[1]),
          ay: double.parse(parts[2]),
          az: double.parse(parts[3]),
          gx: double.parse(parts[4]),
          gy: double.parse(parts[5]),
          gz: double.parse(parts[6]),
          hasGyro: true,
        ));
        continue;
      }
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
    return GoldenFixture(
      name: name,
      expectedSteps: expected,
      samples: samples,
      expectedActivity: activity,
      pressure: parsePressure(pressureContents),
    );
  }

  /// Companion barometer track, stored beside the motion file.
  static List<PressureSample> parsePressure(String? contents) {
    if (contents == null) return const [];
    final out = <PressureSample>[];
    for (final raw in contents.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('t_ms')) {
        continue;
      }
      final parts = line.split(',');
      if (parts.length < 2) continue;
      out.add(PressureSample(
        tNs: (double.parse(parts[0]) * 1e6).round(),
        hPa: double.parse(parts[1]),
      ));
    }
    return out;
  }
}
