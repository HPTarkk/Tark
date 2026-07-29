package com.b1101.tark.widget

import io.flutter.plugin.common.MethodChannel

/**
 * The one live handle from the widget's broadcast receiver into the running
 * Dart isolate.
 *
 * A widget can't run Flutter, and a BroadcastReceiver has no FlutterEngine of
 * its own — but while a session is live the app process *is* alive (the
 * keep-alive foreground service holds it there), so a control tap can be
 * handed to the same engine that owns the session. [MainActivity] installs
 * the channel when it configures the engine and clears it on teardown;
 * [attached] being false means there is nothing running to control.
 *
 * Starting a session this way is deliberately not offered: the audio engine
 * and every transport live in Dart, so "start in the background" would mean
 * spinning up a headless engine and a second, parallel session lifecycle. The
 * widget's GO LIVE opens the app instead.
 */
object WidgetControlBridge {
    const val CHANNEL = "tark/widget_control"

    private var channel: MethodChannel? = null

    val attached: Boolean
        get() = channel != null

    fun attach(channel: MethodChannel) {
        this.channel = channel
    }

    fun detach() {
        channel = null
    }

    /**
     * Fires [method] at Dart. Returns false when no engine is attached, so
     * the caller can correct the widget rather than silently doing nothing.
     * Must be called on the main thread — a MethodChannel invocation from any
     * other thread throws.
     */
    fun dispatch(method: String): Boolean {
        val target = channel ?: return false
        target.invokeMethod(method, null)
        return true
    }
}
