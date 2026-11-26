package com.waterlevel.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * UI activity. Network MethodChannel is provided by [WifiPlugin] so the same
 * APIs work in the WorkManager background FlutterEngine.
 */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        CrashWatch.install(this)
        super.onCreate(savedInstanceState)
        val app = applicationContext
        Thread { CrashWatch.reportPastExits(app) }.start()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(WifiPlugin())
        // Ask runtime permissions once; never auto-open battery / WiFi panels.
        requestWifiPermissionsOnce()
    }

    private fun requestWifiPermissionsOnce() {
        val prefs = getSharedPreferences("waterlevel_prefs", MODE_PRIVATE)
        if (prefs.getBoolean("perms_asked", false)) return
        val needed = mutableListOf<String>()
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        ) {
            needed.add(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            needed.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.NEARBY_WIFI_DEVICES)
            != PackageManager.PERMISSION_GRANTED
        ) {
            needed.add(Manifest.permission.NEARBY_WIFI_DEVICES)
        }
        prefs.edit().putBoolean("perms_asked", true).apply()
        if (needed.isNotEmpty()) {
            ActivityCompat.requestPermissions(this, needed.toTypedArray(), 4401)
        }
    }

    companion object {
        const val DEFAULT_SSID = "WaterLevel"
        const val DEFAULT_PASSWORD = "12345678"
    }
}
