package com.b1101.tark.widget

import android.graphics.Color
import androidx.annotation.ColorInt

/**
 * The app's two palettes, duplicated for the widget process.
 *
 * These are the same values as `AppPalette.dark` / `AppPalette.light` in
 * lib/core/theme/app_colors.dart. The widget can't reach Dart, and it follows
 * the *app's* theme setting rather than the system's — so this can't be a
 * values/values-night resource pair either. When a palette hex changes in
 * Dart, it changes here too.
 */
data class WidgetPalette(
    @ColorInt val background: Int,
    @ColorInt val surface: Int,
    @ColorInt val card: Int,
    @ColorInt val border: Int,
    /**
     * Unlit dial ticks. Not [border]: the border tone is tuned for hairlines
     * against a card, and on the light palette (#E0D5BD on cream) the tick
     * ring all but disappeared. This is pulled to stay legible on the
     * instrument face in both themes.
     */
    @ColorInt val tickIdle: Int,
    @ColorInt val amber: Int,
    @ColorInt val amberDim: Int,
    @ColorInt val red: Int,
    @ColorInt val green: Int,
    @ColorInt val textPrimary: Int,
    @ColorInt val textSecondary: Int,
) {
    /** The accent that represents [session] — drives the dial and the status text. */
    @ColorInt
    fun accentFor(session: Session): Int = when (session) {
        Session.ON_AIR -> red
        Session.MUTED -> textSecondary
        Session.RECEIVING -> green
        Session.DOWN -> red
        Session.RECONNECTING -> amberDim
        Session.LISTENING, Session.CONNECTING -> amber
        Session.IDLE, Session.SETUP -> amber
    }

    companion object {
        /** "Night radio" — gunmetal slate against a hot orange accent. */
        val DARK = WidgetPalette(
            background = Color.parseColor("#0B0E11"),
            surface = Color.parseColor("#13171C"),
            card = Color.parseColor("#1A2027"),
            border = Color.parseColor("#2D343D"),
            tickIdle = Color.parseColor("#3E4753"),
            amber = Color.parseColor("#F5853F"),
            amberDim = Color.parseColor("#D9661F"),
            red = Color.parseColor("#EF5350"),
            green = Color.parseColor("#4CAF50"),
            textPrimary = Color.parseColor("#E9EDF1"),
            textSecondary = Color.parseColor("#8B939D"),
        )

        /** "Field radio" — warm paper and brass. */
        val LIGHT = WidgetPalette(
            background = Color.parseColor("#F6F1E7"),
            surface = Color.parseColor("#EFE8D8"),
            card = Color.parseColor("#FFFDF7"),
            border = Color.parseColor("#E0D5BD"),
            tickIdle = Color.parseColor("#B9A987"),
            amber = Color.parseColor("#B26B00"),
            amberDim = Color.parseColor("#8A5200"),
            red = Color.parseColor("#C62828"),
            green = Color.parseColor("#2E7D32"),
            textPrimary = Color.parseColor("#2A2418"),
            textSecondary = Color.parseColor("#857A64"),
        )

        fun of(isLight: Boolean): WidgetPalette = if (isLight) LIGHT else DARK
    }
}

/** [this] at [alpha] (0..1), keeping its RGB. */
@ColorInt
fun Int.withAlpha(alpha: Float): Int =
    Color.argb(
        (alpha.coerceIn(0f, 1f) * 255f).toInt(),
        Color.red(this),
        Color.green(this),
        Color.blue(this),
    )
