package com.waterlevel.app

import android.Manifest
import android.app.AlarmManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.os.StatFs
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.core.location.LocationManagerCompat
import java.util.UUID

/**
 * Identifies this phone in cloud logs and reports the phone settings that
 * decide whether background sync can work (battery saver, storage, etc.).
 */
object DeviceInfo {
    private const val PREFS = "device_identity"
    private const val KEY_ID = "device_id"
    private const val KEY_NAME = "device_name"

    /** Below this, SQLite writes start failing and installs fail. */
    const val LOW_STORAGE_MB = 300L

    @Synchronized
    fun deviceId(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString(KEY_ID, null)?.let { return it }
        val id = UUID.randomUUID().toString().replace("-", "").take(12)
        prefs.edit().putString(KEY_ID, id).apply()
        return id
    }

    fun defaultName(): String {
        val maker = Build.MANUFACTURER.orEmpty().replaceFirstChar { it.uppercase() }
        val model = Build.MODEL.orEmpty()
        return if (model.startsWith(maker, ignoreCase = true)) model else "$maker $model".trim()
    }

    fun deviceName(context: Context): String {
        val saved = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_NAME, null)
        return saved?.takeIf { it.isNotBlank() } ?: defaultName()
    }

    fun setDeviceName(context: Context, name: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_NAME, name.trim().take(40))
            .apply()
    }

    fun freeStorageMb(context: Context): Long {
        return try {
            val stat = StatFs(Environment.getDataDirectory().path)
            stat.availableBytes / (1024L * 1024L)
        } catch (_: Throwable) {
            -1L
        }
    }

    fun isBatteryUnrestricted(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            pm.isIgnoringBatteryOptimizations(context.packageName)
        } catch (_: Throwable) {
            true
        }
    }

    fun canUseExactAlarms(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        return try {
            (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).canScheduleExactAlarms()
        } catch (_: Throwable) {
            true
        }
    }

    fun snapshot(context: Context): Map<String, Any?> {
        val app = context.applicationContext
        val battery = batteryState(app)
        val (versionName, versionCode) = appVersion(app)
        val locationOn = try {
            LocationManagerCompat.isLocationEnabled(
                app.getSystemService(Context.LOCATION_SERVICE) as LocationManager,
            )
        } catch (_: Throwable) {
            false
        }
        return mapOf(
            "device_id" to deviceId(app),
            "name" to deviceName(app),
            "model" to defaultName(),
            "android" to Build.VERSION.RELEASE,
            "sdk" to Build.VERSION.SDK_INT,
            "app_version" to versionName,
            "app_build" to versionCode,
            "free_storage_mb" to freeStorageMb(app),
            "battery_pct" to battery.first,
            "charging" to battery.second,
            "battery_unrestricted" to isBatteryUnrestricted(app),
            "notifications_on" to NotificationManagerCompat.from(app).areNotificationsEnabled(),
            "exact_alarms" to canUseExactAlarms(app),
            "location_permission" to (
                ContextCompat.checkSelfPermission(app, Manifest.permission.ACCESS_FINE_LOCATION) ==
                    PackageManager.PERMISSION_GRANTED
                ),
            "location_on" to locationOn,
            "wifi_on" to NetworkBinder.isWifiRadioOn(app),
        )
    }

    private fun batteryState(context: Context): Pair<Int, Boolean> {
        return try {
            val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            val level = intent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = intent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
            val plugged = (intent?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0
            val pct = if (level >= 0 && scale > 0) level * 100 / scale else -1
            pct to plugged
        } catch (_: Throwable) {
            -1 to false
        }
    }

    private fun appVersion(context: Context): Pair<String, Long> {
        return try {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toLong()
            }
            (info.versionName ?: "?") to code
        } catch (_: Throwable) {
            "?" to 0L
        }
    }

    /** Opens the requested settings screen, falling back to the app's details page. */
    fun openSettings(context: Context, which: String): Boolean {
        val pkg = Uri.parse("package:${context.packageName}")
        val candidates = listOfNotNull(
            primarySettingsIntent(context, which),
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkg),
        )
        for (intent in candidates) {
            try {
                context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (_: Throwable) {
                // Some OEMs remove screens; try the next one.
            }
        }
        return false
    }

    private fun primarySettingsIntent(context: Context, which: String): Intent? {
        val pkg = Uri.parse("package:${context.packageName}")
        return when (which) {
            "battery" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                @Suppress("BatteryLife")
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, pkg)
            } else {
                null
            }
            "notifications" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            } else {
                null
            }
            "alarms" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, pkg)
            } else {
                null
            }
            "location" -> Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
            else -> null
        }
    }
}
