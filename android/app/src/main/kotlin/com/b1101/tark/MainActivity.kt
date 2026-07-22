package com.b1101.tark

import android.content.Intent
import com.b1101.tark.audio.AudioSessionHandler
import com.b1101.tark.audio.MediaControlHandler
import com.b1101.tark.audio.SystemAudioHandler
import com.b1101.tark.bluetooth.BluetoothServerHandler
import com.b1101.tark.hotspot.HotspotHandler
import com.b1101.tark.hotspot.WifiJoinHandler
import com.b1101.tark.keepalive.KeepAliveHandler
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var bluetoothServerHandler: BluetoothServerHandler? = null
    private var systemAudioHandler: SystemAudioHandler? = null
    private var hotspotHandler: HotspotHandler? = null
    private var wifiJoinHandler: WifiJoinHandler? = null
    private var keepAliveHandler: KeepAliveHandler? = null
    private var audioSessionHandler: AudioSessionHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val handler = BluetoothServerHandler(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
            activityProvider = { this },
        )
        bluetoothServerHandler = handler
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tark/bluetooth_server/methods",
        ).setMethodCallHandler(handler)

        val audioSession = AudioSessionHandler(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        audioSessionHandler = audioSession
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tark/audio_session",
        ).setMethodCallHandler(audioSession)

        val systemAudio = SystemAudioHandler(
            flutterEngine.dartExecutor.binaryMessenger,
            activityProvider = { this },
        )
        systemAudioHandler = systemAudio
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tark/system_audio",
        ).setMethodCallHandler(systemAudio)

        val hotspot = HotspotHandler(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        hotspotHandler = hotspot
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tark/hotspot",
        ).setMethodCallHandler(hotspot)

        val wifiJoin = WifiJoinHandler(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        wifiJoinHandler = wifiJoin
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tark/wifi_join",
        ).setMethodCallHandler(wifiJoin)

        val keepAlive = KeepAliveHandler(
            applicationContext,
            activityProvider = { this },
        )
        keepAliveHandler = keepAlive
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tark/keepalive",
        ).setMethodCallHandler(keepAlive)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tark/media_control",
        ).setMethodCallHandler(
            MediaControlHandler(applicationContext, activityProvider = { this }),
        )
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
        wifiJoinHandler?.leave()
        keepAliveHandler?.stop()
        audioSessionHandler?.dispose()
        super.onDestroy()
    }
}
