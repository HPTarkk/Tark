package com.b1101.tark.audio

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.provider.Settings
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Dart bridge for pausing OTHER apps' media playback — needed because
 * stopping our own capture (see [SystemAudioHandler]'s "stop") only tears
 * down [SystemAudioCaptureService]; AudioPlaybackCapture is non-destructive
 * by design and never touches the source app, so the music the user just
 * "stopped" keeps playing locally.
 *
 * Android has no direct API for one app to pause another's playback. The
 * only general mechanism is enumerating active MediaSessions via
 * [MediaSessionManager.getActiveSessions], which requires this app to be an
 * enabled NotificationListenerService ([TarkNotificationListenerService]) —
 * a real, user-granted permission (Settings > Notification access), not
 * just an in-app dialog.
 *
 * Methods (channel "tark/media_control"):
 *   hasNotificationAccess     -> Boolean
 *   requestNotificationAccess -> null (opens system settings)
 *   pauseOtherMedia           -> null; best-effort, silent no-op without access
 *   isOtherMediaPlaying       -> Boolean; false without access
 */
class MediaControlHandler(
    private val context: Context,
    private val activityProvider: () -> Activity?,
) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasNotificationAccess" -> result.success(hasNotificationAccess())
            "requestNotificationAccess" -> {
                requestNotificationAccess()
                result.success(null)
            }
            "pauseOtherMedia" -> {
                pauseOtherMedia()
                result.success(null)
            }
            "isOtherMediaPlaying" -> result.success(isOtherMediaPlaying())
            else -> result.notImplemented()
        }
    }

    private fun hasNotificationAccess(): Boolean {
        val enabled = Settings.Secure.getString(
            context.contentResolver,
            "enabled_notification_listeners",
        ) ?: return false
        return enabled.contains(context.packageName)
    }

    private fun requestNotificationAccess() {
        val activity = activityProvider() ?: context
        runCatching {
            val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
            if (activity !is Activity) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
        }
    }

    /**
     * Whether some other app currently holds a media session in a playing
     * state.
     *
     * This exists to disambiguate one specific report: a capture stream that
     * runs but delivers pure silence. That is the normal state when nothing is
     * playing, and it is also what a device does when its audio policy refuses
     * to hand over playback capture while our call-mode session is open
     * (confirmed on a Redmi Note 9 Pro / MIUI, Android 12). The capture stream
     * cannot tell those apart — both are zeros — but the session state can.
     *
     * Best-effort by design: without notification access this returns false, so
     * callers must treat it as "cannot confirm anything is playing" rather than
     * as proof that nothing is.
     */
    private fun isOtherMediaPlaying(): Boolean {
        if (!hasNotificationAccess()) return false
        return runCatching {
            val manager = context.getSystemService(Context.MEDIA_SESSION_SERVICE)
                as MediaSessionManager
            val component = ComponentName(context, TarkNotificationListenerService::class.java)
            manager.getActiveSessions(component).any {
                it.playbackState?.state == PlaybackState.STATE_PLAYING
            }
        }.getOrDefault(false)
    }

    private fun pauseOtherMedia() {
        if (!hasNotificationAccess()) return
        runCatching {
            val manager = context.getSystemService(Context.MEDIA_SESSION_SERVICE)
                as MediaSessionManager
            val component = ComponentName(context, TarkNotificationListenerService::class.java)
            for (controller in manager.getActiveSessions(component)) {
                runCatching { controller.transportControls.pause() }
            }
        }
    }
}
