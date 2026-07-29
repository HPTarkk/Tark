package com.b1101.tark.widget

import android.content.Context
import android.content.SharedPreferences
import es.antonborri.home_widget.HomeWidgetPlugin

/**
 * Mirror of Dart's `HomeWidgetKeys` (lib/core/home_widget/home_widget_keys.dart).
 *
 * These strings are a cross-language contract: the Dart side writes them into
 * the home_widget SharedPreferences store, this reads them back. Renaming one
 * here without renaming it there silently blanks the widget, so the Dart file
 * is the source of truth and this is kept in step by hand.
 */
private object Keys {
    const val SESSION = "wk_session"
    const val CALLSIGN = "wk_callsign"
    const val PEER_COUNT = "wk_peers"
    const val UPDATED_AT = "wk_updated_at"
    const val MODE_LABEL = "wk_mode_label"
    const val STATUS_LINE = "wk_status_line"
    const val ACTION_LABEL = "wk_action_label"
    const val PEERS_LABEL = "wk_peers_label"
    const val MUTE_LABEL = "wk_mute_label"
    const val END_LABEL = "wk_end_label"
    const val IS_RTL = "wk_rtl"
    const val IS_LIGHT = "wk_light"
}

/** Mirror of Dart's `HomeWidgetSession`, in the same order. */
enum class Session {
    SETUP,
    IDLE,
    CONNECTING,
    LISTENING,
    RECEIVING,
    ON_AIR,
    MUTED,
    RECONNECTING,
    DOWN;

    /** Everything from [CONNECTING] on is a session the app is holding open. */
    val isLive: Boolean
        get() = this != SETUP && this != IDLE

    companion object {
        /**
         * Dart writes the enum's `name`, which is lowerCamelCase ("onAir"),
         * so match case-insensitively against the underscored Kotlin names.
         */
        fun parse(raw: String?): Session {
            val normalized = raw?.replace("_", "")?.lowercase() ?: return IDLE
            return entries.firstOrNull { it.name.replace("_", "").lowercase() == normalized }
                ?: IDLE
        }
    }
}

/**
 * Everything the widget draws, as last published by the app.
 *
 * Display strings arrive pre-localized — the app owns the fa/en ARB files and
 * renders them at publish time, so there is no strings.xml copy to drift (the
 * only native strings are the widget picker's own label and description,
 * which the app never sees).
 */
data class WidgetState(
    val session: Session,
    val callsign: String,
    val peerCount: Int,
    val modeLabel: String,
    val statusLine: String,
    val actionLabel: String,
    val peersLabel: String,
    val muteLabel: String,
    val endLabel: String,
    val isRtl: Boolean,
    val isLight: Boolean,
    /** Publish timestamp; doubles as the launch nonce (see WidgetActions). */
    val updatedAt: Long,
) {
    companion object {
        /**
         * How long a "live" claim is trusted. The app publishes on every state
         * change and on a clean exit, but a process killed by the OS (low
         * memory, a MIUI-style battery manager) never gets to publish IDLE —
         * without this the home screen would advertise a channel that died
         * hours ago. Comfortably longer than the 2s presence tick, so an
         * app that is merely busy is never demoted.
         */
        private const val LIVE_TTL_MS = 90_000L

        fun read(context: Context): WidgetState = from(HomeWidgetPlugin.getData(context))

        /**
         * Reads a number without caring whether it landed as an Int or a Long.
         *
         * The plugin stores whatever type the method channel produced, and
         * Flutter's codec narrows a Dart int to Int32 when it fits — so
         * `wk_peers` arrives as an Integer while `wk_updated_at` (epoch
         * millis) arrives as a Long. Calling getLong on the former throws
         * ClassCastException, which in an AppWidgetProvider means the widget
         * silently never draws.
         */
        private fun numberOf(prefs: SharedPreferences, key: String): Long =
            (prefs.all[key] as? Number)?.toLong() ?: 0L

        fun from(prefs: SharedPreferences): WidgetState {
            val updatedAt = numberOf(prefs, Keys.UPDATED_AT)
            var session = Session.parse(prefs.getString(Keys.SESSION, null))

            // Stale "live" state is downgraded rather than shown, so the
            // widget can never invite the user back into a dead session.
            val age = System.currentTimeMillis() - updatedAt
            if (session.isLive && (updatedAt <= 0L || age > LIVE_TTL_MS)) {
                session = Session.IDLE
            }

            return WidgetState(
                session = session,
                callsign = prefs.getString(Keys.CALLSIGN, "").orEmpty(),
                peerCount = numberOf(prefs, Keys.PEER_COUNT).toInt(),
                modeLabel = prefs.getString(Keys.MODE_LABEL, "").orEmpty(),
                // A widget added before the app has ever published has no
                // strings at all; the layout falls back to its XML defaults
                // rather than rendering an empty card.
                statusLine = prefs.getString(Keys.STATUS_LINE, "").orEmpty(),
                actionLabel = prefs.getString(Keys.ACTION_LABEL, "").orEmpty(),
                peersLabel = prefs.getString(Keys.PEERS_LABEL, "").orEmpty(),
                muteLabel = prefs.getString(Keys.MUTE_LABEL, "").orEmpty(),
                endLabel = prefs.getString(Keys.END_LABEL, "").orEmpty(),
                isRtl = prefs.getBoolean(Keys.IS_RTL, false),
                isLight = prefs.getBoolean(Keys.IS_LIGHT, false),
                updatedAt = updatedAt,
            )
        }
    }
}
