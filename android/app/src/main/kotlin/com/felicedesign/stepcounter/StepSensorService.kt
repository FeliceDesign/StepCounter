package com.felicedesign.stepcounter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Foreground service that owns the sensors and the live step count.
 *
 * Everything here exists because a step counter that stops when the screen
 * turns off is useless. Android will not let a process hold sensor streams in
 * the background without a foreground service, and will not let a foreground
 * service run without a visible notification — so the notification channel is
 * created at IMPORTANCE_MIN, which is as quiet as the platform permits: silent,
 * no heads-up, collapsed into the low-priority section of the shade.
 */
class StepSensorService : Service(), SensorEventListener {

    private lateinit var sensorManager: SensorManager
    private lateinit var store: StepStore
    private var detector = StepDetectorNative()

    private var accelSensor: Sensor? = null
    private var gyroSensor: Sensor? = null
    private var hardwareCounter: Sensor? = null

    private val lastGyro = FloatArray(3)
    private var hasGyroReading = false

    private var todaySteps = 0
    private var todayIndex = localDayIndex()
    private var lastNotificationSteps = -1
    private var lastNotificationMs = 0L

    // ---- Manual recording (Test & Recalibrate) ----
    private var recording = false
    private val recordBuffer = ArrayList<DoubleArray>()

    // ---- Automatic calibration window capture ----
    private var windowActive = false
    private var windowSettling = false
    private val windowBuffer = ArrayList<DoubleArray>()
    private var windowStartHardware = -1L
    private var windowOurCount = 0
    private var windowStartElapsedNs = 0L
    private var lastStepElapsedNs = 0L

    private var latestHardwareTotal = -1L

    override fun onCreate() {
        super.onCreate()
        instance = this
        store = StepStore(this)
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager

        accelSensor = sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        gyroSensor = sensorManager.getDefaultSensor(Sensor.TYPE_GYROSCOPE)
        hardwareCounter = sensorManager.getDefaultSensor(Sensor.TYPE_STEP_COUNTER)

        store.paramsJson.takeIf { it.isNotEmpty() }?.let { json ->
            runCatching { detector.params = parseParams(json) }
        }

        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            store.serviceEnabled = false
            stopSelf()
            return START_NOT_STICKY
        }

        store.serviceEnabled = true
        startForegroundSafely()
        registerSensors()
        isRunning = true

