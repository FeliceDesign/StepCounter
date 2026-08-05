package com.felicedesign.stepcounter

import kotlin.math.abs
import kotlin.math.pow
import kotlin.math.sqrt

/**
 * Activity identifiers. Must match Activity.id in lib/detection/activity.dart —
 * these strings are written into the database and read back by Dart.
 */
object ActivityId {
    const val UNKNOWN = "unknown"
    const val STILL = "still"
    const val WALKING = "walking"
    const val RUNNING = "running"
    const val STAIRS_UP = "stairs_up"
    const val STAIRS_DOWN = "stairs_down"
    const val VEHICLE = "vehicle"

    fun countsSteps(id: String): Boolean =
        id == WALKING || id == RUNNING || id == STAIRS_UP || id == STAIRS_DOWN
}

/** Mirrors ActivityParams in lib/detection/activity.dart. */
data class ActivityParams(
    val stillAccelSigmaMax: Double = 0.15,
    val vehicleGyroMax: Double = 0.03,
    val runningCadenceMin: Double = 140.0,
    val runningFlightMax: Double = 5.0,
    val runningAmplitudeMin: Double = 8.0,
    val stairsAltitudeRateMin: Double = 0.08,
    val stairsMinDurationMs: Int = 2500,
) {
    fun clamped() = ActivityParams(
        stillAccelSigmaMax = stillAccelSigmaMax.coerceIn(0.02, 0.6),
        vehicleGyroMax = vehicleGyroMax.coerceIn(0.005, 0.15),
        runningCadenceMin = runningCadenceMin.coerceIn(110.0, 190.0),
        runningFlightMax = runningFlightMax.coerceIn(1.0, 8.0),
        runningAmplitudeMin = runningAmplitudeMin.coerceIn(3.0, 20.0),
        stairsAltitudeRateMin = stairsAltitudeRateMin.coerceIn(0.03, 0.30),
        stairsMinDurationMs = stairsMinDurationMs.coerceIn(1000, 6000),
    )

    companion object {
        val FACTORY = ActivityParams()

        fun fromMap(m: Map<*, *>): ActivityParams = ActivityParams(
            stillAccelSigmaMax = num(m["stillAccelSigmaMax"], FACTORY.stillAccelSigmaMax),
            vehicleGyroMax = num(m["vehicleGyroMax"], FACTORY.vehicleGyroMax),
            runningCadenceMin = num(m["runningCadenceMin"], FACTORY.runningCadenceMin),
            runningFlightMax = num(m["runningFlightMax"], FACTORY.runningFlightMax),
            runningAmplitudeMin = num(m["runningAmplitudeMin"], FACTORY.runningAmplitudeMin),
            stairsAltitudeRateMin =
                num(m["stairsAltitudeRateMin"], FACTORY.stairsAltitudeRateMin),
            stairsMinDurationMs =
                num(m["stairsMinDurationMs"], FACTORY.stairsMinDurationMs.toDouble()).toInt(),
        ).clamped()

        private fun num(v: Any?, fallback: Double): Double =
            (v as? Number)?.toDouble() ?: fallback
    }
}

/**
 * Behavioural mirror of lib/detection/activity_classifier.dart.
 *
 * Pinned to the Dart implementation by the shared golden fixtures — see
 * Detection.kt for why that matters.
 */
