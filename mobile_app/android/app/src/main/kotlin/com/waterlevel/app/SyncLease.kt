package com.waterlevel.app

import android.os.SystemClock

/**
 * Process-wide mutual exclusion for sync work. The UI isolate, the WorkManager
 * isolate and [SiteSyncService] all share one process-level network binding
 * (bindProcessToNetwork) and one SQLite file, so only one of them may run a
 * sync cycle at a time. Leases expire so a crashed holder can never wedge sync.
 */
object SyncLease {
    private var owner: String? = null
    private var expiresAt = 0L

    /** Elapsed-realtime of the last finished sensor pull from a Dart worker. */
    @Volatile
    var lastWorkerPullDoneAt = 0L
        private set

    @Synchronized
    fun tryAcquire(who: String, ttlMs: Long): Boolean {
        val now = SystemClock.elapsedRealtime()
        val current = owner
        if (current == null || current == who || now >= expiresAt) {
            owner = who
            expiresAt = now + ttlMs.coerceIn(5_000L, 10 * 60_000L)
            return true
        }
        return false
    }

    @Synchronized
    fun release(who: String) {
        if (owner == who) {
            owner = null
            expiresAt = 0L
        }
    }

    @Synchronized
    fun holder(): String? {
        if (owner != null && SystemClock.elapsedRealtime() >= expiresAt) {
            owner = null
            expiresAt = 0L
        }
        return owner
    }

    fun markWorkerPullDone() {
        lastWorkerPullDoneAt = SystemClock.elapsedRealtime()
    }
}
