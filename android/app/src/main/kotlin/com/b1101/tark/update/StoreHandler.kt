package com.b1101.tark.update

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Opens Tarkk's store listing for the update prompt, and Bazaar's own
 * rating page for the rating story.
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
            "openReview" -> result.success(
                openReview(call.argument<String>("id"), call.argument<String>("url")),
            )
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

    /**
     * Bazaar's "rate and review" page, as Bazaar's developer guide documents
     * it: ACTION_EDIT on `bazaar://details?id=<package>`, aimed at Bazaar's
     * package. The user rates there, signed in to Bazaar; nothing about the
     * rating ever passes through Tarkk.
     *
     * Answers which way it went: "bazaar" (the rating page is up), "web" (no
     * Bazaar app, so the listing opened in a browser) or "none".
     *
     * [listingId] is passed in rather than read from the package name so a
     * `.dev` device-test build still lands on the real listing.
     */
    private fun openReview(listingId: String?, fallbackUrl: String?): String {
        val activity = activityProvider() ?: return "none"
        val id = listingId?.takeIf { it.isNotBlank() } ?: activity.packageName
        val review = Intent(
            Intent.ACTION_EDIT,
            Uri.parse("bazaar://details?id=$id"),
        ).setPackage(BAZAAR_PACKAGE)
        if (tryStart(activity, review)) return "bazaar"
        val url = fallbackUrl ?: return "none"
        return if (tryStart(activity, Intent(Intent.ACTION_VIEW, Uri.parse(url)))) {
            "web"
        } else {
            "none"
        }
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
