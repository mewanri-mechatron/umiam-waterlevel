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
    /** Faster follow-up when rows are still waiting to reach Firebase. */
    private val catchUpTickMs = 35_000L
    /** Retry SoftAP→LTE handoff a bit sooner when upload cannot start. */
    private val noInternetTickMs = 45_000L
    @Volatile
    private var foregroundOk = false
    @Volatile
    private var destroyed = false

    override fun onBind(intent: Intent?): android.os.IBinder? = null

    override fun onCreate() {
        super.onCreate()
        CrashWatch.install(this)
        val app = applicationContext
        Thread { CrashWatch.reportPastExits(app) }.start()
        createChannel()
        foregroundOk = enterForeground()
        if (!foregroundOk) {
            // Android refused foreground start (background-start limits). Stop
            // cleanly instead of crashing; the app restarts us when opened.
            AuditStore.error(applicationContext, "service", "Phone blocked the background service")
            stopSelf()
            return
        }
        isRunning = true
        AuditStore.info(applicationContext, "service", "Background service started")
    }

    /**
     * connectedDevice (talking to the WaterLevel SoftAP) has no daily runtime
     * cap and may start from BOOT_COMPLETED on Android 15. dataSync is only a
     * fallback: it is capped at 6h/24h there.
     */
    private fun enterForeground(): Boolean {
        val notification = buildNotification("Saving and sending readings")
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return try {
                startForeground(NOTIF_ID, notification)
                true
            } catch (t: Throwable) {
                Log.e(TAG, "startForeground failed", t)
                false
            }
        }
        val types = intArrayOf(
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
        for (type in types) {
            try {
                startForeground(NOTIF_ID, notification, type)
                return true
            } catch (t: Throwable) {
                Log.w(TAG, "startForeground type=$type refused", t)
            }
        }
        return false
    }

    /** Android 15+: the dataSync fallback ran out of daily time — stop cleanly. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        Log.w(TAG, "foreground time limit reached type=$fgsType — stopping")
        AuditStore.warn(applicationContext, "service", "Android time limit reached — background service stopped")
        cancelNextAlarm()
        stopSelf()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!foregroundOk || intent?.action == ACTION_STOP) {
            cancelNextAlarm()
            stopSelf()
            return START_NOT_STICKY
        }
        startCycle()
        scheduleNextAlarm()
        return START_STICKY
    }

    override fun onDestroy() {
        if (isRunning) {
            AuditStore.info(applicationContext, "service", "Background service stopped")
        }
        isRunning = false
        destroyed = true
        cancelNextAlarm()
        executor.shutdownNow()
        super.onDestroy()
    }

    private fun startCycle() {
        if (destroyed) return
        if (!cycleRunning.compareAndSet(false, true)) {
            Log.i(TAG, "cycle already running — skip")
            return
        }
        try {
            executor.execute { runCycleWithLocks() }
        } catch (t: Throwable) {
            Log.w(TAG, "cycle rejected", t)
            cycleRunning.set(false)
        }
    }

    private fun runCycleWithLocks() {
        var wake: PowerManager.WakeLock? = null
        var wifiLock: WifiManager.WifiLock? = null
        try {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            wake = pm.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "WaterLevel:SiteSync",
            ).apply {
                setReferenceCounted(false)
                acquire(4 * 60_000L)
            }
            try {
                val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
                @Suppress("DEPRECATION")
                wifiLock = wifi.createWifiLock(
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                    "WaterLevel:SiteSyncWifi",
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
            } catch (_: Throwable) {
                // Some OEMs restrict WifiLock; continue with CPU lock only.
            }
            runSyncPhasesBlocking()
        } catch (t: Throwable) {
            Log.e(TAG, "cycle failed", t)
        } finally {
            try {
                wifiLock?.let { if (it.isHeld) it.release() }
            } catch (_: Throwable) {
            }
            try {
                wake?.let { if (it.isHeld) it.release() }
            } catch (_: Throwable) {
            }
            cycleRunning.set(false)
        }
    }

    private fun runSyncPhasesBlocking() {
        // Heal phones left with WiFi radio off by older builds.
        NetworkBinder.ensureWifiRadioOn(applicationContext)

        if (!SyncLease.tryAcquire(LEASE_OWNER, LEASE_TTL_MS)) {
            Log.i(TAG, "sync held by ${SyncLease.holder()} — skip this tick")
            return
        }
        try {
            runLeasedCycle()
        } finally {
            try {
                CloudReporter.report(applicationContext)
            } catch (t: Throwable) {
                Log.w(TAG, "report failed", t)
            }
            SyncLease.release(LEASE_OWNER)
        }
    }

    private fun runLeasedCycle() {
        val onGateway = NetworkBinder.isOnGateway(applicationContext)
        Log.i(TAG, "cycle start onGateway=$onGateway wifiOn=${NetworkBinder.isWifiRadioOn(applicationContext)}")

        val ctx = applicationContext
        if (onGateway) {
            NetworkBinder.bindToGateway(ctx)
            updateNotification("Getting readings from the sensor…")
            val requestedAt = SystemClock.elapsedRealtime()
            enqueueFlutterSync("pull")
            if (!waitForWorkerPull(requestedAt, 40_000L)) {
                AuditStore.once(
                    ctx, "worker_pull_slow", LOG_REPEAT_MS, "warn", "sensor",
                    "Background sensor read did not finish in time",
                )
            }
        }

        val pendingBefore = NativeCloudUploader.pendingCount(ctx)
        if (pendingBefore == 0) {
            updateNotification(NOTIF_ALL_SENT)
            Log.i(TAG, "cycle done — nothing pending")
            return
        }
        if (pendingBefore < 0) {
            AuditStore.once(
                ctx, "db_unreadable", LOG_REPEAT_MS, "error", "storage",
                "Could not read saved readings (phone storage full?)",
                "free_storage_mb=${DeviceInfo.freeStorageMb(ctx)}",
            )
        }

        // SoftAP has no internet. Prefer LTE bind; never power WiFi off.
        var releasedSoftAp = false
        try {
            var bound = NetworkBinder.requestAndBindCellular(ctx, 8_000L)
            if ((!bound || NetworkBinder.isOnGateway(ctx)) &&
                !NetworkBinder.hasValidatedInternet(ctx)
            ) {
                updateNotification("Sending readings to office…")
                releasedSoftAp = NetworkBinder.softDisconnectWifi(ctx)
                sleepQuiet(2_500)
                bound = NetworkBinder.requestAndBindCellular(ctx, 8_000L)
            }
            Log.i(
                TAG,
                "upload phase bindInternet=$bound validated=${NetworkBinder.hasValidatedInternet(ctx)} releasedSoftAp=$releasedSoftAp",
            )
            if (!bound && !NetworkBinder.hasValidatedInternet(ctx)) {
                updateNotification("No internet. Readings are saved on this phone.")
                AuditStore.once(
                    ctx, "no_internet", LOG_REPEAT_MS, "warn", "cloud",
                    "No internet — $pendingBefore readings waiting on phone",
                )
                rescheduleSoon(noInternetTickMs)
                return
            }

            updateNotification("Sending readings to office…")
            val native = NativeCloudUploader.uploadPending(ctx)
            Log.i(TAG, "native upload: ${native.message} uploaded=${native.uploaded} left=${native.pendingLeft}")
            if (native.uploaded > 0) {
                AuditStore.info(
                    ctx, "cloud", "Sent ${native.uploaded} readings to cloud (background)",
                    "left=${native.pendingLeft}",
                )
            }
            if (native.pendingLeft != 0) {
                AuditStore.once(
                    ctx, "upload_fail:${native.message}", LOG_REPEAT_MS, "warn", "cloud",
                    "Background upload incomplete: ${native.message}",
                    "left=${native.pendingLeft}",
                )
            }
            CloudReporter.report(ctx)

            updateNotification(
                when {
                    native.pendingLeft == 0 -> NOTIF_ALL_SENT
                    native.uploaded > 0 -> "Sending… ${native.pendingLeft} readings left"
                    else -> "Could not send yet. Will try again. Readings are safe."
                },
            )
            if (native.pendingLeft != 0) {
                rescheduleSoon(catchUpTickMs)
            }
            Log.i(TAG, "cycle done")
        } finally {
            NetworkBinder.releaseCellularRequest(applicationContext)
            if (releasedSoftAp) {
                // Only nudge WiFi back when we actually dropped SoftAP.
                resumeWifiAfterUpload()
                sleepQuiet(1_500)
            }
            // Free ESP queue only for readings the office already has.
            if (NetworkBinder.isOnGateway(applicationContext) || releasedSoftAp) {
                NetworkBinder.bindToGateway(applicationContext)
                EspAck.afterCloudUpload(applicationContext)
            }
        }
    }

    /** Wait until the Dart worker reports its SoftAP pull finished (or timeout). */
    private fun waitForWorkerPull(requestedAt: Long, timeoutMs: Long): Boolean {
        val deadline = requestedAt + timeoutMs
        while (SystemClock.elapsedRealtime() < deadline) {
            if (SyncLease.lastWorkerPullDoneAt >= requestedAt) return true
            sleepQuiet(500)
        }
        Log.w(TAG, "worker pull did not finish within ${timeoutMs}ms")
        return false
    }

    private fun rescheduleSoon(delayMs: Long) {
        handler.post {
            cancelNextAlarm()
            scheduleNextAlarm(delayMs)
        }
    }

    private fun resumeWifiAfterUpload() {
        try {
            NetworkBinder.ensureWifiRadioOn(applicationContext)
            val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            try {
                wifi.reconnect()
            } catch (_: Throwable) {
            }
        } catch (t: Throwable) {
            Log.w(TAG, "could not restore WiFi after upload", t)
        }
    }

    private fun scheduleNextAlarm(delayMs: Long = tickMs) {
        val am = getSystemService(ALARM_SERVICE) as AlarmManager
        val pi = tickPendingIntent()
        val triggerAt = SystemClock.elapsedRealtime() + delayMs
        try {
            val exactAllowed = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
                am.canScheduleExactAlarms()
            if (exactAllowed && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                am.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAt, pi)
                Log.i(TAG, "next tick in ${delayMs}ms (exact alarm)")
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                // Exact alarms revoked: inexact but still fires in Doze.
                am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAt, pi)
                Log.i(TAG, "next tick in ~${delayMs}ms (inexact alarm)")
            } else {
                @Suppress("DEPRECATION")
                am.setExact(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAt, pi)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "alarm failed, falling back to handler", t)
            handler.removeCallbacksAndMessages(null)
            handler.postDelayed({
                startCycle()
                scheduleNextAlarm(delayMs)
            }, delayMs)
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
            "Water level sending",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shows that readings are being saved and sent to the office"
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
        // No "Stop" button: a stray tap would silently halt station uploads.
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Water Level app is running")
            .setContentText(content)
            .setSmallIcon(R.drawable.ic_stat_water)
            .setContentIntent(pending)
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

        private const val LEASE_OWNER = "service"
        private const val LOG_REPEAT_MS = 30 * 60_000L
        private const val NOTIF_ALL_SENT = "All readings sent to office"

        @Volatile
        var isRunning = false
            private set
        private const val LEASE_TTL_MS = 4 * 60_000L

        /** Never throws: background-start limits must not crash the caller. */
        fun start(context: Context): Boolean {
            val intent = Intent(context, SiteSyncService::class.java)
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                true
            } catch (t: Throwable) {
                Log.w(TAG, "could not start site sync service", t)
                false
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, SiteSyncService::class.java))
        }
    }
}
