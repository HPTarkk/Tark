package com.b1101.tark.hotspot

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.wifi.SoftApConfiguration
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
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
 *   start() -> { ssid: String, passphrase: String, security: String }
 *                                                      (async; completes on onStarted)
 *   stop()  -> null                                    (closes the reservation)
 *   openLocationSettings() / openTetherSettings() -> null
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

    // True between requesting an AP and the framework calling back.
    private var starting = false

    /**
     * Bumped by every [stop]. `startLocalOnlyHotspot` has no cancel — the only
     * handle on a request is the reservation it hands back, which doesn't exist
     * until it succeeds. So each attempt carries the generation it was made in,
     * and a callback from a superseded one is recognised on arrival: its AP gets
     * closed instead of adopted, and it can't answer a result that has moved on.
     * Without this, backing out of the hotspot screen before it finished coming
     * up left an AP nobody owned — untouchable, and enough to block every
     * subsequent attempt.
     */
    private var generation = 0

    // The start() awaiting an answer, so a teardown can settle it rather than
    // leave the Dart future hanging.
    private var pendingResult: MethodChannel.Result? = null

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
            "openLocationSettings" -> {
                openSettings(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
                result.success(null)
            }
            "openTetherSettings" -> {
                openTetherSettings()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(result: MethodChannel.Result) {
        // Release what we're holding BEFORE looking at the radio, and settle
        // before preflighting. Checking first was a deadlock: an AP this app
        // had left running reads as the *user's* tethering being on, preflight
        // returned early on that, and returning early is exactly what stopped
        // us from ever releasing it. Every attempt afterwards failed the same
        // way, telling the user to turn off a hotspot that Settings correctly
        // showed as off.
        val hadRadio = reservation != null || starting
        stop()
        val gen = generation
        mainHandler.postDelayed({
            if (gen != generation) {
                result.error(CANCELLED, "Superseded by a newer start()", null)
                return@postDelayed
            }
            preflightError()?.let { code ->
                result.error(code, "Hotspot preflight check failed: $code", null)
                return@postDelayed
            }
            pendingResult = result
            starting = true
            requestHotspot(gen, attempt = 0)
        }, if (hadRadio) RESTART_SETTLE_MS else 0L)
    }

    private fun requestHotspot(gen: Int, attempt: Int) {
        try {
            wifiManager.startLocalOnlyHotspot(
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(res: WifiManager.LocalOnlyHotspotReservation) {
                        // This attempt was abandoned while the framework was
                        // still bringing the AP up — the user backed out, or a
                        // newer start took over. Close it here or it stays up
                        // with nobody holding it: invisible in Settings,
                        // impossible to stop, and enough to block every later
                        // attempt.
                        if (gen != generation) {
                            runCatching { res.close() }
                            return
                        }
                        // A fresh AP is up: any later onStopped without an
                        // intervening stop() is a genuine OS teardown.
                        expectingStop = false
                        reservation = res
                        isHosting = true
                        val creds = credentialsOf(res)
                        reply(gen) {
                            it.success(
                                mapOf(
                                    "ssid" to creds.ssid,
                                    "passphrase" to creds.passphrase,
                                    "security" to creds.security,
                                )
                            )
                        }
                    }

                    override fun onFailed(reason: Int) {
                        if (gen != generation) return
                        reservation = null
                        isHosting = false
                        // A transient reason is worth one silent retry: the
                        // radio is often still mode-switching (a Wi-Fi scan, a
                        // just-released AP) and the second attempt succeeds.
                        if (attempt == 0 && reason != ERROR_TETHERING_DISALLOWED) {
                            mainHandler.postDelayed({
                                if (gen == generation) requestHotspot(gen, attempt + 1)
                            }, RETRY_DELAY_MS)
                            return
                        }
                        reply(gen) {
                            it.error(
                                codeFor(reason),
                                "startLocalOnlyHotspot failed (reason $reason)",
                                null,
                            )
                        }
                    }

                    override fun onStopped() {
                        if (gen != generation) return
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
            reply(gen) { it.error("permission_denied", e.message, null) }
        } catch (e: IllegalStateException) {
            // "Caller already has an active LocalOnlyHotspot request" — an
            // abandoned attempt is still unwinding inside WifiManager. Its
            // onStarted closes it (above), so one delayed retry clears this.
            if (attempt == 0) {
                mainHandler.postDelayed({
                    if (gen == generation) requestHotspot(gen, attempt + 1)
                }, RETRY_DELAY_MS)
                return
            }
            reply(gen) { it.error("failed", e.message, null) }
        } catch (e: Exception) {
            reply(gen) { it.error("failed", e.message, null) }
        }
    }

    /** Answers the in-flight start exactly once, and only if it's still ours. */
    private fun reply(gen: Int, action: (MethodChannel.Result) -> Unit) {
        if (gen != generation) return
        val result = pendingResult ?: return
        pendingResult = null
        starting = false
        mainHandler.post { action(result) }
    }

    /**
     * The conditions that make [WifiManager.startLocalOnlyHotspot] fail before
     * it is even worth calling, in the order the user can act on them. Null
     * when nothing is obviously wrong.
     */
    private fun preflightError(): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return "unsupported"
        if (!hasHotspotPermission()) return "permission_denied"
        // Deliberately NOT checked here: whether tethering is already on.
        // `isWifiApEnabled` is hidden API — blocked on Android 11+, and where
        // it does answer it counts our own local-only AP as tethering and lags
        // behind a teardown by a second or so. A stale true turned a fixable
        // failure into a permanent one. The framework's own
        // ERROR_TETHERING_DISALLOWED says the same thing and can't be stale.
        //
        // Through API 32 the hotspot is gated on location, and the *system*
        // location toggle counts — a granted permission with Location off still
        // fails. From 33 NEARBY_WIFI_DEVICES replaces that requirement.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU && !isLocationEnabled()) {
            return "location_off"
        }
        return null
    }

    private fun hasHotspotPermission(): Boolean {
        val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.NEARBY_WIFI_DEVICES
        } else {
            Manifest.permission.ACCESS_FINE_LOCATION
        }
        return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }

    private fun isLocationEnabled(): Boolean {
        val manager =
            context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return true
        return runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                manager.isLocationEnabled
            } else {
                manager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                    manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
            }
        }.getOrDefault(true)
    }

    private fun codeFor(reason: Int): String = when (reason) {
        ERROR_TETHERING_DISALLOWED -> "tethering_on"
        ERROR_INCOMPATIBLE_MODE -> "incompatible_mode"
        ERROR_NO_CHANNEL -> "no_channel"
        else -> "failed"
    }

    private fun openSettings(action: String) {
        runCatching {
            context.startActivity(
                Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    private fun openTetherSettings() {
        // There is no public action for the tethering screen; the AOSP
        // component works on most builds, and wireless settings is a sane
        // landing spot everywhere else.
        val tether = Intent(Intent.ACTION_MAIN).apply {
            setClassName("com.android.settings", "com.android.settings.TetherSettings")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (runCatching { context.startActivity(tether) }.isFailure) {
            openSettings(Settings.ACTION_WIRELESS_SETTINGS)
        }
    }

    /**
     * Extracts the credentials across API levels. API 30+ exposes
     * SoftApConfiguration (including the security type, which the peer needs to
     * pick WPA2 vs WPA3-SAE when joining); older devices only expose the
     * deprecated WifiConfiguration, which is always WPA2 for a local-only AP.
     */
    @Suppress("DEPRECATION")
    private fun credentialsOf(res: WifiManager.LocalOnlyHotspotReservation): Credentials {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val config = res.softApConfiguration
            // getSsid() is deprecated from API 33 but still returns the plain
            // SSID; fall back to the API 33+ WifiSsid only if it's empty.
            var ssid = config.ssid ?: ""
            if (ssid.isEmpty() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                ssid = config.wifiSsid?.toString() ?: ""
            }
            // Security is mapped onto the Wi-Fi QR spec's `T:` values so the
            // peer knows whether to offer a WPA2 or a WPA3-SAE passphrase. A
            // WPA3-*transition* AP still takes a WPA2 passphrase, so only a
            // SAE-only AP is reported as SAE.
            val security = when (config.securityType) {
                SoftApConfiguration.SECURITY_TYPE_OPEN -> "nopass"
                SoftApConfiguration.SECURITY_TYPE_WPA3_SAE -> "SAE"
                else -> "WPA"
            }
            return Credentials(
                ssid = ssid.trim('"'),
                passphrase = config.passphrase ?: "",
                security = security,
            )
        }
        val config = res.wifiConfiguration
        return Credentials(
            ssid = (config?.SSID ?: "").trim('"'),
            passphrase = config?.preSharedKey ?: "",
            security = "WPA",
        )
    }

    fun stop() {
        // Invalidate any attempt still in flight. An AP that arrives after this
        // belongs to nobody, so onStarted closes it on sight.
        generation++
        starting = false
        // Suppress the onStopped event this close() is about to trigger — this
        // teardown is ours, not the OS pulling the rug.
        expectingStop = true
        pendingResult?.let { result ->
            pendingResult = null
            mainHandler.post { result.error(CANCELLED, "Hotspot start cancelled", null) }
        }
        try {
            reservation?.close()
        } catch (_: Exception) {
        }
        reservation = null
        isHosting = false
    }

    private data class Credentials(
        val ssid: String,
        val passphrase: String,
        val security: String,
    )

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

        // WifiManager.LocalOnlyHotspotCallback error reasons. They are public
        // constants but only from API 26, and this file compiles against older
        // minSdk — mirrored here rather than guarded at every use. NOTE the
        // values: TETHERING_DISALLOWED is 4, not 3 (3 is INCOMPATIBLE_MODE).
        private const val ERROR_NO_CHANNEL = 1
        private const val ERROR_INCOMPATIBLE_MODE = 3
        private const val ERROR_TETHERING_DISALLOWED = 4

        /**
         * A start that was superseded or torn down before it could answer.
         * Dart treats it as a non-event rather than an error — the screen that
         * asked for it has already moved on.
         */
        const val CANCELLED = "cancelled"

        // Time the framework needs to fully release a previous AP — and to stop
        // reporting the SoftAP as up — before it will hand out another one.
        private const val RESTART_SETTLE_MS = 1_200L

        // Backoff before the single automatic retry of a transient failure.
        private const val RETRY_DELAY_MS = 1_500L
    }
}
