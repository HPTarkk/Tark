package com.b1101.tark.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicLong

/**
 * Exposes Android network identity without leaking addresses or credentials.
 *
 * The generation changes on route/link transitions so Dart can reject stale
 * results. This handler does not claim the room is healthy; bidirectional
 * transport evidence remains the authority for that.
 */
class NetworkBindingHandler(
    context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val connectivity =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val events = EventChannel(messenger, EVENTS_CHANNEL)
    private val generation = AtomicLong(0L)
    private var sink: EventChannel.EventSink? = null
    private var callbackRegistered = false

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = emitChanged()
        override fun onLost(network: Network) = emitChanged()
        override fun onCapabilitiesChanged(
            network: Network,
            networkCapabilities: NetworkCapabilities,
        ) = emitChanged()
        override fun onLinkPropertiesChanged(
            network: Network,
            linkProperties: LinkProperties,
        ) = emitChanged()
    }

    init {
        events.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "current" -> result.success(snapshot(selectedNetwork()))
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        if (!callbackRegistered) {
            connectivity.registerDefaultNetworkCallback(callback)
            callbackRegistered = true
        }
        events.success(snapshot(selectedNetwork()))
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        unregisterCallback()
    }

    fun dispose() {
        sink = null
        unregisterCallback()
        events.setStreamHandler(null)
    }

    private fun unregisterCallback() {
        if (!callbackRegistered) return
        try {
            connectivity.unregisterNetworkCallback(callback)
        } catch (_: IllegalArgumentException) {
            // Already unregistered by Android/process teardown.
        }
        callbackRegistered = false
    }

    private fun emitChanged() {
        generation.incrementAndGet()
        sink?.success(snapshot(selectedNetwork()))
    }

    /** Prefer a non-VPN Wi-Fi network over Android's default (which may be VPN). */
    private fun selectedNetwork(): Network? {
        val wifi = connectivity.allNetworks.firstOrNull { network ->
            val caps = connectivity.getNetworkCapabilities(network) ?: return@firstOrNull false
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        }
        return wifi ?: connectivity.activeNetwork
    }

    private fun snapshot(network: Network?): Map<String, Any?> {
        if (network == null) {
            return mapOf(
                "generation" to generation.get(),
                "available" to false,
            )
        }
        val link = connectivity.getLinkProperties(network)
        val capabilities = connectivity.getNetworkCapabilities(network)
        return mapOf(
            "generation" to generation.get(),
            "available" to true,
            "networkHandle" to network.networkHandle,
            "interfaceName" to link?.interfaceName,
            "isVpn" to (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true),
            "isWifi" to (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true),
            "isCellular" to (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true),
        )
    }

    companion object {
        const val METHOD_CHANNEL = "tark/network_binding"
        const val EVENTS_CHANNEL = "tark/network_binding/events"
    }
}
