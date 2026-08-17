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
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
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
 *   wifiAdvice() -> { wifiEnabled: Bool, concurrent: Bool, canPanel: Bool }
 *   openWifiPanel() -> Bool                            (false = no panel, fell back)
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

    /**
     * When the AP last went down, by any route. [start] needs this because the
     * teardown has already cleared [reservation] by the time a re-host arrives:
     * judging "was the radio just in AP mode?" from the reservation alone said
     * no exactly when the answer was yes, and skipped the settle delay in the
     * one case it exists for — the framework then hands back a reservation
     * whose AP never makes it onto the air, and the peer scans a QR for a
     * network that isn't there.
     */
    private var lastTeardownAt = 0L

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
            "wifiAdvice" -> result.success(wifiAdvice())
            "openWifiPanel" -> result.success(openWifiPanel())
            "clientIpv4" -> result.success(clientIpv4())
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
        // "Was the radio just in AP mode?" — which includes an AP that went
        // down a moment ago, not only one we're still holding. A re-host after
        // an OS teardown arrives with the reservation already cleared, so
        // asking the reservation alone answered no precisely when it mattered.
        val sinceTeardown = SystemClock.elapsedRealtime() - lastTeardownAt
        val hadRadio = reservation != null || starting || sinceTeardown < RESTART_SETTLE_MS
        stop()
        val gen = generation
        val settle = if (hadRadio) RESTART_SETTLE_MS else 0L
        Log.i(TAG, "start requested (gen=$gen, settle=${settle}ms)")
        mainHandler.postDelayed({
            if (gen != generation) {
                Log.i(TAG, "start superseded before it began (gen=$gen)")
                result.error(CANCELLED, "Superseded by a newer start()", null)
                return@postDelayed
            }
            preflightError()?.let { code ->
                Log.w(TAG, "start preflight failed: $code")
                result.error(code, "Hotspot preflight check failed: $code", null)
                return@postDelayed
            }
            pendingResult = result
            starting = true
            requestHotspot(gen, attempt = 0)
        }, settle)
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
                            Log.i(TAG, "onStarted for a superseded attempt — closing it")
                            // Off the main thread for the same reason as [stop]
                            // — this callback lands on the main looper, and the
                            // supersession that got us here is usually a
                            // re-host, so the radio is as busy as it ever gets.
                            releaseAsync(res)
                            return
                        }
                        // A fresh AP is up: any later onStopped without an
                        // intervening stop() is a genuine OS teardown.
                        expectingStop = false
                        reservation = res
                        isHosting = true
                        val creds = credentialsOf(res)
                        Log.i(TAG, "onStarted ssid='${creds.ssid}' security=${creds.security}")
                        // Hold the credentials back for a beat before handing
                        // them to the UI. `onStarted` means the framework
                        // accepted the request, not that the AP reached the
                        // air — on a radio still unwinding a previous AP it can
                        // come up and die immediately, and publishing on the
                        // callback alone puts a QR on screen for a network that
                        // was never there. The peer then burns its full 40s
                        // join timeout hunting for that SSID.
                        mainHandler.postDelayed({
                            if (gen != generation) return@postDelayed
                            if (reservation == null) {
                                Log.w(TAG, "AP '${creds.ssid}' died inside the confirm window")
                                if (attempt == 0) {
                                    requestHotspot(gen, attempt + 1)
                                } else {
                                    reply(gen) {
                                        it.error(
                                            "failed",
                                            "Hotspot went down as soon as it came up",
                                            null,
                                        )
                                    }
                                }
                                return@postDelayed
                            }
                            Log.i(TAG, "publishing '${creds.ssid}' to the UI")
                            reply(gen) {
                                it.success(
                                    mapOf(
                                        "ssid" to creds.ssid,
                                        "passphrase" to creds.passphrase,
                                        "security" to creds.security,
                                    )
                                )
                            }
                        }, AP_CONFIRM_MS)
                    }

                    override fun onFailed(reason: Int) {
                        if (gen != generation) return
                        Log.w(TAG, "onFailed reason=$reason (${codeFor(reason)}) attempt=$attempt")
                        reservation = null
                        isHosting = false
                        lastTeardownAt = SystemClock.elapsedRealtime()
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
                        lastTeardownAt = SystemClock.elapsedRealtime()
                        val wasExpected = expectingStop
                        expectingStop = false
                        val startInFlight = pendingResult != null
                        Log.w(
                            TAG,
                            "onStopped (expected=$wasExpected, startInFlight=$startInFlight)",
                        )
                        // The OS killed the AP on its own (radio conflict, Doze,
                        // an STA reconnect stealing the single radio, …). Tell
                        // Dart so the session can react instead of silently
                        // going dead — unless a start is still waiting on its
                        // answer, in which case the confirm window above owns
                        // the recovery and telling Dart too would have both
                        // ends re-hosting into each other.
                        if (!wasExpected && !startInFlight) {
                            mainHandler.post { eventSink?.success(mapOf("event" to "stopped")) }
                        }
                    }
                },
                mainHandler,
            )
        } catch (e: SecurityException) {
            Log.e(TAG, "startLocalOnlyHotspot denied", e)
            reply(gen) { it.error("permission_denied", e.message, null) }
        } catch (e: IllegalStateException) {
            Log.w(TAG, "startLocalOnlyHotspot busy (attempt=$attempt): ${e.message}")
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
            Log.e(TAG, "startLocalOnlyHotspot failed", e)
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

    /**
     * Whether leaving Wi-Fi on is likely to cost this device its hotspot.
     *
     * A local-only hotspot and a Wi-Fi client connection are the same radio on
     * most phones. Where the chipset can't run both, the framework tears the AP
     * down the moment the STA side reconnects — a saved network drifting back
     * into range mid-ride kills the channel, and it arrives as our own
     * `onStopped` with nothing to distinguish it from any other teardown.
     *
     * `isStaApConcurrencySupported` (API 30+) answers this directly. Below that
     * there is no query at all, and single-radio is overwhelmingly the norm on
     * hardware that old, so the absence is reported as "not concurrent" rather
     * than as unknown: warning someone whose phone would have coped costs them
     * one dismissed note, while staying quiet on a phone that won't cope costs
     * them the ride.
     *
     * Note this is advisory only — nothing here turns anything off.
     * `setWifiEnabled` has been a no-op returning false for non-system apps
     * since API 29, so the switch is the user's to flip and our job is to ask
     * for it well.
     */
    private fun wifiAdvice(): Map<String, Any> {
        val enabled = runCatching { wifiManager.isWifiEnabled }.getOrDefault(false)
        val concurrent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            runCatching { wifiManager.isStaApConcurrencySupported }.getOrDefault(false)
        } else {
            false
        }
        return mapOf(
            "wifiEnabled" to enabled,
            "concurrent" to concurrent,
            // The inline panel is API 29+. Older builds get the full Wi-Fi
            // settings screen instead, which works but navigates away — worth
            // telling Dart, so the button can say so.
            "canPanel" to (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q),
        )
    }

    /**
     * This device's IPv4 address **as a Wi-Fi client**, or null when it isn't
     * connected to one.
     *
     * The point is to tell our own access point apart from a network we merely
     * joined, on a phone that has both. Interface names can't do it — the AP
     * lands on `ap0`, `swlan0` or `wlan1` depending on the vendor — but the
     * client address is unambiguous: whatever `WifiManager` reports here is by
     * definition the STA side, so every other private address we can see is
     * not.
     *
     * `connectionInfo` is deprecated from API 31 in favour of
     * `NetworkCallback.onCapabilitiesChanged`, and is kept anyway: the
     * replacement is a subscription that answers later, while this is a
     * one-shot question asked from a routing decision that has to be made now.
     * It still returns the right address on every supported release.
     */
    @Suppress("DEPRECATION")
    private fun clientIpv4(): String? = runCatching {
        val raw = wifiManager.connectionInfo?.ipAddress ?: 0
        if (raw == 0) return@runCatching null
        // Little-endian int, as this API has always returned it.
        "%d.%d.%d.%d".format(
            raw and 0xff,
            raw shr 8 and 0xff,
            raw shr 16 and 0xff,
            raw shr 24 and 0xff,
        )
    }.getOrNull()

    /**
     * Opens the Wi-Fi toggle as close to in-place as the platform allows.
     *
     * [Settings.Panel.ACTION_INTERNET_CONNECTIVITY] floats over the calling app,
     * so the host never loses the QR screen it is showing the other phone —
     * which matters more here than usual, since the whole point of the moment
     * is that a second person is looking at this display.
     *
     * Returns true when the floating panel opened, false when we had to fall
     * back to the full settings screen (or nothing at all).
     */
    private fun openWifiPanel(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val panel = Intent(Settings.Panel.ACTION_INTERNET_CONNECTIVITY)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (runCatching { context.startActivity(panel) }.isSuccess) return true
        }
        openSettings(Settings.ACTION_WIFI_SETTINGS)
        return false
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
        if (reservation != null || starting) {
            Log.i(TAG, "stop: releasing our AP (starting=$starting)")
            lastTeardownAt = SystemClock.elapsedRealtime()
        }
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
        // State first, close after. Every field this method touches is now
        // consistent for anything that runs before the AP has actually gone,
        // and the release itself no longer sits in the way — see [releaseAsync].
        val doomed = reservation
        reservation = null
        isHosting = false
        releaseAsync(doomed)
    }

    /**
     * Hands a reservation back to the framework off the main thread.
     *
     * `LocalOnlyHotspotReservation.close()` is a synchronous binder call into
     * system_server, and method-channel handlers run on the platform thread —
     * which on Android is the main thread. That was survivable while the only
     * caller was the user leaving a session they had been hosting.
     *
     * It stopped being survivable when joining started releasing our own AP
     * (WifiHotspotCubit._dropOtherSide, reached from _onJoined). That fires the
     * teardown at the single worst moment: WifiService is mid-association on the
     * network we just joined, and on a single-radio phone releasing the SoftAP
     * means a full radio mode switch it cannot even begin until the association
     * settles. The binder call blocks behind all of it. Measured on a Galaxy S8+
     * (Android 9): ANR immediately after the join, app gone from the screen.
     *
     * Nothing here needs the answer. `close()` returns no result, and the AP
     * going down is reported through `onStopped` on the main looper regardless
     * of which thread asked for it — so [stop] clears its own state up front and
     * lets the release land whenever the framework gets to it.
     *
     * The thread is a daemon on purpose: `onDestroy` calls [stop], and a release
     * in flight must not be what keeps the process alive, nor be cancelled by
     * the activity going away before the AP is down.
     */
    private fun releaseAsync(res: WifiManager.LocalOnlyHotspotReservation?) {
        if (res == null) return
        Thread({ runCatching { res.close() } }, "tark-hotspot-release")
            .apply { isDaemon = true }
            .start()
    }

    private data class Credentials(
        val ssid: String,
        val passphrase: String,
        val security: String,
    )

    companion object {
        /** Logcat tag for on-device diagnosis of the host half of the bridge. */
        private const val TAG = "TarkHotspot"

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

        // How long an AP has to stay up after onStarted before its credentials
        // are worth putting on screen. Long enough to catch the come-up-and-die
        // case, short enough to stay inside the "starting the hotspot" state
        // the host screen is already showing.
        private const val AP_CONFIRM_MS = 1_500L
    }
}
