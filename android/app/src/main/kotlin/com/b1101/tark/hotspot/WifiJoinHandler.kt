package com.b1101.tark.hotspot

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android peer side of the Hotspot Bridge: joins the host's local-only hotspot
 * from *inside* the app, with no trip through Settings.
 *
 * Two problems this solves, both of which the "scan with the system camera and
 * join from the Wi-Fi settings" route suffers from:
 *
 *  1. **Leaving the app.** [WifiNetworkSpecifier] (API 29+) asks the framework
 *     to connect to a named network; the system shows a small in-app dialog
 *     ("Connect to <SSID>?") and that's the whole interaction. No settings
 *     screen, no password typing.
 *
 *  2. **The silent death a few seconds after connecting.** A local-only hotspot
 *     has no internet. When it is joined as an ordinary STA network, Android
 *     evaluates it, finds no internet, and moves the process's *default network*
 *     back to cellular (some OEMs disconnect from it outright). Sockets bound to
 *     0.0.0.0 follow the default network, so outbound UDP stops reaching the AP
 *     subnet while every socket still looks healthy — the app just goes quiet.
 *     A specifier-requested network is app-scoped: it is never internet-
 *     evaluated, never auto-switched away from, and [bindProcessToNetwork] pins
 *     every socket this process opens to it.
 *
 * Because binding only affects sockets opened *afterwards*, Dart must tear down
 * and re-open its UDP sockets once [join] succeeds (see WifiHotspotCubit).
 *
 * Methods (channel "tark/wifi_join"):
 *   join(ssid, passphrase, security) -> Bool   true once bound to the network
 *   bindCurrent()                    -> Bool   pin to the Wi-Fi the user joined manually
 *   leave()                          -> null   release the request and unbind
 *
 * Events (channel "tark/wifi_join/events"):
 *   {event: "lost"}   the joined network went away (host moved off, AP died)
 */
