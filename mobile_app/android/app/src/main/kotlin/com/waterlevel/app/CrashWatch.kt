package com.waterlevel.app

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Makes crashes, freezes and "phone killed the app" events visible to the
 * office: they are written to the audit log, which [CloudReporter] uploads.
 */
object CrashWatch {
    private const val PREFS = "crash_watch"
    private const val KEY_LAST_EXIT = "last_exit_ts"

    @Volatile
    private var installed = false

    /** Records an uncaught JVM exception before the process dies. */
    @Synchronized
    fun install(context: Context) {
        if (installed) return
        installed = true
        val app = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                val stack = error.stackTrace.take(12).joinToString("\n") { "  at $it" }
                AuditStore.error(
                    app,
                    "app",
                    "App crashed",
                    "${error.javaClass.name}: ${error.message}\nthread=${thread.name}\n$stack",
                )
            } catch (_: Throwable) {
            }
            previous?.uncaughtException(thread, error)
        }
    }

    /**
     * Android 11+ keeps the reason for each past process exit. Logs the ones
     * not seen before, so ANRs, native crashes and OEM battery kills show up.
     */
    @Synchronized
    fun reportPastExits(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val app = context.applicationContext
        try {
            val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val lastSeen = prefs.getLong(KEY_LAST_EXIT, 0L)
            val am = app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val exits = am.getHistoricalProcessExitReasons(null, 0, 10)
                .filter { it.timestamp > lastSeen }
                .sortedBy { it.timestamp }
            if (exits.isEmpty()) return
            prefs.edit().putLong(KEY_LAST_EXIT, exits.last().timestamp).apply()
            // First run after install: older history is not useful.
            if (lastSeen == 0L) return
            val fmt = SimpleDateFormat("dd MMM HH:mm:ss", Locale.US)
            for (exit in exits) {
                val (level, message) = describe(exit.reason) ?: continue
                val detail = buildString {
                    append("at ").append(fmt.format(Date(exit.timestamp)))
                    exit.description?.takeIf { it.isNotBlank() }?.let { append(" · ").append(it) }
                    append(" · importance=").append(exit.importance)
                }
                when (level) {
                    "error" -> AuditStore.error(app, "app", message, detail)
                    "warn" -> AuditStore.warn(app, "app", message, detail)
                    else -> AuditStore.info(app, "app", message, detail)
                }
            }
        } catch (_: Throwable) {
            // Diagnostics only.
        }
    }

    private fun describe(reason: Int): Pair<String, String>? = when (reason) {
        ApplicationExitInfo.REASON_ANR -> "error" to "App froze (not responding)"
        ApplicationExitInfo.REASON_CRASH -> "error" to "App crashed (reported by Android)"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "error" to "App crashed (native)"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "error" to "App failed to start"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "warn" to "Phone closed the app (low memory)"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE ->
            "warn" to "Phone closed the app (battery/CPU limit)"
        ApplicationExitInfo.REASON_SIGNALED -> "warn" to "Phone closed the app (system kill)"
        ApplicationExitInfo.REASON_OTHER -> "warn" to "Phone closed the app"
        ApplicationExitInfo.REASON_USER_REQUESTED ->
            "warn" to "App was force-stopped (Settings or phone cleaner)"
        ApplicationExitInfo.REASON_USER_STOPPED -> "warn" to "App was stopped by the user"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE ->
            "info" to "App restarted after a permission change"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "info" to "App restarted (dependency closed)"
        ApplicationExitInfo.REASON_EXIT_SELF -> null
        else -> "info" to "App process ended (reason $reason)"
    }
}
