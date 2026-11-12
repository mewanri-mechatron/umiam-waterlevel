package com.waterlevel.app

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import org.json.JSONObject
import java.io.BufferedReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.roundToInt

/**
 * Uploads pending SQLite readings to Firebase RTDB without Flutter.
 * Used by [SiteSyncService] when the UI process is swiped away — WorkManager's
 * Dart isolate often does not actually push in that state.
 */
object NativeCloudUploader {
    private const val TAG = "NativeCloudUploader"
    private const val API_KEY = "AIzaSyBHAQdfBcowfRfcEga0eqC95ADL-9KXtYM"
    private const val DB_URL =
        "https://umiam-waterlevel-default-rtdb.asia-southeast1.firebasedatabase.app"
    private const val STATION_ID = "station_001"
    private const val BATCH = 40

    data class Result(val uploaded: Int, val pendingLeft: Int, val message: String)

    fun uploadPending(context: Context): Result {
        NetworkBinder.bindToInternet(context)
        val dbFile = context.getDatabasePath("water_level.db")
        if (!dbFile.exists()) {
            return Result(0, 0, "No local database yet")
        }

        val db = SQLiteDatabase.openDatabase(
            dbFile.path,
            null,
            SQLiteDatabase.OPEN_READWRITE,
        )
        try {
            val pending = countPending(db)
            if (pending == 0) {
                return Result(0, 0, "Nothing pending")
            }
            val token = signInAnonymously()
                ?: return Result(0, pending, "Anonymous auth failed")

            val station = readStation(db)
            var uploaded = 0
            var rounds = 0
            while (rounds < 12) {
                rounds += 1
                val batch = readPending(db, BATCH)
                if (batch.isEmpty()) break
                val ok = pushBatch(token, station, batch)
                if (!ok) {
                    return Result(
                        uploaded,
                        countPending(db),
                        "RTDB write failed after $uploaded uploaded",
                    )
                }
                markUploaded(db, batch)
                uploaded += batch.size
            }
            val left = countPending(db)
            Log.i(TAG, "native upload done uploaded=$uploaded pendingLeft=$left")
            return Result(uploaded, left, "Uploaded $uploaded")
        } catch (t: Throwable) {
            Log.e(TAG, "native upload error", t)
            return Result(0, -1, t.message ?: "upload error")
        } finally {
            db.close()
        }
    }

    private fun countPending(db: SQLiteDatabase): Int {
        db.rawQuery(
            "SELECT COUNT(*) FROM readings WHERE station_id=? AND firebase_uploaded=0 AND is_simulated=0",
            arrayOf(STATION_ID),
        ).use { c ->
            return if (c.moveToFirst()) c.getInt(0) else 0
        }
    }

    private fun readStation(db: SQLiteDatabase): JSONObject {
        val obj = JSONObject()
            .put("name", "Umiam Dam")
            .put("last_updated", System.currentTimeMillis() / 1000)
        db.rawQuery(
            "SELECT name, mount_height_mm FROM stations WHERE id=? LIMIT 1",
            arrayOf(STATION_ID),
        ).use { c ->
            if (c.moveToFirst()) {
                obj.put("name", c.getString(0) ?: "Umiam Dam")
                if (!c.isNull(1)) obj.put("mount_height_mm", c.getInt(1))
            }
        }
        return obj
    }

