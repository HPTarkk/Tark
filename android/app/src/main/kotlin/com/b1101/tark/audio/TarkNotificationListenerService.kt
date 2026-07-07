package com.b1101.tark.audio

import android.service.notification.NotificationListenerService

/**
 * Exists solely so this app can be granted Android's "Notification access".
 * Once the user enables it, MediaSessionManager.getActiveSessions(component)
 * is allowed to enumerate other apps' active media sessions — the only
 * general way for a third-party app to pause another app's playback (see
 * [MediaControlHandler]). We never read or act on actual notifications here.
 */
class TarkNotificationListenerService : NotificationListenerService()
