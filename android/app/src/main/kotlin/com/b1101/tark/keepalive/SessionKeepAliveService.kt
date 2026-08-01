package com.b1101.tark.keepalive

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import com.b1101.tark.hotspot.HotspotHandler

/**
 * Keeps a walkie session alive while the screen is off — the motorcycle case.
 *
 * Without this, a locked screen lets the OS (aggressively on MIUI/Xiaomi) doze
 * the process: the CPU sleeps so the audio threads and UDP send/receive stall,
 * and Wi-Fi is powered down. Running as a foreground service, plus three locks,
 * keeps the whole pipeline running with the screen off:
 *
 *  * [PowerManager.PARTIAL_WAKE_LOCK] — CPU stays awake (audio + networking).
 *  * [WifiManager.WifiLock] — keeps the STA (client) radio on and out of
 *    power-save. The MODE is chosen from the screen state and re-chosen every
 *    time it changes (see [refreshWifiLock]); skipped entirely while this
 *    device is the hotspot HOST (see HotspotHandler).
 *  * [WifiManager.MulticastLock] — required to keep RECEIVING UDP broadcast
 *    with the screen off; without it the OS drops non-unicast frames.
 *
 * Foreground type is `microphone` for the in-channel session (it records
 * continuously via audio_io, and Android 14+ requires a mic-accessing FGS to
 * declare that type), or `connectedDevice` when started earlier by the hotspot
 * host to guard the AP before the mic is recording (see [EXTRA_USES_MIC]).
 *
 * OS-level battery managers (MIUI Autostart, "no restrictions") can still kill
 * the app regardless of this service; the app steers the user to whitelist it
 * (see KeepAliveHandler + the in-app banner).
 */
class SessionKeepAliveService : Service() {

