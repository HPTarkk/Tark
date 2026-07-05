package com.b1101.tark.audio

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.Handler
import android.os.Looper
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
 */
class AudioSessionHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        private const val SCO_TIMEOUT_MS = 4000L
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

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "configureVoice" -> configureVoice(result)
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
}
