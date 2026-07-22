package com.b1101.tark.audio

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Call-style audio routing for the walkie session.
 *
 * The (vendored) audio_io engine opens VOICE_COMMUNICATION-class streams,
 * which follow Android's phone-call routing strategy. That strategy needs
 * an explicit route choice — left alone it targets the EARPIECE:
 *
 *  * Bluetooth handsfree connected → bring SCO up BEFORE the engine opens
 *    its streams, and wait for the CONNECTED broadcast (flipping SCO under
 *    already-open streams doesn't re-route on older devices). If SCO never
 *    comes up, fall through to the cases below rather than going silent.
 *  * Wired/USB headset → nothing to select; wired outranks speaker in the
 *    call strategy automatically.
 *  * Nothing attached → speakerphone, the natural walkie-talkie loudness.
 *
 * configureVoice returns true when a Bluetooth SCO route was confirmed.
 *
 * That choice is made once, when the streams open — so headsets that arrive
 * (or leave) mid-session need a second look. The `tark/audio_session/events`
 * stream reports those changes to Dart, which re-opens the engine through
 * reconfigureVoice.
 */
class AudioSessionHandler(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val SCO_TIMEOUT_MS = 4000L

        /** Device types that change which way voice should be routed. The
         *  API-gated constants are compile-time ints, so naming them costs
         *  nothing on older releases — they simply never match there. */
        @Suppress("InlinedApi")
        private val ROUTE_DEVICE_TYPES: Set<Int> = setOf(
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
            AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_HEARING_AID,
            AudioDeviceInfo.TYPE_BLE_HEADSET,
        )
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private val audioManager: AudioManager
        get() = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    /** True while call-mode is engaged, so release only undoes what
     *  configure did and the re-assert call from Dart is a no-op. */
    private var engaged = false

    // Platform voice pre-processing bound to the capture session.
    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null
    private var agc: AutomaticGainControl? = null

    // Route-change reporting. Watching starts when Dart subscribes (i.e. for
    // the lifetime of a walkie session) and stops when it cancels.
    private var eventSink: EventChannel.EventSink? = null
    private var deviceCallback: AudioDeviceCallback? = null
    private var knownRouteDevices: Set<Int>? = null

    init {
        EventChannel(messenger, "tark/audio_session/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    eventSink = events
                    startWatchingDevices()
                }

                override fun onCancel(arguments: Any?) {
                    stopWatchingDevices()
                    eventSink = null
                }
            },
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "configureVoice" -> configureVoice(result)
            "reconfigureVoice" -> reconfigureVoice(result)
            "attachEffects" -> {
                attachEffects(call.argument<Int>("sessionId") ?: -1)
                result.success(null)
            }
            "releaseVoice" -> {
                releaseVoice()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Attaches the platform's voice pre-processing to the AAudio capture
     * session so echo cancellation / noise suppression / auto-gain apply
     * EXPLICITLY, not just implicitly through the VOICE_COMMUNICATION input
     * preset (some devices honour one but not the other). Each effect is
     * optional per device (isAvailable) and best-effort — a failure just
     * leaves the preset-provided processing in place.
     */
    private fun attachEffects(sessionId: Int) {
        releaseEffects()
        if (sessionId < 0) return
        runCatching {
            if (AcousticEchoCanceler.isAvailable()) {
                aec = AcousticEchoCanceler.create(sessionId)?.also { it.enabled = true }
            }
        }
        runCatching {
            if (NoiseSuppressor.isAvailable()) {
                ns = NoiseSuppressor.create(sessionId)?.also { it.enabled = true }
            }
        }
        runCatching {
            if (AutomaticGainControl.isAvailable()) {
                agc = AutomaticGainControl.create(sessionId)?.also { it.enabled = true }
            }
        }
    }

    private fun releaseEffects() {
        runCatching { aec?.release() }
        runCatching { ns?.release() }
        runCatching { agc?.release() }
        aec = null
        ns = null
        agc = null
    }

    /** Stable identity of every attached handsfree device, both directions —
     *  a Bluetooth headset shows up as a separate input and output. Ids are
     *  per-connection, so a re-pair of the same headset reads as a change. */
    private fun routeDeviceIds(am: AudioManager): Set<Int> = runCatching {
        (am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).asSequence() +
            am.getDevices(AudioManager.GET_DEVICES_INPUTS).asSequence())
            .filter { it.type in ROUTE_DEVICE_TYPES }
            .map { it.id }
            .toSet()
    }.getOrDefault(emptySet())

    private fun startWatchingDevices() {
        if (deviceCallback != null) return
        // Seed from the current devices: registering replays everything
        // already attached through onAudioDevicesAdded, and that burst just
        // describes the route the session is about to open with.
        knownRouteDevices = routeDeviceIds(audioManager)
        val callback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) =
                emitIfRouteChanged()

            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) =
                emitIfRouteChanged()
        }
        deviceCallback = callback
        runCatching { audioManager.registerAudioDeviceCallback(callback, mainHandler) }
    }

    private fun stopWatchingDevices() {
        val callback = deviceCallback ?: return
        deviceCallback = null
        knownRouteDevices = null
        runCatching { audioManager.unregisterAudioDeviceCallback(callback) }
    }

    /** Devices churn for reasons that don't affect routing (media streams
     *  opening, the same headset re-announcing itself), so only a real change
     *  in the attached set is worth restarting the engine for. */
    private fun emitIfRouteChanged() {
        val current = routeDeviceIds(audioManager)
        if (current == knownRouteDevices) return
        knownRouteDevices = current
        eventSink?.success("routeChanged")
    }

    private fun devicesOfType(am: AudioManager, vararg types: Int): Boolean = runCatching {
        am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { it.type in types }
    }.getOrDefault(false)

    private fun hasBluetoothScoDevice(am: AudioManager): Boolean =
        devicesOfType(am, AudioDeviceInfo.TYPE_BLUETOOTH_SCO)

    private fun hasWiredHeadset(am: AudioManager): Boolean = devicesOfType(
        am,
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET,
    )

    private fun configureVoice(result: MethodChannel.Result) {
        val am = audioManager
        if (engaged) {
            result.success(false)
            return
        }
        engaged = true
        runCatching { am.mode = AudioManager.MODE_IN_COMMUNICATION }

        if (hasBluetoothScoDevice(am)) {
            engageBluetoothSco(am, result)
        } else {
            routeToWiredOrSpeaker(am)
            result.success(false)
        }
    }

    /**
     * Re-runs route selection for a session that is already in call mode,
     * after a headset was plugged in or pulled out.
     *
     * Undoing the previous choice first is the whole point: [configureVoice]
     * no-ops while engaged, and — worse — a communication device pinned by
     * [routeToWiredOrSpeaker] outranks the headset the call strategy would
     * otherwise pick, so a phone that started on speaker would stay on
     * speaker forever. Call mode itself stays on throughout; only the device
     * selection is released and re-made.
     */
    private fun reconfigureVoice(result: MethodChannel.Result) {
        val am = audioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            runCatching { am.clearCommunicationDevice() }
        } else {
            @Suppress("DEPRECATION")
            runCatching { am.isSpeakerphoneOn = false }
        }
        runCatching {
            @Suppress("DEPRECATION")
            am.stopBluetoothSco()
            @Suppress("DEPRECATION")
            am.isBluetoothScoOn = false
        }
        engaged = false
        configureVoice(result)
    }

    /** Wired headsets win by themselves in the call strategy; with nothing
     *  attached, voice streams default to the earpiece — force speaker. */
    private fun routeToWiredOrSpeaker(am: AudioManager) {
        if (hasWiredHeadset(am)) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            runCatching {
                val speaker = am.availableCommunicationDevices.firstOrNull {
                    it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
                }
                if (speaker != null) am.setCommunicationDevice(speaker)
            }
        } else {
            @Suppress("DEPRECATION")
            runCatching { am.isSpeakerphoneOn = true }
        }
    }

    private fun engageBluetoothSco(am: AudioManager, result: MethodChannel.Result) {
        var settled = false
        var receiver: BroadcastReceiver? = null

        fun finish(connected: Boolean) {
            if (settled) return
            settled = true
            receiver?.let { runCatching { context.unregisterReceiver(it) } }
            if (connected) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    runCatching {
                        val device = am.availableCommunicationDevices.firstOrNull {
                            it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                        }
                        if (device != null) am.setCommunicationDevice(device)
                    }
                }
            } else {
                // SCO refused to come up (older devices + some headsets do
                // this) — stop asking for it and take the loud path so the
                // session is never silent.
                runCatching {
                    @Suppress("DEPRECATION")
                    am.stopBluetoothSco()
                    @Suppress("DEPRECATION")
                    am.isBluetoothScoOn = false
                }
                routeToWiredOrSpeaker(am)
            }
            result.success(connected)
        }

        receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                val state = intent?.getIntExtra(
                    AudioManager.EXTRA_SCO_AUDIO_STATE,
                    AudioManager.SCO_AUDIO_STATE_ERROR,
                ) ?: return
                when (state) {
                    AudioManager.SCO_AUDIO_STATE_CONNECTED -> finish(true)
                    AudioManager.SCO_AUDIO_STATE_ERROR -> finish(false)
                    // DISCONNECTED also fires as the initial state while
                    // the link is coming up — only the timeout treats a
                    // lingering disconnect as failure.
                }
            }
        }
        runCatching {
            context.registerReceiver(
                receiver,
                IntentFilter(AudioManager.ACTION_SCO_AUDIO_STATE_UPDATED),
            )
        }

        val started = runCatching {
            @Suppress("DEPRECATION")
            if (am.isBluetoothScoAvailableOffCall) {
                @Suppress("DEPRECATION")
                am.startBluetoothSco()
                @Suppress("DEPRECATION")
                am.isBluetoothScoOn = true
                true
            } else {
                false
            }
        }.getOrDefault(false)

        if (!started) {
            finish(false)
            return
        }
        mainHandler.postDelayed({ finish(false) }, SCO_TIMEOUT_MS)
    }

    private fun releaseVoice() {
        releaseEffects()
        if (!engaged) return
        engaged = false
        val am = audioManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            runCatching { am.clearCommunicationDevice() }
        } else {
            @Suppress("DEPRECATION")
            runCatching { am.isSpeakerphoneOn = false }
        }
        runCatching {
            @Suppress("DEPRECATION")
            am.stopBluetoothSco()
            @Suppress("DEPRECATION")
            am.isBluetoothScoOn = false
        }
        runCatching { am.mode = AudioManager.MODE_NORMAL }
    }

    /** Activity teardown: Dart never gets to cancel its subscription when the
     *  engine dies with the activity, so drop the device callback here too.
     *  The voice route itself is left alone — that is releaseVoice's job, and
     *  it belongs to whoever still owns the audio engine. */
    fun dispose() {
        stopWatchingDevices()
        eventSink = null
    }
}
