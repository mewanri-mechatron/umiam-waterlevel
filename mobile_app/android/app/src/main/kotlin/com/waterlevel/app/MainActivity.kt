package com.waterlevel.app

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.WifiNetworkSuggestion
import android.os.Build
import android.os.PatternMatcher
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Platform channel for WaterLevel SoftAP connectivity + background site sync.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "com.waterlevel.app/wifi"
    private var boundNetwork: Network? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getWifiSsid" -> result.success(currentSsid())
                    "connectToGatewayWifi" -> {
                        result.success(requestWaterLevelWifi())
                    }
                    "suggestGatewayWifi" -> result.success(suggestWaterLevelWifi())
                    "startSiteSyncService" -> {
                        SiteSyncService.start(applicationContext)
                        result.success(true)
                    }
                    "stopSiteSyncService" -> {
                        SiteSyncService.stop(applicationContext)
                        result.success(true)
                    }
                    "bindToGatewayNetwork" -> result.success(bindToLocalGatewayNetwork())
                    "clearNetworkBinding" -> {
                        clearBinding()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun currentSsid(): String? {
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        val info = wifi.connectionInfo ?: return null
        @Suppress("DEPRECATION")
        var ssid = info.ssid ?: return null
        if (ssid == "<unknown ssid>") return null
        if (ssid.startsWith("\"") && ssid.endsWith("\"")) {
            ssid = ssid.substring(1, ssid.length - 1)
        }
        return ssid
    }

    /** Lets Android auto-join WaterLevel when the phone is nearby (user may approve once). */
    private fun suggestWaterLevelWifi(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return "WiFi suggestions need Android 10+. Connect manually to WaterLevel near the station."
        }
        val suggestion = WifiNetworkSuggestion.Builder()
            .setSsid("WaterLevel")
            .setIsAppInteractionRequired(false)
            .build()
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val status = wifi.addNetworkSuggestions(listOf(suggestion))
        return if (status == WifiManager.STATUS_NETWORK_SUGGESTIONS_SUCCESS) {
            "Phone will prefer WaterLevel WiFi when you are near the station."
        } else {
            "Could not register WiFi suggestion (code $status). Connect manually if needed."
        }
    }

    private fun requestWaterLevelWifi(): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val specifier = WifiNetworkSpecifier.Builder()
                .setSsidPattern(PatternMatcher("WaterLevel", PatternMatcher.PATTERN_LITERAL))
                .build()
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .setNetworkSpecifier(specifier)
                .build()
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            cm.requestNetwork(
                request,
                object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        boundNetwork = network
                        cm.bindProcessToNetwork(network)
                    }
                }
            )
            return "System WiFi dialog requested for WaterLevel. Approve the network without internet if prompted."
        }
        startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
        return "Open WiFi settings and connect to SSID WaterLevel."
    }

    private fun bindToLocalGatewayNetwork(): Boolean {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        if (boundNetwork != null) {
            return cm.bindProcessToNetwork(boundNetwork)
        }
        val networks = cm.allNetworks
        for (network in networks) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) continue
            val ok = cm.bindProcessToNetwork(network)
            if (ok) {
                boundNetwork = network
                return true
            }
        }
        return false
    }

    private fun clearBinding() {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        cm.bindProcessToNetwork(null)
        boundNetwork = null
    }
}
