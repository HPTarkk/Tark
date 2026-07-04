package com.b1101.tark.audio

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Dart bridge for system-audio (music) sharing.
 *
 * Methods (channel "tark/system_audio"):
 *   isSupported -> Boolean (Android 10+)
 *   start       -> Boolean; shows the system screen-capture consent dialog,
 *                  then launches [SystemAudioCaptureService]
 *   stop        -> null
 *
 * Events (channel "tark/system_audio/frames"): Float64List of 16 kHz mono
 * samples, normalized to [-1, 1].
 */
class SystemAudioHandler(
    messenger: BinaryMessenger,
    private val activityProvider: () -> Activity?,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val REQUEST_CAPTURE_CODE = 4243
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var pendingStart: MethodChannel.Result? = null

    init {
        EventChannel(messenger, "tark/system_audio/frames").setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" ->
                result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)

            "start" -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                    result.success(false)
                    return
                }
                if (SystemAudioCaptureService.isRunning) {
                    result.success(true)
                    return
                }
                val activity = activityProvider()
                if (activity == null) {
                    result.success(false)
                    return
                }
                if (pendingStart != null) {
                    result.success(false)
                    return
                }
                pendingStart = result
                val mpm = activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                        as MediaProjectionManager
                activity.startActivityForResult(
                    mpm.createScreenCaptureIntent(),
                    REQUEST_CAPTURE_CODE,
                )
            }

            "stop" -> {
                val context = activityProvider()
                SystemAudioCaptureService.frameListener = null
                context?.stopService(Intent(context, SystemAudioCaptureService::class.java))
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    /** Routed from MainActivity.onActivityResult; true when handled here. */
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CAPTURE_CODE) return false
        val result = pendingStart
        pendingStart = null
        val activity = activityProvider()
        if (resultCode == Activity.RESULT_OK && data != null && activity != null) {
            SystemAudioCaptureService.frameListener = { frame ->
                mainHandler.post { sink?.success(frame) }
            }
            val intent = Intent(activity, SystemAudioCaptureService::class.java)
                .putExtra(SystemAudioCaptureService.EXTRA_RESULT_CODE, resultCode)
                .putExtra(SystemAudioCaptureService.EXTRA_RESULT_DATA, data)
            activity.startForegroundService(intent)
            result?.success(true)
        } else {
            result?.success(false)
        }
        return true
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }
}
