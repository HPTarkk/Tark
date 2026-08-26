package com.b1101.tark.network

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import com.b1101.tark.keepalive.SessionKeepAliveService
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Privacy-safe, read-only platform evidence for Room transport planning.
 *
 * This handler never decides who owns a Room or who should host a transport. It
 * only reports facts the local Android runtime can prove right now. Dart omits
 * the advertisement entirely if this snapshot is unavailable, so unknown state
 * is never fabricated as eligible capability.
 */
class TransportCapabilityHandler(
    private val context: Context,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val METHOD_CHANNEL = "tark/transport_capabilities"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "snapshot" -> result.success(snapshot())
            else -> result.notImplemented()
        }
    }

    private fun snapshot(): Map<String, Any>? {
        val battery = batteryPercent() ?: return null
        val pm = context.packageManager
        return mapOf(
            "canHostHotspot" to (
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    pm.hasSystemFeature(PackageManager.FEATURE_WIFI)
                ),
            "bluetoothSupported" to pm.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH),
            // During a live Room this is concrete evidence that the foreground
            // keep-alive service actually exists. Merely being on Android is
            // not treated as background readiness.
            "backgroundReady" to isKeepAliveRunning(),
            "batteryPercent" to battery,
        )
    }

    @Suppress("DEPRECATION")
    private fun isKeepAliveRunning(): Boolean {
        val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            ?: return false
        // On Android O+ getRunningServices is restricted to this app's own
        // services, which is exactly the evidence needed here.
        return runCatching {
            manager.getRunningServices(Int.MAX_VALUE).any {
                it.service.className == SessionKeepAliveService::class.java.name
            }
        }.getOrDefault(false)
    }

    private fun batteryPercent(): Int? {
        val intent = runCatching {
            context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        }.getOrNull() ?: return null
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        if (level < 0 || scale <= 0) return null
        return ((level * 100.0) / scale).toInt().coerceIn(0, 100)
    }
}
