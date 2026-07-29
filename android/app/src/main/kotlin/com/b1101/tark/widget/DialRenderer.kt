package com.b1101.tark.widget

import android.graphics.Bitmap
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint

import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.SweepGradient
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/**
 * Draws the widget's hero graphic: a radio dial that reads as a signal scope.
 *
 * A Canvas bitmap rather than XML drawables because RemoteViews has no way to
 * express what the design needs — a blurred bloom, a machined bezel and a partial
 * sweep. Layout, text and button chrome stay ordinary views; only
 * this element is rasterized.
 *
 * The canvas is software-backed (it draws into a Bitmap), which is what lets
 * [BlurMaskFilter] work here — it is a no-op under hardware acceleration, so
 * the same code in a normal View would silently lose every glow.
 *
 * Nothing animates. A home-screen widget is a static snapshot the system
 * re-renders only when the app pushes an update, so "live" is carried by
 * weight, bloom and how far the gauge swings rather than by motion.
 */
object DialRenderer {

    /**
     * Rendered at a fixed square size and scaled down by the ImageView.
     * Comfortably above the ~204px a 68dp slot needs at xxhdpi, and ~0.4MB at
     * ARGB_8888. Kept deliberately modest: the animated level strip now sends
     * three bitmaps of its own in the same RemoteViews update, and the whole
     * thing has to cross a Binder transaction with roughly a 1MB ceiling.
     */
    const val SIZE_PX = 320

    /** Ticks around the rim. Divisible by 4 so every fourth reads as a major. */
    private const val TICKS = 40

    /** Arc the gauge sweeps through, leaving a gap at the top like a VU meter. */
    private const val SWEEP_DEGREES = 320f

    fun render(state: WidgetState, palette: WidgetPalette): Bitmap {
        val bitmap = Bitmap.createBitmap(SIZE_PX, SIZE_PX, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val c = SIZE_PX / 2f
        // Leave room for the bloom to fall off inside the bitmap instead of
        // being clipped into a hard edge.
        val radius = SIZE_PX / 2f - 16f
        val accent = palette.accentFor(state.session)
        val level = levelOf(state.session)

        // Deliberately few layers. An earlier pass also drew a needle and
        // sonar rings; at the ~76dp this is displayed at, the needle crossed
        // the sweep arc and read as a rendering glitch rather than an
        // instrument, and the rings were invisible clutter. A gauge is
        // legible at a glance because it has one moving part.
        drawBloom(canvas, c, radius, accent, state.session)
        drawFace(canvas, c, radius, palette)
        drawBezel(canvas, c, radius, accent, palette, state.session)
        drawTicks(canvas, c, radius, palette, accent, state)
        drawSweep(canvas, c, radius, accent, level, state.session)
        drawCore(canvas, c, radius, accent, palette, state.session)
        return bitmap
    }

    /** How far round the dial this state sits, 0..1. */
    private fun levelOf(session: Session): Float = when (session) {
        Session.ON_AIR -> 1f
        Session.RECEIVING -> 0.78f
        Session.LISTENING -> 0.52f
        Session.MUTED -> 0.34f
        Session.CONNECTING, Session.RECONNECTING -> 0.24f
        Session.DOWN -> 0.12f
        Session.IDLE, Session.SETUP -> 0.08f
    }

    /** Soft glow behind everything — most of the "live" feel comes from here. */
    private fun drawBloom(
        canvas: Canvas,
        c: Float,
        radius: Float,
        accent: Int,
        session: Session,
    ) {
        val strength = when (session) {
            Session.ON_AIR -> 0.55f
            Session.RECEIVING -> 0.44f
            Session.LISTENING -> 0.26f
            Session.CONNECTING -> 0.22f
            Session.RECONNECTING, Session.DOWN -> 0.18f
            Session.MUTED -> 0.10f
            Session.IDLE, Session.SETUP -> 0.16f
        }
        // A genuinely blurred disc, not a gradient approximation of one — the
        // falloff is what stops the dial looking like flat vector art.
        val glow = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = accent.withAlpha(strength)
            maskFilter = BlurMaskFilter(radius * 0.38f, BlurMaskFilter.Blur.NORMAL)
        }
        canvas.drawCircle(c, c, radius * 0.62f, glow)
    }

