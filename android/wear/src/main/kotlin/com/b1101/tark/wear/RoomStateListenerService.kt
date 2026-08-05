package com.b1101.tark.wear

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.WearableListenerService

/**
 * Receives phone room state even when the watch UI is closed.
 *
 * A live room becomes an ongoing notification. Tapping it opens the compact
 * Tark room remote; when the phone leaves the room, the notification is
 * cancelled. The watch app must be opened once after installation so Wear OS
 * can grant notification permission on Android 13+.
 */
class RoomStateListenerService : WearableListenerService() {
    override fun onMessageReceived(event: MessageEvent) {
        if (event.path != WearRoomRepository.STATE_RESPONSE_PATH) return

        val previous = WearRoomState.readCached(this)
        val room = WearRoomState.decode(event.data)
        room.persist(this)

        if (room.isLive) {
            showRoomNotification(room, newlyLive = !previous.isLive)
        } else {
            NotificationManagerCompat.from(this).cancel(ROOM_NOTIFICATION_ID)
        }
    }

    private fun showRoomNotification(room: WearRoomState, newlyLive: Boolean) {
        ensureNotificationChannel()
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        val openRoom = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            openRoom,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val title = if (newlyLive) "اتاق ترک آماده است" else "اتاق ترک فعال است"
        val person = room.callsign.ifBlank { "ترک" }
        val peers = if (room.peerCount > 0) "${room.peerCount} عضو" else "منتظر دوستت"
        val status = room.statusLine.ifBlank { "متصل" }
        val text = "$person • $peers • $status"

        val notification = NotificationCompat.Builder(this, ROOM_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_tark_mark)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(contentIntent)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setOnlyAlertOnce(!newlyLive)
            .setAutoCancel(false)
            .build()

        NotificationManagerCompat.from(this).notify(
            ROOM_NOTIFICATION_ID,
            notification,
        )
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            ROOM_CHANNEL_ID,
            "روم فعال ترک",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "اعلان ایجاد و وضعیت روم فعال ترک روی ساعت"
            enableVibration(true)
        }
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val ROOM_CHANNEL_ID = "tark_active_room"
        private const val ROOM_NOTIFICATION_ID = 4401
    }
}
