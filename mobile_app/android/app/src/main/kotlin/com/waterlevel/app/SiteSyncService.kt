package com.waterlevel.app

import android.app.AlarmManager
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
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import dev.fluttercommunity.workmanager.BackgroundWorker
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Foreground service: pull SoftAP → bind LTE → native Firebase upload.
 * Holds CPU/WiFi wake locks during each cycle so lock-screen / Doze does not
 * freeze the upload mid-flight. Next cycle is scheduled with an exact alarm
 * that is allowed while idle.
 */
class SiteSyncService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val cycleRunning = AtomicBoolean(false)
    private val tickMs = 75_000L

    override fun onBind(intent: Intent?): android.os.IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIF_ID,
                buildNotification("Watching for WaterLevel WiFi…"),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIF_ID, buildNotification("Watching for WaterLevel WiFi…"))
        }
        startCycle()
        scheduleNextAlarm()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                cancelNextAlarm()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_TICK, null -> {
                startCycle()
                scheduleNextAlarm()
            }
            else -> {
                startCycle()
                scheduleNextAlarm()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        cancelNextAlarm()
        executor.shutdownNow()
        super.onDestroy()
    }

    private fun startCycle() {
        if (!cycleRunning.compareAndSet(false, true)) {
            Log.i(TAG, "cycle already running — skip")
            return
        }
        executor.execute {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            val wake = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "WaterLevel:SiteSync",
            ).apply { setReferenceCounted(false) }
            val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val wifiLock = wifi.createWifiLock(
                WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                "WaterLevel:SiteSyncWifi",
            ).apply { setReferenceCounted(false) }
            try {
                wake.acquire(3 * 60_000L)
                try {
                    wifiLock.acquire()
                } catch (_: Throwable) {
                    // Some OEMs restrict WifiLock; continue with CPU lock only.
                }
                runSyncPhasesBlocking()
            } catch (t: Throwable) {
                Log.e(TAG, "cycle failed", t)
            } finally {
                try {
                    if (wifiLock.isHeld) wifiLock.release()
                } catch (_: Throwable) {
                }
                try {
                    if (wake.isHeld) wake.release()
                } catch (_: Throwable) {
                }
                cycleRunning.set(false)
            }
        }
    }

    private fun runSyncPhasesBlocking() {
        // Best-effort WiFi enable (Android 10+ often ignores this silently).
        try {
            val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            if (!wifi.isWifiEnabled) {
                @Suppress("DEPRECATION")
                wifi.setWifiEnabled(true)
                sleepQuiet(2_000)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "could not enable WiFi from service", t)
        }

        val onGateway = NetworkBinder.isOnGateway(applicationContext)
        Log.i(TAG, "cycle start onGateway=$onGateway")

        if (onGateway) {
            NetworkBinder.bindToGateway(applicationContext)
            updateNotification("On WaterLevel · pulling sensor data")
            enqueueFlutterSync("pull")
            sleepQuiet(18_000)
        }

        // SoftAP has no internet. Prefer binding to LTE; if that fails while still
        // on WaterLevel, briefly pause WiFi so mobile data becomes the route.
        var wifiPaused = false
        var bound = NetworkBinder.bindToInternet(applicationContext)
        if ((!bound || NetworkBinder.isOnGateway(applicationContext)) &&
            !NetworkBinder.hasValidatedInternet(applicationContext)
        ) {
            updateNotification("Pausing SoftAP WiFi for cloud upload…")
            wifiPaused = pauseWifiForUpload()
            sleepQuiet(4_000)
            bound = NetworkBinder.bindToInternet(applicationContext)
        }
        Log.i(
            TAG,
            "upload phase bindInternet=$bound validated=${NetworkBinder.hasValidatedInternet(applicationContext)} wifiPaused=$wifiPaused",
        )
        if (!bound && !NetworkBinder.hasValidatedInternet(applicationContext)) {
            updateNotification(
                "Waiting for internet — leave WaterLevel WiFi or turn on mobile data",
            )
            Log.i(TAG, "cycle done — no internet for upload")
            if (wifiPaused) resumeWifiAfterUpload()
            return
        }

        updateNotification("Uploading pending readings over mobile/data…")
        val native = NativeCloudUploader.uploadPending(applicationContext)
        Log.i(TAG, "native upload: ${native.message} uploaded=${native.uploaded} left=${native.pendingLeft}")
        enqueueFlutterSync("upload")
        sleepQuiet(3_000)

        if (wifiPaused) {
            updateNotification("Restoring WiFi for next sensor pull…")
            resumeWifiAfterUpload()
            sleepQuiet(2_000)
        }

        updateNotification(
            when {
                native.uploaded > 0 && native.pendingLeft == 0 ->
                    "Cloud up to date · sent ${native.uploaded}"
                native.uploaded > 0 ->
                    "Sent ${native.uploaded} · ${native.pendingLeft} still pending"
                native.pendingLeft == 0 ->
                    "Cloud up to date"
                NetworkBinder.isOnGateway(applicationContext) ->
                    "On WaterLevel · ${native.pendingLeft} waiting — will retry upload"
                else ->
                    "Online · ${native.pendingLeft} pending (${native.message})"
            },
        )
        Log.i(TAG, "cycle done")
    }

    /** Best-effort SoftAP release so LTE can carry Firebase traffic. */
    private fun pauseWifiForUpload(): Boolean {
        return try {
            val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
            NetworkBinder.clearBinding(applicationContext)
            @Suppress("DEPRECATION")
            if (wifi.isWifiEnabled) {
                @Suppress("DEPRECATION")
                wifi.setWifiEnabled(false)
            } else {
                true
            }
        } catch (t: Throwable) {
            Log.w(TAG, "could not pause WiFi for upload", t)
            false
        }
    }

    private fun resumeWifiAfterUpload() {
        try {
            val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            if (!wifi.isWifiEnabled) {
                @Suppress("DEPRECATION")
                wifi.setWifiEnabled(true)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "could not restore WiFi after upload", t)
        }
    }

    private fun scheduleNextAlarm() {
        val am = getSystemService(ALARM_SERVICE) as AlarmManager
        val pi = tickPendingIntent()
        val triggerAt = SystemClock.elapsedRealtime() + tickMs
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                am.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAt, pi)
            } else {
                @Suppress("DEPRECATION")
                am.setExact(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAt, pi)
            }
            Log.i(TAG, "next tick in ${tickMs}ms (exact alarm)")
        } catch (t: Throwable) {
            Log.w(TAG, "exact alarm failed, falling back to handler", t)
            handler.removeCallbacksAndMessages(null)
            handler.postDelayed({
                startCycle()
                scheduleNextAlarm()
            }, tickMs)
        }
    }

    private fun cancelNextAlarm() {
        val am = getSystemService(ALARM_SERVICE) as AlarmManager
        am.cancel(tickPendingIntent())
        handler.removeCallbacksAndMessages(null)
    }

    private fun tickPendingIntent(): PendingIntent {
        val intent = Intent(this, SiteSyncService::class.java).setAction(ACTION_TICK)
        return PendingIntent.getService(
            this,
            42,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun enqueueFlutterSync(reason: String) {
        val input = Data.Builder()
            .putString(BackgroundWorker.DART_TASK_KEY, DART_TASK)
            .putString("reason", reason)
            .build()
        val builder = OneTimeWorkRequestBuilder<BackgroundWorker>()
            .setInputData(input)
            .addTag(WORK_TAG)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
        }
        WorkManager.getInstance(applicationContext).enqueueUniqueWork(
            "$WORK_NAME-$reason",
            ExistingWorkPolicy.REPLACE,
            builder.build(),
        )
        Log.i(TAG, "enqueued Flutter sync reason=$reason")
    }

    private fun sleepQuiet(ms: Long) {
        try {
            Thread.sleep(ms)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun updateNotification(text: String) {
        handler.post {
            val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIF_ID, buildNotification(text))
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "WaterLevel auto sync",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Pulls dam readings near the station and uploads when online"
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
        private const val TAG = "SiteSyncService"
        const val CHANNEL_ID = "waterlevel_site_sync"
        const val NOTIF_ID = 4201
        const val ACTION_STOP = "com.waterlevel.app.STOP_SITE_SYNC"
        const val ACTION_TICK = "com.waterlevel.app.SITE_SYNC_TICK"
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