    /** Recessed instrument face the rest of the dial sits in. */
    private fun drawFace(canvas: Canvas, c: Float, radius: Float, palette: WidgetPalette) {
        val face = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = RadialGradient(
                c,
                c * 0.86f,
                radius,
                intArrayOf(palette.surface, palette.background),
                floatArrayOf(0f, 1f),
                Shader.TileMode.CLAMP,
            )
        }
        canvas.drawCircle(c, c, radius * 0.88f, face)
    }

    /**
     * Machined bezel: a sweep gradient that runs bright through the top-left
     * and falls away opposite, so the ring catches light like a turned metal
     * edge instead of reading as a flat stroke.
     */
    private fun drawBezel(
        canvas: Canvas,
        c: Float,
        radius: Float,
        accent: Int,
        palette: WidgetPalette,
        session: Session,
    ) {
        val hot = if (session.isLive) accent.withAlpha(0.55f) else palette.tickIdle
        val bezel = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = radius * 0.055f
            shader = SweepGradient(
                c,
                c,
                intArrayOf(
                    palette.tickIdle.withAlpha(0.35f),
                    hot,
                    palette.tickIdle.withAlpha(0.9f),
                    palette.tickIdle.withAlpha(0.25f),
                    palette.tickIdle.withAlpha(0.35f),
                ),
                floatArrayOf(0f, 0.18f, 0.45f, 0.75f, 1f),
            )
        }
        canvas.drawCircle(c, c, radius * 0.94f, bezel)
    }

    /**
     * Dial ticks, longer every fourth. The lit run tracks how many people are
     * on the channel, so the rim says "there are others here" before any text
     * is read — capped at two-thirds so the dial keeps reading as an
     * instrument rather than a full ring.
     */
    private fun drawTicks(
        canvas: Canvas,
        c: Float,
        radius: Float,
        palette: WidgetPalette,
        accent: Int,
        state: WidgetState,
    ) {
        val lit = if (!state.session.isLive) 0 else min(TICKS * 2 / 3, 5 + state.peerCount * 5)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { strokeCap = Paint.Cap.ROUND }
        val glow = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            strokeCap = Paint.Cap.ROUND
            color = accent.withAlpha(0.5f)
            maskFilter = BlurMaskFilter(6f, BlurMaskFilter.Blur.NORMAL)
        }

        for (i in 0 until TICKS) {
            // 12 o'clock, running clockwise.
            val angle = (-90f + i * (360f / TICKS)) * Math.PI.toFloat() / 180f
            val major = i % 4 == 0
            val outer = radius * 0.845f
            val inner = outer - if (major) radius * 0.13f else radius * 0.075f
            val x1 = c + cos(angle) * inner
            val y1 = c + sin(angle) * inner
            val x2 = c + cos(angle) * outer
            val y2 = c + sin(angle) * outer

            if (i < lit) {
                glow.strokeWidth = if (major) 7f else 4f
                canvas.drawLine(x1, y1, x2, y2, glow)
            }
            paint.color = if (i < lit) accent else palette.tickIdle
            paint.strokeWidth = if (major) 5f else 2.8f
            // Unlit ticks stay clearly present — dimming them too far made the
            // bezel look half-drawn rather than like an unlit part of a scale.
            paint.alpha = when {
                i < lit -> 255
                major -> 235
                else -> 180
            }
            canvas.drawLine(x1, y1, x2, y2, paint)
        }
    }

    /**
     * The gauge itself: a thick arc riding inside the ticks, its length the
     * one thing that moves with [level]. Drawn over a full-circle track so a
     * short reading looks like a gauge at rest rather than a broken ring —
     * which is also what gives the idle state something to show.
     */
    private fun drawSweep(
        canvas: Canvas,
        c: Float,
        radius: Float,
        accent: Int,
        level: Float,
        session: Session,
    ) {
        val r = radius * 0.63f
        val rect = RectF(c - r, c - r, c + r, c + r)
        val width = radius * 0.085f

        canvas.drawArc(
            rect,
            -90f,
            SWEEP_DEGREES,
            false,
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = width
                strokeCap = Paint.Cap.ROUND
                color = accent.withAlpha(if (session.isLive) 0.16f else 0.12f)
            },
        )

        val sweep = SWEEP_DEGREES * level
        if (session.isLive) {
            canvas.drawArc(
                rect,
                -90f,
                sweep,
                false,
                Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    style = Paint.Style.STROKE
                    strokeWidth = width * 1.25f
                    strokeCap = Paint.Cap.ROUND
                    color = accent.withAlpha(0.5f)
                    maskFilter = BlurMaskFilter(12f, BlurMaskFilter.Blur.NORMAL)
                },
            )
        }
        canvas.drawArc(
            rect,
            -90f,
            sweep,
            false,
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = width
                strokeCap = Paint.Cap.ROUND
                color = if (session.isLive) accent else accent.withAlpha(0.55f)
            },
        )
    }

    /** Center puck: filled disc with a lit rim, and a slash when muted. */
    private fun drawCore(
        canvas: Canvas,
        c: Float,
        radius: Float,
        accent: Int,
        palette: WidgetPalette,
        session: Session,
    ) {
        val core = radius * 0.155f
        canvas.drawCircle(
            c,
            c,
            core * 1.9f,
            Paint(Paint.ANTI_ALIAS_FLAG).apply { color = palette.card },
        )
        canvas.drawCircle(
            c,
            c,
            core * 1.9f,
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = 3f
                color = accent.withAlpha(0.45f)
            },
        )
        canvas.drawCircle(
            c,
            c,
            core,
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = RadialGradient(
                    c,
                    c - core * 0.4f,
                    core * 1.6f,
                    intArrayOf(lighten(accent), accent),
                    floatArrayOf(0f, 1f),
                    Shader.TileMode.CLAMP,
                )
                alpha = if (session.isLive) 255 else 150
            },
        )

        if (session == Session.MUTED) {
            val d = core * 1.55f
            canvas.drawLine(
                c - d,
                c - d,
                c + d,
                c + d,
                Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    strokeWidth = 7f
                    strokeCap = Paint.Cap.ROUND
                    color = palette.red
                },
            )
        }
    }

    /** Pulls a color toward white, for the core's lit top edge. */
    private fun lighten(color: Int): Int {
        fun up(v: Int) = v + ((255 - v) * 0.45f).toInt()
        return Color.rgb(up(Color.red(color)), up(Color.green(color)), up(Color.blue(color)))
    }
}
