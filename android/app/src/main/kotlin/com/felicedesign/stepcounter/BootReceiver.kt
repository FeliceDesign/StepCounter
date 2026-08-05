package com.felicedesign.stepcounter

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/**
 * Restarts counting after a reboot.
 *
 * Without this the app silently stops counting until the user next opens it,
 * which is the failure mode people notice weeks later as "it missed a day".
 * The service is only restarted if the user actually had it on.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }

        val store = StepStore(context)
        if (!store.serviceEnabled) return

        // TYPE_STEP_COUNTER restarts from zero after a reboot, so the stored
        // baseline now refers to a count that no longer exists. Clearing it
        // makes the service re-baseline on its first reading instead of
        // computing a large negative delta.
        store.hardwareBaseline = -1L

        val serviceIntent = Intent(context, StepSensorService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }
    }
}
