package com.b1101.tark.widget

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import com.b1101.tark.R
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * The Tark home-screen widget.
 *
 * Renders whatever the app last published (see `HomeWidgetService.publish` on
 * the Dart side) — a widget can't run Flutter, so it is a pure view over that
 * snapshot. Taps either launch the app with a `tark://widget/...` URI or, when
 * a session is already live, go to [TarkWidgetControlReceiver] and never open
 * the app at all.
 */
class TarkWidgetProvider : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val state = WidgetState.from(widgetData)
        appWidgetIds.forEach { id ->
            appWidgetManager.updateAppWidget(id, buildViews(context, appWidgetManager, id, state))
        }
    }

    /**
     * Resizing changes which layout fits, so re-render rather than leaving a
     * compact face stretched across four cells.
     */
    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        super.onAppWidgetOptionsChanged(context, appWidgetManager, appWidgetId, newOptions)
        appWidgetManager.updateAppWidget(
            appWidgetId,
            buildViews(context, appWidgetManager, appWidgetId, WidgetState.read(context)),
        )
    }

    private fun buildViews(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        state: WidgetState,
    ): RemoteViews {
        val palette = WidgetPalette.of(state.isLight)
        val accent = palette.accentFor(state.session)

        // Measured width decides the layout, rather than branching on API 31's
        // size-mapped RemoteViews — this works identically on every version
        // the app supports, and onAppWidgetOptionsChanged keeps it honest.
        val minWidthDp = appWidgetManager.getAppWidgetOptions(appWidgetId)
            .getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)
        val wide = minWidthDp >= WIDE_THRESHOLD_DP
        val layout = if (wide) R.layout.widget_tark_wide else R.layout.widget_tark_compact

        return RemoteViews(context.packageName, layout).apply {
            setInt(
                R.id.widget_root,
                "setBackgroundResource",
                if (state.isLight) R.drawable.widget_bg_light else R.drawable.widget_bg_dark,
            )
            setImageViewBitmap(R.id.widget_dial, DialRenderer.render(state, palette))

            setTextViewText(R.id.widget_status, state.statusLine.ifEmpty {
                context.getString(R.string.widget_status_placeholder)
            })
            setTextColor(R.id.widget_status, accent)

            setTextViewText(R.id.widget_mode_badge, state.modeLabel)
            setTextColor(R.id.widget_mode_badge, palette.textSecondary)

            // The whole card opens the app; specific controls below override
            // it for their own bounds.
            setOnClickPendingIntent(
                R.id.widget_root,
                WidgetActions.primary(context, state.session, state.updatedAt),
            )

            if (wide) bindWide(context, state, palette, accent)
        }
    }

    private fun RemoteViews.bindWide(
        context: Context,
        state: WidgetState,
        palette: WidgetPalette,
        accent: Int,
    ) {
        // Only the wide face has room for the level strip. The three frames
        // are what the ViewFlipper cross-fades between; off a live session
        // they render identically, so the flip is invisible (see the layout).
        val waveIds = intArrayOf(R.id.widget_wave_0, R.id.widget_wave_1, R.id.widget_wave_2)
        for (frame in 0 until WaveformRenderer.FRAMES) {
            setImageViewBitmap(waveIds[frame], WaveformRenderer.render(state, palette, frame))
        }

        setInt(
            R.id.widget_mode_badge,
            "setBackgroundResource",
            if (state.isLight) R.drawable.widget_badge_light else R.drawable.widget_badge_dark,
        )
        setOnClickPendingIntent(
            R.id.widget_mode_badge,
            WidgetActions.badge(context, state.updatedAt),
        )

        // Falls back to the app name so the card never shows a blank line
        // before the user has picked a callsign.
        setTextViewText(
            R.id.widget_callsign,
            state.callsign.ifEmpty { context.getString(R.string.widget_app_name) },
        )
        setTextColor(R.id.widget_callsign, palette.textPrimary)

        setTextViewText(R.id.widget_peers, state.peersLabel)
        setTextColor(R.id.widget_peers, palette.textSecondary)
        setViewVisibility(
            R.id.widget_peers,
            if (state.peersLabel.isEmpty()) View.GONE else View.VISIBLE,
        )

        setTextViewText(R.id.widget_primary, state.actionLabel.ifEmpty {
            context.getString(R.string.widget_action_placeholder)
        })
        setInt(
            R.id.widget_primary,
            "setBackgroundResource",
            if (state.isLight) {
                R.drawable.widget_btn_primary_light
            } else {
                R.drawable.widget_btn_primary_dark
            },
        )
        // The primary pill is amber-filled in both palettes, so its label sits
        // on the accent — not on the card — and needs the background color.
        setTextColor(R.id.widget_primary, palette.background)
        setOnClickPendingIntent(
            R.id.widget_primary,
            WidgetActions.primary(context, state.session, state.updatedAt),
        )

        // Mute/end only exist while there is a session to control. Outside
        // one they'd be dead buttons, and their broadcasts would have nothing
        // to reach (see TarkWidgetControlReceiver).
        val live = state.session.isLive
        setViewVisibility(R.id.widget_mute, if (live) View.VISIBLE else View.GONE)
        setViewVisibility(R.id.widget_end, if (live) View.VISIBLE else View.GONE)
        if (!live) return

        setTextViewText(R.id.widget_mute, state.muteLabel)
        setInt(
            R.id.widget_mute,
            "setBackgroundResource",
            if (state.isLight) R.drawable.widget_btn_ghost_light else R.drawable.widget_btn_ghost_dark,
        )
        // Muted is a state worth spotting at a glance, so the button carries
        // the accent while it's the one thing standing between you and the
        // channel hearing you.
        setTextColor(
            R.id.widget_mute,
            if (state.session == Session.MUTED) accent else palette.textPrimary,
        )
        setOnClickPendingIntent(R.id.widget_mute, WidgetActions.mute(context, state.updatedAt))

        setTextViewText(R.id.widget_end, state.endLabel)
        setInt(
            R.id.widget_end,
            "setBackgroundResource",
            if (state.isLight) {
                R.drawable.widget_btn_danger_light
            } else {
                R.drawable.widget_btn_danger_dark
            },
        )
        setTextColor(R.id.widget_end, palette.red)
        setOnClickPendingIntent(R.id.widget_end, WidgetActions.end(context, state.updatedAt))
    }

    companion object {
        /**
         * Below this the console layout can't hold the dial, three lines of
         * text and the action row without clipping, so the compact face is
         * used instead. Roughly three home-screen cells.
         */
        private const val WIDE_THRESHOLD_DP = 180

        /** Redraws every placed widget — used after a background control tap. */
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                android.content.ComponentName(context, TarkWidgetProvider::class.java),
            )
            if (ids.isEmpty()) return
            val state = WidgetState.read(context)
            val provider = TarkWidgetProvider()
            ids.forEach { id ->
                manager.updateAppWidget(id, provider.buildViews(context, manager, id, state))
            }
        }
    }
}
