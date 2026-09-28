package com.b1101.tark.billing

import android.app.Activity
import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import ir.cafebazaar.poolakey.Connection
import ir.cafebazaar.poolakey.ConnectionState
import ir.cafebazaar.poolakey.Payment
import ir.cafebazaar.poolakey.config.PaymentConfiguration
import ir.cafebazaar.poolakey.config.SecurityCheck
import ir.cafebazaar.poolakey.entity.PurchaseInfo

/**
 * Cafe Bazaar in-app billing (Poolakey) for the subscription screens.
 *
 * This only talks to the Bazaar app on the phone. Nothing it returns unlocks
 * anything: Dart hands the purchase token to our server, which checks it with
 * Bazaar's developer API and answers with the signed entitlement.
 *
 * Poolakey's local RSA signature check runs when Dart passes the app's
 * public key (a build-time define, see BazaarBillingService). It is an early
 * filter in front of the server, not the decision. Without a key it is off,
 * which Poolakey allows only because a server verifies through Bazaar's REST
 * API.
 *
 * Every call either answers or errors. Poolakey reports some failures only
 * through the connection callback, so an operation is started only while the
 * connection is up, and Dart puts a timeout on each call as the backstop.
 */
class BazaarBillingHandler(
    private val context: Context,
    private val activityProvider: () -> Activity?,
) : MethodChannel.MethodCallHandler {

    private var payment: Payment? = null
    private var connection: Connection? = null
    private var generation = 0

    /** Callers waiting on a connect that is already under way. */
    private val pendingConnects = mutableListOf<MethodChannel.Result>()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "connect" -> connect(call.argument<String>("rsaKey"), result)
                "subscribe" -> subscribe(call, result)
                "subscribedProducts" -> subscribedProducts(result)
                "skuDetails" -> skuDetails(call, result)
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            result.error(ERROR_FAILED, error.javaClass.simpleName, null)
        }
    }

    private fun isConnected(): Boolean =
        connection?.getState() == ConnectionState.Connected

    /** Answers true once Bazaar's billing service is bound, false if it can't be. */
    private fun connect(rsaKey: String?, result: MethodChannel.Result) {
        if (isConnected()) {
            result.success(true)
            return
        }
        if (pendingConnects.isNotEmpty()) {
            pendingConnects += result
            return
        }

        // A Payment is single-use: disconnecting it disposes its worker
        // thread, so every new connection gets a fresh one. Released before
        // this caller is queued, because the old connection's disconnect
        // callback fires synchronously.
        releaseConnection()
        pendingConnects += result
        val attempt = ++generation
        val fresh = Payment(
            context = context,
            config = PaymentConfiguration(
                localSecurityCheck = if (rsaKey.isNullOrBlank()) {
                    SecurityCheck.Disable
                } else {
                    SecurityCheck.Enable(rsaPublicKey = rsaKey)
                },
            ),
        )
        payment = fresh
        connection = fresh.connect {
            // A late callback from an earlier connection must not answer
            // callers waiting on this one.
            connectionSucceed { if (attempt == generation) settleConnects(true) }
            connectionFailed { if (attempt == generation) settleConnects(false) }
            disconnected { if (attempt == generation) settleConnects(false) }
        }
    }

    private fun settleConnects(connected: Boolean) {
        val waiting = pendingConnects.toList()
        pendingConnects.clear()
        waiting.forEach { it.success(connected) }
    }

    private fun subscribe(call: MethodCall, result: MethodChannel.Result) {
        val sku = call.argument<String>("sku")
        if (sku.isNullOrEmpty()) {
            result.error(ERROR_FAILED, "missing sku", null)
            return
        }
        val current = payment
        if (current == null || !isConnected()) {
            result.error(ERROR_NOT_CONNECTED, null, null)
            return
        }
        val activity = activityProvider()
        if (activity == null) {
            result.error(ERROR_FAILED, "no activity", null)
            return
        }
        if (!BazaarPaymentActivity.start(activity, current, sku, result)) {
            result.error(ERROR_BUSY, null, null)
        }
    }

    private fun subscribedProducts(result: MethodChannel.Result) {
        val current = payment
        if (current == null || !isConnected()) {
            result.error(ERROR_NOT_CONNECTED, null, null)
            return
        }
        current.getSubscribedProducts {
            querySucceed { purchases -> result.success(purchases.map { it.toMap() }) }
            queryFailed { error -> result.error(ERROR_FAILED, error.javaClass.simpleName, null) }
        }
    }

    private fun skuDetails(call: MethodCall, result: MethodChannel.Result) {
        val skus = call.argument<List<String>>("skus").orEmpty()
        val current = payment
        if (current == null || !isConnected()) {
            result.error(ERROR_NOT_CONNECTED, null, null)
            return
        }
        current.getSubscriptionSkuDetails(skus) {
            getSkuDetailsSucceed { details ->
                result.success(details.map { mapOf("sku" to it.sku, "price" to it.price) })
            }
            getSkuDetailsFailed { error ->
                result.error(ERROR_FAILED, error.javaClass.simpleName, null)
            }
        }
    }

    private fun releaseConnection() {
        val stale = connection
        connection = null
        payment = null
        generation++
        if (stale != null && stale.getState() == ConnectionState.Connected) {
            stale.disconnect()
        }
    }

    /** Unbinds from Bazaar. Called from MainActivity.onDestroy. */
    fun dispose() {
        settleConnects(false)
        releaseConnection()
    }

    companion object {
        const val METHOD_CHANNEL = "tark/bazaar_billing"

        const val ERROR_CANCELLED = "cancelled"
        const val ERROR_NOT_CONNECTED = "not_connected"
        const val ERROR_BUSY = "busy"
        const val ERROR_FLOW = "flow_failed"
        const val ERROR_FAILED = "failed"
    }
}

/**
 * What Dart needs from a purchase. originalJson and dataSignature stay on the
 * phone: the server re-reads the purchase from Bazaar and would ignore them.
 */
internal fun PurchaseInfo.toMap(): Map<String, Any> = mapOf(
    "orderId" to orderId,
    "purchaseToken" to purchaseToken,
    "productId" to productId,
    "purchaseState" to purchaseState.name,
    "purchaseTime" to purchaseTime,
)
