package com.felicedesign.stepcounter

import android.content.Context
import android.content.Intent
import android.hardware.Sensor
import android.hardware.SensorManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Bridge between the Dart UI and the counting service.
 *
 * Dart never touches sensors directly. It sends commands down this channel and
 * receives step events back, which keeps the live counting path entirely inside
 * the service where it can outlive the UI.
 */
class MainActivity : FlutterActivity() {

    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val store = StepStore(this)

        MethodChannel(messenger, CONTROL_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    val intent = Intent(this, StepSensorService::class.java)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }

                "stopService" -> {
                    startService(
                        Intent(this, StepSensorService::class.java)
                            .apply { action = StepSensorService.ACTION_STOP }
                    )
                    result.success(true)
                }

                "isRunning" -> result.success(StepSensorService.isRunning)

                // Destructive by design: buckets leave service storage only once
                // Dart has them in hand to commit to SQLite.
                "drainBuckets" -> result.success(store.drainBuckets())

                "drainAutoWindows" -> {
                    val windows = store.listAutoWindows()
                    store.clearAutoWindows()
                    result.success(windows)
                }

                "autoWindowCount" -> result.success(store.autoWindowCount())

                "setParams" -> {
                    val json = call.arguments as String
                    store.paramsJson = json
                    StepSensorService.instance?.applyParams(json)
                    result.success(true)
                }

                "setActivityParams" -> {
                    val json = call.arguments as String
                    store.activityParamsJson = json
                    StepSensorService.instance?.applyActivityParams(json)
                    result.success(true)
                }

                "setAutoCalibration" -> {
                    store.autoCalibrationEnabled = call.arguments as Boolean
                    result.success(true)
                }

                "startRecording" -> {
                    val svc = StepSensorService.instance
                    if (svc == null) {
                        result.error("no_service", "Counting service is not running", null)
                    } else {
                        svc.startRecording()
                        result.success(true)
                    }
                }

                "recordingHardwareDelta" -> {
                    val svc = StepSensorService.instance
                    result.success(svc?.recordingHardwareDelta() ?: -1)
                }

                "stopRecording" -> {
                    val svc = StepSensorService.instance
                    if (svc == null) {
                        result.error("no_service", "Counting service is not running", null)
                    } else {
                        result.success(svc.stopRecording())
                    }
                }

                "setTodayTotal" -> {
                    StepSensorService.instance
                        ?.setTodayTotal((call.arguments as Number).toInt())
                    result.success(true)
                }

                "resetDetector" -> {
                    StepSensorService.instance?.resetDetector()
                    result.success(true)
                }

                "clearAutoWindows" -> {
                    store.clearAutoWindows()
                    result.success(true)
                }

                "diagnostics" -> result.success(diagnostics(store))

                "isIgnoringBatteryOptimizations" ->
                    result.success(isIgnoringBatteryOptimizations())

                "requestIgnoreBatteryOptimizations" -> {
                    requestIgnoreBatteryOptimizations()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                    StepSensorService.listener = { payload ->
                        runOnUiThread { eventSink?.success(payload) }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    StepSensorService.listener = null
                    eventSink = null
                }
            }
        )
    }

    private fun diagnostics(store: StepStore): Map<String, Any?> {
        val sm = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        val live: Map<String, Any?> = StepSensorService.instance?.liveDebug() ?: emptyMap()
        // Typed explicitly: mapOf here infers Map<String, Any>, which will not
        // accept a Map<String, Any?> on the right of `plus`.
        val base: Map<String, Any?> = mapOf(
            "serviceRunning" to StepSensorService.isRunning,
            "hasAccelerometer" to (sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) != null),
            "hasGyroscope" to (sm.getDefaultSensor(Sensor.TYPE_GYROSCOPE) != null),
            "hasHardwareCounter" to (sm.getDefaultSensor(Sensor.TYPE_STEP_COUNTER) != null),
            "hasBarometer" to (sm.getDefaultSensor(Sensor.TYPE_PRESSURE) != null),
            "autoCalibrationEnabled" to store.autoCalibrationEnabled,
            "autoWindowCount" to store.autoWindowCount(),
            "pendingSteps" to store.pendingTotal(),
            "ignoringBatteryOptimizations" to isIgnoringBatteryOptimizations(),
        )
        return base + live
    }

    /**
     * Several OEM Android skins kill background services aggressively unless the
     * app is exempted, which is the most common cause of a step counter silently
     * under-counting. Settings surfaces this so the user can fix it.
     */
    private fun isIgnoringBatteryOptimizations(): Boolean {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestIgnoreBatteryOptimizations() {
        runCatching {
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                    .setData(Uri.parse("package:$packageName"))
            )
        }.onFailure {
            // Some devices hide that screen entirely; fall back to the list.
            runCatching {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            }
        }
    }

    companion object {
        private const val CONTROL_CHANNEL = "stepcounter/control"
        private const val EVENT_CHANNEL = "stepcounter/events"
    }
}
