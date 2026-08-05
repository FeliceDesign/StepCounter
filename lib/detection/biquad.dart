import 'dart:math' as math;

/// A single second-order IIR section, Direct Form II transposed.
///
/// Coefficients follow the Robert Bristow-Johnson audio EQ cookbook, which is
/// the standard formulation for these filters. With Q = 1/sqrt(2) a single
/// section is a 2nd-order Butterworth response (maximally flat passband), which
/// is what we want for gait: no ripple that would distort peak amplitudes, since
/// amplitude is exactly what the detector thresholds on.
class Biquad {
  Biquad._(this._b0, this._b1, this._b2, this._a1, this._a2);

  final double _b0, _b1, _b2, _a1, _a2;
  double _z1 = 0, _z2 = 0;

  static const double _butterworthQ = math.sqrt1_2;

  factory Biquad.lowPass(double cutoffHz, double sampleRateHz, {double q = _butterworthQ}) {
    final w0 = 2 * math.pi * cutoffHz / sampleRateHz;
    final cosW0 = math.cos(w0);
    final alpha = math.sin(w0) / (2 * q);

    final a0 = 1 + alpha;
    return Biquad._(
      ((1 - cosW0) / 2) / a0,
      (1 - cosW0) / a0,
      ((1 - cosW0) / 2) / a0,
      (-2 * cosW0) / a0,
      (1 - alpha) / a0,
    );
  }

  factory Biquad.highPass(double cutoffHz, double sampleRateHz, {double q = _butterworthQ}) {
    final w0 = 2 * math.pi * cutoffHz / sampleRateHz;
    final cosW0 = math.cos(w0);
    final alpha = math.sin(w0) / (2 * q);

    final a0 = 1 + alpha;
    return Biquad._(
      ((1 + cosW0) / 2) / a0,
      (-(1 + cosW0)) / a0,
      ((1 + cosW0) / 2) / a0,
      (-2 * cosW0) / a0,
      (1 - alpha) / a0,
    );
  }

  double process(double x) {
    final y = _b0 * x + _z1;
    _z1 = _b1 * x - _a1 * y + _z2;
    _z2 = _b2 * x - _a2 * y;
    return y;
  }

  void reset() {
    _z1 = 0;
    _z2 = 0;
  }
}

/// Band-pass built as a high-pass then a low-pass in cascade.
///
/// The high-pass removes the ~9.81 m/s² gravity DC term (and any slow drift from
/// changing device orientation); the low-pass removes handling noise and the
/// high-frequency content of footfall impact shock. What survives is the gait
/// fundamental, roughly 0.5–3 Hz.
class BandPass {
  BandPass({
    required double lowHz,
    required double highHz,
    required double sampleRateHz,
  })  : _hp = Biquad.highPass(lowHz, sampleRateHz),
        _lp = Biquad.lowPass(highHz, sampleRateHz);

  final Biquad _hp;
  final Biquad _lp;

  double process(double x) => _lp.process(_hp.process(x));

  void reset() {
    _hp.reset();
    _lp.reset();
  }
}

/// Fixed-window mean and standard deviation in O(1) per sample.
///
/// Running sums drift over millions of samples, so the accumulators are rebuilt
/// from the ring periodically. A step counter runs for weeks at 50 Hz, which is
/// well past where naive incremental sums start to visibly lose precision.
class RollingStats {
  RollingStats(this.size) : _buf = List<double>.filled(size, 0);

  final int size;
  final List<double> _buf;
  int _head = 0;
  int _count = 0;
  double _sum = 0;
  double _sumSq = 0;
  int _sinceRebuild = 0;

  static const int _rebuildEvery = 5000;

  void add(double v) {
    if (_count == size) {
      final old = _buf[_head];
      _sum -= old;
      _sumSq -= old * old;
    } else {
      _count++;
    }
    _buf[_head] = v;
    _sum += v;
    _sumSq += v * v;
    _head = (_head + 1) % size;

    if (++_sinceRebuild >= _rebuildEvery) {
      _rebuild();
    }
  }

  void _rebuild() {
    _sinceRebuild = 0;
    var s = 0.0, sq = 0.0;
    for (var i = 0; i < _count; i++) {
      final v = _buf[i];
      s += v;
      sq += v * v;
    }
    _sum = s;
    _sumSq = sq;
  }

  bool get isFull => _count == size;
  int get count => _count;

  double get mean => _count == 0 ? 0 : _sum / _count;

  double get stdDev {
    if (_count < 2) return 0;
    final m = mean;
    final variance = (_sumSq / _count) - (m * m);
    return variance <= 0 ? 0 : math.sqrt(variance);
  }

  void reset() {
    _head = 0;
    _count = 0;
    _sum = 0;
    _sumSq = 0;
    _sinceRebuild = 0;
    _buf.fillRange(0, size, 0);
  }
}
