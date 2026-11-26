package com.waterlevel.app

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.net.Network
import android.util.Log
import org.json.JSONObject
import java.io.BufferedReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import kotlin.math.roundToInt

/**
 * Uploads pending SQLite readings to Firebase RTDB without Flutter.
 * Used by [SiteSyncService] when the UI process is swiped away — WorkManager's
 * Dart isolate often does not actually push in that state.
 */
object NativeCloudUploader {
    private const val TAG = "NativeCloudUploader"
    private const val API_KEY = "AIzaSyBHAQdfBcowfRfcEga0eqC95ADL-9KXtYM"
    internal const val DB_URL =
        "https://umiam-waterlevel-default-rtdb.asia-southeast1.firebasedatabase.app"
    internal const val STATION_ID = "station_001"
    // Chunk size keeps each RTDB PATCH under practical size/timeout limits.
    private const val BATCH = 100
    private const val AUTH_PREFS = "native_cloud_auth"
    private const val KEY_ID_TOKEN = "id_token"
    private const val KEY_REFRESH_TOKEN = "refresh_token"
    private const val KEY_EXPIRES_AT = "expires_at_ms"
    /** Refresh a few minutes early so a token never expires mid-upload. */
    private const val TOKEN_SKEW_MS = 5 * 60_000L

    data class Result(val uploaded: Int, val pendingLeft: Int, val message: String)

    internal class HttpResult(val code: Int, val body: String?)

    private class AuthExpired : Exception("auth token rejected")

