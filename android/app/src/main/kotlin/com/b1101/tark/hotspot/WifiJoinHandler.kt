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
import android.net.wifi.WifiInfo
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
    private var keeperCallback: ConnectivityManager.NetworkCallback? = null
    private var suggested: List<WifiNetworkSuggestion> = emptyList()
    private var joinedSsid: String? = null
    private var lostAnnouncement: Runnable? = null
    private var pendingJoin: PendingJoin? = null
    private var associationProbe: Runnable? = null

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
        if (ssid == joinedSsid) releaseSpecifier() else leave()

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            Log.i(TAG, "join '$ssid' via legacy addNetwork (SDK ${Build.VERSION.SDK_INT})")
            joinLegacy(ssid, passphrase, result)
            return
        }

        if (!wifiManager.isWifiEnabled) {
            Log.w(TAG, "join rejected: Wi-Fi radio is off")
            result.error("wifi_off", "Wi-Fi is turned off", null)
            return
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU && !isLocationEnabled()) {
            Log.w(TAG, "join rejected: system Location is off (Wi-Fi scans fail)")
            result.error("location_off", "Location is off, so Wi-Fi can't scan", null)
            return
        }

        Log.i(
            TAG,
            "join requested security=$security pass=${passphrase.length}ch " +
                "sdk=${Build.VERSION.SDK_INT} importance=${uidImportance()}",
        )

        val specifier = WifiNetworkSpecifier.Builder()
            .setSsid(ssid)
            .apply {
                when {
                    passphrase.isEmpty() -> Unit
                    security.equals("SAE", ignoreCase = true) -> setWpa3Passphrase(passphrase)
                    else -> setWpa2Passphrase(passphrase)
                }
            }
            .build()

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        val pending = PendingJoin(result, AtomicBoolean(false))
        pendingJoin = pending
        val startedAt = SystemClock.elapsedRealtime()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (pendingJoin !== pending || !pending.isPending) return
                cancelAssociationProbe()
                Log.i(TAG, "join completed by specifier callback after ${SystemClock.elapsedRealtime() - startedAt}ms")
                bind(network)
                joinedSsid = ssid
                installSuggestion(ssid, passphrase, security)
                startKeeper()
                pending.reply(true)
            }

            override fun onLost(network: Network) {
                if (network != boundNetwork) return
                if (keeperCallback != null) {
                    Log.i(TAG, "specifier network released — keeper takes over")
                    return
                }
                Log.w(TAG, "network lost with no keeper registered")
                boundNetwork = null
                runCatching { connectivity.bindProcessToNetwork(null) }
                scheduleLostAnnouncement()
            }

            override fun onUnavailable() {
                if (pendingJoin !== pending || !pending.isPending) return
                val elapsed = SystemClock.elapsedRealtime() - startedAt
                if (tryAdoptExpectedCurrentWifi(pending, ssid, passphrase, security)) {
                    Log.i(TAG, "join completed by current-Wi-Fi evidence at framework timeout")
                    return
                }
                cancelAssociationProbe()
                Log.w(TAG, "onUnavailable after ${elapsed}ms (importance=${uidImportance()})")
                pending.reply(false)
            }
        }
        callback = cb

        try {
            connectivity.requestNetwork(request, cb, JOIN_TIMEOUT_MS)
            scheduleAssociationProbe(pending, ssid, passphrase, security)
        } catch (e: SecurityException) {
            cancelAssociationProbe()
            Log.e(TAG, "requestNetwork denied (foreground-only)", e)
            callback = null
            pending.fail("foreground_required", e.message)
        } catch (e: Exception) {
            cancelAssociationProbe()
            Log.e(TAG, "requestNetwork failed", e)
            callback = null
            pending.fail("failed", e.message)
        }
    }

    private fun scheduleAssociationProbe(
        pending: PendingJoin,
        ssid: String,
        passphrase: String,
        security: String,
    ) {
        cancelAssociationProbe()
        lateinit var probe: Runnable
        probe = Runnable {
            if (pendingJoin !== pending || !pending.isPending) {
                if (associationProbe === probe) associationProbe = null
                return@Runnable
            }
            if (tryAdoptExpectedCurrentWifi(pending, ssid, passphrase, security)) {
                if (associationProbe === probe) associationProbe = null
                return@Runnable
            }
            mainHandler.postDelayed(probe, ASSOCIATION_PROBE_INTERVAL_MS)
        }
        associationProbe = probe
        mainHandler.postDelayed(probe, ASSOCIATION_PROBE_INTERVAL_MS)
    }

    private fun cancelAssociationProbe() {
        associationProbe?.let(mainHandler::removeCallbacks)
        associationProbe = null
    }

    private fun tryAdoptExpectedCurrentWifi(
        pending: PendingJoin,
        expectedSsid: String,
        passphrase: String,
        security: String,
    ): Boolean {
        if (pendingJoin !== pending || !pending.isPending) return false
        val network = findExpectedWifiNetwork(expectedSsid) ?: return false

        Log.i(TAG, "join completed by exact current-Wi-Fi evidence")
        bind(network)
        joinedSsid = expectedSsid
        installSuggestion(expectedSsid, passphrase, security)
        startKeeper()
        cancelAssociationProbe()
        pending.reply(true)
        return true
    }

    private fun eligibleWifiNetworks(): List<Pair<Network, NetworkCapabilities>> =
        connectivity.allNetworks.mapNotNull { network ->
            val caps = connectivity.getNetworkCapabilities(network) ?: return@mapNotNull null
            if (
                !caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            ) {
                return@mapNotNull null
            }
            network to caps
        }

    private fun normalizedSsid(raw: String?): String? =
        raw?.trim('"')?.takeIf { it.isNotEmpty() && it != UNKNOWN_SSID }

    @Suppress("DEPRECATION")
    private fun currentWifiSsid(): String? =
        normalizedSsid(runCatching { wifiManager.connectionInfo?.ssid }.getOrNull())

    @Suppress("DEPRECATION")
    private fun capabilityWifiSsid(caps: NetworkCapabilities): String? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        return normalizedSsid((caps.transportInfo as? WifiInfo)?.ssid)
    }

    /**
     * Whether this Android can tell one Wi-Fi Network from another at all.
     *
     * Every discriminator #71 introduced rests on
     * `NetworkCapabilities.transportInfo`, which is API 29+. Below that the
     * framework will not say which SSID a given Network carries, and
     * `getConnectionInfo().getSSID()` is redacted to "<unknown ssid>" without
     * location permission — so "refuse unless proven" is not caution there, it
     * is a permanent refusal. Android 9 keeps the pre-#71 behaviour: prefer the
     * station address wherever it answers, and otherwise bind what is in front
     * of us, exactly as the deleted `looksLikeOurAp()` did.
     *
     * The cost of being wrong runs one way. On Q+ a mis-bind is a live risk
     * worth failing closed over. On pre-Q, refusing leaves the process pinned
     * to nothing with no route back onto the AP — a joiner that reports itself
     * connected and cannot hear a thing.
     */
    private val canIdentifyNetworks: Boolean
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    /**
     * The first eligible handle — what `bindCurrent` did before #71, and null
     * on any Android able to do better.
     */
    private fun fallbackWifiNetwork(
        candidates: List<Pair<Network, NetworkCapabilities>>,
    ): Network? {
        if (canIdentifyNetworks) return null
        Log.w(TAG, "no SSID or station evidence below API 29 — taking the first Wi-Fi handle")
        return candidates.firstOrNull()?.first
    }

    /**
     * The IPv4 address the *station* side of the radio currently holds.
     *
     * The one piece of network identity that survives every API level: unlike
     * the SSID it is not location-gated, and it can only ever describe a
     * network this phone joined — never one it is hosting, because a
     * LocalOnlyHotspot is not a station connection. Below API 29 it is the
     * only evidence there is: [capabilityWifiSsid] returns null for every
     * candidate, and `getConnectionInfo().getSSID()` is redacted to
     * "<unknown ssid>" without location permission.
     */
    @Suppress("DEPRECATION")
    private fun stationIpv4(): String? {
        val raw = runCatching { wifiManager.connectionInfo?.ipAddress }.getOrNull() ?: return null
        if (raw == 0) return null
        // WifiInfo.getIpAddress() is little-endian.
        return "${raw and 0xFF}.${(raw shr 8) and 0xFF}." +
            "${(raw shr 16) and 0xFF}.${(raw shr 24) and 0xFF}"
    }

    /**
     * Which candidate carries the station address, if exactly one does.
     *
     * Sharper than "the only Wi-Fi handle", and sharper in the case that
     * matters: a phone joined to an AP while its own is still up has two
     * handles, and this picks the joined one out of them rather than
     * refusing to choose. Still fails closed when nothing (or more than one
     * thing) matches.
     */
    private fun stationWifiNetwork(
        candidates: List<Pair<Network, NetworkCapabilities>>,
    ): Network? {
        val ipv4 = stationIpv4() ?: return null
        return candidates
            .filter { (network, _) ->
                connectivity.getLinkProperties(network)
                    ?.linkAddresses
                    ?.any { it.address.hostAddress == ipv4 } == true
            }
            .singleOrNull()
            ?.first
    }

    private fun isTheOnlyWifiNetwork(
        network: Network,
        candidates: List<Pair<Network, NetworkCapabilities>>,
    ): Boolean = candidates.size == 1 && candidates.single().first == network

    private fun findExpectedWifiNetwork(expectedSsid: String): Network? {
        val candidates = eligibleWifiNetworks()
        val exact = candidates.filter { (_, caps) -> capabilityWifiSsid(caps) == expectedSsid }
        if (exact.size == 1) return exact.single().first
        if (exact.size > 1) {
            Log.w(TAG, "expected Wi-Fi is exposed by multiple Network handles; refusing ambiguous bind")
            return null
        }

        if (currentWifiSsid() != expectedSsid) return null
        if (candidates.size == 1) return candidates.single().first

        // Two handles is the ordinary shape of "joined an AP while our own was
        // still up", not proof of ambiguity — and refusing it is what silently
        // killed the join on every pre-Q phone, where the checks above can
        // never match. The SSID already said we are on the network we wanted;
        // the station address says which of the handles carries it.
        val station = stationWifiNetwork(candidates)
        if (station != null) return station
        val fallback = fallbackWifiNetwork(candidates)
        if (fallback == null) {
            Log.w(TAG, "matching current Wi-Fi has ${candidates.size} eligible handles; refusing ambiguous bind")
        }
        return fallback
    }

    private fun networkMatchesJoinedAp(network: Network): Boolean {
        val candidates = eligibleWifiNetworks()
        val want = joinedSsid
        if (want == null) {
            // Reached whenever `bindCurrent` could not read an SSID to record —
            // the manual "I've joined" path on Android 9. `looksLikeOurAp()`
            // answered `true` for a null name on every API level; only Q+ has
            // the means to do better.
            if (isTheOnlyWifiNetwork(network, candidates)) return true
            val station = stationWifiNetwork(candidates)
            if (station != null) return station == network
            return !canIdentifyNetworks
        }

        val caps = connectivity.getNetworkCapabilities(network) ?: return false
        if (
            !caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
            caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        ) {
            return false
        }

        capabilityWifiSsid(caps)?.let { return it == want }
        val current = currentWifiSsid()
        if (current != null) {
            return current == want &&
                (isTheOnlyWifiNetwork(network, candidates) ||
                    stationWifiNetwork(candidates) == network)
        }

        // No readable SSID on either side of the comparison — the pre-Q norm,
        // and an association that is perfectly real.
        val station = stationWifiNetwork(candidates)
        if (station != null) return station == network
        // Below API 29, nothing further can be learned. This callback usually
        // arrives *before* DHCP has finished, so there is no station address to
        // match yet and there never will be a per-Network SSID — and this is
        // the one path back onto the AP after `onLost` unpinned the process.
        // Refusing here is what left an Android 9 joiner bound to nothing while
        // the same phone worked perfectly as a host, which never runs a keeper.
        return !canIdentifyNetworks
    }

    private fun startKeeper() {
        if (keeperCallback != null) return
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                cancelLostAnnouncement()
                if (network == boundNetwork) return
                if (!networkMatchesJoinedAp(network)) {
                    Log.w(
                        TAG,
                        "keeper: callback Network is not the joined AP — not binding " +
                            "(sdk=${Build.VERSION.SDK_INT} joinedSsid=${joinedSsid != null} " +
                            "station=${stationIpv4() != null})",
                    )
                    return
                }
                Log.i(TAG, "keeper: joined AP returned — re-pinning the process")
                bind(network)
                mainHandler.post { eventSink?.success(mapOf("event" to "rebound")) }
            }

            override fun onLost(network: Network) {
                if (network != boundNetwork) return
                Log.w(TAG, "keeper: bound network went away")
                boundNetwork = null
                runCatching { connectivity.bindProcessToNetwork(null) }
                scheduleLostAnnouncement()
            }
        }
        keeperCallback = cb
        if (runCatching { connectivity.requestNetwork(request, cb) }.isFailure) {
            Log.w(TAG, "keeper: requestNetwork refused — link will not survive background")
            keeperCallback = null
        }
    }

    private fun stopKeeper() {
        keeperCallback?.let { cb -> runCatching { connectivity.unregisterNetworkCallback(cb) } }
        keeperCallback = null
    }

    private fun installSuggestion(ssid: String, passphrase: String, security: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        removeSuggestions()
        val builder = WifiNetworkSuggestion.Builder().setSsid(ssid)
        when {
            passphrase.isEmpty() -> Unit
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
            Log.i(TAG, "suggestion installed")
        } else {
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

    private fun uidImportance(): Int = runCatching {
        val am = context.applicationContext
            .getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        am.runningAppProcesses
            ?.firstOrNull { it.pid == Process.myPid() }
            ?.importance ?: -1
    }.getOrDefault(-1)

    private inner class PendingJoin(
        private val result: MethodChannel.Result,
        private val replied: AtomicBoolean,
    ) {
        val isPending: Boolean
            get() = !replied.get()

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
        val netId: Int
        try {
            if (!wifiManager.isWifiEnabled) wifiManager.isWifiEnabled = true
            netId = wifiManager.addNetwork(config)
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
        awaitLegacyAssociation(ssid, netId, result, attempt = 0)
    }

    /**
     * Whether the radio has settled on the network [joinLegacy] asked for.
     *
     * The SSID is the obvious test and the one that fails: from Android 8 it
     * reads back as "<unknown ssid>" without location permission, so a
     * perfectly good association polls for the full 25s and then reports
     * itself declined — leaving the user at a "did you join?" card for a
     * network they are already on. The network id is the same fact without the
     * redaction, and it is a handle this class created moments ago, so
     * matching it cannot mean some other network.
     */
    @Suppress("DEPRECATION")
    private fun isAssociatedWith(ssid: String, netId: Int): Boolean {
        val info = runCatching { wifiManager.connectionInfo }.getOrNull() ?: return false
        if (normalizedSsid(info.ssid) == ssid) return true
        return netId != -1 && info.networkId == netId
    }

    private fun awaitLegacyAssociation(
        ssid: String,
        netId: Int,
        result: MethodChannel.Result,
        attempt: Int,
    ) {
        if (isAssociatedWith(ssid, netId)) {
            val bound = bindCurrent()
            // bindCurrent can only record the SSID where the framework will
            // read it back. This path knows it either way, and the keeper
            // needs the name to recognise the AP after a drop.
            if (bound) joinedSsid = ssid
            result.success(bound)
            return
        }
        if (attempt >= LEGACY_POLL_ATTEMPTS) {
            result.success(false)
            return
        }
        mainHandler.postDelayed(
            { awaitLegacyAssociation(ssid, netId, result, attempt + 1) },
            LEGACY_POLL_INTERVAL_MS,
        )
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

    private fun openLocationSettings() {
        runCatching {
            context.startActivity(
                Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

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
        runCatching {
            context.startActivity(
                Intent(Settings.ACTION_WIFI_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
        Log.w(TAG, "enableWifi: no Wi-Fi panel, fell back to settings")
        return false
    }

    private fun bindCurrent(): Boolean {
        val candidates = eligibleWifiNetworks()
        if (candidates.isEmpty()) {
            Log.w(TAG, "bindCurrent: no Wi-Fi network to pin to")
            return false
        }
        val currentSsid = currentWifiSsid()
        // There is no expectation to verify here: bindCurrent means "pin to
        // whatever Wi-Fi this phone is on", either because the user joined it
        // from Settings or because the legacy join loop just associated with
        // it. Where the SSID is readable it still goes through the matched
        // path; where it is not — every phone below API 29 without location
        // permission — the station address is the evidence, and demanding more
        // than that would mean never binding at all.
        val network = if (currentSsid != null) {
            findExpectedWifiNetwork(currentSsid)
        } else {
            stationWifiNetwork(candidates)
                ?: candidates.singleOrNull()?.first
                ?: fallbackWifiNetwork(candidates)
        }
        if (network == null) {
            Log.w(TAG, "bindCurrent: current Wi-Fi Network handle is ambiguous")
            return false
        }

        Log.i(TAG, "bindCurrent: pinning process to verified current Wi-Fi")
        bind(network)
        joinedSsid = currentSsid
        startKeeper()
        return true
    }

    private fun bind(network: Network) {
        boundNetwork = network
        runCatching { connectivity.bindProcessToNetwork(network) }
    }

    private fun releaseSpecifier() {
        cancelLostAnnouncement()
        cancelAssociationProbe()
        callback?.let { cb -> runCatching { connectivity.unregisterNetworkCallback(cb) } }
        callback = null
        pendingJoin?.reply(false)
        pendingJoin = null
    }

    fun leave() {
        if (callback != null || boundNetwork != null) {
            Log.i(TAG, "leave: releasing request (bound=${boundNetwork != null})")
        }
        releaseSpecifier()
        stopKeeper()
        removeSuggestions()
        joinedSsid = null
        boundNetwork = null
        runCatching { connectivity.bindProcessToNetwork(null) }
    }

    companion object {
        private const val TAG = "TarkWifiJoin"
        private const val JOIN_TIMEOUT_MS = 40_000
        private const val LOST_GRACE_MS = 15_000L
        private const val ASSOCIATION_PROBE_INTERVAL_MS = 500L
        private const val UNKNOWN_SSID = "<unknown ssid>"
        private const val LEGACY_POLL_ATTEMPTS = 50
        private const val LEGACY_POLL_INTERVAL_MS = 500L
    }
}