class WifiJoinHandler(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val connectivity: ConnectivityManager =
        context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE)
            as ConnectivityManager
    private val wifiManager: WifiManager =
        context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private val stateEvents = EventChannel(messenger, "tark/wifi_join/events")
    private var eventSink: EventChannel.EventSink? = null

    private var callback: ConnectivityManager.NetworkCallback? = null
    private var boundNetwork: Network? = null

    // A join that hasn't answered Dart yet. Unregistering a network callback
    // does NOT deliver onUnavailable, so tearing a request down has to settle
    // its result itself or the awaiting Dart future hangs forever.
    private var pendingJoin: PendingJoin? = null

    init {
        stateEvents.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "join" -> join(
                ssid = call.argument<String>("ssid").orEmpty(),
                passphrase = call.argument<String>("passphrase").orEmpty(),
                security = call.argument<String>("security").orEmpty(),
                result = result,
            )
            "bindCurrent" -> result.success(bindCurrent())
            "leave" -> {
                leave()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun join(
        ssid: String,
        passphrase: String,
        security: String,
        result: MethodChannel.Result,
    ) {
        if (ssid.isEmpty()) {
            result.error("no_ssid", "Join requires an SSID", null)
            return
        }
        // Drop any previous request first: two live specifier requests fight
        // over the single STA and the older one usually wins.
        leave()

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            joinLegacy(ssid, passphrase, result)
            return
        }

        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .apply {
                when {
                    passphrase.isEmpty() -> Unit // open network
                    // The host reports SAE only when its SoftAP is WPA3-only;
                    // WPA2 and WPA3-transition APs both accept a WPA2 passphrase.
                    security.equals("SAE", ignoreCase = true) -> setWpa3Passphrase(passphrase)
                    else -> setWpa2Passphrase(passphrase)
                }
            }
            .build()

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            // Mandatory for a specifier request, and the whole point here: the
            // hotspot has no internet and must not be judged for lacking it.
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        // A MethodChannel.Result may be completed exactly once, but the
        // callback can fire onAvailable again after a reconnect.
        val pending = PendingJoin(result, AtomicBoolean(false))
        pendingJoin = pending
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                bind(network)
                pending.reply(true)
            }

            override fun onLost(network: Network) {
                if (network != boundNetwork) return
                boundNetwork = null
                // Don't leave the process pinned to a network that no longer
                // exists — that would block every recovery path, including the
                // user rejoining by hand.
                runCatching { connectivity.bindProcessToNetwork(null) }
                mainHandler.post { eventSink?.success(mapOf("event" to "lost")) }
            }

            override fun onUnavailable() {
                // The user dismissed the system dialog, the passphrase was
                // wrong, or the AP never showed up before the timeout. Not an
                // error — the UI falls back to a manual join.
                pending.reply(false)
            }
        }
        callback = cb

        try {
            connectivity.requestNetwork(request, cb, JOIN_TIMEOUT_MS)
        } catch (e: SecurityException) {
            // requestNetwork with a specifier is foreground-only.
            callback = null
            pending.fail("foreground_required", e.message)
        } catch (e: Exception) {
            callback = null
            pending.fail("failed", e.message)
        }
    }

    /** A join awaiting its answer, guarded so it is delivered exactly once. */
    private inner class PendingJoin(
        private val result: MethodChannel.Result,
        private val replied: AtomicBoolean,
    ) {
        fun reply(joined: Boolean) {
            if (replied.compareAndSet(false, true)) {
                mainHandler.post { result.success(joined) }
            }
        }

        fun fail(code: String, message: String?) {
            if (replied.compareAndSet(false, true)) {
                mainHandler.post { result.error(code, message, null) }
            }
        }
    }

    /**
     * Pre-API-29 join: there is no specifier API, so add the network the old
     * way and then pin the process to the Wi-Fi transport once it associates.
     * Still worth doing — the cellular fallback that kills the session exists
     * on these versions too.
     */
    @Suppress("DEPRECATION")
    private fun joinLegacy(ssid: String, passphrase: String, result: MethodChannel.Result) {
        val config = WifiConfiguration().apply {
            SSID = "\"$ssid\""
            if (passphrase.isEmpty()) {
                allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE)
            } else {
                preSharedKey = "\"$passphrase\""
            }
        }
        try {
            if (!wifiManager.isWifiEnabled) wifiManager.isWifiEnabled = true
            val netId = wifiManager.addNetwork(config)
            if (netId == -1) {
                result.success(false)
                return
            }
            wifiManager.disconnect()
            wifiManager.enableNetwork(netId, true)
            wifiManager.reconnect()
        } catch (e: Exception) {
            result.error("failed", e.message, null)
            return
        }
        awaitLegacyAssociation(ssid, result, attempt = 0)
    }

    @Suppress("DEPRECATION")
    private fun awaitLegacyAssociation(
        ssid: String,
        result: MethodChannel.Result,
        attempt: Int,
    ) {
        val current = runCatching { wifiManager.connectionInfo?.ssid?.trim('"') }.getOrNull()
        if (current == ssid) {
            result.success(bindCurrent())
            return
        }
        if (attempt >= LEGACY_POLL_ATTEMPTS) {
            result.success(false)
            return
        }
        mainHandler.postDelayed(
            { awaitLegacyAssociation(ssid, result, attempt + 1) },
            LEGACY_POLL_INTERVAL_MS,
        )
    }

    /**
     * Pins the process to whatever Wi-Fi network is already connected. Used
     * when the user joined the host's hotspot by hand (the manual fallback):
     * the association exists, it's the default-network switch away from an
     * internet-less network that has to be defended against.
     */
    private fun bindCurrent(): Boolean {
        val network = connectivity.allNetworks.firstOrNull { candidate ->
            connectivity.getNetworkCapabilities(candidate)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        } ?: return false
        bind(network)
        return true
    }

    private fun bind(network: Network) {
        boundNetwork = network
        runCatching { connectivity.bindProcessToNetwork(network) }
    }

    fun leave() {
        callback?.let { cb -> runCatching { connectivity.unregisterNetworkCallback(cb) } }
        callback = null
        // Unregistering is silent, so anything still waiting on this request is
        // told here that it didn't happen.
        pendingJoin?.reply(false)
        pendingJoin = null
        boundNetwork = null
        runCatching { connectivity.bindProcessToNetwork(null) }
    }

    companion object {
        // How long the framework may spend finding and associating with the
        // host AP before reporting onUnavailable. Generous: the host may still
        // be bringing its hotspot up when the peer scans the code.
        private const val JOIN_TIMEOUT_MS = 40_000

        private const val LEGACY_POLL_ATTEMPTS = 50
        private const val LEGACY_POLL_INTERVAL_MS = 500L
    }
}
