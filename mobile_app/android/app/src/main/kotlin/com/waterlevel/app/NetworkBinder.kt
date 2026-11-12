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
        // Prefer SoftAP subnet.
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
            if (isSoftApNetwork(context, network, caps) && cm.bindProcessToNetwork(network)) {
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
        // Prefer cellular with validated internet.
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
        // Any other validated internet network that is not SoftAP.
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) continue
            if (isSoftApNetwork(context, network, caps)) continue
            if (cm.bindProcessToNetwork(network)) {
                boundNetwork = network
                return true
            }
        }
        // Last resort: clear SoftAP sticky bind and hope the system picks LTE.
        clearBinding(context)
        return hasValidatedInternet(context)
    }

    fun hasValidatedInternet(context: Context): Boolean {
        val cm = connectivity(context)
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) continue
            if (isSoftApNetwork(context, network, caps)) continue
            return true
        }
        return false
    }

    fun isOnGateway(context: Context): Boolean {
        val ssid = currentSsid(context)
        if (ssid == MainActivity.DEFAULT_SSID) return true
        val cm = connectivity(context)
        for (network in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (isSoftApNetwork(context, network, caps)) return true
        }
        return false
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
        return mapOf(
            "ssid" to currentSsid(context),
            "ipv4" to ips,
            "onGatewaySubnet" to ips.any { it.startsWith("192.168.4.") },
            "gatewaySsidMatch" to (currentSsid(context) == MainActivity.DEFAULT_SSID),
            "hasValidatedInternet" to hasValidatedInternet(context),
        )
    }

    private fun isSoftApNetwork(
        context: Context,
        network: Network,
        caps: NetworkCapabilities,
    ): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val info = caps.transportInfo as? WifiInfo
            if (normalizeSsid(info?.ssid) == MainActivity.DEFAULT_SSID) return true
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