class ActivityClassifierNative(
    initialParams: ActivityParams = ActivityParams.FACTORY,
) {
    var params: ActivityParams = initialParams.clamped()
        set(value) {
            field = value.clamped()
            reset()
        }

    private val filteredStats = RollingStats(WINDOW_SAMPLES)
    private val gyroStats = RollingStats(WINDOW_SAMPLES)

    private val rawRing = DoubleArray(WINDOW_SAMPLES) { 9.81 }
    private var rawHead = 0
    private var rawCount = 0

    private val filteredRing = DoubleArray(WINDOW_SAMPLES)
    private var filteredHead = 0
    private var filteredCount = 0

    private val pressureT = ArrayList<Double>()
    private val pressureAlt = ArrayList<Double>()
    private var hasBarometer = false
    private var altitudeRate = 0.0

    private val stepTimes = ArrayList<Long>()
    private var lastStepNs: Long? = null
    private var lastSampleNs: Long? = null

    private var stairsSinceNs: Long? = null
    private var candidate: String? = null
    private var candidateSinceNs: Long? = null
    private var samplesSinceClassify = 0

    var current: String = ActivityId.UNKNOWN
        private set

    fun reset() {
        filteredStats.reset()
        gyroStats.reset()
        rawRing.fill(9.81)
        rawHead = 0
        rawCount = 0
        filteredRing.fill(0.0)
        filteredHead = 0
        filteredCount = 0
        pressureT.clear()
        pressureAlt.clear()
        altitudeRate = 0.0
        stepTimes.clear()
        lastStepNs = null
        lastSampleNs = null
        stairsSinceNs = null
        current = ActivityId.UNKNOWN
        candidate = null
        candidateSinceNs = null
        samplesSinceClassify = 0
    }

    fun addPressure(tNs: Long, hPa: Double) {
        if (hPa <= 0) return
        hasBarometer = true
        pressureT.add(tNs / 1e9)
        pressureAlt.add(altitudeFromPressure(hPa))

        val cutoff = tNs / 1e9 - PRESSURE_WINDOW_SECONDS
        while (pressureT.size > 2 && pressureT[0] < cutoff) {
            pressureT.removeAt(0)
            pressureAlt.removeAt(0)
        }
        altitudeRate = slope()
    }

    private fun slope(): Double {
        val n = pressureT.size
        if (n < 4) return 0.0
        var sumT = 0.0
        var sumA = 0.0
        for (i in 0 until n) {
            sumT += pressureT[i]
            sumA += pressureAlt[i]
        }
        val meanT = sumT / n
        val meanA = sumA / n
        var num = 0.0
        var den = 0.0
        for (i in 0 until n) {
            val dt = pressureT[i] - meanT
            num += dt * (pressureAlt[i] - meanA)
            den += dt * dt
        }
        return if (den <= 0) 0.0 else num / den
    }

    fun update(
        tNs: Long,
        rawMagnitude: Double,
        filteredMagnitude: Double,
        gyroMagnitude: Double,
        hasGyro: Boolean,
        stepsEmitted: Int,
    ): String {
        lastSampleNs?.let { prev ->
            val gapMs = (tNs - prev) / 1e6
            if (gapMs > MAX_GAP_MS || gapMs < 0) reset()
        }
        lastSampleNs = tNs

        filteredStats.add(filteredMagnitude)
        if (hasGyro) gyroStats.add(gyroMagnitude)

        rawRing[rawHead] = rawMagnitude
        rawHead = (rawHead + 1) % rawRing.size
        if (rawCount < rawRing.size) rawCount++

        filteredRing[filteredHead] = filteredMagnitude
        filteredHead = (filteredHead + 1) % filteredRing.size
        if (filteredCount < filteredRing.size) filteredCount++

        if (stepsEmitted > 0) {
            lastStepNs = tNs
            repeat(stepsEmitted) { stepTimes.add(tNs) }
            while (stepTimes.size > 12) stepTimes.removeAt(0)
        }

        samplesSinceClassify++
        if (stepsEmitted > 0 || samplesSinceClassify >= 10) {
            samplesSinceClassify = 0
            applyLabel(classify(tNs, hasGyro), tNs)
        }
        return current
    }

    private fun classify(tNs: Long, hasGyro: Boolean): String {
        val lastStep = lastStepNs
        val stepping = lastStep != null && (tNs - lastStep) / 1e6 <= STEP_RECENCY_MS

        if (stepping) {
            stairsLabel(tNs)?.let { return it }
            return if (isRunning()) ActivityId.RUNNING else ActivityId.WALKING
        }

        stairsSinceNs = null

        if (filteredStats.stdDev() < params.stillAccelSigmaMax) return ActivityId.STILL
        if (hasGyro && gyroStats.mean() < params.vehicleGyroMax) return ActivityId.VEHICLE
        return ActivityId.UNKNOWN
    }

    private fun stairsLabel(tNs: Long): String? {
        if (!hasBarometer) return null
        if (abs(altitudeRate) < params.stairsAltitudeRateMin) {
            stairsSinceNs = null
            return null
        }
        val since = stairsSinceNs ?: tNs.also { stairsSinceNs = it }
        if ((tNs - since) / 1e6 < params.stairsMinDurationMs) return null
        return if (altitudeRate > 0) ActivityId.STAIRS_UP else ActivityId.STAIRS_DOWN
    }

    private fun isRunning(): Boolean {
        if (cadence() < params.runningCadenceMin) return false
        return minRawMagnitude() < params.runningFlightMax ||
            amplitude() >= params.runningAmplitudeMin
    }

    private fun applyLabel(next: String, tNs: Long) {
        if (next == current) {
            candidate = null
            candidateSinceNs = null
            return
        }
        if (ActivityId.countsSteps(next) && !ActivityId.countsSteps(current)) {
            current = next
            candidate = null
            candidateSinceNs = null
            return
        }
        if (candidate != next) {
            candidate = next
            candidateSinceNs = tNs
            return
        }
        if ((tNs - candidateSinceNs!!) / 1e6 >= SWITCH_CONFIRM_MS) {
            current = next
            candidate = null
            candidateSinceNs = null
        }
    }

    fun cadence(): Double {
        if (stepTimes.size < 2) return 0.0
        val span = (stepTimes.last() - stepTimes.first()) / 1e9
        if (span <= 0) return 0.0
        return (stepTimes.size - 1) / span * 60.0
    }

    fun minRawMagnitude(): Double {
        if (rawCount == 0) return 9.81
        var m = Double.MAX_VALUE
        for (i in 0 until rawCount) if (rawRing[i] < m) m = rawRing[i]
        return m
    }

    fun amplitude(): Double {
        if (filteredCount == 0) return 0.0
        var lo = Double.MAX_VALUE
        var hi = -Double.MAX_VALUE
        for (i in 0 until filteredCount) {
            val v = filteredRing[i]
            if (v < lo) lo = v
            if (v > hi) hi = v
        }
        return hi - lo
    }

    fun debugSnapshot(): Map<String, Any?> = mapOf(
        "activity" to current,
        "cadence" to cadence(),
        "accelSigma" to filteredStats.stdDev(),
        "amplitude" to amplitude(),
        "minRawMagnitude" to minRawMagnitude(),
        "altitudeRate" to altitudeRate,
        "hasBarometer" to hasBarometer,
    )

    companion object {
        const val SAMPLE_RATE_HZ = 50.0
        const val WINDOW_SECONDS = 3.0
        const val PRESSURE_WINDOW_SECONDS = 6.0
        const val SWITCH_CONFIRM_MS = 1000
        const val STEP_RECENCY_MS = 3000
        const val MAX_GAP_MS = 200

        val WINDOW_SAMPLES = Math.round(SAMPLE_RATE_HZ * WINDOW_SECONDS).toInt()

        /** Absolute value is meaningless without a local reference; only differences are used. */
        fun altitudeFromPressure(hPa: Double): Double =
            44330.0 * (1 - (hPa / 1013.25).pow(0.1903))
    }
}

/** Shared helper so the service and classifier agree on magnitude. */
fun magnitude(x: Double, y: Double, z: Double): Double = sqrt(x * x + y * y + z * z)
