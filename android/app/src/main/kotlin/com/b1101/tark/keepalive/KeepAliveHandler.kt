package com.b1101.tark.keepalive

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Dart bridge for keeping a walkie session alive in the background.
 *
 * Methods (channel "tark/keepalive"):
 *   start / stop                       -> start/stop [SessionKeepAliveService]
 *   isIgnoringBatteryOptimizations     -> Boolean
 *   requestIgnoreBatteryOptimizations  -> null  (system dialog)
 *   isMiui                             -> Boolean
 *   openAutoStartSettings              -> Boolean (MIUI Autostart, else app details)
 *
 * The service is what actually holds the process alive; the battery / Autostart
 * intents exist because OS-level battery managers (especially MIUI) will freeze
 * or kill the app anyway unless the user whitelists it.
 *
 * `start` and `stop` are ordered against each other here — a stop landing
 * inside the foreground-start window is fatal, so it is parked rather than
 * delivered (see [stop]). Everything stays best-effort: the keep-alive is
 * allowed to not happen, never to take the app down with it.
 */
class KeepAliveHandler(
    private val context: Context,
    private val activityProvider: () -> android.app.Activity?,
) : MethodChannel.MethodCallHandler {

    private companion object {
        /**
         * How long a parked stop waits for its start before being forced.
         *
         * Only ever reached if a start we handed to the OS never produced an
         * onStartCommand at all — past this, AMS's own foreground-start
         * timeout (10s, 20s on low-RAM devices) has already come and gone, so
         * there is no window left to protect and the real risk is the opposite
         * one: a foreground service nobody wants left holding wake locks.
         */
        const val STOP_WATCHDOG_MS = 20_000L
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private val stopWatchdog = Runnable {
        if (!SessionKeepAliveService.isStopPending) return@Runnable
        SessionKeepAliveService.abandonPendingStart()
        stopServiceNow()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                // Defaults to true (mic session); the hotspot host passes false
                // to start earlier, before mic capture, as a connectedDevice FGS.
                start(usesMicrophone = call.argument<Boolean>("usesMicrophone") ?: true)
                result.success(null)
            }
            "stop" -> {
                stop()
                result.success(null)
            }
            "isIgnoringBatteryOptimizations" ->
                result.success(isIgnoringBatteryOptimizations())
            "requestIgnoreBatteryOptimizations" -> {
                requestIgnoreBatteryOptimizations()
                result.success(null)
            }
            "isMiui" -> result.success(isMiui())
            "openAutoStartSettings" -> result.success(openAutoStartSettings())
            else -> result.notImplemented()
        }
    }

    fun start(usesMicrophone: Boolean = true) {
        val intent = Intent(context, SessionKeepAliveService::class.java)
            .putExtra(SessionKeepAliveService.EXTRA_USES_MIC, usesMicrophone)
        mainHandler.removeCallbacks(stopWatchdog)
        SessionKeepAliveService.onStartIssued()
        val issued = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }.isSuccess
        // e.g. Android 12+ refusing a foreground start from the background.
        // Nothing will arrive at onStartCommand, so don't leave a stop parked
        // behind a start that isn't coming.
        if (!issued) SessionKeepAliveService.onStartFailed()
    }

    /**
     * Stops the keep-alive — but never *inside* the foreground-start window.
     *
     * `stopService()` between `startForegroundService()` and the service's own
     * `startForeground()` is a fatal RemoteServiceException, and the callers
     * here are one tap apart: starting the hotspot host and immediately backing
     * out of the pairing screen puts the two microseconds apart. A stop that
     * lands mid-window is handed to the service instead, which shuts itself
     * down as soon as it is legally in the foreground (see
     * [SessionKeepAliveService]).
     */
    fun stop() {
        if (SessionKeepAliveService.queueStopIfStarting()) {
            mainHandler.removeCallbacks(stopWatchdog)
            stopServiceNow()
            return
        }
        // Parked. The service normally honours it within a frame; the watchdog
        // only covers a start that never lands at all.
        mainHandler.removeCallbacks(stopWatchdog)
        mainHandler.postDelayed(stopWatchdog, STOP_WATCHDOG_MS)
    }

    private fun stopServiceNow() {
        runCatching {
            context.stopService(Intent(context, SessionKeepAliveService::class.java))
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return runCatching { pm.isIgnoringBatteryOptimizations(context.packageName) }
            .getOrDefault(false)
    }

    @Suppress("BatteryLife")
    private fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        val activity = activityProvider() ?: return
        runCatching {
            activity.startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:${context.packageName}"),
                ),
            )
        }.onFailure {
            // Some OEMs don't expose the direct-request action — fall back to
            // the general battery-optimization list.
            runCatching {
                activity.startActivity(
                    Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
                )
            }
        }
    }

    private fun isMiui(): Boolean =
        !getSystemProperty("ro.miui.ui.version.name").isNullOrBlank()

    /**
     * Opens MIUI's Autostart manager (the setting that actually stops MIUI
     * from killing the app in the background). Falls back to this app's
     * details page where the component isn't present.
     */
    private fun openAutoStartSettings(): Boolean {
        val activity = activityProvider() ?: context
        val candidates = listOf(
            Intent().setClassName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity",
            ),
            Intent().setClassName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartDetailManagementActivity",
            ),
        )
        for (intent in candidates) {
            if (activity !is android.app.Activity) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (runCatching { activity.startActivity(intent); true }.getOrDefault(false)) {
                return true
            }
        }
        return runCatching {
            val details = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:${context.packageName}"),
            )
            if (activity !is android.app.Activity) {
                details.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(details)
            true
        }.getOrDefault(false)
    }

    @Suppress("PrivateApi")
    private fun getSystemProperty(key: String): String? = runCatching {
        val c = Class.forName("android.os.SystemProperties")
        val get = c.getMethod("get", String::class.java)
        get.invoke(null, key) as? String
    }.getOrNull()
}