        // START_STICKY: if the system kills us under memory pressure, come back.
        return START_STICKY
    }

    private fun startForegroundSafely() {
        val type = if (Build.VERSION.SDK_INT >= 34) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_HEALTH
        } else {
            0
        }
        ServiceCompat.startForeground(this, NOTIFICATION_ID, buildNotification(todaySteps), type)
    }

    private fun registerSensors() {
        // SENSOR_DELAY_GAME is 20 ms (50 Hz), comfortably inside the 200 Hz cap
        // Android 12+ applies without HIGH_SAMPLING_RATE_SENSORS.
        //
        // The one-second batch latency is the single biggest battery lever here:
        // it lets the sensor hub buffer readings and deliver them in bursts
        // while the application processor stays asleep, instead of waking it
        // fifty times a second.
        accelSensor?.let {
            sensorManager.registerListener(this, it, SAMPLING_PERIOD_US, BATCH_LATENCY_US)
        }
        gyroSensor?.let {
            sensorManager.registerListener(this, it, SAMPLING_PERIOD_US, BATCH_LATENCY_US)
        }
        hardwareCounter?.let {
            sensorManager.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL)
        }
    }

    override fun onDestroy() {
        sensorManager.unregisterListener(this)
        isRunning = false
        instance = null
        flushPending()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_GYROSCOPE -> {
                lastGyro[0] = event.values[0]
                lastGyro[1] = event.values[1]
                lastGyro[2] = event.values[2]
                hasGyroReading = true
            }

            Sensor.TYPE_STEP_COUNTER -> onHardwareCount(event.values[0].toLong())

            Sensor.TYPE_ACCELEROMETER -> onAccel(event)
        }
    }

    private fun onAccel(event: SensorEvent) {
        val tNs = event.timestamp
        val ax = event.values[0].toDouble()
        val ay = event.values[1].toDouble()
        val az = event.values[2].toDouble()
        val gx = lastGyro[0].toDouble()
        val gy = lastGyro[1].toDouble()
        val gz = lastGyro[2].toDouble()

        if (recording) {
            recordBuffer.add(sampleRow(tNs, ax, ay, az, gx, gy, gz))
        }
        if (windowActive) {
            windowBuffer.add(sampleRow(tNs, ax, ay, az, gx, gy, gz))
        }

        val steps = detector.addSample(tNs, ax, ay, az, gx, gy, gz, hasGyroReading)
        if (steps.isNotEmpty()) {
            onStepsConfirmed(steps)
        }

        maintainCalibrationWindow(tNs, steps.size)
        maybeUpdateNotification()
    }

    private fun onStepsConfirmed(stepTimestampsNs: List<Long>) {
        val nowMs = System.currentTimeMillis()
        val nowNs = SystemClock.elapsedRealtimeNanos()

        // Sensor timestamps are monotonic and, with batching, can be seconds
        // older than delivery. Projecting each step back through the current
        // clock offset puts it in the minute bucket it actually happened in,
        // instead of smearing a burst into the moment it was delivered.
        val byMinute = HashMap<Long, Int>()
        for (tNs in stepTimestampsNs) {
            val wallMs = nowMs - (nowNs - tNs) / 1_000_000L
            val minute = wallMs / 60_000L
            byMinute[minute] = (byMinute[minute] ?: 0) + 1
        }
        byMinute.forEach { (minute, count) -> store.addSteps(minute, count) }

        // Without this the notification keeps accumulating past midnight and
        // reports a multi-day total as "today".
        val day = localDayIndex()
        if (day != todayIndex) {
            todayIndex = day
            todaySteps = 0
        }
        todaySteps += stepTimestampsNs.size
        windowOurCount += stepTimestampsNs.size
        lastStepElapsedNs = SystemClock.elapsedRealtimeNanos()

        listener?.invoke(
            mapOf(
                "type" to "steps",
                "count" to stepTimestampsNs.size,
                "pendingTotal" to store.pendingTotal(),
            )
        )
    }

    private fun onHardwareCount(total: Long) {
        val baseline = store.hardwareBaseline
        // TYPE_STEP_COUNTER counts from boot and resets to zero on reboot, so a
        // reading below the baseline means the device restarted, not that the
        // user un-walked.
        if (baseline < 0 || total < baseline) {
            store.hardwareBaseline = total
        }
        latestHardwareTotal = total
    }

    /**
     * Captures short labelled windows for automatic calibration.
     *
     * A window is only finalised after the user has stopped for [QUIET_MS].
     * The hardware pedometer reports with up to ten seconds of latency, so a
     * label read while the user is still moving would attribute the wrong
     * number of steps to the window. Waiting for a genuine pause makes the
     * label essentially exact; walks that never pause are discarded rather than
     * labelled badly.
     */
    private fun maintainCalibrationWindow(tNs: Long, newSteps: Int) {
        if (!store.autoCalibrationEnabled || hardwareCounter == null) {
            if (windowActive) abandonWindow()
            return
        }

        if (!windowActive && newSteps > 0 && latestHardwareTotal >= 0) {
            windowActive = true
            windowSettling = false
            windowBuffer.clear()
            windowStartHardware = latestHardwareTotal
            windowOurCount = newSteps
            windowStartElapsedNs = tNs
            return
        }

        if (!windowActive) return

        val windowAgeMs = (tNs - windowStartElapsedNs) / 1_000_000L
        val sinceStepMs = (SystemClock.elapsedRealtimeNanos() - lastStepElapsedNs) / 1_000_000L

        if (!windowSettling) {
            if (windowAgeMs > MAX_WINDOW_MS) {
                // Still walking past the cap: no clean pause is coming, so this
                // window can never get an accurate label.
                abandonWindow()
                return
            }
            if (sinceStepMs > PAUSE_MS && windowOurCount >= MIN_WINDOW_STEPS) {
                windowSettling = true
            } else if (sinceStepMs > PAUSE_MS) {
                abandonWindow()
            }
            return
        }

        if (newSteps > 0) {
            // Walking resumed before the pedometer had flushed. Not a clean label.
            abandonWindow()
            return
        }

        if (sinceStepMs > QUIET_MS) {
            finaliseWindow()
        }
    }

    private fun finaliseWindow() {
        val hwDelta = (latestHardwareTotal - windowStartHardware).toInt()
        if (hwDelta in 1..MAX_PLAUSIBLE_WINDOW_STEPS) {
            store.saveAutoWindow(packSamples(windowBuffer), windowOurCount, hwDelta)
            listener?.invoke(
                mapOf(
                    "type" to "autoWindow",
                    "ourCount" to windowOurCount,
                    "hardwareCount" to hwDelta,
                    "totalWindows" to store.autoWindowCount(),
                )
            )
        }
        abandonWindow()
    }

    private fun abandonWindow() {
        windowActive = false
        windowSettling = false
        windowBuffer.clear()
        windowOurCount = 0
        windowStartHardware = -1L
    }

    // ---- Notification -----------------------------------------------------

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Step counting",
            // The quietest the platform allows for a foreground service: no
            // sound, no heads-up, collapsed into the silent section of the shade.
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            description = "Keeps counting steps while the app is closed"
            setShowBadge(false)
            enableVibration(false)
            setSound(null, null)
        }
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(channel)
    }

    private fun buildNotification(steps: Int): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_IMMUTABLE,
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("$steps steps")
            .setContentText("Counting in the background")
            .setSmallIcon(android.R.drawable.ic_menu_compass)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setSilent(true)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(open)
            .build()
    }

    /**
     * Notification updates are rate limited. Posting on every step would wake
     * the UI thread of SystemUI dozens of times a minute for a number nobody is
     * watching, which costs meaningfully more battery than the sensors do.
     */
    private fun maybeUpdateNotification() {
        val now = SystemClock.elapsedRealtime()
        if (todaySteps == lastNotificationSteps) return
        if (now - lastNotificationMs < NOTIFICATION_INTERVAL_MS) return

        lastNotificationSteps = todaySteps
        lastNotificationMs = now
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
            .notify(NOTIFICATION_ID, buildNotification(todaySteps))
    }

    private fun flushPending() {
        listener?.invoke(mapOf("type" to "flushed", "pendingTotal" to store.pendingTotal()))
    }

    // ---- Commands from Dart -----------------------------------------------

    /**
     * Dart is the authority on today's total, because it holds the database and
     * knows about steps counted by earlier service instances. A freshly started
     * service has counted nothing yet, so without this the notification would
     * restart from zero partway through the day.
     */
    fun setTodayTotal(total: Int) {
        todaySteps = total
        todayIndex = localDayIndex()
        lastNotificationMs = 0L
        maybeUpdateNotification()
    }

    /** Days since the epoch in the device's current local time zone. */
    private fun localDayIndex(): Int {
        val cal = java.util.Calendar.getInstance()
        cal.timeInMillis = System.currentTimeMillis()
        cal.set(java.util.Calendar.HOUR_OF_DAY, 0)
        cal.set(java.util.Calendar.MINUTE, 0)
        cal.set(java.util.Calendar.SECOND, 0)
        cal.set(java.util.Calendar.MILLISECOND, 0)
        return (cal.timeInMillis / 86_400_000L).toInt()
    }

    fun applyParams(json: String) {
        store.paramsJson = json
        runCatching { detector.params = parseParams(json) }
    }

    fun startRecording() {
        recordBuffer.clear()
        recording = true
    }

    fun stopRecording(): ByteArray {
        recording = false
        val packed = packSamples(recordBuffer)
        recordBuffer.clear()
        return packed
    }

    fun liveDebug(): Map<String, Any?> = detector.debugSnapshot() + mapOf(
        "todaySteps" to todaySteps,
        "hasGyro" to (gyroSensor != null),
        "hasHardwareCounter" to (hardwareCounter != null),
        "recording" to recording,
        "autoWindows" to store.autoWindowCount(),
    )

    fun resetDetector() {
        detector.reset()
        detector.resetCount()
        todaySteps = 0
        abandonWindow()
    }

    /**
     * Rows are held as doubles, not floats, purely because of the timestamp.
     *
     * elapsedRealtimeNanos is nanoseconds since boot: after a few days of
     * uptime that is ~4e8 ms, where float32 resolves to only ~32 ms. Rounding
     * to float here — before the relative subtraction in [packSamples] — would
     * quantise sample times far more coarsely than the 20 ms sampling period
     * and corrupt every recorded session on a phone that has not rebooted
     * recently. Doubles carry the full range; the narrowing to float happens
     * only after times are made relative to the first sample, where the values
     * are small.
     */
    private fun sampleRow(
        tNs: Long,
        ax: Double, ay: Double, az: Double,
        gx: Double, gy: Double, gz: Double,
    ) = doubleArrayOf(tNs / 1e6, ax, ay, az, gx, gy, gz)

    /**
     * Packs to the same little-endian float32 layout that
     * lib/detection/sensor_sample.dart unpacks, with timestamps in milliseconds
     * relative to the first sample.
     */
    private fun packSamples(rows: List<DoubleArray>): ByteArray {
        if (rows.isEmpty()) return ByteArray(0)
        val t0 = rows.first()[0]
        val out = ByteArrayOutputStream(rows.size * 7 * 4)
        val buf = ByteBuffer.allocate(7 * 4).order(ByteOrder.LITTLE_ENDIAN)
        for (r in rows) {
            buf.clear()
            buf.putFloat((r[0] - t0).toFloat())
            for (i in 1 until 7) buf.putFloat(r[i].toFloat())
            out.write(buf.array())
        }
        return out.toByteArray()
    }

    private fun parseParams(json: String): CalibrationParams {
        val o = org.json.JSONObject(json)
        val map = HashMap<String, Any?>()
        o.keys().forEach { map[it] = o.get(it) }
        return CalibrationParams.fromMap(map)
    }

    companion object {
        const val CHANNEL_ID = "stepcounter_counting"
        const val NOTIFICATION_ID = 1001
        const val ACTION_STOP = "com.felicedesign.stepcounter.STOP"

        private const val SAMPLING_PERIOD_US = 20_000      // 50 Hz
        private const val BATCH_LATENCY_US = 1_000_000     // 1 s of batching
        private const val NOTIFICATION_INTERVAL_MS = 20_000L

        private const val PAUSE_MS = 4_000L
        private const val QUIET_MS = 20_000L
        private const val MAX_WINDOW_MS = 90_000L
        private const val MIN_WINDOW_STEPS = 15
        private const val MAX_PLAUSIBLE_WINDOW_STEPS = 400

        @Volatile
        var isRunning = false
            private set

        /** Set by the Flutter plugin while the UI is attached. */
        @Volatile
        var listener: ((Map<String, Any?>) -> Unit)? = null

        @Volatile
        var instance: StepSensorService? = null
    }
}
