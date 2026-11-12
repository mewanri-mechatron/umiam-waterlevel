package com.waterlevel.app

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.WifiNetworkSuggestion
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Registers on every FlutterEngine (UI + WorkManager background), so SoftAP /
 * cellular binding works with the app closed.
 */
class WifiPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var appContext: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = appContext
        if (context == null) {
            result.error("no_context", "WifiPlugin not attached", null)
            return
        }
        val args = call.arguments as? Map<*, *>
        val ssid = (args?.get("ssid") as? String)?.ifBlank { null } ?: MainActivity.DEFAULT_SSID
        val password =
            (args?.get("password") as? String)?.ifBlank { null } ?: MainActivity.DEFAULT_PASSWORD

        when (call.method) {
            "getWifiSsid" -> result.success(NetworkBinder.currentSsid(context))
            "getWifiDiagnostics" -> result.success(NetworkBinder.wifiDiagnostics(context))
            "requestWifiPermissions" -> result.success(true) // Activity requests; noop here
            "connectToGatewayWifi" -> result.success(requestWaterLevelWifi(context, ssid, password))
            "suggestGatewayWifi" -> result.success(suggestWaterLevelWifi(context, ssid, password))
            "startSiteSyncService" -> {
                SiteSyncService.start(context)
                result.success(true)
            }
            "stopSiteSyncService" -> {
                SiteSyncService.stop(context)
                result.success(true)
            }
            "bindToGatewayNetwork" -> result.success(NetworkBinder.bindToGateway(context))
            "bindToInternetNetwork" -> result.success(NetworkBinder.bindToInternet(context))
            "clearNetworkBinding" -> {
                NetworkBinder.clearBinding(context)
                result.success(null)
            }
            "hasValidatedInternet" -> result.success(NetworkBinder.hasValidatedInternet(context))
            else -> result.notImplemented()
        }
    }

    private fun suggestWaterLevelWifi(context: Context, ssid: String, password: String): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            return "WiFi suggestions need Android 10+. Connect manually to $ssid."
        }
        val suggestion = WifiNetworkSuggestion.Builder()
            .setSsid(ssid)
            .setWpa2Passphrase(password)
            .setIsAppInteractionRequired(false)
            .build()
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val status = wifi.addNetworkSuggestions(listOf(suggestion))
        return if (status == WifiManager.STATUS_NETWORK_SUGGESTIONS_SUCCESS) {
            "Phone will prefer $ssid when you are near the station."
        } else {
            "Could not register WiFi suggestion (code $status)."
        }
    }

    private fun requestWaterLevelWifi(context: Context, ssid: String, password: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val specifier = WifiNetworkSpecifier.Builder()
                .setSsid(ssid)
                .setWpa2Passphrase(password)
                .build()
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .setNetworkSpecifier(specifier)
                .build()
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            cm.requestNetwork(
                request,
                object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        cm.bindProcessToNetwork(network)
                    }
                },
            )
            return "System WiFi dialog requested for $ssid."
        }
        val intent = Intent(Settings.ACTION_WIFI_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        return "Open WiFi settings and connect to SSID $ssid."
    }

    companion object {
        const val CHANNEL = "com.waterlevel.app/wifi"
    }
}
