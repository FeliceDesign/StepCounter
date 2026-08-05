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
    initialParams: CalibrationParams = CalibrationParams.FACTORY,
    private val sampleRateHz: Double = 50.0,
) {
    var params: CalibrationParams = initialParams.clamped()
        set(value) {
            field = value.clamped()
            reset()
        }

    private val accelBand = BandPass(BAND_LOW_HZ, BAND_HIGH_HZ, sampleRateHz)
    private val stats = RollingStats((sampleRateHz * STATS_WINDOW_SECONDS).toInt())
    private val gyroStats = RollingStats((sampleRateHz * STATS_WINDOW_SECONDS).toInt())

    // Plain ring buffer rather than ArrayDeque: this runs on every sensor
    // sample, and it avoids the boxing a Deque<Double> would do fifty times a
    // second for the lifetime of the service.
    private val smoothBuf = DoubleArray(SMOOTHING_SAMPLES)
    private var smoothHead = 0
    private var smoothCount = 0
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

    /**
     * Magnitudes from the most recent sample, read by the activity classifier
     * rather than recomputed. It needs the raw value specifically: the flight
     * phase of running is a dip toward freefall that the band-pass removes.
     */
    var lastRawMagnitude: Double = 0.0
        private set

    var lastFilteredMagnitude: Double = 0.0
        private set

    private val warmupSamples: Int get() = (sampleRateHz * WARMUP_SECONDS).toInt()

    fun reset() {
        accelBand.reset()
        stats.reset()
        gyroStats.reset()
        smoothBuf.fill(0.0)
        smoothHead = 0
        smoothCount = 0
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

        val raw = sqrt(ax * ax + ay * ay + az * az)
        val filtered = accelBand.process(raw)
        lastRawMagnitude = raw
        lastFilteredMagnitude = filtered

        // Raw magnitude level, not band-passed - see the Dart implementation for
        // why band-passing the gyroscope breaks faster gaits.
        if (hasGyro) gyroStats.add(sqrt(gx * gx + gy * gy + gz * gz))

        if (smoothCount == SMOOTHING_SAMPLES) {
            smoothSum -= smoothBuf[smoothHead]
        } else {
            smoothCount++
        }
        smoothBuf[smoothHead] = filtered
        smoothSum += filtered
        smoothHead = (smoothHead + 1) % SMOOTHING_SAMPLES
        val smoothed = smoothSum / smoothCount

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
        // Absolute motion floor. The adaptive threshold below scales with the
        // signal, so on a near-still phone it collapses toward zero and fires on
        // desk vibration; no setting of thresholdSigma can prevent that, because
        // it shrinks along with the noise it is meant to reject.
        if (stats.stdDev() < params.minMotionSigma) {
            breakStreak()
            return emptyList()
        }

        val threshold = stats.mean() + params.thresholdSigma * stats.stdDev()
        if (peakValue <= threshold) return emptyList()

        val valley = lastValleyValue ?: return emptyList()
        if (peakValue - valley < params.minAmplitude) return emptyList()

        // Gyro gate. Absent a gyroscope this is skipped rather than failed, so
        // the detector degrades to accelerometer-only instead of counting
        // nothing. Rejects vehicle vibration (acceleration without rotation)
        // and shaking (rotation far beyond anything gait produces).
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
