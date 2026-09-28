package com.b1101.tark.update

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Opens Tark's store listing for the update prompt.
 *
 * Tries the Cafe Bazaar app first — it goes straight to the Update button —
 * and falls back to the listing URL Dart passes in, which any browser opens.
 * Nothing is queried beforehand (that would need a <queries> entry for
 * Bazaar's package); a missing app simply throws ActivityNotFoundException.
 */
class StoreHandler(
    private val activityProvider: () -> Activity?,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val METHOD_CHANNEL = "tark/store"
        private const val BAZAAR_PACKAGE = "com.farsitel.bazaar"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "openListing" -> result.success(openListing(call.argument<String>("url")))
            else -> result.notImplemented()
        }
    }

    private fun openListing(fallbackUrl: String?): Boolean {
        val activity = activityProvider() ?: return false
        val bazaar = Intent(
            Intent.ACTION_VIEW,
            Uri.parse("bazaar://details?id=${activity.packageName}"),
        ).setPackage(BAZAAR_PACKAGE)
        if (tryStart(activity, bazaar)) return true
        val url = fallbackUrl ?: return false
        return tryStart(activity, Intent(Intent.ACTION_VIEW, Uri.parse(url)))
    }

    private fun tryStart(activity: Activity, intent: Intent): Boolean = try {
        activity.startActivity(intent)
        true
    } catch (_: ActivityNotFoundException) {
        false
    } catch (_: SecurityException) {
        false
    }
}
