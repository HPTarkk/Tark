package com.b1101.tark.watch

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.b1101.tark.widget.WidgetControlBridge
import com.b1101.tark.widget.WidgetState
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONObject

/**
 * Live bridge between the paired Wear OS app and the Flutter session.
 *
 * The watch is deliberately a remote, not a second voice endpoint: the phone
 * continues to own audio, transport and reconnect state. While a room is live
 * the keep-alive foreground service keeps the Flutter engine in this process,
 * so watch actions can reuse [WidgetControlBridge], the same proven path as the
 * home-screen widget's MUTE and END buttons.
 */
class WatchCompanionBridge(context: Context) : MessageClient.OnMessageReceivedListener {
    private val appContext = context.applicationContext
    private val messages by lazy { Wearable.getMessageClient(appContext) }
    private val main = Handler(Looper.getMainLooper())

    fun attach() {
        runCatching { messages.addListener(this) }
    }

    fun detach() {
        runCatching { messages.removeListener(this) }
    }

    override fun onMessageReceived(event: MessageEvent) {
        when (event.path) {
            ACTION_PATH -> dispatchAction(event.data.toString(Charsets.UTF_8))
            STATE_REQUEST_PATH -> sendState(event.sourceNodeId)
        }
    }

    private fun dispatchAction(action: String) {
        val method = when (action) {
            ACTION_TOGGLE_MUTE -> "toggleMute"
            ACTION_RECONNECT -> "retryConnection"
            ACTION_LEAVE -> "endSession"
            else -> return
        }
        main.post { WidgetControlBridge.dispatch(method) }
    }

    private fun sendState(nodeId: String) {
        val widget = WidgetState.read(appContext)
        val prefs = HomeWidgetPlugin.getData(appContext)
        val payload = JSONObject()
            .put("session", widget.session.name.lowercase())
            .put("isLive", widget.session.isLive)
            .put("callsign", widget.callsign)
            .put("peerCount", widget.peerCount)
            .put("talker", prefs.getString("wk_talker", "").orEmpty())
            .put("modeLabel", widget.modeLabel)
            .put("statusLine", widget.statusLine)
            .put("muteLabel", widget.muteLabel)
            .put("endLabel", widget.endLabel)
            .put("isRtl", widget.isRtl)
            .put("updatedAt", widget.updatedAt)
            .toString()
            .toByteArray(Charsets.UTF_8)

        runCatching { messages.sendMessage(nodeId, STATE_RESPONSE_PATH, payload) }
    }

    companion object {
        const val ACTION_PATH = "/tark/room/action"
        const val STATE_REQUEST_PATH = "/tark/room/state/request"
        const val STATE_RESPONSE_PATH = "/tark/room/state/response"

        const val ACTION_TOGGLE_MUTE = "toggle_mute"
        const val ACTION_RECONNECT = "reconnect"
        const val ACTION_LEAVE = "leave"
    }
}
