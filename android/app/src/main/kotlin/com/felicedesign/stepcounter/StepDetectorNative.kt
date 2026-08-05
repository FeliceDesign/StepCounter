package com.felicedesign.stepcounter

import kotlin.math.sqrt

/**
 * Streaming step detector. Behavioural mirror of lib/detection/step_detector.dart.
 *
 * Kotlin owns the live counting path because it has to keep running with the
 * screen off and the app swiped away, which a Dart isolate cannot do reliably.
 * Dart owns the replay path used by calibration. See Detection.kt for how the
 * two are kept in agreement.
 */
class StepDetectorNative(
    params: CalibrationParams = CalibrationParams.FACTORY,
    private val sampleRateHz: Double = 50.0,
) {
    var params: CalibrationParams = params.clamped()
        set(value) {
            field = value.clamped()
            reset()
        }

    private val accelBand = BandPass(BAND_LOW_HZ, BAND_HIGH_HZ, sampleRateHz)
    private val stats = RollingStats((sampleRateHz * STATS_WINDOW_SECONDS).toInt())
    private val gyroStats = RollingStats((sampleRateHz * STATS_WINDOW_SECONDS).toInt())

    private val smoothBuf = ArrayDeque<Double>()
    private var smoothSum = 0.0

    private var v0: Double? = null
    private var v1: Double? = null
    private var v2: Double? = null
    private var t1: Long? = null

    private var lastValleyValue: Double? = null
    private var lastCandidateNs: Long? = null
    private var cadenceMs: Double? = null

    private val pending = ArrayList<Long>()
    private var inConfirmedRun = false
    private var lastSampleNs: Long? = null

    var totalSteps: Int = 0
        private set

    private val warmupSamples: Int get() = (sampleRateHz * WARMUP_SECONDS).toInt()

    fun reset() {
        accelBand.reset()
        stats.reset()
        gyroStats.reset()
        smoothBuf.clear()
        smoothSum = 0.0
        v0 = null; v1 = null; v2 = null
        t1 = null
        lastValleyValue = null
        lastCandidateNs = null
        cadenceMs = null
        pending.clear()
        inConfirmedRun = false
        lastSampleNs = null
    }

    fun resetCount() {
        totalSteps = 0
    }

    /** Returns the hardware timestamps of any steps confirmed by this sample. */
    fun addSample(
        tNs: Long,
        ax: Double, ay: Double, az: Double,
        gx: Double, gy: Double, gz: Double,
        hasGyro: Boolean,
    ): List<Long> {
        lastSampleNs?.let { prev ->
            val gapMs = (tNs - prev) / 1e6
            if (gapMs > MAX_GAP_MS || gapMs < 0) reset()
        }
        lastSampleNs = tNs

        val filtered = accelBand.process(sqrt(ax * ax + ay * ay + az * az))

        // Raw magnitude level, not band-passed - see the Dart implementation for
        // why band-passing the gyroscope breaks faster gaits.
        if (hasGyro) gyroStats.add(sqrt(gx * gx + gy * gy + gz * gz))

        smoothBuf.addLast(filtered)
        smoothSum += filtered
        if (smoothBuf.size > SMOOTHING_SAMPLES) smoothSum -= smoothBuf.removeFirst()
        val smoothed = smoothSum / smoothBuf.size

        stats.add(smoothed)

        v0 = v1
        v1 = v2
        v2 = smoothed
        val tPrev = t1
        t1 = tNs

        val a = v0 ?: return emptyList()
        val b = v1 ?: return emptyList()
        val c = v2 ?: return emptyList()
        if (tPrev == null) return emptyList()

        if (b < a && b <= c) {
            lastValleyValue = b
            return emptyList()
        }
        if (!(b > a && b >= c)) return emptyList()
        if (stats.count < warmupSamples) return emptyList()

        return evaluatePeak(b, tPrev, hasGyro)
    }

    private fun evaluatePeak(peakValue: Double, peakNs: Long, hasGyro: Boolean): List<Long> {
        val threshold = stats.mean() + params.thresholdSigma * stats.stdDev()
        if (peakValue <= threshold) return emptyList()

        val valley = lastValleyValue ?: return emptyList()
        if (peakValue - valley < params.minAmplitude) return emptyList()

        if (hasGyro && gyroStats.count >= warmupSamples) {
            val gs = gyroStats.mean()
            if (gs < params.gyroMinLevel || gs > params.gyroMaxLevel) {
                breakStreak()
                return emptyList()
            }
        }

        val last = lastCandidateNs ?: return acceptCandidate(peakNs, null)

        val dtMs = (peakNs - last) / 1e6
        if (dtMs < params.minStepIntervalMs) return emptyList()

        val cadence = cadenceMs
        val offRhythm = cadence != null && (dtMs < 0.5 * cadence || dtMs > 2.0 * cadence)
        if (dtMs > params.maxStepIntervalMs || offRhythm) {
            breakStreak()
            return acceptCandidate(peakNs, null)
        }

        return acceptCandidate(peakNs, dtMs)
    }

    private fun acceptCandidate(peakNs: Long, dtMs: Double?): List<Long> {
        lastCandidateNs = peakNs
        if (dtMs != null) {
            val c = cadenceMs
            cadenceMs = if (c == null) dtMs else 0.7 * c + 0.3 * dtMs
        }

        if (inConfirmedRun) {
            totalSteps++
            return listOf(peakNs)
        }

        pending.add(peakNs)
        if (pending.size >= params.regularityRunLength) {
            val released = ArrayList(pending)
            pending.clear()
            inConfirmedRun = true
            totalSteps += released.size
            return released
        }
        return emptyList()
    }

    private fun breakStreak() {
        pending.clear()
        inConfirmedRun = false
        cadenceMs = null
    }

    fun debugSnapshot(): Map<String, Any?> = mapOf(
        "threshold" to stats.mean() + params.thresholdSigma * stats.stdDev(),
        "sigma" to stats.stdDev(),
        "gyroLevel" to gyroStats.mean(),
        "cadenceMs" to cadenceMs,
        "pendingCandidates" to pending.size,
        "inConfirmedRun" to inConfirmedRun,
        "warmedUp" to (stats.count >= warmupSamples),
    )

    companion object {
        const val BAND_LOW_HZ = 0.5
        const val BAND_HIGH_HZ = 3.0
        const val STATS_WINDOW_SECONDS = 2.5
        const val WARMUP_SECONDS = 0.5
        const val SMOOTHING_SAMPLES = 5
        const val MAX_GAP_MS = 200
    }
}
