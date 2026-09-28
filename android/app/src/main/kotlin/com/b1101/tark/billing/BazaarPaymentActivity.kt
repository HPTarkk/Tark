package com.b1101.tark.billing

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import io.flutter.plugin.common.MethodChannel
import ir.cafebazaar.poolakey.Payment
import ir.cafebazaar.poolakey.request.PurchaseRequest

/**
 * Invisible host for Bazaar's checkout. Poolakey launches checkout through an
 * ActivityResultRegistry, which MainActivity (a plain FlutterActivity) does
 * not have, so this translucent ComponentActivity opens, starts the flow, and
 * closes as soon as Bazaar answers.
 *
 * One purchase at a time: the pending request lives in the companion because
 * an Intent cannot carry the Payment or the Dart result. Dart is answered
 * exactly once, including when this screen goes away without an answer.
 */
class BazaarPaymentActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val request = pending
        // Recreated after the process died, or opened with nothing to do: the
        // Dart side that asked is gone, so there is nobody to answer.
        if (request == null || request.owner != null) {
            finish()
            return
        }
        request.owner = this
        request.payment.subscribeProduct(
            registry = activityResultRegistry,
            request = PurchaseRequest(productId = request.sku),
        ) {
            purchaseFlowBegan { }
            failedToBeginFlow { error ->
                reply { it.error(BazaarBillingHandler.ERROR_FLOW, error.javaClass.simpleName, null) }
            }
            purchaseSucceed { purchase -> reply { it.success(purchase.toMap()) } }
            purchaseCanceled { reply { it.error(BazaarBillingHandler.ERROR_CANCELLED, null, null) } }
            purchaseFailed { error ->
                reply { it.error(BazaarBillingHandler.ERROR_FAILED, error.javaClass.simpleName, null) }
            }
        }
    }

    override fun onDestroy() {
        // Gone before Bazaar answered: back pressed on the blank screen, or
        // the system took it away (configChanges rules out a rotation). Its
        // registry callback dies with it, so answer now or the purchase lock
        // never clears. The purchase may still have gone through and the
        // paywall's restore path finds it, so this is "failed", not
        // "cancelled".
        reply { it.error(BazaarBillingHandler.ERROR_FAILED, "interrupted", null) }
        super.onDestroy()
    }

    private fun reply(answer: (MethodChannel.Result) -> Unit) {
        // Only the screen that opened checkout may answer for it.
        val request = pending?.takeIf { it.owner === this } ?: return
        pending = null
        answer(request.result)
        if (!isFinishing) finish()
    }

    private class Pending(
        val payment: Payment,
        val sku: String,
        val result: MethodChannel.Result,
    ) {
        var owner: BazaarPaymentActivity? = null
    }

    companion object {
        private var pending: Pending? = null

        /** False when a purchase is already open; the caller answers "busy". */
        fun start(
            activity: Activity,
            payment: Payment,
            sku: String,
            result: MethodChannel.Result,
        ): Boolean {
            if (pending != null) return false
            val request = Pending(payment, sku, result)
            pending = request
            try {
                activity.startActivity(Intent(activity, BazaarPaymentActivity::class.java))
            } catch (error: Throwable) {
                pending = null
                throw error
            }
            return true
        }
    }
}
