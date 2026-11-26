package com.waterlevel.app

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.os.SystemClock
import android.util.Log

/**
 * Writes background-service events into the app's `audit_log` table so they
 * reach the office through [CloudReporter] like every other app log line.
 */
object AuditStore {
    private const val TAG = "AuditStore"
    private val lastLoggedAt = HashMap<String, Long>()

    fun info(context: Context, category: String, message: String, detail: String? = null) =
        write(context, "info", category, message, detail)

    fun warn(context: Context, category: String, message: String, detail: String? = null) =
        write(context, "warn", category, message, detail)

    fun error(context: Context, category: String, message: String, detail: String? = null) =
        write(context, "error", category, message, detail)

    /**
     * Logs [message] at most once per [minGapMs] for the same [key], so a
     * condition that repeats every cycle (e.g. "no internet") cannot flood logs.
     */
    fun once(
        context: Context,
        key: String,
        minGapMs: Long,
        level: String,
        category: String,
        message: String,
        detail: String? = null,
    ) {
        val now = SystemClock.elapsedRealtime()
        synchronized(lastLoggedAt) {
            val last = lastLoggedAt[key]
            if (last != null && now - last < minGapMs) return
            lastLoggedAt[key] = now
        }
        write(context, level, category, message, detail)
    }

    private fun write(
        context: Context,
        level: String,
        category: String,
        message: String,
        detail: String?,
    ) {
        Log.i(TAG, "[$level/$category] $message ${detail.orEmpty()}")
        val dbFile = context.getDatabasePath("water_level.db")
        if (!dbFile.exists()) return
        try {
            SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READWRITE).use { db ->
                val values = ContentValues().apply {
                    put("created_at", System.currentTimeMillis())
                    put("level", level)
                    put("category", category)
                    put("message", message)
                    if (detail != null) put("detail", detail.take(1000))
                }
                db.insert("audit_log", null, values)
            }
        } catch (t: Throwable) {
            // Logging must never break sync (e.g. storage full, table missing).
            Log.w(TAG, "audit insert failed", t)
        }
    }
}
