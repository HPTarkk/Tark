package com.b1101.tark

import android.content.Intent
import com.b1101.tark.audio.AudioSessionHandler
import com.b1101.tark.audio.MediaControlHandler
import com.b1101.tark.audio.SystemAudioHandler
import com.b1101.tark.billing.BillingHandler
import com.b1101.tark.bluetooth.BluetoothServerHandler
import com.b1101.tark.hotspot.HotspotHandler
import com.b1101.tark.hotspot.WifiJoinHandler
import com.b1101.tark.keepalive.KeepAliveHandler
import com.b1101.tark.watch.WatchCompanionBridge
import com.b1101.tark.widget.WidgetControlBridge
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
    private var billingHandler: BillingHandler? = null
    private var watchCompanionBridge: WatchCompanionBridge? = null

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

        // Needs the Activity, not just the context: Myket's purchase flow is
        // started with startActivityForResult under the hood.
        val billing = BillingHandler(
            applicationContext,
            activityProvider = { this },
        )
        billingHandler = billing
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BillingHandler.CHANNEL,
        ).setMethodCallHandler(billing)

        // Outbound only: the home-screen widget and paired watches call INTO
        // Dart through this while the live session's keep-alive service keeps
        // the engine available.
        WidgetControlBridge.attach(
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                WidgetControlBridge.CHANNEL,
            ),
        )

        watchCompanionBridge = WatchCompanionBridge(applicationContext).also {
            it.attach()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (systemAudioHandler?.handleActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        if (bluetoothServerHandler?.handleActivityResult(requestCode, resultCode, data) == true) {
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        watchCompanionBridge?.detach()
        watchCompanionBridge = null
        // Leaves widget/watch control taps with nothing to dispatch to, which
        // is what tells the native clients the session is gone.
        WidgetControlBridge.detach()
        bluetoothServerHandler?.stopHosting()
        hotspotHandler?.stop()
        wifiJoinHandler?.leave()
        keepAliveHandler?.stop()
        audioSessionHandler?.dispose()
        // Unbinds from the Myket service; leaking it holds a ServiceConnection
        // against a dead Activity.
        billingHandler?.dispose()
        super.onDestroy()
    }
}
