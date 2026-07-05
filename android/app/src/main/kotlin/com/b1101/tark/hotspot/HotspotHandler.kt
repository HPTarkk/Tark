package com.b1101.tark.hotspot

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Local Wi-Fi hotspot host for the cross-platform "Hotspot Bridge": Android
 * creates a temporary WPA2 access point (`WifiManager.startLocalOnlyHotspot`,
 * API 26+) that an iPhone can join, putting both phones on the same LAN so the
 * app's ordinary Wi-Fi transport carries the audio. Unlike Wi-Fi Direct, a
 * local-only hotspot is a standard AP any device — including iOS — can join.
 *
 * Methods (channel "tark/hotspot"):
 *   start() -> { ssid: String, passphrase: String }   (async; completes on onStarted)
 *   stop()  -> null                                    (closes the reservation)
 *
 * The reservation is deliberately held open across navigation into the walkie
 * screen — the live session runs over it. It is released by stop(), by a
 * subsequent start(), or when the activity is destroyed.
 */
class HotspotHandler(
    private val context: Context,
) : MethodChannel.MethodCallHandler {

    private val wifiManager: WifiManager =
        context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val mainHandler = Handler(Looper.getMainLooper())

    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null

    // Guards against a start() while a previous one is still starting.
    private var starting = false

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
                        reservation = res
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
        try {
            reservation?.close()
        } catch (_: Exception) {
        }
        reservation = null
    }

    private companion object {
        // WifiManager.LocalOnlyHotspotCallback.ERROR_TETHERING_DISALLOWED
        const val ERROR_TETHERING_DISALLOWED = 3
    }
}
