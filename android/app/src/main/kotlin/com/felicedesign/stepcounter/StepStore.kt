package com.felicedesign.stepcounter

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject
import java.io.File

/**
 * Durable state owned by the foreground service.
 *
 * The service has to keep counting when no Flutter engine exists, so it cannot
 * write to the app's drift database — two writers on one SQLite file across
 * process lifetimes is a reliable way to lose data. Instead the service
 * accumulates into its own storage and Dart drains it into drift whenever the
 * UI next runs. Draining is destructive and only happens once Dart confirms the
 * write, so a crash mid-handover costs nothing.
 *
 * Steps are bucketed per minute. That is granular enough to draw any chart the
 * app offers, and 1440 rows a day is nothing for SQLite.
 */
class StepStore(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences("stepcounter_service", Context.MODE_PRIVATE)

    private val calibDir = File(context.filesDir, "auto_calib").apply { mkdirs() }

    // ---- Pending minute buckets -------------------------------------------

    /**
     * Keys are `minuteEpoch:activityId`. A composite string keeps this a flat
     * JSON map — which is what a SharedPreferences value can cheaply be —
     * while still carrying which activity the steps belong to.
     */
    @Synchronized
    fun addSteps(minuteEpoch: Long, activityId: String, count: Int) {
        val obj = pendingObject()
        val key = "$minuteEpoch:$activityId"
        obj.put(key, obj.optInt(key, 0) + count)
        trimPending(obj)
        prefs.edit().putString(KEY_PENDING, obj.toString()).apply()
    }

    @Synchronized
    fun drainBuckets(): Map<String, Int> {
        val obj = pendingObject()
        val out = HashMap<String, Int>()
        obj.keys().forEach { k -> out[k] = obj.optInt(k, 0) }
        prefs.edit().remove(KEY_PENDING).apply()
        return out
    }

    @Synchronized
    fun pendingTotal(): Int {
        val obj = pendingObject()
        var total = 0
        obj.keys().forEach { total += obj.optInt(it, 0) }
        return total
    }

    private fun pendingObject(): JSONObject =
        try {
            JSONObject(prefs.getString(KEY_PENDING, "{}") ?: "{}")
        } catch (_: Exception) {
            JSONObject()
        }

    /**
     * Caps unsynced history at 30 days. If the UI is never opened the oldest
     * buckets are dropped rather than growing the preference file without
     * bound, which would eventually make every service write slow.
     */
    private fun trimPending(obj: JSONObject) {
        val cutoff = (System.currentTimeMillis() / 60_000L) - 30L * 24 * 60
        val stale = obj.keys().asSequence().filter {
            (it.substringBefore(':').toLongOrNull() ?: 0L) < cutoff
        }.toList()
        stale.forEach { obj.remove(it) }
    }

    // ---- Automatic calibration windows ------------------------------------

    /**
     * Stores one labelled window: raw samples plus the counts from us and from
     * the hardware pedometer.
     *
     * Raw samples are kept, not summary features, because the optimiser has to
     * replay the window through the real detector to score a candidate
     * parameter set. A 60 s window is ~84 KB packed, so the whole capped corpus
     * costs under 2 MB.
     */
    @Synchronized
    fun saveAutoWindow(
        packed: ByteArray,
        ourCount: Int,
        hardwareCount: Int,
        packedPressure: ByteArray? = null,
    ) {
        val ts = System.currentTimeMillis()
        File(calibDir, "$ts.bin").writeBytes(packed)
        if (packedPressure != null && packedPressure.isNotEmpty()) {
            File(calibDir, "$ts.baro").writeBytes(packedPressure)
        }
        File(calibDir, "$ts.json").writeText(
            JSONObject()
                .put("recordedAt", ts)
                .put("ourCount", ourCount)
                .put("hardwareCount", hardwareCount)
                .toString()
        )
        enforceWindowCap()
    }

    @Synchronized
    fun listAutoWindows(): List<Map<String, Any?>> =
        calibDir.listFiles { f -> f.name.endsWith(".json") }
            ?.sortedBy { it.name }
            ?.mapNotNull { meta ->
                val bin = File(calibDir, meta.name.removeSuffix(".json") + ".bin")
                if (!bin.exists()) return@mapNotNull null
                try {
                    val j = JSONObject(meta.readText())
                    val baro = File(calibDir, meta.name.removeSuffix(".json") + ".baro")
                    mapOf(
                        "recordedAt" to j.optLong("recordedAt"),
                        "ourCount" to j.optInt("ourCount"),
                        "hardwareCount" to j.optInt("hardwareCount"),
                        "samples" to bin.readBytes(),
                        "pressureSamples" to if (baro.exists()) baro.readBytes() else null,
                    )
                } catch (_: Exception) {
                    null
                }
            } ?: emptyList()

    @Synchronized
    fun clearAutoWindows() {
        calibDir.listFiles()?.forEach { it.delete() }
    }

    @Synchronized
    fun autoWindowCount(): Int =
        calibDir.listFiles { f -> f.name.endsWith(".json") }?.size ?: 0

    private fun enforceWindowCap() {
        val metas = calibDir.listFiles { f -> f.name.endsWith(".json") }
            ?.sortedBy { it.name } ?: return
        if (metas.size <= MAX_AUTO_WINDOWS) return
        metas.take(metas.size - MAX_AUTO_WINDOWS).forEach { meta ->
            val stem = meta.name.removeSuffix(".json")
            File(calibDir, "$stem.bin").delete()
            File(calibDir, "$stem.baro").delete()
            meta.delete()
        }
    }

    // ---- Detector parameters ----------------------------------------------

    /**
     * The service needs the active parameters at boot, before any Flutter
     * engine exists to hand them over, so they are mirrored here.
     */
    var paramsJson: String
        get() = prefs.getString(KEY_PARAMS, "") ?: ""
        set(v) = prefs.edit().putString(KEY_PARAMS, v).apply()

    var activityParamsJson: String
        get() = prefs.getString(KEY_ACTIVITY_PARAMS, "") ?: ""
        set(v) = prefs.edit().putString(KEY_ACTIVITY_PARAMS, v).apply()

    var autoCalibrationEnabled: Boolean
        get() = prefs.getBoolean(KEY_AUTO_CALIB, true)
        set(v) = prefs.edit().putBoolean(KEY_AUTO_CALIB, v).apply()

    var serviceEnabled: Boolean
        get() = prefs.getBoolean(KEY_SERVICE_ENABLED, false)
        set(v) = prefs.edit().putBoolean(KEY_SERVICE_ENABLED, v).apply()

    /**
     * Hardware pedometer baseline. TYPE_STEP_COUNTER reports steps since boot
     * and resets to zero on reboot, so a raw reading is meaningless without the
     * value we last saw.
     */
    var hardwareBaseline: Long
        get() = prefs.getLong(KEY_HW_BASELINE, -1L)
        set(v) = prefs.edit().putLong(KEY_HW_BASELINE, v).apply()

    /**
     * Hardware counter reading at the start of today, so the app can show
     * Android's own count for the day beside its own.
     *
     * Persisted because the service is routinely restarted mid-day and would
     * otherwise have no idea where the day began.
     */
    var hardwareDayStart: Long
        get() = prefs.getLong(KEY_HW_DAY_START, -1L)
        set(v) = prefs.edit().putLong(KEY_HW_DAY_START, v).apply()

    var hardwareDayIndex: Int
        get() = prefs.getInt(KEY_HW_DAY_INDEX, -1)
        set(v) = prefs.edit().putInt(KEY_HW_DAY_INDEX, v).apply()

    companion object {
        private const val KEY_PENDING = "pending_buckets"
        private const val KEY_PARAMS = "params_json"
        private const val KEY_ACTIVITY_PARAMS = "activity_params_json"
        private const val KEY_AUTO_CALIB = "auto_calibration"
        private const val KEY_SERVICE_ENABLED = "service_enabled"
        private const val KEY_HW_BASELINE = "hw_baseline"
        private const val KEY_HW_DAY_START = "hw_day_start"
        private const val KEY_HW_DAY_INDEX = "hw_day_index"

        const val MAX_AUTO_WINDOWS = 20
    }
}
