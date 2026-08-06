import 'dart:math' as math;

import 'package:stepcounter/detection/sensor_sample.dart';

/// Synthetic motion signals for detector tests.
///
/// These are generated rather than recorded so the expected step count is known
/// exactly and the tests stay deterministic. Recorded walks from real devices
/// can be dropped in later via [fromMagnitudeSeries] without changing the tests
/// around them.
class GaitFixtures {
  /// A walk with a known number of footfalls.
  ///
  /// Models acceleration magnitude as gravity plus a gait fundamental at the
  /// step frequency, plus a smaller second harmonic (real footfall impact is
  /// not a pure sinusoid). Exactly one peak per step survives the 3 Hz
  /// low-pass, so [steps] is ground truth.
  ///
  /// [leadInSeconds] of standing still is prepended because the band-pass needs
  /// time to settle — the app's Test & Recalibrate flow has a countdown for the
  /// same reason.
  static List<SensorSample> walk({
    required int steps,
    double stepFrequencyHz = 1.8,
    double amplitude = 2.0,
    double gyroAmplitude = 0.8,
    double sampleRateHz = 50,
    double noise = 0.05,
    double leadInSeconds = 3.0,
    double leadOutSeconds = 2.0,
    int seed = 42,
  }) {
    final rnd = math.Random(seed);
    final dt = 1 / sampleRateHz;
    final walkDuration = steps / stepFrequencyHz;
    final total = leadInSeconds + walkDuration + leadOutSeconds;
    final n = (total * sampleRateHz).round();

    final out = <SensorSample>[];
    for (var i = 0; i < n; i++) {
      final t = i * dt;
      final walking = t >= leadInSeconds && t < leadInSeconds + walkDuration;
      final tw = t - leadInSeconds;

      var az = 9.81;
      var gyro = 0.0;
      if (walking) {
        final phase = 2 * math.pi * stepFrequencyHz * tw;
        az += amplitude * math.sin(phase) + 0.35 * amplitude * math.sin(2 * phase + 0.7);
        gyro = gyroAmplitude * math.sin(phase + 0.4);
      }

      out.add(SensorSample(
        tNs: (t * 1e9).round(),
        ax: _n(rnd, noise),
        ay: _n(rnd, noise),
        az: az + _n(rnd, noise),
        gx: gyro + _n(rnd, noise * 0.2),
        gy: _n(rnd, noise * 0.2),
        gz: _n(rnd, noise * 0.2),
        hasGyro: true,
      ));
    }
    return out;
  }

  /// Riding in a vehicle: the body oscillates at a gait-like frequency from
  /// road and engine vibration, but the phone barely rotates. This is the
  /// single largest source of phantom steps in naive pedometers.
  static List<SensorSample> vehicle({
    double durationSeconds = 60,
    double sampleRateHz = 50,
    int seed = 7,
  }) {
    final rnd = math.Random(seed);
    final n = (durationSeconds * sampleRateHz).round();
    final out = <SensorSample>[];
    for (var i = 0; i < n; i++) {
      final t = i / sampleRateHz;
      final az = 9.81 +
          1.6 * math.sin(2 * math.pi * 2.0 * t) +
          0.5 * math.sin(2 * math.pi * 5.5 * t) +
          _n(rnd, 0.25);
      out.add(SensorSample(
        tNs: (t * 1e9).round(),
        ax: _n(rnd, 0.2),
        ay: _n(rnd, 0.2),
        az: az,
        // Suspension isolates rotation almost entirely.
        gx: _n(rnd, 0.004),
        gy: _n(rnd, 0.004),
        gz: _n(rnd, 0.004),
        hasGyro: true,
      ));
    }
    return out;
  }

  /// Phone held still on a surface — only sensor noise.
  static List<SensorSample> still({
    double durationSeconds = 60,
    double sampleRateHz = 50,
    int seed = 3,
  }) {
    final rnd = math.Random(seed);
    final n = (durationSeconds * sampleRateHz).round();
    return List.generate(n, (i) {
      final t = i / sampleRateHz;
      return SensorSample(
        tNs: (t * 1e9).round(),
        ax: _n(rnd, 0.02),
        ay: _n(rnd, 0.02),
        az: 9.81 + _n(rnd, 0.02),
        gx: _n(rnd, 0.002),
        gy: _n(rnd, 0.002),
        gz: _n(rnd, 0.002),
        hasGyro: true,
      );
    });
  }

