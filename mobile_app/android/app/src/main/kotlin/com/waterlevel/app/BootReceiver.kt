package com.waterlevel.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Restart background site sync after phone reboot. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != Intent.ACTION_BOOT_COMPLETED) return
        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("flutter.site_sync_enabled", true)) return
        SiteSyncService.start(context.applicationContext)
    }
}
