package com.b1101.tark.keepalive

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
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
 */
class KeepAliveHandler(
    private val context: Context,
    private val activityProvider: () -> android.app.Activity?,
) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                start()
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

    fun start() {
        val intent = Intent(context, SessionKeepAliveService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    fun stop() {
        context.stopService(Intent(context, SessionKeepAliveService::class.java))
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
