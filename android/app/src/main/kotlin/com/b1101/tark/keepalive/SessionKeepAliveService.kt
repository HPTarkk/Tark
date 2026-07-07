package com.b1101.tark.keepalive

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps a walkie session alive while the screen is off — the motorcycle case.
 *
 * Without this, a locked screen lets the OS (aggressively on MIUI/Xiaomi) doze
 * the process: the CPU sleeps so the audio threads and UDP send/receive stall,
 * and Wi-Fi is powered down. Running as a foreground service, plus three locks,
 * keeps the whole pipeline running with the screen off:
 *
 *  * [PowerManager.PARTIAL_WAKE_LOCK] — CPU stays awake (audio + networking).
 *  * [WifiManager.WifiLock] — Wi-Fi radio stays on and out of power-save
 *    (FULL_LOW_LATENCY on API 29+, else FULL_HIGH_PERF).
 *  * [WifiManager.MulticastLock] — required to keep RECEIVING UDP broadcast
 *    with the screen off; without it the OS drops non-unicast frames.
 *
 * Foreground type is `microphone` because the session records continuously via
 * audio_io — Android 14+ requires a mic-accessing FGS to declare that type.
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
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createNotificationChannel()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
            )
        } else {
            startForeground(NOTIFICATION_ID, buildNotification())
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
        if (wifiLock == null) {
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                @Suppress("DEPRECATION")
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wm.createWifiLock(mode, WIFI_TAG).apply {
                setReferenceCounted(false)
                runCatching { acquire() }
            }
        }
        if (multicastLock == null) {
            multicastLock = wm.createMulticastLock(MULTICAST_TAG).apply {
                setReferenceCounted(false)
                runCatching { acquire() }
            }
        }
    }

    private fun releaseLocks() {
        runCatching { if (wakeLock?.isHeld == true) wakeLock?.release() }
        runCatching { if (wifiLock?.isHeld == true) wifiLock?.release() }
        runCatching { if (multicastLock?.isHeld == true) multicastLock?.release() }
        wakeLock = null
        wifiLock = null
        multicastLock = null
    }

    override fun onDestroy() {
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
