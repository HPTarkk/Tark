package com.b1101.tark.billing

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import ir.myket.billingclient.IabHelper
import ir.myket.billingclient.util.Purchase
import ir.myket.billingclient.util.SkuDetails

/**
 * Myket in-app billing, bound directly to the native SDK.
 *
 * Written by hand instead of using the myket_iap Flutter plugin because that
 * plugin only calls IabHelper's four-argument launchPurchaseFlow, which is
 * hardcoded to ITEM_TYPE_INAPP — subscriptions are simply unreachable
 * through it. The SDK itself has launchSubscriptionPurchaseFlow, and the
 * business plan's 1/6/12-month tiers are subscriptions, so this talks to the
 * SDK directly.
 *
 * Signature verification is not done here on purpose: IabHelper runs
 * Security.verifyPurchase with the RSA public key from [init] and refuses to
 * hand back a Purchase whose signature doesn't check out. A Purchase
 * reaching Dart has already been verified against the key.
 */
class BillingHandler(
    private val context: Context,
    private val activityProvider: () -> Activity?,
) : MethodChannel.MethodCallHandler {

    private var helper: IabHelper? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "init" -> setup(call.argument<String>("rsaKey").orEmpty(), result)
            "subscriptionsSupported" ->
                result.success(helper?.subscriptionsSupported() == true)
            "queryInventory" -> queryInventory(call, result)
            "purchase" -> purchase(call, result)
            "consume" -> consume(call, result)
            "dispose" -> {
                dispose()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun setup(rsaKey: String, result: MethodChannel.Result) {
        if (rsaKey.isEmpty()) {
            Log.w(TAG, "init without an RSA key — billing stays unavailable")
            result.success(false)
            return
        }
        dispose()
        val created = IabHelper(context, rsaKey)
        helper = created
        // startSetup fires on the main thread and, on a device without Myket
        // installed, may never fire at all — guard so a late or repeated
        // callback can't reply twice on the same channel result.
        var replied = false
        try {
            created.startSetup { outcome ->
                if (replied) return@startSetup
                replied = true
                if (!outcome.isSuccess) {
                    Log.w(TAG, "billing setup failed: ${outcome.message}")
                }
                result.success(outcome.isSuccess)
            }
        } catch (e: Exception) {
            if (!replied) {
                replied = true
                Log.w(TAG, "billing setup threw: ${e.message}")
                result.success(false)
            }
        }
    }

    /**
     * Owned purchases plus SKU details for both product families.
     *
     * Uses the blocking three-list overload rather than queryInventoryAsync:
     * the async variant takes a single SKU list and only ever queries the
     * in-app family, so subscription prices would come back empty. Run on a
     * worker thread for exactly that reason.
     */
    private fun queryInventory(call: MethodCall, result: MethodChannel.Result) {
        val active = helper
        if (active == null) {
            result.success(mapOf("ok" to false, "message" to "not_initialized"))
            return
        }
        val inappSkus = call.argument<List<String>>("inappSkus") ?: emptyList()
        val requestedSubs = call.argument<List<String>>("subsSkus") ?: emptyList()
        Thread {
            val payload: Map<String, Any?> = try {
                val subsSkus =
                    if (active.subscriptionsSupported()) requestedSubs else emptyList()
                val inventory = active.queryInventory(true, inappSkus, subsSkus)
                mapOf(
                    "ok" to true,
                    "subscriptionsSupported" to active.subscriptionsSupported(),
                    "purchases" to inventory.allPurchases.map(::purchaseToMap),
                    "skus" to inventory.allProducts.map(::skuToMap),
                )
            } catch (e: Exception) {
                Log.w(TAG, "queryInventory failed: ${e.message}")
                mapOf("ok" to false, "message" to (e.message ?: "query_failed"))
            }
            main.post { result.success(payload) }
        }.start()
    }

    private fun purchase(call: MethodCall, result: MethodChannel.Result) {
        val active = helper
        if (active == null) {
            result.success(mapOf("ok" to false, "message" to "not_initialized"))
            return
        }
        val activity = activityProvider()
        if (activity == null) {
            result.success(mapOf("ok" to false, "message" to "no_activity"))
            return
        }
        val sku = call.argument<String>("sku")
        if (sku.isNullOrEmpty()) {
            result.success(mapOf("ok" to false, "message" to "no_sku"))
            return
        }
        val payload = call.argument<String>("payload")
        val subscription = call.argument<Boolean>("subscription") == true

        var replied = false
        val listener = IabHelper.OnIabPurchaseFinishedListener { outcome, purchase ->
            if (replied) return@OnIabPurchaseFinishedListener
            replied = true
            result.success(
                mapOf(
                    "ok" to outcome.isSuccess,
                    "response" to outcome.response,
                    "message" to outcome.message,
                    "purchase" to purchase?.let(::purchaseToMap),
                ),
            )
        }
        try {
            if (subscription) {
                active.launchSubscriptionPurchaseFlow(activity, sku, listener, payload)
            } else {
                active.launchPurchaseFlow(activity, sku, listener, payload)
            }
        } catch (e: Exception) {
            if (!replied) {
                replied = true
                Log.w(TAG, "purchase threw: ${e.message}")
                result.success(
                    mapOf("ok" to false, "message" to (e.message ?: "purchase_failed")),
                )
            }
        }
    }

    /**
     * Only ever used by the consumable fallback. Subscriptions and the
     * lifetime non-consumable must never be consumed — consuming them hands
     * the entitlement back to the store and the user loses what they paid
     * for.
     */
    private fun consume(call: MethodCall, result: MethodChannel.Result) {
        val active = helper
        if (active == null) {
            result.success(false)
            return
        }
        val itemType = call.argument<String>("itemType") ?: IabHelper.ITEM_TYPE_INAPP
        val originalJson = call.argument<String>("originalJson").orEmpty()
        val signature = call.argument<String>("signature").orEmpty()
        var replied = false
        try {
            val purchase = Purchase(itemType, originalJson, signature)
            active.consumeAsync(purchase) { _, outcome ->
                if (replied) return@consumeAsync
                replied = true
                result.success(outcome.isSuccess)
            }
        } catch (e: Exception) {
            if (!replied) {
                replied = true
                Log.w(TAG, "consume failed: ${e.message}")
                result.success(false)
            }
        }
    }

    fun dispose() {
        try {
            helper?.dispose()
        } catch (e: Exception) {
            Log.w(TAG, "dispose failed: ${e.message}")
        }
        helper = null
    }

    private fun purchaseToMap(purchase: Purchase): Map<String, Any?> = mapOf(
        "itemType" to purchase.itemType,
        "orderId" to purchase.orderId,
        "sku" to purchase.sku,
        "purchaseTime" to purchase.purchaseTime,
        "purchaseState" to purchase.purchaseState,
        "developerPayload" to purchase.developerPayload,
        "token" to purchase.token,
        "originalJson" to purchase.originalJson,
        "signature" to purchase.signature,
    )

    private fun skuToMap(sku: SkuDetails): Map<String, Any?> = mapOf(
        "sku" to sku.sku,
        "type" to sku.type,
        "price" to sku.price,
        "title" to sku.title,
        "description" to sku.description,
    )

    companion object {
        const val CHANNEL = "tark/billing"
        private const val TAG = "TarkBilling"
    }
}
