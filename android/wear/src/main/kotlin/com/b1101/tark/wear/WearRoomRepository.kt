package com.b1101.tark.wear

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import com.google.android.gms.wearable.MessageClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable

class WearRoomRepository(context: Context) : MessageClient.OnMessageReceivedListener {
    private val appContext = context.applicationContext
    private val messages by lazy { Wearable.getMessageClient(appContext) }
    private val nodes by lazy { Wearable.getNodeClient(appContext) }
    private val main = Handler(Looper.getMainLooper())

    private val _state = mutableStateOf(WearRoomState.idle)
    val state: State<WearRoomState> get() = _state

    private var started = false
    private val poll = object : Runnable {
        override fun run() {
            requestState()
            if (started) main.postDelayed(this, POLL_MS)
        }
    }

    fun start() {
        if (started) return
        started = true
        runCatching { messages.addListener(this) }
        requestState()
        main.postDelayed(poll, POLL_MS)
    }

    fun stop() {
        started = false
        main.removeCallbacks(poll)
        runCatching { messages.removeListener(this) }
    }

    fun requestState() {
        nodes.connectedNodes
            .addOnSuccessListener { connected ->
                connected.forEach { node ->
                    messages.sendMessage(node.id, STATE_REQUEST_PATH, byteArrayOf())
                }
            }
    }

    fun sendAction(action: String) {
        nodes.connectedNodes
            .addOnSuccessListener { connected ->
                connected.forEach { node ->
                    messages.sendMessage(
                        node.id,
                        ACTION_PATH,
                        action.toByteArray(Charsets.UTF_8),
                    )
                }
                main.postDelayed({ requestState() }, 250L)
            }
    }

    override fun onMessageReceived(event: MessageEvent) {
        if (event.path != STATE_RESPONSE_PATH) return
        val decoded = WearRoomState.decode(event.data)
        main.post { _state.value = decoded }
    }

    companion object {
        private const val POLL_MS = 2_000L
        private const val ACTION_PATH = "/tark/room/action"
        private const val STATE_REQUEST_PATH = "/tark/room/state/request"
        private const val STATE_RESPONSE_PATH = "/tark/room/state/response"

        const val ACTION_TOGGLE_MUTE = "toggle_mute"
        const val ACTION_RECONNECT = "reconnect"
        const val ACTION_LEAVE = "leave"
    }
}
