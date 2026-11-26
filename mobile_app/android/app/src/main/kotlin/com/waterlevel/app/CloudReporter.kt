package com.waterlevel.app

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.os.SystemClock
import android.util.Log
import org.json.JSONObject

/**
 * Sends this phone's status ("heartbeat") and its app logs to Firebase so the
 * office can see every field phone:
 *   water/devices/{deviceId}         latest status of the phone
 *   water/logs/{deviceId}/{logKey}   log lines from that phone
 * Uses an explicit internet Network, so it never disturbs the SoftAP binding.
 */
object CloudReporter {
    private const val TAG = "CloudReporter"
    private const val MIN_GAP_MS = 60_000L
    private const val FORCED_MIN_GAP_MS = 15_000L
    private const val LOG_BATCH = 300
    private const val MAX_BATCHES = 4

    @Volatile
    private var lastReportAt = 0L

    @Synchronized
    fun report(context: Context, force: Boolean = false) {
        val app = context.applicationContext
        val now = SystemClock.elapsedRealtime()
        val gap = if (force) FORCED_MIN_GAP_MS else MIN_GAP_MS
        if (lastReportAt != 0L && now - lastReportAt < gap) return
        val network = NetworkBinder.internetNetwork(app) ?: return
        lastReportAt = now

        val dbFile = app.getDatabasePath("water_level.db")
        if (!dbFile.exists()) return
        try {
            val token = NativeCloudUploader.idToken(app, network, forceRefresh = false) ?: return
            val deviceId = DeviceInfo.deviceId(app)
            SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READWRITE).use { db ->
                for (round in 0 until MAX_BATCHES) {
                    val logs = readPendingLogs(db)
                    val updates = JSONObject()
                    if (round == 0) {
                        updates.put("water/devices/$deviceId", heartbeat(app, db))
                    }
                    for (row in logs) {
                        updates.put("water/logs/$deviceId/${row.key}", row.json)
                    }
                    if (updates.length() == 0) break
                    val res = NativeCloudUploader.http(
                        network,
                        "PATCH",
                        "${NativeCloudUploader.DB_URL}/.json?auth=$token",
                        updates.toString(),
                    )
                    if (res.code !in 200..299) {
                        Log.w(TAG, "report HTTP ${res.code} ${res.body}")
                        return
                    }
                    if (logs.isEmpty()) break
                    markLogsUploaded(db, logs.maxOf { it.id })
                    if (logs.size < LOG_BATCH) break
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "report failed", t)
        }
    }

    private class LogRow(val id: Long, val key: String, val json: JSONObject)

    private fun readPendingLogs(db: SQLiteDatabase): List<LogRow> {
        val out = ArrayList<LogRow>()
        try {
            db.rawQuery(
                """
                SELECT id, created_at, level, category, message, detail
                FROM audit_log WHERE cloud_uploaded = 0
                ORDER BY id ASC LIMIT $LOG_BATCH
                """.trimIndent(),
                null,
            ).use { c ->
                while (c.moveToNext()) {
                    val id = c.getLong(0)
                    val createdAt = c.getLong(1)
                    val json = JSONObject()
                        .put("created_at", createdAt)
                        .put("level", c.getString(2) ?: "info")
                        .put("category", c.getString(3) ?: "app")
                        .put("message", c.getString(4) ?: "")
                    if (!c.isNull(5)) json.put("detail", c.getString(5).take(1000))
                    out.add(LogRow(id, "${createdAt}_$id", json))
                }
            }
        } catch (t: Throwable) {
            // Column appears once the app has opened after the update.
            Log.i(TAG, "logs not ready: ${t.message}")
        }
        return out
    }

    private fun markLogsUploaded(db: SQLiteDatabase, upToId: Long) {
        db.execSQL(
            "UPDATE audit_log SET cloud_uploaded = 1 WHERE cloud_uploaded = 0 AND id <= ?",
            arrayOf<Any>(upToId),
        )
    }

    private fun heartbeat(context: Context, db: SQLiteDatabase): JSONObject {
        val json = JSONObject()
        for ((k, v) in DeviceInfo.snapshot(context)) json.put(k, v ?: JSONObject.NULL)
        json.put("station_id", NativeCloudUploader.STATION_ID)
        json.put("last_seen_phone", System.currentTimeMillis())
        json.put("last_seen", JSONObject().put(".sv", "timestamp"))
        json.put("on_sensor_wifi", NetworkBinder.isOnGateway(context))
        json.put("service_running", SiteSyncService.isRunning)
        try {
            db.rawQuery(
                """
                SELECT MAX(measurement_time),
                       MAX(CASE WHEN firebase_uploaded = 1 THEN measurement_time END),
                       SUM(CASE WHEN firebase_uploaded = 0 AND is_simulated = 0 THEN 1 ELSE 0 END)
                FROM readings WHERE station_id = ?
                """.trimIndent(),
                arrayOf(NativeCloudUploader.STATION_ID),
            ).use { c ->
                if (c.moveToFirst()) {
                    if (!c.isNull(0)) json.put("newest_reading_on_phone", c.getLong(0))
                    if (!c.isNull(1)) json.put("newest_reading_in_cloud", c.getLong(1))
                    json.put("readings_waiting", if (c.isNull(2)) 0 else c.getInt(2))
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "reading stats failed", t)
        }
        return json
    }
}
