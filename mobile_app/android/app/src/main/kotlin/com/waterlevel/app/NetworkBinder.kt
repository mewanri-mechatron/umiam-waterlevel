package com.waterlevel.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import java.net.Inet4Address
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * SoftAP (WaterLevel / 192.168.4.x) has no real internet. While it is the
 * default route, Firebase uploads fail even if LTE is up. Bind the process to
 * a validated internet network (prefer cellular) before cloud upload.
 *
 * Never turn the WiFi radio off — that left field phones stuck offline.
 */
object NetworkBinder {
    private const val TAG = "NetworkBinder"

    @Volatile
    private var boundNetwork: Network? = null

    fun clearBinding(context: Context) {
        val cm = connectivity(context)
        cm.bindProcessToNetwork(null)
        boundNetwork = null
    }

    /** Keep WiFi radio on. Returns true if already on or enable succeeded. */
    fun ensureWifiRadioOn(context: Context): Boolean {
        return try {
            val wifi =
                context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            if (wifi.isWifiEnabled) return true
            // Apps may toggle WiFi only below Android 10.
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                @Suppress("DEPRECATION")
                return wifi.setWifiEnabled(true)
            }
            false
        } catch (t: Throwable) {
            Log.w(TAG, "ensureWifiRadioOn failed", t)
            false
        }
    }

    fun isWifiRadioOn(context: Context): Boolean {
        return try {
            val wifi =
                context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            wifi.isWifiEnabled
        } catch (_: Throwable) {
            true
        }
    }

    /**
     * Drop the current SoftAP association without powering WiFi off, so LTE
     * can become the default route. WiFi radio stays enabled.
     */
    fun softDisconnectWifi(context: Context): Boolean {
        return try {
            clearBinding(context)
            val wifi =
                context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            wifi.disconnect()
            true
        } catch (t: Throwable) {
            Log.w(TAG, "softDisconnectWifi failed", t)
            false
        }
    }

    @Volatile
    private var cellularCallback: ConnectivityManager.NetworkCallback? = null

    /**
     * Ask Android for a cellular route and bind this process to it. The request
     * stays registered (so LTE is not torn down mid-upload) until
     * [releaseCellularRequest] is called.
     */
    @Synchronized
    fun requestAndBindCellular(context: Context, timeoutMs: Long = 8_000L): Boolean {
        if (bindToInternet(context) && hasValidatedInternet(context)) return true

        releaseCellularRequest(context)
        val cm = connectivity(context)
        val latch = CountDownLatch(1)
        val ok = AtomicBoolean(false)
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (cm.bindProcessToNetwork(network)) {
                    boundNetwork = network
                    ok.set(true)
                }
                latch.countDown()
            }

            override fun onUnavailable() {
                latch.countDown()
            }
        }
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        return try {
            cm.requestNetwork(request, callback)
            cellularCallback = callback
            latch.await(timeoutMs, TimeUnit.MILLISECONDS)
            val bound = ok.get() || (bindToInternet(context) && hasValidatedInternet(context))
            if (!bound) releaseCellularRequest(context)
            bound
        } catch (t: Throwable) {
            Log.w(TAG, "requestAndBindCellular failed", t)
            releaseCellularRequest(context)
            bindToInternet(context) && hasValidatedInternet(context)
        }
    }

    fun releaseCellularRequest(context: Context) {
        val callback = cellularCallback ?: return
        cellularCallback = null
        try {
            connectivity(context).unregisterNetworkCallback(callback)
        } catch (_: Throwable) {
        }
    }

    /**
     * Network to use for cloud HTTP: the bound one when it has internet, else
     * any validated non-SoftAP network. Opening sockets on an explicit Network
     * keeps uploads working even if another component rebinds the process.
     */
    /** SoftAP Network for HTTP to 192.168.4.1 without disturbing process binding. */
    fun gatewayNetwork(context: Context): Network? {
        val cm = connectivity(context)
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
            if (isSoftApNetwork(context, network, caps)) return network
        }
        boundNetwork?.let { net ->
            val caps = cm.getNetworkCapabilities(net) ?: return@let
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                (isSoftApNetwork(context, net, caps) || isLocalOnlyWifi(caps))
            ) {
                return net
            }
        }
        return null
    }

    fun internetNetwork(context: Context): Network? {
        val cm = connectivity(context)
        boundNetwork?.let { net ->
            val caps = cm.getNetworkCapabilities(net)
            if (caps != null &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                !isSoftApNetwork(context, net, caps) &&
                !isLocalOnlyWifi(caps)
            ) {
                return net
            }
        }
        var fallback: Network? = null
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
            if (isSoftApNetwork(context, network, caps) || isLocalOnlyWifi(caps)) continue
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) return network
            if (fallback == null && caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
                fallback = network
            }
        }
        return fallback
    }

    fun bindToGateway(context: Context): Boolean {
        val cm = connectivity(context)
        // Prefer SoftAP subnet / SSID match.
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
            if (isSoftApNetwork(context, network, caps) && cm.bindProcessToNetwork(network)) {
                boundNetwork = network
                return true
            }
        }
        // Local-only WiFi (WifiNetworkSpecifier SoftAP has no INTERNET capability).
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
            if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
            ) {
                continue
            }
            if (cm.bindProcessToNetwork(network)) {
                boundNetwork = network
                return true
            }
        }
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
            if (cm.bindProcessToNetwork(network)) {
                boundNetwork = network
                return true
            }
        }
        return false
    }

    /** Bind to a validated internet path that is NOT the SoftAP. */
    fun bindToInternet(context: Context): Boolean {
        val cm = connectivity(context)
        // Prefer validated cellular.
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) continue
            if (cm.bindProcessToNetwork(network)) {
                boundNetwork = network
                return true
            }
        }
        // Cellular present but not yet VALIDATED (common right after SoftAP).
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
            if (cm.bindProcessToNetwork(network)) {
                boundNetwork = network
                return true
            }
        }
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) continue
            if (isSoftApNetwork(context, network, caps)) continue
            if (isLocalOnlyWifi(caps)) continue
            if (cm.bindProcessToNetwork(network)) {
                boundNetwork = network
                return true
            }
        }
        // Do NOT clearProcessBinding — that drops WifiNetworkSpecifier SoftAP.
        return hasValidatedInternet(context)
    }

    fun hasValidatedInternet(context: Context): Boolean {
        val cm = connectivity(context)
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) continue
            if (isSoftApNetwork(context, network, caps)) continue
            if (isLocalOnlyWifi(caps)) continue
            return true
        }
        return false
    }

    fun isOnGateway(context: Context): Boolean {
        // Strict: only WaterLevel SoftAP (SSID and/or 192.168.4.x).
        // Do NOT treat generic unvalidated / local-only WiFi as the sensor —
        // that made the home screen show "Connected" on normal WiFi.
        if (wifiManagerLooksLikeSoftAp(context)) return true

        val ssid = currentSsid(context)
        if (ssid != null && ssid.equals(MainActivity.DEFAULT_SSID, ignoreCase = true)) {
            return true
        }
        val cm = connectivity(context)
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
            if (isSoftApNetwork(context, network, caps)) return true
        }
        return false
    }

    /** SoftAP DHCP is always 192.168.4.x for this project. */
    private fun wifiManagerLooksLikeSoftAp(context: Context): Boolean {
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        val info = wifi.connectionInfo
        val ssid = normalizeSsid(info?.ssid)
        if (ssid != null && ssid.equals(MainActivity.DEFAULT_SSID, ignoreCase = true)) {
            return true
        }
        @Suppress("DEPRECATION")
        val ip = info?.ipAddress ?: 0
        if (ip != 0 && isSoftApIpv4LittleEndian(ip)) return true
        @Suppress("DEPRECATION")
        val gateway = wifi.dhcpInfo?.gateway ?: 0
        if (gateway != 0 && isSoftApIpv4LittleEndian(gateway)) return true
        return false
    }

    private fun isSoftApIpv4LittleEndian(ip: Int): Boolean {
        val a = ip and 0xff
        val b = (ip shr 8) and 0xff
        val c = (ip shr 16) and 0xff
        return a == 192 && b == 168 && c == 4
    }

    fun currentSsid(context: Context): String? {
        val cm = connectivity(context)
        val networks = mutableListOf<Network>()
        cm.activeNetwork?.let { networks.add(it) }
        networks.addAll(cm.allNetworks)
        for (network in networks.distinct()) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val info = caps.transportInfo as? WifiInfo
                normalizeSsid(info?.ssid)?.let { return it }
            }
        }
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        return normalizeSsid(wifi.connectionInfo?.ssid)
    }

    fun wifiDiagnostics(context: Context): Map<String, Any?> {
        val ips = ipv4Addresses(context)
        val ssid = currentSsid(context)
        return mapOf(
            "ssid" to ssid,
            "ipv4" to ips,
            "onGatewaySubnet" to ips.any { it.startsWith("192.168.4.") },
            "gatewaySsidMatch" to (
                ssid != null && ssid.equals(MainActivity.DEFAULT_SSID, ignoreCase = true)
            ),
            "hasValidatedInternet" to hasValidatedInternet(context),
            "onGateway" to isOnGateway(context),
            "localOnlyWifi" to hasLocalOnlyWifi(context),
        )
    }

    private fun hasLocalOnlyWifi(context: Context): Boolean {
        val cm = connectivity(context)
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
            if (isLocalOnlyWifi(caps)) return true
        }
        return false
    }

    private fun isLocalOnlyWifi(caps: NetworkCapabilities): Boolean {
        if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return false
        return !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    private fun isSoftApNetwork(
        context: Context,
        network: Network,
        caps: NetworkCapabilities,
    ): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val info = caps.transportInfo as? WifiInfo
            val ssid = normalizeSsid(info?.ssid)
            if (ssid != null && ssid.equals(MainActivity.DEFAULT_SSID, ignoreCase = true)) {
                return true
            }
        }
        val cm = connectivity(context)
        val props = cm.getLinkProperties(network) ?: return false
        return props.linkAddresses.any {
            val a = it.address
            a is Inet4Address && (a.hostAddress?.startsWith("192.168.4.") == true)
        }
    }

    private fun ipv4Addresses(context: Context): List<String> {
        val cm = connectivity(context)
        val out = mutableListOf<String>()
        val networks = mutableListOf<Network>()
        cm.activeNetwork?.let { networks.add(it) }
        networks.addAll(cm.allNetworks)
        for (network in networks.distinct()) {
            val props = cm.getLinkProperties(network) ?: continue
            for (addr in props.linkAddresses) {
                val ip = addr.address
                if (ip is Inet4Address && !ip.isLoopbackAddress) {
                    out.add(ip.hostAddress ?: continue)
                }
            }
        }
        return out.distinct()
    }

    private fun normalizeSsid(raw: String?): String? {
        if (raw.isNullOrBlank()) return null
        var ssid = raw
        if (ssid == "<unknown ssid>") return null
        if (ssid.startsWith("\"") && ssid.endsWith("\"") && ssid.length >= 2) {
            ssid = ssid.substring(1, ssid.length - 1)
        }
        return ssid.ifBlank { null }
    }

    private fun connectivity(context: Context): ConnectivityManager =
        context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
}
