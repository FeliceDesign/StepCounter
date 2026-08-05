import 'dart:math' as math;
import 'dart:typed_data';

/// One synchronised accelerometer (+ optional gyroscope) reading.
///
/// [tNs] is the sensor hardware timestamp in nanoseconds on a monotonic clock,
/// never wall clock. Sensor batching delivers events in bursts long after they
/// were measured, so wall clock at delivery time would smear the cadence and
/// break the temporal gates.
class SensorSample {
  const SensorSample({
    required this.tNs,
    required this.ax,
    required this.ay,
    required this.az,
    this.gx = 0,
    this.gy = 0,
    this.gz = 0,
    this.hasGyro = false,
  });

  final int tNs;
  final double ax, ay, az;
  final double gx, gy, gz;
  final bool hasGyro;

  /// Orientation-independent acceleration magnitude, including gravity.
  /// Using magnitude rather than a single axis is what lets the detector work
  /// with the phone in a pocket, a bag, or a hand without knowing its pose.
  double get accelMagnitude => math.sqrt(ax * ax + ay * ay + az * az);

  double get gyroMagnitude => math.sqrt(gx * gx + gy * gy + gz * gz);

  /// Number of float32 values one sample occupies in the packed blob format.
  static const int floatsPerSample = 7;

  /// Packs samples for storage in a calibration session BLOB.
  ///
  /// Float32 costs ~0.4 % relative precision, far below sensor noise, and
  /// halves the stored size versus float64: a 60 s session at 50 Hz is ~84 KB.
  /// The timestamp is stored as milliseconds relative to the first sample so it
  /// fits a float32 without losing sub-millisecond resolution.
  static Uint8List pack(List<SensorSample> samples) {
    final out = Float32List(samples.length * floatsPerSample);
    if (samples.isEmpty) return out.buffer.asUint8List();
    final t0 = samples.first.tNs;
    for (var i = 0; i < samples.length; i++) {
      final s = samples[i];
      final o = i * floatsPerSample;
      out[o] = (s.tNs - t0) / 1e6;
      out[o + 1] = s.ax;
      out[o + 2] = s.ay;
      out[o + 3] = s.az;
      out[o + 4] = s.gx;
      out[o + 5] = s.gy;
      out[o + 6] = s.gz;
    }
    return out.buffer.asUint8List();
  }

  static List<SensorSample> unpack(Uint8List bytes, {bool hasGyro = true}) {
    if (bytes.isEmpty) return const [];
    final f = Float32List.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes ~/ Float32List.bytesPerElement,
    );
    final n = f.length ~/ floatsPerSample;
    return List<SensorSample>.generate(n, (i) {
      final o = i * floatsPerSample;
      return SensorSample(
        tNs: (f[o] * 1e6).round(),
        ax: f[o + 1],
        ay: f[o + 2],
        az: f[o + 3],
        gx: f[o + 4],
        gy: f[o + 5],
        gz: f[o + 6],
        hasGyro: hasGyro,
      );
    });
  }
}

/// One barometer reading.
///
/// Stored in a separate blob from [SensorSample] rather than as an eighth float
/// on it. Barometers report a few times a second against the accelerometer's
/// fifty, so interleaving them would waste most of the space — and, more
/// importantly, a separate column lets sessions recorded before stairs existed
/// stay readable instead of becoming ambiguous byte lengths.
class PressureSample {
  const PressureSample({required this.tNs, required this.hPa});

  final int tNs;
  final double hPa;

  static const int floatsPerSample = 2;

  static Uint8List pack(List<PressureSample> samples) {
    final out = Float32List(samples.length * floatsPerSample);
    if (samples.isEmpty) return out.buffer.asUint8List();
    final t0 = samples.first.tNs;
    for (var i = 0; i < samples.length; i++) {
      out[i * floatsPerSample] = (samples[i].tNs - t0) / 1e6;
      out[i * floatsPerSample + 1] = samples[i].hPa;
    }
    return out.buffer.asUint8List();
  }

  static List<PressureSample> unpack(Uint8List bytes) {
    if (bytes.isEmpty) return const [];
    final f = Float32List.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes ~/ Float32List.bytesPerElement,
    );
    final n = f.length ~/ floatsPerSample;
    return List<PressureSample>.generate(
      n,
      (i) => PressureSample(
        tNs: (f[i * floatsPerSample] * 1e6).round(),
        hPa: f[i * floatsPerSample + 1],
      ),
    );
  }
}