  /// Isolated bursts of motion with gaps between them: taking the phone out of
  /// a pocket, gesturing while talking, setting it down. Each burst is short
  /// enough that it can never build a regularity streak.
  static List<SensorSample> isolatedBursts({
    int bursts = 12,
    int peaksPerBurst = 2,
    double sampleRateHz = 50,
    int seed = 11,
  }) {
    final rnd = math.Random(seed);
    final out = <SensorSample>[];
    var t = 0.0;
    final dt = 1 / sampleRateHz;

    for (var b = 0; b < bursts; b++) {
      final f = 1.2 + rnd.nextDouble() * 1.2;
      final burstDuration = peaksPerBurst / f;
      final amp = 2.5 + rnd.nextDouble() * 2.0;
      final n = (burstDuration * sampleRateHz).round();
      for (var i = 0; i < n; i++) {
        final phase = 2 * math.pi * f * (i * dt);
        out.add(SensorSample(
          tNs: (t * 1e9).round(),
          ax: _n(rnd, 0.1),
          ay: _n(rnd, 0.1),
          az: 9.81 + amp * math.sin(phase) + _n(rnd, 0.1),
          gx: 1.2 * math.sin(phase),
          gy: _n(rnd, 0.05),
          gz: _n(rnd, 0.05),
          hasGyro: true,
        ));
        t += dt;
      }
      // Idle gap, long enough to break any streak.
      final gap = (2.5 * sampleRateHz).round();
      for (var i = 0; i < gap; i++) {
        out.add(SensorSample(
          tNs: (t * 1e9).round(),
          ax: _n(rnd, 0.02),
          ay: _n(rnd, 0.02),
          az: 9.81 + _n(rnd, 0.02),
          gx: _n(rnd, 0.002),
          gy: _n(rnd, 0.002),
          gz: _n(rnd, 0.002),
          hasGyro: true,
        ));
        t += dt;
      }
    }
    return out;
  }

  /// Vigorous shaking — far more rotational energy than gait ever produces.
  static List<SensorSample> shaking({
    double durationSeconds = 30,
    double sampleRateHz = 50,
    int seed = 5,
  }) {
    final rnd = math.Random(seed);
    final n = (durationSeconds * sampleRateHz).round();
    return List.generate(n, (i) {
      final t = i / sampleRateHz;
      final phase = 2 * math.pi * 2.6 * t;
      return SensorSample(
        tNs: (t * 1e9).round(),
        ax: 6 * math.sin(phase) + _n(rnd, 1.0),
        ay: 4 * math.cos(phase * 1.3) + _n(rnd, 1.0),
        az: 9.81 + 5 * math.sin(phase * 0.9) + _n(rnd, 1.0),
        gx: 9 * math.sin(phase),
        gy: 8 * math.cos(phase),
        gz: 7 * math.sin(phase * 1.1),
        hasGyro: true,
      );
    });
  }

  /// Running, with the flight phase that distinguishes it from fast walking.
  ///
  /// During flight both feet are off the ground and the device approaches
  /// freefall, so |a| dips far below gravity. Walking never does this, and it is
  /// the signal the classifier keys on — cadence alone cannot separate a jog
  /// from a brisk walk.
  static List<SensorSample> run({
    required int steps,
    double stepFrequencyHz = 2.8,
    double sampleRateHz = 50,
    double leadInSeconds = 3.0,
    int seed = 71,
  }) {
    final rnd = math.Random(seed);
    final dt = 1 / sampleRateHz;
    final duration = steps / stepFrequencyHz;
    final n = ((leadInSeconds + duration + 2.0) * sampleRateHz).round();

    final out = <SensorSample>[];
    for (var i = 0; i < n; i++) {
      final t = i * dt;
      final running = t >= leadInSeconds && t < leadInSeconds + duration;
      final tr = t - leadInSeconds;

      var az = 9.81;
      var gyro = 0.0;
      if (running) {
        final phase = 2 * math.pi * stepFrequencyHz * tr;
        // Sharp impact peak plus a deep trough: the trough takes |a| close to
        // zero, which is the flight phase.
        az = 9.81 + 11.0 * math.sin(phase) + 3.0 * math.sin(2 * phase + 0.5);
        if (az < 0.4) az = 0.4;
        gyro = 2.2 * math.sin(phase + 0.3);
      }

      out.add(SensorSample(
        tNs: (t * 1e9).round(),
        ax: _n(rnd, 0.3),
        ay: _n(rnd, 0.3),
        az: az + _n(rnd, 0.3),
        gx: gyro + _n(rnd, 0.05),
        gy: _n(rnd, 0.05),
        gz: _n(rnd, 0.05),
        hasGyro: true,
      ));
    }
    return out;
  }

