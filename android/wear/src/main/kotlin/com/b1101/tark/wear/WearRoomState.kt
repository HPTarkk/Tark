package com.b1101.tark.wear

import android.content.Context
import org.json.JSONObject

enum class RoomSession {
    SETUP,
    IDLE,
    CONNECTING,
    LISTENING,
    RECEIVING,
    ON_AIR,
    MUTED,
    RECONNECTING,
    DOWN;

    val isLive: Boolean get() = this != SETUP && this != IDLE

    companion object {
        fun parse(raw: String?): RoomSession {
            val normalized = raw?.replace("_", "")?.lowercase() ?: return IDLE
            return entries.firstOrNull {
                it.name.replace("_", "").lowercase() == normalized
            } ?: IDLE
        }
    }
}

data class WearRoomState(
    val session: RoomSession,
    val callsign: String,
    val peerCount: Int,
    val talker: String,
    val modeLabel: String,
    val statusLine: String,
    val updatedAt: Long,
) {
    val isLive: Boolean get() = session.isLive
    val isMuted: Boolean get() = session == RoomSession.MUTED
    val isReconnecting: Boolean get() = session == RoomSession.RECONNECTING

    fun persist(context: Context) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_ROOM_STATE, toJson().toString())
            .apply()
    }

    private fun toJson(): JSONObject = JSONObject()
        .put("session", session.name.lowercase())
        .put("callsign", callsign)
        .put("peerCount", peerCount)
        .put("talker", talker)
        .put("modeLabel", modeLabel)
        .put("statusLine", statusLine)
        .put("updatedAt", updatedAt)

    companion object {
        private const val PREFS_NAME = "tark_watch_room"
        private const val KEY_ROOM_STATE = "last_room_state"

        val idle = WearRoomState(
            session = RoomSession.IDLE,
            callsign = "",
            peerCount = 0,
            talker = "",
            modeLabel = "",
            statusLine = "گوشی را باز کن",
            updatedAt = 0L,
        )

        fun readCached(context: Context): WearRoomState {
            val raw = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getString(KEY_ROOM_STATE, null)
                ?: return idle
            return decode(raw)
        }

        fun decode(bytes: ByteArray): WearRoomState =
            decode(bytes.toString(Charsets.UTF_8))

        private fun decode(raw: String): WearRoomState = runCatching {
            val json = JSONObject(raw)
            WearRoomState(
                session = RoomSession.parse(json.optString("session")),
                callsign = json.optString("callsign"),
                peerCount = json.optInt("peerCount"),
                talker = json.optString("talker"),
                modeLabel = json.optString("modeLabel"),
                statusLine = json.optString("statusLine"),
                updatedAt = json.optLong("updatedAt"),
            )
        }.getOrDefault(idle)
    }
}
