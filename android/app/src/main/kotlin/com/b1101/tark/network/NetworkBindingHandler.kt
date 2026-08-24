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
 * Exposes Android's selected network identity to Dart without leaking network
 * addresses or credentials.
 *
 * Dart sockets still own transport IO. This bridge only answers which Android
 * Network is currently selected, which interface backs it, and a monotonic
 * generation that changes whenever Android reports a network/link transition.
 * Callers can therefore reject stale callbacks/results from an older route.
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
        override fun onAvailable(network: Network) = emitChanged(network)
        override fun onLost(network: Network) = emitChanged(connectivity.activeNetwork)
        override fun onCapabilitiesChanged(
            network: Network,
            networkCapabilities: NetworkCapabilities,
        ) = emitChanged(network)
        override fun onLinkPropertiesChanged(
            network: Network,
            linkProperties: LinkProperties,
        ) = emitChanged(network)
    }

    init {
        events.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "current" -> result.success(snapshot(connectivity.activeNetwork))
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        if (!callbackRegistered) {
            connectivity.registerDefaultNetworkCallback(callback)
            callbackRegistered = true
        }
        events.success(snapshot(connectivity.activeNetwork))
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
            // Already unregistered by the OS/process teardown.
        }
        callbackRegistered = false
    }

    private fun emitChanged(network: Network?) {
        generation.incrementAndGet()
        sink?.success(snapshot(network))
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
            "isCellular" to
                (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true),
        )
    }

    companion object {
        const val METHOD_CHANNEL = "tark/network_binding"
        const val EVENTS_CHANNEL = "tark/network_binding/events"
    }
}