  /// Barometer readings for a constant vertical speed.
  ///
  /// [verticalSpeed] is in m/s: positive climbs. Noise is set to 0.03 hPa,
  /// which is representative of a real phone barometer and about 0.25 m — large
  /// enough that a naive two-point slope would be useless.
  static List<PressureSample> pressureRamp({
    required double durationSeconds,
    required double verticalSpeed,
    double startHPa = 1013.25,
    double sampleRateHz = 5,
    double flatLeadInSeconds = 3.0,
    double noiseHPa = 0.03,
    int seed = 17,
  }) {
    final rnd = math.Random(seed);
    final n = ((flatLeadInSeconds + durationSeconds) * sampleRateHz).round();
    final out = <PressureSample>[];

    for (var i = 0; i < n; i++) {
      final t = i / sampleRateHz;
      final climbing = t >= flatLeadInSeconds;
      final metres = climbing ? (t - flatLeadInSeconds) * verticalSpeed : 0.0;
      // ~0.12 hPa per metre near sea level.
      final hPa = startHPa - metres * 0.1201 + _n(rnd, noiseHPa);
      out.add(PressureSample(tNs: (t * 1e9).round(), hPa: hPa));
    }
    return out;
  }

  /// Barometer readings at a constant altitude, with realistic drift.
  static List<PressureSample> pressureFlat({
    required double durationSeconds,
    double sampleRateHz = 5,
    int seed = 23,
  }) =>
      pressureRamp(
        durationSeconds: durationSeconds,
        verticalSpeed: 0,
        flatLeadInSeconds: 0,
        sampleRateHz: sampleRateHz,
        seed: seed,
      );

  /// Sustained low-amplitude motion: a phone on a desk being typed beside, or
  /// shifting in a chair. Rhythmic enough to reach the detector's peak logic,
  /// far too weak to be walking.
  ///
  /// Phase is integrated rather than written as 2*pi*f(t)*t, which would make
  /// the instantaneous frequency grow without bound and produce a signal the
  /// band-pass simply removes — a fixture that tests nothing.
  static List<SensorSample> lowAmplitudeMotion({
    double durationSeconds = 600,
    double amplitude = 0.35,
    double baseHz = 1.5,
    double sampleRateHz = 50,
    int seed = 5,
  }) {
    final rnd = math.Random(seed);
    final n = (durationSeconds * sampleRateHz).round();
    final dt = 1 / sampleRateHz;
    final out = <SensorSample>[];
    var phase = 0.0;

    for (var i = 0; i < n; i++) {
      final t = i * dt;
      phase += 2 * math.pi * (baseHz + 0.3 * math.sin(2 * math.pi * 0.05 * t)) * dt;
      out.add(SensorSample(
        tNs: (t * 1e9).round(),
        ax: 0.05 * math.sin(phase * 0.7) + _n(rnd, 0.03),
        ay: _n(rnd, 0.03),
        az: 9.81 + amplitude * math.sin(phase) + _n(rnd, 0.05),
        // Enough rotation that the gyro gate cannot be what saves us.
        gx: 0.10 * math.sin(phase + 0.3),
        gy: _n(rnd, 0.01),
        gz: _n(rnd, 0.01),
        hasGyro: true,
      ));
    }
    return out;
  }

  /// Small fidgeting movements of a phone held in the hand: scrolling,
  /// gesturing while talking, turning it over, tapping at it.
  ///
  /// This is deliberately the hardest possible negative, built to defeat every
  /// gate the detector had before the rhythm-quality work:
  ///   - amplitude ~2.5 m/s², comfortably above `minAmplitude` (1.0) and far
  ///     above `minMotionSigma` (0.35), so the motion floor cannot reject it;
  ///   - frequency inside the 0.5-3 Hz gait band, so the band-pass passes it;
  ///   - gyroscope 0.3-1.5 rad/s, squarely inside the walking band
  ///     (0.03-5.0), so the gyro gate cannot be what saves us either.
  ///
  /// What makes it *not* walking is only its irregularity: the interval
  /// between peaks jitters by [frequencyJitter] and their height by
  /// [amplitudeJitter], where real gait holds both to within a few per cent.
  /// A fixture that any earlier gate could reject would prove nothing about
  /// the gates that are supposed to reject this.
  ///
  /// Phase is integrated rather than written as 2*pi*f(t)*t, for the same
  /// reason [lowAmplitudeMotion] documents: the closed form makes the
  /// instantaneous frequency run away and produces a signal the band-pass
  /// simply deletes.
  static List<SensorSample> handJiggle({
    double durationSeconds = 180,
    double amplitude = 2.5,
    double baseHz = 2.2,
    double frequencyJitter = 0.35,
    double amplitudeJitter = 0.7,
    double sampleRateHz = 50,
    int seed = 91,
  }) {
    final rnd = math.Random(seed);
    final n = (durationSeconds * sampleRateHz).round();
    final dt = 1 / sampleRateHz;
    final out = <SensorSample>[];

    var phase = 0.0;
    // Re-rolled once per cycle rather than per sample: a hand changes what it
    // is doing every half-second or so, it does not jitter at 50 Hz.
    var cycleFreq = baseHz;
    var cycleAmp = amplitude;

    for (var i = 0; i < n; i++) {
      phase += 2 * math.pi * cycleFreq * dt;
      if (phase >= 2 * math.pi) {
        phase -= 2 * math.pi;
        cycleFreq = baseHz * (1 + _n(rnd, frequencyJitter));
        cycleAmp = amplitude * (1 + _n(rnd, amplitudeJitter));
      }

      final swing = cycleAmp * math.sin(phase);
      out.add(SensorSample(
        tNs: (i * dt * 1e9).round(),
        // Hand movement is mostly horizontal; gravity stays on z because the
        // detector reads only the magnitude, so where the swing sits does not
        // matter to it. It will matter to a future gravity-projection gate,
        // which is why the axes are modelled honestly rather than all piled
        // onto z.
        ax: 0.8 * swing + _n(rnd, 0.15),
        ay: 0.5 * swing + _n(rnd, 0.15),
        az: 9.81 + 0.35 * swing + _n(rnd, 0.15),
        gx: 0.9 * math.sin(phase + 0.5) + _n(rnd, 0.08),
        gy: 0.6 * math.cos(phase * 1.1) + _n(rnd, 0.08),
        gz: 0.3 * math.sin(phase * 0.9) + _n(rnd, 0.08),
        hasGyro: true,
      ));
    }
    return out;
  }

