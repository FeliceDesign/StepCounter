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

    /**
     * One golden row, always as six axes.
     *
     * Magnitude-only fixtures are widened here by placing each magnitude on x,
     * exactly as the Dart parser does. That is lossless for every gate that
     * reads sqrt(x^2+y^2+z^2) - which is all of them except the vertical-share
     * gate, and fixtures that exist to pin that gate store all six axes. See
     * GoldenFixture.parse for the full reasoning.
     */
    private data class Sample(
        val tNs: Long,
        val ax: Double, val ay: Double, val az: Double,
        val gx: Double, val gy: Double, val gz: Double,
    ) {
        val accelMag: Double get() = Math.sqrt(ax * ax + ay * ay + az * az)
        val gyroMag: Double get() = Math.sqrt(gx * gx + gy * gy + gz * gz)
    }

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
                    // Rounded, not truncated, to match the Dart parser exactly.
                    // Both sides must turn the same text into the same integer.
                    if (p.size >= 7) {
                        samples.add(
                            Sample(
                                tNs = Math.round(p[0].toDouble() * 1e6),
                                ax = p[1].toDouble(), ay = p[2].toDouble(), az = p[3].toDouble(),
                                gx = p[4].toDouble(), gy = p[5].toDouble(), gz = p[6].toDouble(),
                            )
                        )
                    } else if (p.size >= 3) {
                        samples.add(
                            Sample(
                                tNs = Math.round(p[0].toDouble() * 1e6),
                                ax = p[1].toDouble(), ay = 0.0, az = 0.0,
                                gx = p[2].toDouble(), gy = 0.0, gz = 0.0,
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
                s.tNs, s.ax, s.ay, s.az, s.gx, s.gy, s.gz, true,
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
                ax = s.ax, ay = s.ay, az = s.az,
                gx = s.gx, gy = s.gy, gz = s.gz,
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

    /**
     * Hand jiggle is the one negative that cannot be held to exactly zero, so
     * it gets a budget rather than an equality. Before the rhythm-quality and
     * vertical-share gates this fixture scored 278; the budget is what stops
     * that regressing quietly back toward it.
     */
    @Test
    fun handJiggleIsAlmostEntirelyRejected() {
        val counted = load("reject_jiggle").expected
        assertTrue("three minutes of jiggle counted " + counted, counted <= 15)
    }

    /**
     * The regression test for the confirmed-run latch. The old detector counted
     * straight through the jiggle because the walk had already confirmed the
     * run and nothing ever re-checked it - 204 steps for a 60-step walk.
     */
    @Test
    fun aConfirmedWalkDoesNotLicenseCountingThroughJiggle() {
        val counted = load("walk_then_jiggle").expected
        assertTrue("walk-then-jiggle counted " + counted, counted in 55..80)
    }

    /** Walking with the phone in a swinging hand must still be counted. */
    @Test
    fun armSwingWalkingIsStillCounted() {
        val counted = load("walk_arm_swing").expected
        assertTrue("arm-swing walk counted " + counted, counted >= 50)
    }

    @Test
    fun paramsAreClampedIntoLegalRange() {
        val wild = CalibrationParams(
            thresholdSigma = 99.0,
            minAmplitude = -5.0,
            minStepIntervalMs = 1,
            regularityRunLength = 500,
            offRhythmTolerance = 9.0,
            maxIntervalCv = -1.0,
            minVerticalShare = 4.0,
        ).clamped()
        assertEquals(2.0, wild.thresholdSigma, 1e-9)
        assertEquals(0.1, wild.minAmplitude, 1e-9)
        assertEquals(180, wild.minStepIntervalMs)
        assertEquals(8, wild.regularityRunLength)
        assertEquals(1.0, wild.offRhythmTolerance, 1e-9)
        assertEquals(0.08, wild.maxIntervalCv, 1e-9)
        assertEquals(0.9, wild.minVerticalShare, 1e-9)
    }

    @Test
    fun aGapInTheStreamResetsRatherThanEmittingABurst() {
        val golden = load("walk_normal")
        val d = StepDetectorNative()
        for (s in golden.samples) {
            d.addSample(s.tNs, s.ax, s.ay, s.az, s.gx, s.gy, s.gz, true)
        }
        val before = d.totalSteps
        // A ten-minute jump must not manufacture steps.
        d.addSample(golden.samples.last().tNs + 600_000_000_000L, 9.81, 0.0, 0.0, 0.3, 0.0, 0.0, true)
        assertEquals(before, d.totalSteps)
    }
}
