package com.waterlevel.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import dev.fluttercommunity.workmanager.BackgroundWorker

/**
 * Keeps a low-priority notification and periodically wakes the Flutter WorkManager
 * sync callback so the phone can pull from the ESP SoftAP / upload without the UI open.
 */
class SiteSyncService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val tickMs = 90_000L

    private val tick = object : Runnable {
        override fun run() {
            maybeEnqueueSync()
            handler.postDelayed(this, tickMs)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        val notification = buildNotification("Watching for WaterLevel WiFi…")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIF_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
        handler.post(tick)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            else -> maybeEnqueueSync()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(tick)
        super.onDestroy()
    }

    private fun maybeEnqueueSync() {
        val ssid = currentSsid()
        val onGateway = ssid == GATEWAY_SSID
        // Always nudge WorkManager; Dart side decides download vs upload.
        enqueueFlutterSync()
        val text = when {
            onGateway -> "On WaterLevel · pulling sensor data"
            else -> "Standby · near station or on internet to sync"
        }
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIF_ID, buildNotification(text))
    }

    private fun enqueueFlutterSync() {
        val input = Data.Builder()
            .putString(BackgroundWorker.DART_TASK_KEY, DART_TASK)
            .build()
        val request = OneTimeWorkRequestBuilder<BackgroundWorker>()
            .setInputData(input)
            .addTag(WORK_TAG)
            .build()
        WorkManager.getInstance(applicationContext).enqueueUniqueWork(
            WORK_NAME,
            ExistingWorkPolicy.KEEP,
            request,
        )
    }

    private fun currentSsid(): String? {
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        val info = wifi.connectionInfo ?: return null
        @Suppress("DEPRECATION")
        var ssid = info.ssid ?: return null
        if (ssid == "<unknown ssid>") return null
        if (ssid.startsWith("\"") && ssid.endsWith("\"")) {
            ssid = ssid.substring(1, ssid.length - 1)
        }
        return ssid
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "WaterLevel auto sync",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Pulls dam readings when near the station and uploads when online"
        }
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification(content: String): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, SiteSyncService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("WaterLevel")
            .setContentText(content)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentIntent(pending)
            .addAction(0, "Stop", stop)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    companion object {
        const val CHANNEL_ID = "waterlevel_site_sync"
        const val NOTIF_ID = 4201
        const val ACTION_STOP = "com.waterlevel.app.STOP_SITE_SYNC"
        const val GATEWAY_SSID = "WaterLevel"
        const val WORK_NAME = "waterlevel_site_sync_once"
        const val WORK_TAG = "waterlevel_site_sync"
        const val DART_TASK = "waterlevel_site_sync"

        fun start(context: Context) {
            val intent = Intent(context, SiteSyncService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, SiteSyncService::class.java))
        }
    }
}
