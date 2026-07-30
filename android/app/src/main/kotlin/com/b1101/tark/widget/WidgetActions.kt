package com.b1101.tark.widget

import android.app.ActivityOptions
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import com.b1101.tark.MainActivity
import es.antonborri.home_widget.HomeWidgetLaunchIntent

/**
 * The PendingIntents behind every tappable part of the widget.
 *
 * Launch taps go straight to [MainActivity] carrying a `tark://widget/...`
 * URI, which Dart reads through `HomeWidget.initiallyLaunchedFromHomeWidget`
 * (see lib/core/home_widget/home_widget_launch.dart). Control taps go to
 * [TarkWidgetControlReceiver] instead and never open the app.
 *
 * These deliberately do not use home_widget's own `HomeWidgetLaunchIntent
 * .getActivity` helper: it hardcodes request code 0, so every button built
 * with it collides into a single PendingIntent and the last one wins.
 */
object WidgetActions {

    /** Mirrors Dart's `HomeWidgetIntent` names — they travel in the URI path. */
    const val INTENT_GO_LIVE = "goLive"
    const val INTENT_OPEN = "open"
    const val INTENT_SETUP = "setup"
    const val INTENT_SETTINGS = "settings"

    // Distinct per button, so PendingIntents don't overwrite each other.
    private const val RC_PRIMARY = 3101
    private const val RC_BADGE = 3102
    private const val RC_MUTE = 3103
    private const val RC_END = 3104

    private val immutableFlags: Int
        get() = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }

    /**
     * The widget's main button. [nonce] is the app's last publish timestamp;
     * Dart records the one it acted on and ignores a repeat, which is what
     * stops the sticky launch intent from re-opening the mic on a later
     * cold start (see `HomeWidgetLaunch`).
     */
    fun primary(context: Context, session: Session, nonce: Long): PendingIntent {
        val intent = if (session == Session.SETUP) INTENT_SETUP else INTENT_GO_LIVE
        return launch(context, intent, nonce, RC_PRIMARY)
    }

    /** Mode badge — the way in that can never start transmitting. */
    fun badge(context: Context, nonce: Long): PendingIntent =
        launch(context, INTENT_OPEN, nonce, RC_BADGE)

    /**
     * MUTE / END. Both only reach [TarkWidgetControlReceiver] while a Dart
     * isolate is attached to take them; with nothing running they open the
     * app instead, which is the only thing a tap can usefully do.
     */
    fun mute(context: Context, nonce: Long): PendingIntent =
        if (WidgetControlBridge.attached) {
            control(context, TarkWidgetControlReceiver.ACTION_TOGGLE_MUTE, RC_MUTE)
        } else {
            launch(context, INTENT_GO_LIVE, nonce, RC_MUTE)
        }

    fun end(context: Context, nonce: Long): PendingIntent =
        if (WidgetControlBridge.attached) {
            control(context, TarkWidgetControlReceiver.ACTION_END_SESSION, RC_END)
        } else {
            launch(context, INTENT_GO_LIVE, nonce, RC_END)
        }

    /** Plain "bring the app up", for the receiver's stale-binding fallback. */
    fun openIntent(context: Context): Intent =
        Intent(context, MainActivity::class.java).apply {
            action = HomeWidgetLaunchIntent.HOME_WIDGET_LAUNCH_ACTION
            data = Uri.parse("tark://widget/$INTENT_GO_LIVE?n=${System.currentTimeMillis()}")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }

    private fun launch(
        context: Context,
        widgetIntent: String,
        nonce: Long,
        requestCode: Int,
    ): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            // The action the home_widget plugin looks for when the Dart side
            // asks what launched the app.
            action = HomeWidgetLaunchIntent.HOME_WIDGET_LAUNCH_ACTION
            data = Uri.parse("tark://widget/$widgetIntent?n=$nonce")
            // NEW_TASK is required to start an activity from a non-activity
            // context at all. Uniqueness is guaranteed by MainActivity's
            // singleTask launchMode rather than by these flags — the custom
            // action and tark:// data below mean the task this creates does
            // NOT look like a launcher task, which is exactly the case
            // singleTop failed to cover (see AndroidManifest). CLEAR_TOP is
            // kept so a plugin activity left open on top (QR scanner, a
            // permission dialog) doesn't hide the channel we just opened.
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            return PendingIntent.getActivity(context, requestCode, intent, immutableFlags)
        }

        // Android 14 tightened background activity starts: without opting in,
        // the launch from the home screen can be dropped.
        val options = ActivityOptions.makeBasic()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) {
            options.setPendingIntentCreatorBackgroundActivityStartMode(
                ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED,
            )
        } else {
            @Suppress("DEPRECATION")
            options.pendingIntentBackgroundActivityStartMode =
                ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED
        }
        return PendingIntent.getActivity(
            context,
            requestCode,
            intent,
            immutableFlags,
            options.toBundle(),
        )
    }

    private fun control(context: Context, action: String, requestCode: Int): PendingIntent {
        val intent = Intent(context, TarkWidgetControlReceiver::class.java).apply {
            this.action = action
            // Explicit package keeps this an internal broadcast even though
            // the receiver is not exported.
            setPackage(context.packageName)
        }
        return PendingIntent.getBroadcast(context, requestCode, intent, immutableFlags)
    }
}
