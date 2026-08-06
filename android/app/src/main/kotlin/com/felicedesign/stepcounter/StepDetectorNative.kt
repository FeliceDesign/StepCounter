package com.felicedesign.stepcounter

import kotlin.math.abs
import kotlin.math.max
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

    // Acceleration resolved along, and across, the estimated gravity direction.
    private val verticalStats = RollingStats((sampleRateHz * STATS_WINDOW_SECONDS).toInt())
    private val horizontalStats = RollingStats((sampleRateHz * STATS_WINDOW_SECONDS).toInt())

    private var gvx = 0.0
    private var gvy = 0.0
    private var gvz = 0.0
    private var hasGravity = false

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

    // Recent accepted step intervals: the run's quality, re-judged on every
    // candidate. See runIsRhythmic().
    private val recentIntervalsMs = ArrayList<Double>()

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
        verticalStats.reset()
        horizontalStats.reset()
        gvx = 0.0; gvy = 0.0; gvz = 0.0
        hasGravity = false
        recentIntervalsMs.clear()
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

        // Gravity estimate, and the split of acceleration along versus across
        // it. The one place the detector looks at direction rather than at the
        // orientation-free magnitude - see the Dart implementation for why
        // that is what separates walking from a hand fidgeting with the phone.
        if (hasGravity) {
            gvx += GRAVITY_ALPHA * (ax - gvx)
            gvy += GRAVITY_ALPHA * (ay - gvy)
            gvz += GRAVITY_ALPHA * (az - gvz)
        } else {
            gvx = ax; gvy = ay; gvz = az
            hasGravity = true
        }
        val gMag = sqrt(gvx * gvx + gvy * gvy + gvz * gvz)
        if (gMag > 0) {
            val ux = gvx / gMag
            val uy = gvy / gMag
            val uz = gvz / gMag
            val along = ax * ux + ay * uy + az * uz
            val hx = ax - ux * along
            val hy = ay - uy * along
            val hz = az - uz * along
            verticalStats.add(along)
            horizontalStats.add(sqrt(hx * hx + hy * hy + hz * hz))
        }

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

        // Vertical share, placed directly after the motion floor: it too asks
        // whether this is the right *kind* of movement, before any question of
        // how big or how well timed it is.
        if (gravityTrusted() && verticalStats.count >= warmupSamples) {
            if (verticalShare() < params.minVerticalShare) {
                breakStreak()
                return emptyList()
            }
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
        val tolerance = params.offRhythmTolerance
        val offRhythm = cadence != null &&
            (dtMs < (1 - tolerance) * cadence || dtMs > (1 + tolerance) * cadence)
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

            recentIntervalsMs.add(dtMs)
            val cap = max(params.regularityRunLength - 1, RHYTHM_WINDOW_INTERVALS)
            while (recentIntervalsMs.size > cap) recentIntervalsMs.removeAt(0)
        }

        val rhythmic = runIsRhythmic()

        // A confirmed run is re-examined on every candidate, which is the whole
        // point. The previous version latched inConfirmedRun true after
        // regularityRunLength candidates and never looked again.
        if (inConfirmedRun) {
            if (rhythmic) {
                totalSteps++
                return listOf(peakNs)
            }
            // Fall back out of the run. Steps already counted are never
            // retracted: a number that goes backwards is worse than one that
            // is slightly too high.
            inConfirmedRun = false
            pending.clear()
            pending.add(peakNs)
            return emptyList()
        }

        pending.add(peakNs)
        if (pending.size >= params.regularityRunLength && rhythmic) {
            val released = ArrayList(pending)
            pending.clear()
            inConfirmedRun = true
            totalSteps += released.size
            return released
        }
        return emptyList()
    }

    /**
     * Whether the recent intervals look like walking rather than like motion
     * that merely happens to be repetitive.
     *
     * At the minimum legal regularityRunLength of 2 there is only ever one
     * interval, a coefficient of variation over which is meaningless, so the
     * gate stands aside and regularityRunLength alone governs.
     */
    private fun runIsRhythmic(): Boolean {
        val needed = params.regularityRunLength - 1
        if (recentIntervalsMs.size < needed) return false
        if (recentIntervalsMs.size < 2) return true
        return intervalCv(recentIntervalsMs) <= params.maxIntervalCv
    }

    /**
     * Coefficient of variation, computed in two passes.
     *
     * Two passes rather than RollingStats' sqrt(E[x^2] - mean^2) shortcut: this
     * buffer holds at most eight elements so the cost is irrelevant, and the
     * shortcut can produce a small negative variance from floating-point
     * cancellation when the intervals are nearly identical - which is precisely
     * the case for real walking. Dart and Kotlin must agree here to the last
     * bit or the goldens diverge.
     */
    private fun intervalCv(xs: List<Double>): Double {
        if (xs.size < 2) return 0.0
        var sum = 0.0
        for (x in xs) sum += x
        val mean = sum / xs.size
        if (mean <= 0) return 0.0
        var sq = 0.0
        for (x in xs) {
            val d = x - mean
            sq += d * d
        }
        return sqrt(sq / xs.size) / mean
    }

    /** Whether the gravity estimate currently looks like gravity. */
    private fun gravityTrusted(): Boolean {
        if (!hasGravity) return false
        val m = sqrt(gvx * gvx + gvy * gvy + gvz * gvz)
        return m >= GRAVITY_MIN && m <= GRAVITY_MAX
    }

    /**
     * Fraction of recent movement lying along gravity rather than across it.
     * Ratio of standard deviations, because the vertical channel carries
     * gravity itself as a large constant offset that says nothing about
     * movement.
     */
    fun verticalShare(): Double {
        val v = verticalStats.stdDev()
        val h = horizontalStats.stdDev()
        val total = v + h
        return if (total <= 0) 0.0 else v / total
    }

    private fun breakStreak() {
        pending.clear()
        inConfirmedRun = false
        cadenceMs = null
        recentIntervalsMs.clear()
    }

    fun debugSnapshot(): Map<String, Any?> = mapOf(
        "threshold" to stats.mean() + params.thresholdSigma * stats.stdDev(),
        "sigma" to stats.stdDev(),
        "gyroLevel" to gyroStats.mean(),
        "cadenceMs" to cadenceMs,
        "pendingCandidates" to pending.size,
        "inConfirmedRun" to inConfirmedRun,
        "warmedUp" to (stats.count >= warmupSamples),
        "intervalCv" to intervalCv(recentIntervalsMs),
        "verticalShare" to if (gravityTrusted()) verticalShare() else null,
    )

    companion object {
        const val BAND_LOW_HZ = 0.5
        const val BAND_HIGH_HZ = 3.0
        const val STATS_WINDOW_SECONDS = 2.5
        const val WARMUP_SECONDS = 0.5
        const val SMOOTHING_SAMPLES = 5
        const val MAX_GAP_MS = 200

        /**
         * How many recent intervals the coefficient-of-variation gate judges.
         * Deliberately larger than regularityRunLength - 1, and deliberately
         * not tunable: how soon counting may start and how much evidence
         * "still walking" requires are different questions.
         */
        const val RHYTHM_WINDOW_INTERVALS = 8

        /**
         * Single-pole gravity estimate smoothing, per sample. A literal, never
         * derived from sampleRateHz - a constant computed from the sample rate
         * is exactly what the two ports would round differently and drift
         * apart on. ~0.24 Hz at the 50 Hz both ports run at.
         */
        const val GRAVITY_ALPHA = 0.03
        const val GRAVITY_MIN = 8.0
        const val GRAVITY_MAX = 11.5
    }
}
