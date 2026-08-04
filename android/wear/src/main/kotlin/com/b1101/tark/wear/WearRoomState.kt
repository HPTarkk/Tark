package com.b1101.tark.wear

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

    companion object {
        val idle = WearRoomState(
            session = RoomSession.IDLE,
            callsign = "",
            peerCount = 0,
            talker = "",
            modeLabel = "",
            statusLine = "گوشی را باز کن",
            updatedAt = 0L,
        )

        fun decode(bytes: ByteArray): WearRoomState = runCatching {
            val json = JSONObject(bytes.toString(Charsets.UTF_8))
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
