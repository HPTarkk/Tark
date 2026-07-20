package com.b1101.tark.hotspot

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Local Wi-Fi hotspot host for the cross-platform "Hotspot Bridge": Android
 * creates a temporary WPA2 access point (`WifiManager.startLocalOnlyHotspot`,
 * API 26+) that a peer (iPhone, or a second Android) can join, putting both
 * phones on the same LAN so the app's ordinary Wi-Fi transport carries the
 * audio. Unlike Wi-Fi Direct, a local-only hotspot is a standard AP any device
 * can join.
 *
 * Methods (channel "tark/hotspot"):
 *   start() -> { ssid: String, passphrase: String }   (async; completes on onStarted)
 *   stop()  -> null                                    (closes the reservation)
 *
 * Events (channel "tark/hotspot/events"):
 *   {event: "stopped"}   the OS tore the hotspot down on its own (NOT our stop())
 *
 * The reservation is deliberately held open across navigation into the walkie
 * screen — the live session runs over it. It is released by stop(), by a
 * subsequent start(), or when the activity is destroyed.
 *
 * [isHosting] is a process-wide flag other components read (see
 * SessionKeepAliveService, which must NOT hold an STA Wi-Fi lock while this
 * device is acting as the AP — that lock has no STA link to help and can knock
 * the SoftAP down on single-radio phones).
 */
class HotspotHandler(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val wifiManager: WifiManager =
        context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private val stateEvents = EventChannel(messenger, "tark/hotspot/events")
    private var eventSink: EventChannel.EventSink? = null

    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null

    // Guards against a start() while a previous one is still starting.
    private var starting = false

    // Distinguishes an app-initiated close() from an OS-initiated teardown, so
    // only the latter is reported to Dart as a lost hotspot. Set true right
    // before we close the reservation ourselves; the onStopped callback that
    // follows then stays silent.
    private var expectingStop = false

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
            "start" -> start(result)
            "stop" -> {
                stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.error("unsupported", "Local hotspot requires Android 8.0+", null)
            return
        }
        // Restart cleanly if one is already up (idempotent re-entry).
        stop()
        if (starting) {
            result.error("busy", "A hotspot is already starting", null)
            return
        }
        starting = true

        try {
            wifiManager.startLocalOnlyHotspot(
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(res: WifiManager.LocalOnlyHotspotReservation) {
                        starting = false
                        // A fresh AP is up: any later onStopped without an
                        // intervening stop() is a genuine OS teardown.
                        expectingStop = false
                        reservation = res
                        isHosting = true
                        val creds = credentialsOf(res)
                        mainHandler.post {
                            result.success(
                                mapOf(
                                    "ssid" to creds.first,
                                    "passphrase" to creds.second,
                                )
                            )
                        }
                    }

                    override fun onFailed(reason: Int) {
                        starting = false
                        reservation = null
                        isHosting = false
                        // REASON_TETHERING_DISALLOWED (3) is the common one:
                        // regular tethering/hotspot is already on.
                        val code = if (reason == ERROR_TETHERING_DISALLOWED) {
                            "tethering_on"
                        } else {
                            "failed"
                        }
                        mainHandler.post {
                            result.error(code, "startLocalOnlyHotspot failed (reason $reason)", null)
                        }
                    }

                    override fun onStopped() {
                        reservation = null
                        isHosting = false
                        val wasExpected = expectingStop
                        expectingStop = false
                        // The OS killed the AP on its own (radio conflict, Doze,
                        // an STA reconnect stealing the single radio, …). Tell
                        // Dart so the session can react instead of silently
                        // going dead.
                        if (!wasExpected) {
                            mainHandler.post { eventSink?.success(mapOf("event" to "stopped")) }
                        }
                    }
                },
                mainHandler,
            )
        } catch (e: SecurityException) {
            starting = false
            mainHandler.post {
                result.error("permission_denied", e.message, null)
            }
        } catch (e: Exception) {
            starting = false
            mainHandler.post {
                result.error("failed", e.message, null)
            }
        }
    }

    /**
     * Extracts (ssid, passphrase) across API levels. API 30+ exposes
     * SoftApConfiguration; older devices only expose the deprecated
     * WifiConfiguration.
     */
    @Suppress("DEPRECATION")
    private fun credentialsOf(res: WifiManager.LocalOnlyHotspotReservation): Pair<String, String> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val config = res.softApConfiguration
            // getSsid() is deprecated from API 33 but still returns the plain
            // SSID; fall back to the API 33+ WifiSsid only if it's empty.
            var ssid = config.ssid ?: ""
            if (ssid.isEmpty() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                ssid = config.wifiSsid?.toString() ?: ""
            }
            return Pair(ssid.trim('"'), config.passphrase ?: "")
        }
        val config = res.wifiConfiguration
        val ssid = (config?.SSID ?: "").trim('"')
        return Pair(ssid, config?.preSharedKey ?: "")
    }

    fun stop() {
        // Suppress the onStopped event this close() is about to trigger — this
        // teardown is ours, not the OS pulling the rug.
        expectingStop = true
        try {
            reservation?.close()
        } catch (_: Exception) {
        }
        reservation = null
        isHosting = false
    }

    companion object {
        /**
         * True while this device is hosting a local-only hotspot. Read by
         * [com.b1101.tark.keepalive.SessionKeepAliveService] to avoid holding
         * an STA Wi-Fi lock that would fight the SoftAP. Volatile because it is
         * written on the main thread and read on the service thread.
         */
        @Volatile
        var isHosting: Boolean = false
            private set

        // WifiManager.LocalOnlyHotspotCallback.ERROR_TETHERING_DISALLOWED
        private const val ERROR_TETHERING_DISALLOWED = 3
    }
}