    private fun readPending(db: SQLiteDatabase, limit: Int): List<JSONObject> {
        val out = ArrayList<JSONObject>()
        db.rawQuery(
            """
            SELECT boot_id, seq, measurement_time, received_time, age_seconds,
                   distance_mm, water_level_mm, status, valid_samples, send_interval_seconds
            FROM readings
            WHERE station_id=? AND firebase_uploaded=0 AND is_simulated=0
            ORDER BY measurement_time ASC
            LIMIT $limit
            """.trimIndent(),
            arrayOf(STATION_ID),
        ).use { c ->
            val iBoot = c.getColumnIndexOrThrow("boot_id")
            val iSeq = c.getColumnIndexOrThrow("seq")
            val iMeas = c.getColumnIndexOrThrow("measurement_time")
            val iRecv = c.getColumnIndexOrThrow("received_time")
            val iAge = c.getColumnIndexOrThrow("age_seconds")
            val iDist = c.getColumnIndexOrThrow("distance_mm")
            val iLevel = c.getColumnIndexOrThrow("water_level_mm")
            val iStatus = c.getColumnIndexOrThrow("status")
            val iSamples = c.getColumnIndexOrThrow("valid_samples")
            val iInterval = c.getColumnIndexOrThrow("send_interval_seconds")
            while (c.moveToNext()) {
                val boot = c.getInt(iBoot)
                val seq = c.getInt(iSeq)
                val uploadedAt = System.currentTimeMillis() / 1000
                val row = JSONObject()
                    .put("boot_id", boot)
                    .put("seq", seq)
                    .put("measurement_time", c.getLong(iMeas))
                    .put("received_time", c.getLong(iRecv))
                    .put("age_seconds", c.getInt(iAge))
                    .put("status", c.getInt(iStatus))
                    .put("valid_samples", c.getInt(iSamples))
                    .put("send_interval_seconds", c.getInt(iInterval))
                    .put("uploaded_at", uploadedAt)
                    .put("_key", "${boot}_$seq")
                if (!c.isNull(iDist)) {
                    val mm = c.getInt(iDist)
                    if (mm != 0xFFFF) {
                        row.put("distance_mm", mm)
                        row.put("distance_m", metres(mm))
                    }
                }
                if (!c.isNull(iLevel)) {
                    val mm = c.getInt(iLevel)
                    if (mm != 0xFFFF) {
                        row.put("water_level_mm", mm)
                        row.put("water_level_m", metres(mm))
                    }
                }
                out.add(row)
            }
        }
        return out
    }

    private fun markUploaded(db: SQLiteDatabase, batch: List<JSONObject>) {
        db.beginTransaction()
        try {
            for (row in batch) {
                val args = arrayOf<Any>(
                    STATION_ID,
                    row.getInt("boot_id"),
                    row.getInt("seq"),
                )
                db.execSQL(
                    "UPDATE readings SET firebase_uploaded=1 WHERE station_id=? AND boot_id=? AND seq=?",
                    args,
                )
            }
            db.setTransactionSuccessful()
        } finally {
            db.endTransaction()
        }
    }

    private fun pushBatch(
        token: String,
        station: JSONObject,
        batch: List<JSONObject>,
    ): Boolean {
        val updates = JSONObject()
        var newest: JSONObject? = null
        for (row in batch) {
            val key = row.getString("_key")
            val clean = JSONObject(row.toString())
            clean.remove("_key")
            updates.put("water/readings/$STATION_ID/$key", clean)
            newest = newer(newest, clean)
        }
        if (newest != null) {
            updates.put("water/latest/$STATION_ID", newest)
        }
        station.put("last_updated", System.currentTimeMillis() / 1000)
        updates.put("water/stations/$STATION_ID", station)

        val url = URL("$DB_URL/.json?auth=$token")
        val conn = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "PATCH"
            connectTimeout = 20000
            readTimeout = 30000
            doOutput = true
            setRequestProperty("Content-Type", "application/json")
        }
        try {
            OutputStreamWriter(conn.outputStream).use { it.write(updates.toString()) }
            val code = conn.responseCode
            if (code !in 200..299) {
                val err = (conn.errorStream ?: conn.inputStream)?.bufferedReader()?.use(BufferedReader::readText)
                Log.e(TAG, "RTDB PATCH HTTP $code $err")
                return false
            }
            return true
        } finally {
            conn.disconnect()
        }
    }

    private fun newer(a: JSONObject?, b: JSONObject): JSONObject {
        if (a == null) return b
        val at = a.optLong("measurement_time")
        val bt = b.optLong("measurement_time")
        if (bt != at) return if (bt > at) b else a
        val ab = a.optInt("boot_id")
        val bb = b.optInt("boot_id")
        if (bb != ab) return if (bb > ab) b else a
        return if (b.optInt("seq") >= a.optInt("seq")) b else a
    }

    private fun metres(mm: Int): Double {
        return (mm / 1000.0 * 100.0).roundToInt() / 100.0
    }

    private fun signInAnonymously(): String? {
        val url = URL(
            "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$API_KEY",
        )
        val conn = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 15000
            readTimeout = 15000
            doOutput = true
            setRequestProperty("Content-Type", "application/json")
        }
        try {
            OutputStreamWriter(conn.outputStream).use {
                it.write("""{"returnSecureToken":true}""")
            }
            val code = conn.responseCode
            val body = (if (code in 200..299) conn.inputStream else conn.errorStream)
                ?.bufferedReader()?.use(BufferedReader::readText)
            if (code !in 200..299) {
                Log.e(TAG, "auth HTTP $code $body")
                return null
            }
            return JSONObject(body ?: "{}").optString("idToken").ifBlank { null }
        } finally {
            conn.disconnect()
        }
    }
}
