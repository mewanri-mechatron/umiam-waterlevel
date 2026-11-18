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
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Registers on every FlutterEngine (UI + WorkManager background), so SoftAP /
 * cellular binding works with the app closed.
 */
class WifiPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private var channel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var events: EventChannel.EventSink? = null
    private var appContext: Context? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Must be retained — Android drops SoftAP if the callback is GC'd. */
    private var gatewayCallback: ConnectivityManager.NetworkCallback? = null
    private var gatewayNetwork: Network? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL).also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        releaseGatewayRequest()
        channel?.setMethodCallHandler(null)
        channel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        events = null
        appContext = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        this.events = events
    }

    override fun onCancel(arguments: Any?) {
        this.events = null
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
            "isOnGateway" -> result.success(isOnGatewayNow(context))
            "requestWifiPermissions" -> result.success(true)
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
                // Do NOT clear while SoftAP specifier session is active — that drops WaterLevel.
                if (gatewayNetwork == null) {
                    NetworkBinder.clearBinding(context)
                }
                result.success(null)
            }
            "hasValidatedInternet" -> result.success(NetworkBinder.hasValidatedInternet(context))
            "isWifiEnabled" -> result.success(isWifiEnabled(context))
            "ensureWifiEnabled" -> result.success(ensureWifiEnabled(context))
            else -> result.notImplemented()
        }
    }

    private fun isOnGatewayNow(context: Context): Boolean {
        if (gatewayNetwork != null) return true
        return NetworkBinder.isOnGateway(context)
    }

    private fun emit(event: String, extras: Map<String, Any?> = emptyMap()) {
        val payload = HashMap<String, Any?>()
        payload["event"] = event
        payload.putAll(extras)
        mainHandler.post {
            events?.success(payload)
        }
    }

    private fun isWifiEnabled(context: Context): Boolean {
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        return wifi.isWifiEnabled
    }

    private fun ensureWifiEnabled(context: Context): String {
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        @Suppress("DEPRECATION")
        if (wifi.isWifiEnabled) return "already_on"
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            @Suppress("DEPRECATION")
            if (wifi.setWifiEnabled(true)) return "enabling"
        }
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            Intent(Settings.Panel.ACTION_WIFI)
        } else {
            Intent(Settings.ACTION_WIFI_SETTINGS)
        }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        return "prompt"
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

    private fun releaseGatewayRequest() {
        val context = appContext ?: return
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        gatewayCallback?.let {
            try {
                cm.unregisterNetworkCallback(it)
            } catch (_: Throwable) {
            }
        }
        gatewayCallback = null
        gatewayNetwork = null
    }

    private fun requestWaterLevelWifi(context: Context, ssid: String, password: String): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            releaseGatewayRequest()
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
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    gatewayNetwork = network
                    cm.bindProcessToNetwork(network)
                    emit(
                        "gateway_connected",
                        mapOf("ssid" to ssid),
                    )
                }

                override fun onLost(network: Network) {
                    if (gatewayNetwork == network) {
                        gatewayNetwork = null
                    }
                    emit("gateway_lost")
                }

                override fun onUnavailable() {
                    emit("gateway_unavailable")
                }
            }
            gatewayCallback = callback
            cm.requestNetwork(request, callback)
            emit("gateway_request_started", mapOf("ssid" to ssid))
            return "System WiFi dialog requested for $ssid."
        }
        val intent = Intent(Settings.ACTION_WIFI_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
        return "Open WiFi settings and connect to SSID $ssid."
    }

    companion object {
        const val CHANNEL = "com.waterlevel.app/wifi"
        const val EVENT_CHANNEL = "com.waterlevel.app/wifi_events"
    }
}
