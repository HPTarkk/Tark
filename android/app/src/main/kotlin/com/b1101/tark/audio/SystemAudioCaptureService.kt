package com.b1101.tark.audio

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/**
 * Foreground service that captures other apps' playback (music, navigation
 * prompts — NOT phone calls, which the OS never exposes) via the Android 10+
 * AudioPlaybackCapture API and hands 16 kHz mono frames to
 * [SystemAudioHandler] for mixing into the walkie transmit stream.
 *
 * MediaProjection rules require the projection to be used from a foreground
 * service with type mediaProjection — that is this service's only job.
 * Capture runs at 48 kHz stereo (the guaranteed-supported format), then is
 * downmixed and box-filter decimated ×3 to the pipeline's 16 kHz mono.
 *
 * Apps can opt out of playback capture (some streaming apps do); those
 * simply come through as silence.
 */
class SystemAudioCaptureService : Service() {

    companion object {
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        private const val NOTIFICATION_ID = 1101
        private const val CHANNEL_ID = "tark_system_audio"
        private const val CAPTURE_RATE = 48000
        private const val DECIMATION = 3 // 48 kHz -> 16 kHz

        /** Set by [SystemAudioHandler]; invoked on the main thread. */
        @Volatile
        var frameListener: ((DoubleArray) -> Unit)? = null

        @Volatile
        var isRunning = false
            private set
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var record: AudioRecord? = null
    private var captureThread: Thread? = null

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            stopSelf()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || intent == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
        @Suppress("DEPRECATION")
        val resultData: Intent? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
            } else {
                intent.getParcelableExtra(EXTRA_RESULT_DATA)
            }
        if (resultCode != Activity.RESULT_OK || resultData == null) {
            stopSelf()
            return START_NOT_STICKY
        }

        createNotificationChannel()
        startForeground(
            NOTIFICATION_ID,
            buildNotification(),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
        )

        try {
            val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            val mp = mpm.getMediaProjection(resultCode, resultData)
                ?: throw IllegalStateException("MediaProjection unavailable")
            mp.registerCallback(projectionCallback, mainHandler)
            projection = mp
            startCapture(mp)
            isRunning = true
        } catch (e: Exception) {
            stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startCapture(mp: MediaProjection) {
        val config = AudioPlaybackCaptureConfiguration.Builder(mp)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(CAPTURE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
            .build()
        val audioRecord = AudioRecord.Builder()
            .setAudioFormat(format)
            .setBufferSizeInBytes(CAPTURE_RATE * 2 * 2) // 1 s of 16-bit stereo
            .setAudioPlaybackCaptureConfig(config)
            .build()
        record = audioRecord
        audioRecord.startRecording()

        captureThread = Thread {
            // 100 ms of stereo frames per read.
            val stereo = ShortArray(CAPTURE_RATE / 10 * 2)
            while (!Thread.currentThread().isInterrupted) {
                val read = audioRecord.read(stereo, 0, stereo.size)
                if (read <= 0) continue
                val frames = read / 2
                val outLen = frames / DECIMATION
                if (outLen == 0) continue
                val out = DoubleArray(outLen)
                for (j in 0 until outLen) {
                    // Downmix L+R, then average DECIMATION mono samples as a
                    // cheap anti-alias box filter before dropping to 16 kHz.
                    var acc = 0.0
                    val base = j * DECIMATION * 2
                    for (k in 0 until DECIMATION) {
                        val left = stereo[base + k * 2].toDouble()
                        val right = stereo[base + k * 2 + 1].toDouble()
                        acc += (left + right) * 0.5
                    }
                    out[j] = (acc / DECIMATION) / 32768.0
                }
                val listener = frameListener ?: continue
                mainHandler.post { listener(out) }
            }
        }.also { it.start() }
    }

    override fun onDestroy() {
        isRunning = false
        captureThread?.interrupt()
        captureThread = null
        try {
            record?.stop()
        } catch (_: Exception) {
        }
        record?.release()
        record = null
        projection?.unregisterCallback(projectionCallback)
        projection?.stop()
        projection = null
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Audio sharing",
                NotificationManager.IMPORTANCE_LOW,
            )
        )
    }

    private fun buildNotification(): Notification =
        Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Tark")
            .setContentText("Sharing device audio to the channel")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .build()
}
