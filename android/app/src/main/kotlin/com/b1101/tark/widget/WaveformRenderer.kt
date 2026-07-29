package com.b1101.tark.widget

import android.graphics.Bitmap
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import kotlin.math.abs
import kotlin.math.sin

/**
 * The slim bar strip under the status line — a voice-level readout.
 *
 * Deliberately deterministic: the bar envelope is a fixed sum of sines, not
 * random, so consecutive publishes of the same state redraw identically. A
 * widget repaints at unpredictable moments (any app state change, a launcher
 * reload), and a randomized waveform would visibly reshuffle each time for no
 * reason, which reads as broken rather than lively.
 *
 * Only the *amplitude* tracks the session, so the strip settles to a quiet
 * line when nothing is happening and fills out when the channel is hot.
 */
object WaveformRenderer {

    /**
     * Few and chunky on purpose. The strip is displayed with `fitXY` across a
     * wide, short slot (~230x18dp), so the bitmap's aspect has to be close to
     * that or the bars get squashed vertically on the way in — an earlier
     * 30-bar 640x72 version collapsed into what looked like a dotted line.
     */
    private const val BARS = 13
    private const val WIDTH_PX = 560
    private const val HEIGHT_PX = 48

    /**
     * Frames the ViewFlipper cycles through to fake motion. Three is enough to
     * read as movement without the bitmaps crowding the RemoteViews Binder
     * budget (see DialRenderer.SIZE_PX for the other half of that budget).
     */
    const val FRAMES = 3

    /**
     * [frame] shifts the wave along, so consecutive frames look like the same
     * meter a moment later rather than three unrelated pictures. Ignored when
     * the session isn't live — every frame comes out identical, which is what
     * makes the flip invisible at rest.
     */
    fun render(state: WidgetState, palette: WidgetPalette, frame: Int = 0): Bitmap {
        val bitmap = Bitmap.createBitmap(WIDTH_PX, HEIGHT_PX, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val accent = palette.accentFor(state.session)

        val amplitude = when (state.session) {
            Session.ON_AIR -> 1f
            Session.RECEIVING -> 0.82f
            Session.LISTENING -> 0.34f
            Session.CONNECTING, Session.RECONNECTING -> 0.22f
            Session.MUTED -> 0.14f
            Session.DOWN -> 0.10f
            Session.IDLE, Session.SETUP -> 0.16f
        }
        val live = state.session.isLive
        val phase = if (live) frame * (2f * Math.PI.toFloat() / FRAMES) else 0f
        // Bar : gap = 1 : 0.75, so the bars stay solid rather than hairlines.
        val barWidth = WIDTH_PX / (BARS + (BARS - 1) * 0.75f)
        val stride = barWidth * 1.75f
        val mid = HEIGHT_PX / 2f

        val bar = Paint(Paint.ANTI_ALIAS_FLAG)
        val glow = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            maskFilter = BlurMaskFilter(7f, BlurMaskFilter.Blur.NORMAL)
        }

        for (i in 0 until BARS) {
            val t = i / (BARS - 1f)
            // Two incommensurate sines plus a centre-weighted envelope: reads
            // as speech rather than as a repeating pattern.
            val shape = abs(sin(t * 9.4f + phase) * 0.6f + sin(t * 3.1f + 1.7f - phase) * 0.4f)
            val envelope = 0.45f + 0.55f * sin(t * Math.PI.toFloat())
            // Amplitude scales the bar *range* rather than multiplying a fixed
            // one, so the envelope still shows at low levels. Multiplying
            // straight through left a flat floor dominating every quiet state,
            // and the strip read as a row of identical dashes — a loading
            // skeleton, not a level meter. Half-height: 0.46 fills most of the
            // strip when the channel is hot.
            val h = HEIGHT_PX * (0.10f + 0.36f * amplitude) * shape * envelope +
                HEIGHT_PX * 0.045f

            val left = i * stride
            val rect = RectF(left, mid - h, left + barWidth, mid + h)
            // Softened corners, NOT a pill: at barWidth/2 every short bar
            // became a circle and the strip read as a row of dots.
            val radius = barWidth * 0.3f

            if (live && amplitude > 0.3f) {
                glow.color = accent.withAlpha(0.35f)
                canvas.drawRoundRect(rect, radius, radius, glow)
            }
            // Bars fade toward the edges so the strip ends softly instead of
            // being cut off by the bitmap bounds.
            val fade = 0.45f + 0.55f * sin(t * Math.PI.toFloat())
            bar.color =
                if (live) accent.withAlpha(fade) else palette.tickIdle.withAlpha(fade * 0.8f)
            canvas.drawRoundRect(rect, radius, radius, bar)
        }
        return bitmap
    }
}
