package com.b1101.tark.widget

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Handles the widget's mute and end buttons without opening the app.
 *
 * These are only wired to this receiver while [WidgetControlBridge] is
 * attached — that is, while a Dart isolate is actually running to receive
 * them. The provider re-checks at bind time and points the buttons at the
 * app instead when it isn't (see TarkWidgetProvider.bindWide).
 *
 * The binding can still go stale: the engine can go away between the last
 * redraw and the tap. When that happens the tap opens the app rather than
 * being swallowed. An earlier version instead wrote "session ended" into the
 * widget store, which was wrong twice over — it fabricated state the app had
 * never published, and it made MUTE look like it had hung up.
 */
class TarkWidgetControlReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val method = when (intent.action) {
            ACTION_TOGGLE_MUTE -> "toggleMute"
            ACTION_END_SESSION -> "endSession"
            else -> return
        }

        // onReceive runs on the main thread, which is where a MethodChannel
        // invocation has to happen.
        if (WidgetControlBridge.dispatch(method)) return

        // Nothing running to control. Bring the app up so the user can act —
        // a widget tap is direct user interaction, which is what grants this
        // receiver the temporary background-activity-start allowance.
        runCatching {
            context.startActivity(WidgetActions.openIntent(context))
        }
        TarkWidgetProvider.refresh(context)
    }

    companion object {
        const val ACTION_TOGGLE_MUTE = "com.b1101.tark.widget.TOGGLE_MUTE"
        const val ACTION_END_SESSION = "com.b1101.tark.widget.END_SESSION"
    }
}
