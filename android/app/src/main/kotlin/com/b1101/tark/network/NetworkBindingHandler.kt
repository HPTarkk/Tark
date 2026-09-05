package com.b1101.tark.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
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
    private val mainHandler = Handler(Looper.getMainLooper())
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
            "bindSelected" -> {
                val handle = call.argument<Number>("networkHandle")?.toLong()
                val expectedGeneration = call.argument<Number>("generation")?.toLong()
                result.success(bindSelected(handle, expectedGeneration))
            }
            "clearBinding" -> {
                connectivity.bindProcessToNetwork(null)
                result.success(null)
            }
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

    /**
     * Network callbacks land on ConnectivityThread, but [EventChannel.EventSink]
     * is `@UiThread` — emitting straight from the callback takes the process down
     * with "Methods marked with @UiThread must be executed on the main thread".
     * The generation is still bumped inline: a `bindSelected` racing in from Dart
     * has to be invalidated the moment the route moves, not whenever the main
     * thread next drains. Hopping threads also keeps every [sink] read on the
     * main thread, so the field no longer has to be published across threads.
     */
    private fun emitChanged() {
        generation.incrementAndGet()
        mainHandler.post { sink?.success(snapshot(selectedNetwork())) }
    }

    /**
     * Pins only the exact network Dart observed. A callback can arrive between
     * `current` and this method; generation + handle checks prevent that stale
     * selection from pulling the process back onto an old route.
     */
    private fun bindSelected(handle: Long?, expectedGeneration: Long?): Boolean {
        if (handle == null || expectedGeneration == null) return false
        if (expectedGeneration != generation.get()) return false
        val selected = selectedNetwork() ?: return false
        if (selected.networkHandle != handle) return false
        val caps = connectivity.getNetworkCapabilities(selected) ?: return false
        if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return false
        if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return false
        return connectivity.bindProcessToNetwork(selected)
    }

    private fun isLocalWifi(network: Network?): Boolean {
        if (network == null) return false
        val caps = connectivity.getNetworkCapabilities(network) ?: return false
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
            !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
    }

    /**
     * Prefer the process-bound Wi-Fi selected by [WifiJoinHandler] before
     * looking at Android's default or arbitrary Wi-Fi handles.
     *
     * A local-only hotspot requested through WifiNetworkSpecifier is normally
     * *not* Android's default network because it deliberately has no internet.
     * `WifiJoinHandler` verifies the expected SSID/station network and pins the
     * process to that exact handle. Picking `allNetworks.firstOrNull` here can
     * then choose the user's ordinary router instead and immediately overwrite
     * the correct pin. The field symptom is asymmetric reachability: the host
     * hears the joiner while the joiner's outbound UDP follows the router.
     *
     * The existing process binding is therefore the strongest evidence we
     * have. Only when there is no eligible bound Wi-Fi do we fall back to an
     * eligible default Wi-Fi, and only then to another non-VPN Wi-Fi handle.
     */
    @Suppress("DEPRECATION")
    private fun selectedNetwork(): Network? {
        val bound = runCatching { connectivity.boundNetworkForProcess }.getOrNull()
        if (isLocalWifi(bound)) return bound

        val active = connectivity.activeNetwork
        if (isLocalWifi(active)) return active

        val wifi = connectivity.allNetworks.firstOrNull(::isLocalWifi)
        return wifi ?: active
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