    companion object {
        private const val NOTIFICATION_ID = 2110
        private const val CHANNEL_ID = "tark_session_keepalive"
        private const val WAKE_TAG = "tark:session"
        private const val WIFI_TAG = "tark:wifi"
        private const val MULTICAST_TAG = "tark:multicast"

        /**
         * Intent extra: whether the mic is actively recording at start time.
         * The in-channel session records continuously, so its FGS is typed
         * `microphone`. The hotspot HOST starts this service earlier — while
         * showing the QR, before any mic capture — where a `microphone`-typed
         * FGS would throw on Android 14+ (no mic while-in-use). That phase runs
         * as `connectedDevice` instead (we're sustaining a Wi-Fi AP link).
         */
        const val EXTRA_USES_MIC = "uses_mic"
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    /** Mode [wifiLock] was created with, so a no-op refresh stays a no-op. */
    private var wifiLockMode: Int? = null

    private var screenReceiverRegistered = false

    /**
     * The screen turning off is the moment the Wi-Fi lock has to change shape
     * (see [wantedWifiLockMode]) — and the moment the whole keep-alive exists
     * for, so it must not be missed.
     */
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_ON, Intent.ACTION_SCREEN_OFF -> refreshWifiLock()
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createNotificationChannel()
        // Default to microphone: the plain in-channel session (and any restart
        // via START_STICKY, where intent is null) records the mic.
        val usesMic = intent?.getBooleanExtra(EXTRA_USES_MIC, true) ?: true
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val type = if (usesMic) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                } else {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                }
                startForeground(NOTIFICATION_ID, buildNotification(), type)
            } else {
                startForeground(NOTIFICATION_ID, buildNotification())
            }
        } catch (_: Exception) {
            // Best-effort: e.g. Android 14 rejecting a microphone FGS when the
            // mic while-in-use op isn't held. Bail cleanly rather than crash —
            // the session simply runs without the keep-alive guarantees.
            stopSelf()
            return START_NOT_STICKY
        }
        acquireLocks()
        // Restart if the OS kills us while a session is still meant to run.
        return START_STICKY
    }

    private fun acquireLocks() {
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_TAG).apply {
                setReferenceCounted(false)
                runCatching { acquire() }
            }
        }
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        if (multicastLock == null) {
            multicastLock = wm.createMulticastLock(MULTICAST_TAG).apply {
                setReferenceCounted(false)
                runCatching { acquire() }
            }
        }
        registerScreenReceiver()
        refreshWifiLock()
    }

    /**
     * The Wi-Fi lock mode this device should be holding right now, or null for
     * "hold none".
     *
     * WIFI_MODE_FULL_LOW_LATENCY is the better lock — but only while the screen
     * is on: the platform documents it as active only for a foreground app on a
     * lit screen, and silently gives you nothing otherwise. Holding it across a
     * screen-off session therefore left the STA free to enter power save during
     * the exact stretch this whole service exists to protect. HIGH_PERF is
     * deprecated in favour of it and still does the one thing needed here, so
     * the two are swapped as the screen goes on and off.
     *
     * Null while hosting: a host has no STA link — the single Wi-Fi radio is in
     * SoftAP mode — so the lock does nothing useful and, in LOW_LATENCY mode,
     * nudges the chip back toward STA, which on single-radio phones tears the
     * AP down (the "hotspot drops right after connecting" report).
     */
    private fun wantedWifiLockMode(): Int? {
        if (HotspotHandler.isHosting) return null
        @Suppress("DEPRECATION")
        val highPerf = WifiManager.WIFI_MODE_FULL_HIGH_PERF
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return highPerf
        return if (isScreenOn()) WifiManager.WIFI_MODE_FULL_LOW_LATENCY else highPerf
    }

    /**
     * Brings the Wi-Fi lock in line with [wantedWifiLockMode]. A lock's mode is
     * fixed at creation, so changing it means dropping one and taking another —
     * cheap, and it happens only on screen transitions.
     */
    private fun refreshWifiLock() {
        val wanted = wantedWifiLockMode()
        if (wanted == wifiLockMode && (wanted == null || wifiLock != null)) return
        releaseWifiLock()
        if (wanted == null) return
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        wifiLock = runCatching {
            wm.createWifiLock(wanted, WIFI_TAG).apply {
                setReferenceCounted(false)
                acquire()
            }
        }.getOrNull()
        wifiLockMode = if (wifiLock != null) wanted else null
    }

    private fun isScreenOn(): Boolean {
        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return true
        return runCatching { pm.isInteractive }.getOrDefault(true)
    }

    private fun registerScreenReceiver() {
        if (screenReceiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        }
        // Screen on/off are protected broadcasts and cannot be registered for
        // in the manifest, so this receiver lives exactly as long as the
        // service does. Android 14 wants an explicit export flag; these come
        // from the system and nothing else may reach this receiver.
        runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(screenReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(screenReceiver, filter)
            }
        }.onSuccess { screenReceiverRegistered = true }
    }

    private fun releaseWifiLock() {
        runCatching { if (wifiLock?.isHeld == true) wifiLock?.release() }
        wifiLock = null
        wifiLockMode = null
    }

    private fun releaseLocks() {
        runCatching { if (wakeLock?.isHeld == true) wakeLock?.release() }
        runCatching { if (multicastLock?.isHeld == true) multicastLock?.release() }
        releaseWifiLock()
        wakeLock = null
        multicastLock = null
    }

    override fun onDestroy() {
        if (screenReceiverRegistered) {
            runCatching { unregisterReceiver(screenReceiver) }
            screenReceiverRegistered = false
        }
        releaseLocks()
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Walkie session",
                NotificationManager.IMPORTANCE_LOW,
            ).apply { setShowBadge(false) },
        )
    }

    private fun buildNotification(): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val contentIntent = launch?.let {
            PendingIntent.getActivity(this, 0, it, flags)
        }
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Tark")
            .setContentText("Channel active — keeping the link alive")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .apply { if (contentIntent != null) setContentIntent(contentIntent) }
            .build()
    }
}
