package com.waterlevel.app

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.net.Network
import android.util.Log
import java.net.HttpURLConnection
import java.net.URL

/**
 * Tells Node B it may delete queue rows the office already has.
 *
 * Never ACKs past an unsent reading: `/ack?upto=N` deletes every ESP record
 * with id ≤ N, so we only advance N when every local row with
 * gateway_record_id ≤ N is already in the cloud.
 */
object EspAck {
    private const val TAG = "EspAck"
    private const val STATION_ID = NativeCloudUploader.STATION_ID
    private const val ACK_URL = "http://192.168.4.1/ack"

    /**
     * Call after a successful cloud upload, while (or after reconnecting to)
     * the sensor WiFi. No-op when offline from the SoftAP or when nothing is
     * safe to ACK yet.
     */
    @Synchronized
    fun afterCloudUpload(context: Context) {
        if (!NetworkBinder.isOnGateway(context)) return
        val dbFile = context.getDatabasePath("water_level.db")
        if (!dbFile.exists()) return
        try {
            SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READWRITE).use { db ->
                val upTo = safeAckUpTo(db) ?: return
                val last = lastAckId(db)
                // Skip only exact duplicates; allow upTo < last after id reset.
                if (upTo == last) return
                val network = NetworkBinder.gatewayNetwork(context) ?: return
                if (!httpAck(network, upTo)) return
                setLastAckId(db, upTo)
                Log.i(TAG, "ESP ACK upto=$upTo (was $last)")
                AuditStore.info(
                    context,
                    "sensor",
                    "Told sensor it may free readings already at office",
                    "ack_upto=$upTo",
                )
            }
        } catch (t: Throwable) {
            Log.w(TAG, "ESP ACK skipped", t)
        }
    }

    private fun safeAckUpTo(db: SQLiteDatabase): Int? {
        db.rawQuery(
            """
            SELECT MIN(gateway_record_id) FROM readings
            WHERE station_id=? AND gateway_record_id IS NOT NULL
              AND firebase_uploaded=0 AND is_simulated=0
            """.trimIndent(),
            arrayOf(STATION_ID),
        ).use { c ->
            if (c.moveToFirst() && !c.isNull(0)) {
                val upTo = c.getInt(0) - 1
                return if (upTo > 0) upTo else null
            }
        }
        db.rawQuery(
            """
            SELECT MAX(gateway_record_id) FROM readings
            WHERE station_id=? AND gateway_record_id IS NOT NULL
              AND firebase_uploaded=1
            """.trimIndent(),
            arrayOf(STATION_ID),
        ).use { c ->
            if (c.moveToFirst() && !c.isNull(0)) return c.getInt(0)
        }
        return null
    }

    private fun lastAckId(db: SQLiteDatabase): Int {
        db.rawQuery(
            "SELECT last_esp_ack_id FROM sync_state WHERE station_id=? LIMIT 1",
            arrayOf(STATION_ID),
        ).use { c ->
            return if (c.moveToFirst() && !c.isNull(0)) c.getInt(0) else 0
        }
    }

    private fun setLastAckId(db: SQLiteDatabase, upTo: Int) {
        try {
            // Absolute set so a gateway id wrap/reset can move the watermark down.
            db.execSQL(
                "UPDATE sync_state SET last_esp_ack_id=? WHERE station_id=?",
                arrayOf<Any>(upTo, STATION_ID),
            )
        } catch (t: Throwable) {
            // Column appears after the app opens once (DB v5 migration).
            Log.i(TAG, "last_esp_ack_id not ready: ${t.message}")
        }
    }

    private fun httpAck(network: Network, upTo: Int): Boolean {
        return try {
            val url = URL("$ACK_URL?upto=$upTo")
            val conn = network.openConnection(url) as HttpURLConnection
            conn.connectTimeout = 8_000
            conn.readTimeout = 8_000
            conn.requestMethod = "GET"
            conn.useCaches = false
            val code = conn.responseCode
            conn.disconnect()
            code in 200..299
        } catch (t: Throwable) {
            Log.w(TAG, "ACK HTTP failed", t)
            false
        }
    }
}