  /// Walking with the phone carried in a swinging hand.
  ///
  /// The adversarial case for any gate that keys on vertical movement, and the
  /// reason [minVerticalShare] cannot simply be set as high as the tidy
  /// fixtures would allow. The arm swings once per *stride* — that is, once per
  /// two steps — so this adds a large horizontal component at half the step
  /// frequency, on top of the same vertical gait signal as [walk].
  ///
  /// It is still genuine walking and must still be counted in full.
  static List<SensorSample> walkWithArmSwing({
    required int steps,
    double stepFrequencyHz = 1.8,
    double amplitude = 2.0,
    double swingAmplitude = 3.0,
    double sampleRateHz = 50,
    double leadInSeconds = 3.0,
    int seed = 57,
  }) {
    final rnd = math.Random(seed);
    final dt = 1 / sampleRateHz;
    final walkDuration = steps / stepFrequencyHz;
    final n = ((leadInSeconds + walkDuration + 2.0) * sampleRateHz).round();

    final out = <SensorSample>[];
    for (var i = 0; i < n; i++) {
      final t = i * dt;
      final walking = t >= leadInSeconds && t < leadInSeconds + walkDuration;
      final tw = t - leadInSeconds;

      var az = 9.81;
      var swing = 0.0;
      var gyro = 0.0;
      if (walking) {
        final phase = 2 * math.pi * stepFrequencyHz * tw;
        az += amplitude * math.sin(phase) + 0.35 * amplitude * math.sin(2 * phase + 0.7);
        // Half the step frequency: one arm swing per stride.
        swing = swingAmplitude * math.sin(phase / 2);
        gyro = 1.4 * math.sin(phase / 2 + 0.2);
      }

      out.add(SensorSample(
        tNs: (t * 1e9).round(),
        ax: swing + _n(rnd, 0.08),
        ay: 0.4 * swing + _n(rnd, 0.08),
        az: az + _n(rnd, 0.08),
        gx: gyro + _n(rnd, 0.04),
        gy: 0.5 * gyro + _n(rnd, 0.04),
        gz: _n(rnd, 0.04),
        hasGyro: true,
      ));
    }
    return out;
  }

  /// Concatenates fixtures onto one continuous timeline.
  ///
  /// Each fixture is generated from t=0, so appending them naively would send
  /// timestamps backwards and trip the detector's gap reset — which would hide
  /// exactly the transition a walk-then-jiggle test exists to exercise.
  static List<SensorSample> concat(
    List<List<SensorSample>> parts, {
    double sampleRateHz = 50,
  }) {
    final dtNs = (1e9 / sampleRateHz).round();
    final out = <SensorSample>[];
    var tNs = 0;
    for (final part in parts) {
      for (final s in part) {
        out.add(SensorSample(
          tNs: tNs,
          ax: s.ax, ay: s.ay, az: s.az,
          gx: s.gx, gy: s.gy, gz: s.gz,
          hasGyro: s.hasGyro,
        ));
        tNs += dtNs;
      }
    }
    return out;
  }

  static double _n(math.Random r, double sigma) =>
      sigma == 0 ? 0 : (r.nextDouble() * 2 - 1) * sigma;
}
