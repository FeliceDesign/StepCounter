package com.felicedesign.stepcounter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The JVM half of the cross-implementation contract.
 *
 * test/golden_fixtures_test.dart asserts the same expectations against the same
 * files. Kotlin counts steps live in the foreground service while Dart replays
 * recorded sessions during calibration, so if these two implementations drift
 * apart, every before/after number the user is shown describes an algorithm
 * that is not the one counting their steps. These goldens are what makes that
 * drift a build failure instead of a silent wrong answer.
 */
class DetectionGoldenTest {

    private data class Golden(
        val name: String,
        val expected: Int,
        val activity: String?,
        val samples: List<Sample>,
        val pressure: List<Pressure>,
    )

    private data class Sample(val tNs: Long, val accelMag: Double, val gyroMag: Double)

    private data class Pressure(val tNs: Long, val hPa: Double)

    private fun loadPressure(name: String): List<Pressure> {
        val stream = javaClass.classLoader!!.getResourceAsStream("goldens/$name.baro.csv")
            ?: return emptyList()
        val out = ArrayList<Pressure>()
        stream.bufferedReader().forEachLine { raw ->
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("#") || line.startsWith("t_ms")) {
                return@forEachLine
            }
            val p = line.split(",")
            if (p.size >= 2) {
                out.add(Pressure(Math.round(p[0].toDouble() * 1e6), p[1].toDouble()))
            }
        }
        return out
    }

    private fun load(name: String): Golden {
        val stream = javaClass.classLoader!!.getResourceAsStream("goldens/$name.csv")
            ?: error("missing golden resource: goldens/$name.csv")
        var expected = -1
        var activity: String? = null
        val samples = ArrayList<Sample>()

        stream.bufferedReader().forEachLine { raw ->
            val line = raw.trim()
            when {
                line.isEmpty() -> Unit
                line.startsWith("#") -> {
                    Regex("""expected=(\d+)""").find(line)?.let {
                        expected = it.groupValues[1].toInt()
                    }
                    Regex("""activity=(\w+)""").find(line)?.let {
                        activity = it.groupValues[1]
                    }
                }
                line.startsWith("t_ms") -> Unit
                else -> {
                    val p = line.split(",")
                    if (p.size >= 3) {
                        samples.add(
                            Sample(
                                // Rounded, not truncated, to match the Dart
                                // parser exactly. Both sides must turn the same
                                // text into the same integer.
                                tNs = Math.round(p[0].toDouble() * 1e6),
                                accelMag = p[1].toDouble(),
                                gyroMag = p[2].toDouble(),
                            )
                        )
                    }
                }
            }
        }

        require(expected >= 0) { "golden $name has no expected= header" }
        return Golden(name, expected, activity, samples, loadPressure(name))
    }

    /**
     * Replays a golden through the detector and classifier together, returning
     * steps attributed to each activity. Mirrors MotionPipeline.replay in Dart,
     * including merging the barometer track in by timestamp.
     */
    private fun replay(golden: Golden): Map<String, Int> {
        val detector = StepDetectorNative()
        val classifier = ActivityClassifierNative()
        val counts = HashMap<String, Int>()

        var p = 0
        for (s in golden.samples) {
            while (p < golden.pressure.size && golden.pressure[p].tNs <= s.tNs) {
                classifier.addPressure(golden.pressure[p].tNs, golden.pressure[p].hPa)
                p++
            }
            val steps = detector.addSample(
                s.tNs, s.accelMag, 0.0, 0.0, s.gyroMag, 0.0, 0.0, true,
            )
            val activity = classifier.update(
                tNs = s.tNs,
                rawMagnitude = detector.lastRawMagnitude,
                filteredMagnitude = detector.lastFilteredMagnitude,
                gyroMagnitude = s.gyroMag,
                hasGyro = true,
                stepsEmitted = steps.size,
            )
            if (steps.isNotEmpty()) {
                counts[activity] = (counts[activity] ?: 0) + steps.size
            }
        }
        return counts
    }

    private fun checkActivity(name: String) {
        val golden = load(name)
        val counts = replay(golden)
        val total = counts.values.sum()

        assertEquals(
            "Kotlin step count drifted from Dart on golden $name",
            golden.expected,
            total,
        )

        val dominant = counts.maxByOrNull { it.value }?.key
        assertEquals(
            "Kotlin classified golden $name differently from Dart",
            golden.activity,
            dominant,
        )
    }

    /**
     * Magnitudes are replayed on a single axis each. The detector only reads
     * sqrt(x^2+y^2+z^2), so this is exactly equivalent to three-axis input.
     */
    private fun count(golden: Golden): Int {
        val d = StepDetectorNative()
        for (s in golden.samples) {
            d.addSample(
                tNs = s.tNs,
                ax = s.accelMag, ay = 0.0, az = 0.0,
                gx = s.gyroMag, gy = 0.0, gz = 0.0,
                hasGyro = true,
            )
        }
        return d.totalSteps
    }

    private fun check(name: String) {
        val golden = load(name)
        assertTrue("golden $name is empty", golden.samples.isNotEmpty())
        assertEquals(
            "Kotlin detector no longer matches golden $name — it has drifted " +
                "from the Dart implementation used for calibration replay",
            golden.expected,
            count(golden),
        )
    }

    @Test fun walkNormal() = check("walk_normal")
    @Test fun walkSlow() = check("walk_slow")
    @Test fun walkJog() = check("walk_jog")
    @Test fun walkDamped() = check("walk_damped")
    @Test fun rejectVehicle() = check("reject_vehicle")
    @Test fun rejectStill() = check("reject_still")
    @Test fun rejectBursts() = check("reject_bursts")
    @Test fun rejectShaking() = check("reject_shaking")

    @Test fun activityWalk() = checkActivity("act_walk")
    @Test fun activityRun() = checkActivity("act_run")
    @Test fun activityStairsUp() = checkActivity("act_stairs_up")
    @Test fun activityStairsDown() = checkActivity("act_stairs_down")
    @Test fun activityLevelWithBarometer() = checkActivity("act_level_with_baro")

    @Test
    fun withoutABarometerStairsAreNeverClaimed() {
        // Same climbing motion, barometer track withheld. Vertical movement is
        // the only evidence for stairs, so absent it the answer must be walking.
        val golden = load("act_stairs_up").copy(pressure = emptyList())
        val dominant = replay(golden).maxByOrNull { it.value }?.key
        assertEquals(ActivityId.WALKING, dominant)
    }

    @Test
    fun activityParamsAreClampedIntoLegalRange() {
        val wild = ActivityParams(
            stairsAltitudeRateMin = 99.0,
            runningCadenceMin = 1.0,
            stairsMinDurationMs = 999999,
        ).clamped()
        assertEquals(0.30, wild.stairsAltitudeRateMin, 1e-9)
        assertEquals(110.0, wild.runningCadenceMin, 1e-9)
        assertEquals(6000, wild.stairsMinDurationMs)
    }

    @Test
    fun barometricAltitudeMatchesTheDartGradient() {
        val a = ActivityClassifierNative.altitudeFromPressure(1013.25)
        val b = ActivityClassifierNative.altitudeFromPressure(1012.25)
        // ~8.3 m per hPa near sea level; same assertion as the Dart test.
        assertEquals(8.3, b - a, 0.6)
    }

    @Test
    fun rejectionGoldensExpectZero() {
        for (name in listOf("reject_vehicle", "reject_still", "reject_bursts", "reject_shaking")) {
            assertEquals("$name should count nothing", 0, load(name).expected)
        }
    }

    @Test
    fun paramsAreClampedIntoLegalRange() {
        val wild = CalibrationParams(
            thresholdSigma = 99.0,
            minAmplitude = -5.0,
            minStepIntervalMs = 1,
            regularityRunLength = 500,
        ).clamped()
        assertEquals(2.0, wild.thresholdSigma, 1e-9)
        assertEquals(0.1, wild.minAmplitude, 1e-9)
        assertEquals(180, wild.minStepIntervalMs)
        assertEquals(8, wild.regularityRunLength)
    }

    @Test
    fun aGapInTheStreamResetsRatherThanEmittingABurst() {
        val golden = load("walk_normal")
        val d = StepDetectorNative()
        for (s in golden.samples) {
            d.addSample(s.tNs, s.accelMag, 0.0, 0.0, s.gyroMag, 0.0, 0.0, true)
        }
        val before = d.totalSteps
        // A ten-minute jump must not manufacture steps.
        d.addSample(golden.samples.last().tNs + 600_000_000_000L, 9.81, 0.0, 0.0, 0.3, 0.0, 0.0, true)
        assertEquals(before, d.totalSteps)
    }
}
