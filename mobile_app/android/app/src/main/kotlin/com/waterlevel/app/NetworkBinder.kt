package com.waterlevel.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import java.net.Inet4Address

/**
 * SoftAP (WaterLevel / 192.168.4.x) has no real internet. While it is the
 * default route, Firebase uploads fail even if LTE is up. Bind the process to
 * a validated internet network (prefer cellular) before cloud upload.
 */
object NetworkBinder {
    @Volatile
    private var boundNetwork: Network? = null

    fun clearBinding(context: Context) {
        val cm = connectivity(context)
        cm.bindProcessToNetwork(null)
        boundNetwork = null
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