    /** Pending row count, or -1 if the database could not be read. */
    fun pendingCount(context: Context): Int {
        val dbFile = context.getDatabasePath("water_level.db")
        if (!dbFile.exists()) return 0
        return try {
            SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READONLY).use {
                countPending(it)
            }
        } catch (t: Throwable) {
            Log.w(TAG, "pending count failed", t)
            -1
        }
    }

    @Synchronized
    fun uploadPending(context: Context): Result {
        NetworkBinder.bindToInternet(context)
        val dbFile = context.getDatabasePath("water_level.db")
        if (!dbFile.exists()) {
            return Result(0, 0, "No local database yet")
        }

        val db = try {
            SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READWRITE)
        } catch (t: Throwable) {
            Log.e(TAG, "cannot open database", t)
            return Result(0, -1, "Database busy")
        }
        try {
            val pending = countPending(db)
            if (pending == 0) {
                return Result(0, 0, "Nothing pending")
            }
            val network = NetworkBinder.internetNetwork(context)
            var token = idToken(context, network, forceRefresh = false)
                ?: return Result(0, pending, "Cloud sign-in failed (will retry)")

            val station = readStation(db)
            var cloudLatest = fetchCloudLatest(network, token)
            var uploaded = 0
            var rounds = 0
            while (rounds < 200) {
                rounds += 1
                val batch = readPending(db, BATCH)
                if (batch.isEmpty()) break
                val ok = try {
                    pushBatch(network, token, station, batch, cloudLatest)
                } catch (_: AuthExpired) {
                    token = idToken(context, network, forceRefresh = true)
                        ?: return Result(uploaded, countPending(db), "Cloud sign-in expired")
                    pushBatch(network, token, station, batch, cloudLatest)
                }
                if (ok == null) {
                    return Result(
                        uploaded,
                        countPending(db),
                        "RTDB write failed after $uploaded uploaded",
                    )
                }
                cloudLatest = ok
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
            try {
                db.close()
            } catch (_: Throwable) {
            }
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
            """
            SELECT name, calib_actual_mm, calib_raw_level_mm, calib_distance_mm
            FROM stations WHERE id=? LIMIT 1
            """.trimIndent(),
            arrayOf(STATION_ID),
        ).use { c ->
            if (c.moveToFirst()) {
                obj.put("name", c.getString(0) ?: "Umiam Dam")
                if (!c.isNull(1)) obj.put("calib_actual_mm", c.getInt(1))
                if (!c.isNull(2)) obj.put("calib_raw_level_mm", c.getInt(2))
                if (!c.isNull(3)) obj.put("calib_distance_mm", c.getInt(3))
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

    /** Current `water/latest` node so a backlog upload never moves it backwards. */
    private fun fetchCloudLatest(network: Network?, token: String): JSONObject? {
        return try {
            val res = http(network, "GET", "$DB_URL/water/latest/$STATION_ID.json?auth=$token", null)
            if (res.code !in 200..299) return null
            val body = res.body?.trim()
            if (body.isNullOrEmpty() || body == "null") null else JSONObject(body)
        } catch (t: Throwable) {
            Log.w(TAG, "latest fetch skipped", t)
            null
        }
    }

    /** Returns the newest reading now in the cloud, or null if the write failed. */
    private fun pushBatch(
        network: Network?,
        token: String,
        station: JSONObject,
        batch: List<JSONObject>,
        cloudLatest: JSONObject?,
    ): JSONObject? {
        val updates = JSONObject()
        var newest: JSONObject? = null
        val actual = if (station.has("calib_actual_mm")) station.getInt("calib_actual_mm") else null
        val refDist = if (station.has("calib_distance_mm")) station.getInt("calib_distance_mm") else null
        for (row in batch) {
            val key = row.getString("_key")
            val clean = JSONObject(row.toString())
            clean.remove("_key")
            // Preserve Node B raw level field; display water_level = actual + Δgap.
            if (clean.has("water_level_mm")) {
                val raw = clean.getInt("water_level_mm")
                clean.put("sensor_level_mm", raw)
                clean.put("sensor_level_m", metres(raw))
            }
            // Elevation stored as feet×1000; gap is true mm → Δft = Δmm / 304.8
            if (actual != null && refDist != null && clean.has("distance_mm")) {
                val deltaFt = (refDist - clean.getInt("distance_mm")) / 304.8
                val computed = (actual + deltaFt * 1000.0).roundToInt()
                clean.put("water_level_mm", computed)
                // Legacy field name: value is feet AMSL, not metres.
                clean.put("water_level_m", (computed / 1000.0 * 100.0).roundToInt() / 100.0)
            }
            updates.put("water/readings/$STATION_ID/$key", clean)
            newest = newer(newest, clean)
        }
        val latestAfter = if (newest == null) cloudLatest else newer(cloudLatest, newest)
        if (newest != null && latestAfter === newest) {
            updates.put("water/latest/$STATION_ID", newest)
        }
        station.put("last_updated", System.currentTimeMillis() / 1000)
        updates.put("water/stations/$STATION_ID", station)

        val res = http(network, "PATCH", "$DB_URL/.json?auth=$token", updates.toString())
        if (res.code == 401 || res.code == 403) throw AuthExpired()
        if (res.code !in 200..299) {
            Log.e(TAG, "RTDB PATCH HTTP ${res.code} ${res.body}")
            return null
        }
        return latestAfter
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

    /**
     * Cached anonymous identity. Creating a new anonymous user on every cycle
     * hits Firebase's sign-up quota within hours and silently stops uploads.
     */
    @Synchronized
    internal fun idToken(context: Context, network: Network?, forceRefresh: Boolean): String? {
        val prefs = context.getSharedPreferences(AUTH_PREFS, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        val cached = prefs.getString(KEY_ID_TOKEN, null)
        val expiresAt = prefs.getLong(KEY_EXPIRES_AT, 0L)
        if (!forceRefresh && cached != null && now < expiresAt - TOKEN_SKEW_MS) {
            return cached
        }

        val refresh = prefs.getString(KEY_REFRESH_TOKEN, null)
        if (refresh != null) {
            val res = try {
                http(
                    network,
                    "POST",
                    "https://securetoken.googleapis.com/v1/token?key=$API_KEY",
                    "grant_type=refresh_token&refresh_token=" + URLEncoder.encode(refresh, "UTF-8"),
                    contentType = "application/x-www-form-urlencoded",
                )
            } catch (t: Throwable) {
                Log.w(TAG, "token refresh network error", t)
                return null
            }
            if (res.code in 200..299) {
                val json = JSONObject(res.body ?: "{}")
                val id = json.optString("id_token").ifBlank { null }
                if (id != null) {
                    saveTokens(
                        prefs,
                        id,
                        json.optString("refresh_token").ifBlank { refresh },
                        json.optString("expires_in", "3600"),
                    )
                    return id
                }
            }
            // Only a definitive rejection discards the identity; transient
            // failures keep it so we never mint a new anonymous user needlessly.
            if (res.code != 400) {
                Log.w(TAG, "token refresh HTTP ${res.code}")
                return null
            }
            Log.w(TAG, "refresh token rejected — signing up again: ${res.body}")
        }

        val res = try {
            http(
                network,
                "POST",
                "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$API_KEY",
                """{"returnSecureToken":true}""",
            )
        } catch (t: Throwable) {
            Log.w(TAG, "sign-up network error", t)
            return null
        }
        if (res.code !in 200..299) {
            Log.e(TAG, "auth HTTP ${res.code} ${res.body}")
            return null
        }
        val json = JSONObject(res.body ?: "{}")
        val id = json.optString("idToken").ifBlank { null } ?: return null
        val newRefresh = json.optString("refreshToken").ifBlank { null } ?: return id
        saveTokens(prefs, id, newRefresh, json.optString("expiresIn", "3600"))
        return id
    }

    private fun saveTokens(
        prefs: android.content.SharedPreferences,
        idToken: String,
        refreshToken: String,
        expiresInSeconds: String,
    ) {
        val ttlMs = (expiresInSeconds.toLongOrNull() ?: 3600L) * 1000L
        prefs.edit()
            .putString(KEY_ID_TOKEN, idToken)
            .putString(KEY_REFRESH_TOKEN, refreshToken)
            .putLong(KEY_EXPIRES_AT, System.currentTimeMillis() + ttlMs)
            .apply()
    }

    internal fun http(
        network: Network?,
        method: String,
        url: String,
        body: String?,
        contentType: String = "application/json",
    ): HttpResult {
        val target = URL(url)
        val raw = network?.openConnection(target) ?: target.openConnection()
        val conn = raw as HttpURLConnection
        try {
            conn.connectTimeout = 15_000
            conn.readTimeout = 30_000
            conn.requestMethod = method
            if (body != null) {
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", contentType)
                OutputStreamWriter(conn.outputStream, Charsets.UTF_8).use { it.write(body) }
            }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            val text = stream?.bufferedReader()?.use(BufferedReader::readText)
            return HttpResult(code, text)
        } finally {
            conn.disconnect()
        }
    }
}
