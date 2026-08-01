package com.b1101.tark.hotspot

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.WifiNetworkSuggestion
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
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
 * and re-open its UDP sockets once [join] succeeds (see WifiHotspotCubit), and
 * again on every `rebound` event below.
 *
 * ## Surviving the screen going off
 *
 * A specifier request is scoped to the requesting app being in the FOREGROUND.
 * When the screen locks, the activity stops, the process drops from
 * IMPORTANCE_FOREGROUND to IMPORTANCE_FOREGROUND_SERVICE, and the framework
 * releases the request and disconnects — the reported "locks the phone, call
 * dies; wakes the screen, call comes back". A foreground service does not
 * prevent this, and it cannot be worked around: it is what the API is
 * specified to do.
 *
 * So the specifier is used only to make the FIRST connection (it is the one
 * API that can join a named AP with no trip through Settings), and two
 * background-safe mechanisms are layered underneath it to hold the link:
 *
 *  1. **A network suggestion** ([installSuggestion]) for the same SSID, so once
 *     the specifier request is released the platform reconnects to the AP on
 *     its own, as an ordinary system-owned STA connection that has nothing to
 *     do with our foreground state.
 *  2. **A plain, specifier-less [ConnectivityManager.requestNetwork] for Wi-Fi
 *     without NET_CAPABILITY_INTERNET** ([startKeeper]). That flavour is NOT
 *     foreground-gated, it stops the framework from reaping an internet-less
 *     network as useless, and its onAvailable is what re-pins the process (and
 *     tells Dart to rebuild its sockets) after each reconnect.
 *
 * A loss is therefore not announced immediately: [LOST_GRACE_MS] is given to
 * the two mechanisms above to put us back on the AP silently. Only if they
 * fail does Dart hear `lost` and fall back to a full (foreground-only) rejoin.
 *
 * Methods (channel "tark/wifi_join"):
 *   join(ssid, passphrase, security) -> Bool   true once bound to the network
 *   bindCurrent()                    -> Bool   pin to the Wi-Fi the user joined manually
 *   leave()                          -> null   release the request and unbind
 *
 * Events (channel "tark/wifi_join/events"):
 *   {event: "rebound"} the OS dropped and re-established the network under us;
 *                      we are pinned to it again and sockets need rebuilding
 *   {event: "lost"}    the joined network went away and did not come back
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

    /**
     * The specifier-less request that outlives the foreground. Registered once
     * a join succeeds and kept until [leave]; its onAvailable is the only thing
     * that re-pins the process after the OS drops and rebuilds the link.
     */
    private var keeperCallback: ConnectivityManager.NetworkCallback? = null

    /** Suggestions we installed, so [leave] can take exactly ours back out. */
    private var suggested: List<WifiNetworkSuggestion> = emptyList()

    /** SSID of the AP this session belongs to, for the re-bind sanity check. */
    private var joinedSsid: String? = null

    /**
     * Pending "the link is really gone" announcement. Held back for
     * [LOST_GRACE_MS] so the suggestion/keeper pair can reconnect us without
     * the session ever noticing — an immediate `lost` would kick Dart into a
     * foreground-only rejoin at the exact moment the app is not foreground.
     */
    private var lostAnnouncement: Runnable? = null

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
            "enableWifi" -> result.success(enableWifi())
            "openLocationSettings" -> {
                openLocationSettings()
                result.success(null)
            }
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
            Log.w(TAG, "join rejected: empty SSID")
            result.error("no_ssid", "Join requires an SSID", null)
            return
        }
        // Drop any previous request first: two live specifier requests fight
        // over the single STA and the older one usually wins.
        //
        // Only the specifier, though, when this is a retry at the SAME AP — the
        // suggestion and the keeper are what recover a screen-off drop, and a
        // full leave() here would throw away the working mechanism to make room
        // for the fallback. A different SSID is a different session and does
        // get the full teardown.
        if (ssid == joinedSsid) releaseSpecifier() else leave()

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            Log.i(TAG, "join '$ssid' via legacy addNetwork (SDK ${Build.VERSION.SDK_INT})")
            joinLegacy(ssid, passphrase, result)
            return
        }

        // A specifier request against a disabled radio is rejected by
        // WifiNetworkFactory the moment it arrives — the caller would see an
        // instant "couldn't join" with no dialog and no timeout, which reads as
        // the app being broken rather than Wi-Fi being off. Say which it is.
        // From API 29 an app can no longer flip the radio itself, so this can
        // only be reported, not fixed here.
        if (!wifiManager.isWifiEnabled) {
            Log.w(TAG, "join '$ssid' rejected: Wi-Fi radio is off")
            result.error("wifi_off", "Wi-Fi is turned off", null)
            return
        }

        // Through API 32, Wi-Fi scanning is gated on the *system* Location
        // toggle. The framework does the scanning for a specifier request, so
        // with Location off its network picker comes up empty and cancels
        // itself ~32s later — the app just sees onUnavailable and drops to the
        // manual card, having shown a spinner the whole time. The host side
        // has always preflighted this (HotspotHandler.preflightError); the
        // join side is subject to exactly the same requirement.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU && !isLocationEnabled()) {
            Log.w(TAG, "join '$ssid' rejected: system Location is off (Wi-Fi scans fail)")
            result.error("location_off", "Location is off, so Wi-Fi can't scan", null)
            return
        }

        Log.i(
            TAG,
            "join '$ssid' security=$security pass=${passphrase.length}ch " +
                "sdk=${Build.VERSION.SDK_INT} importance=${uidImportance()}",
        )

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
        val startedAt = SystemClock.elapsedRealtime()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                Log.i(TAG, "onAvailable after ${SystemClock.elapsedRealtime() - startedAt}ms")
                bind(network)
                joinedSsid = ssid
                // Both of these outlive the foreground; the specifier request
                // that got us here does not. Installed only once the AP has
                // actually accepted us, so a failed join leaves nothing behind.
                installSuggestion(ssid, passphrase, security)
                startKeeper()
                pending.reply(true)
            }

            override fun onLost(network: Network) {
                if (network != boundNetwork) return
                // Normally the keeper's to report: this fires every time the
                // screen goes off (the framework releasing an app-scoped
                // request), which is precisely the case that must NOT surface
                // as a dropped link.
                if (keeperCallback != null) {
                    Log.i(TAG, "specifier network released — keeper takes over")
                    return
                }
                // Unless there is no keeper — requestNetwork refused it — in
                // which case nothing else is watching and this is the only
                // report of the loss there will be.
                Log.w(TAG, "network lost with no keeper registered")
                boundNetwork = null
                runCatching { connectivity.bindProcessToNetwork(null) }
                scheduleLostAnnouncement()
            }

            override fun onUnavailable() {
                // The user dismissed the system dialog, the passphrase was
                // wrong, or the AP never showed up before the timeout. Not an
                // error — the UI falls back to a manual join.
                //
                // The elapsed time is the whole diagnosis here: ~JOIN_TIMEOUT_MS
                // means the framework looked for the AP and never found it,
                // while a near-instant one means WifiNetworkFactory refused the
                // request outright (app not judged foreground, radio busy) and
                // the user never even saw the "Connect to …?" dialog.
                val elapsed = SystemClock.elapsedRealtime() - startedAt
                Log.w(TAG, "onUnavailable after ${elapsed}ms (importance=${uidImportance()})")
                pending.reply(false)
            }
        }
        callback = cb

        try {
            connectivity.requestNetwork(request, cb, JOIN_TIMEOUT_MS)
        } catch (e: SecurityException) {
            // requestNetwork with a specifier is foreground-only.
            Log.e(TAG, "requestNetwork denied (foreground-only)", e)
            callback = null
            pending.fail("foreground_required", e.message)
        } catch (e: Exception) {
            Log.e(TAG, "requestNetwork failed", e)
            callback = null
            pending.fail("failed", e.message)
        }
    }

    /**
     * Registers the specifier-less Wi-Fi request that holds the link up once
     * the foreground-scoped one is gone.
     *
     * Two jobs. It asks the framework to keep a Wi-Fi network around even
     * though it has no internet (`removeCapability(NET_CAPABILITY_INTERNET)`),
     * which is what stops an internet-less AP from being scored as useless and
     * dropped. And its onAvailable fires on every reconnect the platform makes
     * on our behalf, which is the only chance we get to re-pin the process —
     * [ConnectivityManager.bindProcessToNetwork] applies to a Network handle,
     * and the handle changes with every reassociation.
     *
     * Unlike a specifier request this one is not foreground-gated and needs no
     * user dialog, so it keeps working with the screen off.
     */
    private fun startKeeper() {
        if (keeperCallback != null) return
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                // Whatever this is, the radio found a Wi-Fi network — so the
                // "it's really gone" verdict is at least premature.
                cancelLostAnnouncement()
                if (network == boundNetwork) return
                if (!looksLikeOurAp()) {
                    // The phone came up on some OTHER Wi-Fi (a remembered home
                    // network usually wins the race against a suggestion).
                    // Pinning to it would send the whole session into a subnet
                    // the peer is not on, which is worse than admitting the
                    // link is gone — so let the grace period run out instead.
                    Log.w(TAG, "keeper: Wi-Fi came up, but not '$joinedSsid' — not binding")
                    return
                }
                Log.i(TAG, "keeper: back on '$joinedSsid' — re-pinning the process")
                bind(network)
                mainHandler.post { eventSink?.success(mapOf("event" to "rebound")) }
            }

            override fun onLost(network: Network) {
                if (network != boundNetwork) return
                Log.w(TAG, "keeper: bound network went away")
                boundNetwork = null
                // Don't leave the process pinned to a network that no longer
                // exists — that would block every recovery path, including the
                // user rejoining by hand.
                runCatching { connectivity.bindProcessToNetwork(null) }
                scheduleLostAnnouncement()
            }
        }
        keeperCallback = cb
        // No timeout: this request has no deadline to meet, it just has to be
        // there whenever the platform brings Wi-Fi back.
        if (runCatching { connectivity.requestNetwork(request, cb) }.isFailure) {
            Log.w(TAG, "keeper: requestNetwork refused — link will not survive background")
            keeperCallback = null
        }
    }

    private fun stopKeeper() {
        keeperCallback?.let { cb -> runCatching { connectivity.unregisterNetworkCallback(cb) } }
        keeperCallback = null
    }

    /**
     * Whether the Wi-Fi we are on now is the AP we joined.
     *
     * Deliberately permissive: from API 31 the SSID is redacted for apps
     * without location permission and comes back as `<unknown ssid>`. An
     * unreadable name must not be treated as a mismatch — that would disable
     * re-binding entirely on exactly the devices that need it — so only a name
     * we can read AND that disagrees counts as a different network.
     */
    private fun looksLikeOurAp(): Boolean {
        val want = joinedSsid ?: return true
        @Suppress("DEPRECATION")
        val current = runCatching { wifiManager.connectionInfo?.ssid?.trim('"') }.getOrNull()
        if (current.isNullOrEmpty() || current == UNKNOWN_SSID) return true
        return current == want
    }

    /**
     * Asks the platform to remember this AP as a network worth connecting to.
     *
     * This is the half that survives the screen going off: a suggestion is
     * system-owned, so the reconnect it drives has nothing to do with whether
     * this app is foreground. Best-effort — on API 30+ the user has to approve
     * suggestions once, and a refusal only costs us the automatic reconnect,
     * not the session.
     */
    private fun installSuggestion(ssid: String, passphrase: String, security: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        removeSuggestions()
        val builder = WifiNetworkSuggestion.Builder().setSsid(ssid)
        when {
            passphrase.isEmpty() -> Unit // open network
            security.equals("SAE", ignoreCase = true) -> builder.setWpa3Passphrase(passphrase)
            else -> builder.setWpa2Passphrase(passphrase)
        }
        val list = listOf(builder.build())
        val status = runCatching { wifiManager.addNetworkSuggestions(list) }
            .getOrElse { e ->
                Log.w(TAG, "addNetworkSuggestions threw: ${e.message}")
                return
            }
        if (status == WifiManager.STATUS_NETWORK_SUGGESTIONS_SUCCESS) {
            suggested = list
            Log.i(TAG, "suggestion installed for '$ssid'")
        } else {
            // Most often STATUS_NETWORK_SUGGESTIONS_ERROR_APP_DISALLOWED (3):
            // the user dismissed the one-time approval. The keeper request
            // still holds an existing association up; only the automatic
            // re-association is lost.
            Log.w(TAG, "addNetworkSuggestions refused (status=$status)")
        }
    }

    private fun removeSuggestions() {
        if (suggested.isEmpty()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            runCatching { wifiManager.removeNetworkSuggestions(suggested) }
        }
        suggested = emptyList()
    }

    /**
     * Starts the countdown to telling Dart the link is gone. Cancelled by any
     * Wi-Fi network turning up in the meantime, which is the normal outcome of
     * a screen-off drop.
     */
    private fun scheduleLostAnnouncement() {
        cancelLostAnnouncement()
        val announcement = Runnable {
            lostAnnouncement = null
            Log.w(TAG, "no Wi-Fi back after ${LOST_GRACE_MS}ms — reporting the link lost")
            eventSink?.success(mapOf("event" to "lost"))
        }
        lostAnnouncement = announcement
        mainHandler.postDelayed(announcement, LOST_GRACE_MS)
    }

    private fun cancelLostAnnouncement() {
        lostAnnouncement?.let { mainHandler.removeCallbacks(it) }
        lostAnnouncement = null
    }

    /**
     * This process's importance as ActivityManager reports it. Purely
     * diagnostic: WifiNetworkFactory drops a specifier request from anything it
     * doesn't consider foreground, and that rejection is otherwise
     * indistinguishable from "the AP wasn't there". Lower is more foreground
     * (IMPORTANCE_FOREGROUND = 100, FOREGROUND_SERVICE = 125).
     */
    private fun uidImportance(): Int = runCatching {
        val am = context.applicationContext
            .getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        am.runningAppProcesses
            ?.firstOrNull { it.pid == Process.myPid() }
            ?.importance ?: -1
    }.getOrDefault(-1)

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
     * Whether the system Location toggle is on — not the app's permission, the
     * device-wide switch, which is what Wi-Fi scanning is actually gated on
     * through API 32. Assumes on when it can't tell, so an unreadable
     * LocationManager blocks nothing.
     */
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

    /** Opens the system Location screen, for the `location_off` dead end. */
    private fun openLocationSettings() {
        runCatching {
            context.startActivity(
                Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    /**
     * Gets the Wi-Fi radio back on, which is a precondition for [join] that the
     * user has no other reason to think about — the bridge screen never
     * mentions Wi-Fi, so "off" just looked like the join being broken.
     *
     * Returns true when the radio is on by the time this answers. From API 29
     * an app can no longer flip it: the best available is [Settings.Panel], a
     * slide-up over the app with a Wi-Fi toggle in it — no full trip through
     * Settings, in keeping with the rest of this flow. That path returns false
     * because the toggle is the user's to make, and the caller has to wait for
     * them rather than retry the join straight away.
     */
    private fun enableWifi(): Boolean {
        if (wifiManager.isWifiEnabled) return true

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            @Suppress("DEPRECATION")
            val ok = runCatching { wifiManager.setWifiEnabled(true) }.getOrDefault(false)
            Log.i(TAG, "enableWifi: setWifiEnabled -> $ok")
            return ok
        }

        val panel = Intent(Settings.Panel.ACTION_WIFI)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (runCatching { context.startActivity(panel) }.isSuccess) {
            Log.i(TAG, "enableWifi: opened the Wi-Fi settings panel")
            return false
        }
        // No panel on this build — the full Wi-Fi settings screen still gets
        // the user to the same switch.
        runCatching {
            context.startActivity(
                Intent(Settings.ACTION_WIFI_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
        Log.w(TAG, "enableWifi: no Wi-Fi panel, fell back to settings")
        return false
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
        }
        if (network == null) {
            Log.w(TAG, "bindCurrent: no Wi-Fi network to pin to")
            return false
        }
        Log.i(TAG, "bindCurrent: pinning process to $network")
        bind(network)
        @Suppress("DEPRECATION")
        joinedSsid = runCatching { wifiManager.connectionInfo?.ssid?.trim('"') }
            .getOrNull()
            ?.takeIf { it.isNotEmpty() && it != UNKNOWN_SSID }
        // A hand-joined network is already system-owned, so it needs no
        // suggestion — but it still gets a new Network handle on every
        // reassociation, and the process pin still has to follow it.
        startKeeper()
        return true
    }

    private fun bind(network: Network) {
        boundNetwork = network
        runCatching { connectivity.bindProcessToNetwork(network) }
    }

    /**
     * Releases only the foreground-scoped specifier request, leaving the
     * suggestion and the keeper in place. This is what a retry at the same AP
     * needs; [leave] is what the end of a session needs.
     */
    private fun releaseSpecifier() {
        cancelLostAnnouncement()
        callback?.let { cb -> runCatching { connectivity.unregisterNetworkCallback(cb) } }
        callback = null
        // Unregistering is silent, so anything still waiting on this request is
        // told here that it didn't happen.
        pendingJoin?.reply(false)
        pendingJoin = null
    }

    fun leave() {
        if (callback != null || boundNetwork != null) {
            Log.i(TAG, "leave: releasing request (bound=${boundNetwork != null})")
        }
        releaseSpecifier()
        // Everything else that would otherwise keep pulling this phone back
        // onto an AP the user has finished with.
        stopKeeper()
        removeSuggestions()
        joinedSsid = null
        boundNetwork = null
        runCatching { connectivity.bindProcessToNetwork(null) }
    }

    companion object {
        /** Logcat tag for on-device diagnosis of the join half of the bridge. */
        private const val TAG = "TarkWifiJoin"

        // How long the framework may spend finding and associating with the
        // host AP before reporting onUnavailable. Generous: the host may still
        // be bringing its hotspot up when the peer scans the code.
        private const val JOIN_TIMEOUT_MS = 40_000

        /**
         * How long the link may be down before Dart is told it is gone.
         *
         * Sized for the screen-off case, which is not an error at all: the
         * framework releases our foreground-scoped specifier request, and the
         * suggestion + keeper put us back on the AP a few seconds later.
         * Announcing a loss inside that window would start a rejoin that
         * cannot succeed (a specifier join needs the foreground) and would
         * bury the user in "Connect to …?" dialogs on their lock screen.
         */
        private const val LOST_GRACE_MS = 15_000L

        /** What WifiInfo returns instead of an SSID when it is redacted. */
        private const val UNKNOWN_SSID = "<unknown ssid>"

        private const val LEGACY_POLL_ATTEMPTS = 50
        private const val LEGACY_POLL_INTERVAL_MS = 500L
    }
}
