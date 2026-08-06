package com.felicedesign.stepcounter

import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Signal-processing primitives, ported from lib/detection/biquad.dart.
 *
 * This file and StepDetectorNative.kt must stay behaviourally identical to
 * their Dart counterparts: Kotlin counts steps live in the foreground service,
 * while Dart replays recorded sessions during calibration. If the two drift,
 * the before/after numbers shown to the user stop describing the detector that
 * actually counts their steps.
 *
 * That equivalence is enforced by golden fixtures in src/test/resources, which
 * both DetectionGoldenTest (JVM) and test/golden_fixtures_test.dart assert
 * against. Change either implementation and the goldens will catch it.
 */
class Biquad private constructor(
    private val b0: Double,
    private val b1: Double,
    private val b2: Double,
    private val a1: Double,
    private val a2: Double,
) {
    private var z1 = 0.0
    private var z2 = 0.0

    fun process(x: Double): Double {
        val y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    fun reset() {
        z1 = 0.0
        z2 = 0.0
    }

    companion object {
        private val BUTTERWORTH_Q = 1.0 / sqrt(2.0)

        fun lowPass(cutoffHz: Double, sampleRateHz: Double, q: Double = BUTTERWORTH_Q): Biquad {
            val w0 = 2 * Math.PI * cutoffHz / sampleRateHz
            val cosW0 = cos(w0)
            val alpha = sin(w0) / (2 * q)
            val a0 = 1 + alpha
            return Biquad(
                ((1 - cosW0) / 2) / a0,
                (1 - cosW0) / a0,
                ((1 - cosW0) / 2) / a0,
                (-2 * cosW0) / a0,
                (1 - alpha) / a0,
            )
        }

        fun highPass(cutoffHz: Double, sampleRateHz: Double, q: Double = BUTTERWORTH_Q): Biquad {
            val w0 = 2 * Math.PI * cutoffHz / sampleRateHz
            val cosW0 = cos(w0)
            val alpha = sin(w0) / (2 * q)
            val a0 = 1 + alpha
            return Biquad(
                ((1 + cosW0) / 2) / a0,
                (-(1 + cosW0)) / a0,
                ((1 + cosW0) / 2) / a0,
                (-2 * cosW0) / a0,
                (1 - alpha) / a0,
            )
        }
    }
}

class BandPass(lowHz: Double, highHz: Double, sampleRateHz: Double) {
    private val hp = Biquad.highPass(lowHz, sampleRateHz)
    private val lp = Biquad.lowPass(highHz, sampleRateHz)

    fun process(x: Double): Double = lp.process(hp.process(x))

    fun reset() {
        hp.reset()
        lp.reset()
    }
}

/** Fixed-window mean and standard deviation in O(1) per sample. */
class RollingStats(private val size: Int) {
    private val buf = DoubleArray(size)
    private var head = 0
    private var _count = 0
    private var sum = 0.0
    private var sumSq = 0.0
    private var sinceRebuild = 0

    val count: Int get() = _count

    fun add(v: Double) {
        if (_count == size) {
            val old = buf[head]
            sum -= old
            sumSq -= old * old
        } else {
            _count++
        }
        buf[head] = v
        sum += v
        sumSq += v * v
        head = (head + 1) % size

        if (++sinceRebuild >= REBUILD_EVERY) rebuild()
    }

    private fun rebuild() {
        sinceRebuild = 0
        var s = 0.0
        var sq = 0.0
        for (i in 0 until _count) {
            val v = buf[i]
            s += v
            sq += v * v
        }
        sum = s
        sumSq = sq
    }

    fun mean(): Double = if (_count == 0) 0.0 else sum / _count

    fun stdDev(): Double {
        if (_count < 2) return 0.0
        val m = mean()
        val variance = (sumSq / _count) - (m * m)
        return if (variance <= 0) 0.0 else sqrt(variance)
    }

    fun reset() {
        head = 0
        _count = 0
        sum = 0.0
        sumSq = 0.0
        sinceRebuild = 0
        buf.fill(0.0)
    }

    private companion object {
        const val REBUILD_EVERY = 5000
    }
}

/** Mirrors lib/detection/calibration_params.dart. */
data class CalibrationParams(
    val thresholdSigma: Double = 0.6,
    val minMotionSigma: Double = 0.35,
    val minAmplitude: Double = 1.0,
    val minStepIntervalMs: Int = 250,
    val maxStepIntervalMs: Int = 2000,
    val regularityRunLength: Int = 4,
    val offRhythmTolerance: Double = 0.35,
    val maxIntervalCv: Double = 0.15,
    val minVerticalShare: Double = 0.45,
    val gyroMinLevel: Double = 0.03,
    val gyroMaxLevel: Double = 5.0,
) {
    fun clamped() = CalibrationParams(
        thresholdSigma = thresholdSigma.coerceIn(0.2, 2.0),
        minMotionSigma = minMotionSigma.coerceIn(0.05, 1.5),
        minAmplitude = minAmplitude.coerceIn(0.1, 4.0),
        minStepIntervalMs = minStepIntervalMs.coerceIn(180, 400),
        maxStepIntervalMs = maxStepIntervalMs.coerceIn(1000, 2500),
        regularityRunLength = regularityRunLength.coerceIn(2, 8),
        offRhythmTolerance = offRhythmTolerance.coerceIn(0.15, 1.0),
        maxIntervalCv = maxIntervalCv.coerceIn(0.08, 1.0),
        minVerticalShare = minVerticalShare.coerceIn(0.0, 0.9),
        gyroMinLevel = gyroMinLevel.coerceIn(0.0, 0.5),
        gyroMaxLevel = gyroMaxLevel.coerceIn(1.0, 8.0),
    )

    fun toMap(): Map<String, Any> = mapOf(
        "thresholdSigma" to thresholdSigma,
        "minMotionSigma" to minMotionSigma,
        "minAmplitude" to minAmplitude,
        "minStepIntervalMs" to minStepIntervalMs,
        "maxStepIntervalMs" to maxStepIntervalMs,
        "regularityRunLength" to regularityRunLength,
        "offRhythmTolerance" to offRhythmTolerance,
        "maxIntervalCv" to maxIntervalCv,
        "minVerticalShare" to minVerticalShare,
        "gyroMinLevel" to gyroMinLevel,
        "gyroMaxLevel" to gyroMaxLevel,
    )

    companion object {
        val FACTORY = CalibrationParams()

        fun fromMap(m: Map<*, *>): CalibrationParams = CalibrationParams(
            thresholdSigma = num(m["thresholdSigma"], FACTORY.thresholdSigma),
            minMotionSigma = num(m["minMotionSigma"], FACTORY.minMotionSigma),
            minAmplitude = num(m["minAmplitude"], FACTORY.minAmplitude),
            minStepIntervalMs = num(m["minStepIntervalMs"], FACTORY.minStepIntervalMs.toDouble()).toInt(),
            maxStepIntervalMs = num(m["maxStepIntervalMs"], FACTORY.maxStepIntervalMs.toDouble()).toInt(),
            regularityRunLength = num(m["regularityRunLength"], FACTORY.regularityRunLength.toDouble()).toInt(),
            offRhythmTolerance = num(m["offRhythmTolerance"], FACTORY.offRhythmTolerance),
            maxIntervalCv = num(m["maxIntervalCv"], FACTORY.maxIntervalCv),
            minVerticalShare = num(m["minVerticalShare"], FACTORY.minVerticalShare),
            gyroMinLevel = num(m["gyroMinLevel"], FACTORY.gyroMinLevel),
            gyroMaxLevel = num(m["gyroMaxLevel"], FACTORY.gyroMaxLevel),
        ).clamped()

        private fun num(v: Any?, fallback: Double): Double =
            (v as? Number)?.toDouble() ?: fallback
    }
}
