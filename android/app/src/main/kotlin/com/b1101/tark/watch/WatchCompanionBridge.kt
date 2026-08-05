package com.b1101.tark.watch

import android.content.Context
import android.content.SharedPreferences
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
 * The watch is a remote for the phone-owned room: audio, transport, music
 * capture and reconnect all remain on the phone. Room state is pushed to the
 * watch whenever Flutter republishes its live widget snapshot, which lets the
 * background listener on the watch raise the "room is ready" notification.
 */
class WatchCompanionBridge(context: Context) :
    MessageClient.OnMessageReceivedListener,
    SharedPreferences.OnSharedPreferenceChangeListener {

    private val appContext = context.applicationContext
    private val messages by lazy { Wearable.getMessageClient(appContext) }
    private val nodes by lazy { Wearable.getNodeClient(appContext) }
    private val prefs by lazy { HomeWidgetPlugin.getData(appContext) }
    private val main = Handler(Looper.getMainLooper())

    private val pushState = Runnable { sendStateToAllNodes() }

    fun attach() {
        runCatching { messages.addListener(this) }
        runCatching { prefs.registerOnSharedPreferenceChangeListener(this) }
        main.post(pushState)
    }

    fun detach() {
        main.removeCallbacks(pushState)
        runCatching { prefs.unregisterOnSharedPreferenceChangeListener(this) }
        runCatching { messages.removeListener(this) }
    }

    override fun onMessageReceived(event: MessageEvent) {
        when (event.path) {
            ACTION_PATH -> dispatchAction(event.data.toString(Charsets.UTF_8))
            STATE_REQUEST_PATH -> sendState(event.sourceNodeId)
        }
    }

    override fun onSharedPreferenceChanged(
        sharedPreferences: SharedPreferences?,
        key: String?,
    ) {
        if (key?.startsWith("wk_") != true) return
        // HomeWidgetService writes a complete snapshot as several preference
        // edits. Debounce those edits so the watch receives one coherent room
        // payload instead of a half-updated sequence.
        main.removeCallbacks(pushState)
        main.postDelayed(pushState, STATE_PUSH_DEBOUNCE_MS)
    }

    private fun dispatchAction(action: String) {
        val method = when (action) {
            ACTION_TOGGLE_MUTE -> "toggleMute"
            ACTION_TOGGLE_MUSIC -> "toggleMusic"
            ACTION_RECONNECT -> "retryConnection"
            ACTION_LEAVE -> "endSession"
            else -> return
        }
        main.post {
            WidgetControlBridge.dispatch(method)
            main.postDelayed(pushState, ACTION_REFRESH_DELAY_MS)
        }
    }

    private fun sendStateToAllNodes() {
        nodes.connectedNodes.addOnSuccessListener { connected ->
            connected.forEach { node -> sendState(node.id) }
        }
    }

    private fun sendState(nodeId: String) {
        val widget = WidgetState.read(appContext)
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
        const val ACTION_TOGGLE_MUSIC = "toggle_music"
        const val ACTION_RECONNECT = "reconnect"
        const val ACTION_LEAVE = "leave"

        private const val STATE_PUSH_DEBOUNCE_MS = 180L
        private const val ACTION_REFRESH_DELAY_MS = 450L
    }
}
