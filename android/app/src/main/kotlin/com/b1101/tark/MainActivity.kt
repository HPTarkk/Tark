package com.b1101.tark

import android.content.Intent
import com.b1101.tark.audio.AudioSessionHandler
import com.b1101.tark.audio.SystemAudioHandler
import com.b1101.tark.bluetooth.BluetoothServerHandler
import com.b1101.tark.hotspot.HotspotHandler
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var bluetoothServerHandler: BluetoothServerHandler? = null
    private var systemAudioHandler: SystemAudioHandler? = null
    private var hotspotHandler: HotspotHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val handler = BluetoothServerHandler(
            flutterEngine.dartExecutor.binaryMessenger,
            activityProvider = { this },
        )
        bluetoothServerHandler = handler
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tark/bluetooth_server/methods",
        ).setMethodCallHandler(handler)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tark/audio_session",
        ).setMethodCallHandler(AudioSessionHandler(applicationContext))

        val systemAudio = SystemAudioHandler(
            flutterEngine.dartExecutor.binaryMessenger,
            activityProvider = { this },
        )
        systemAudioHandler = systemAudio
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tark/system_audio",
        ).setMethodCallHandler(systemAudio)

        val hotspot = HotspotHandler(applicationContext)
        hotspotHandler = hotspot
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tark/hotspot",
        ).setMethodCallHandler(hotspot)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (systemAudioHandler?.handleActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        bluetoothServerHandler?.stopHosting()
        hotspotHandler?.stop()
        super.onDestroy()
    }
}
