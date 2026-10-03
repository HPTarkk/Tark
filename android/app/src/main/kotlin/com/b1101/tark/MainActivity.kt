package com.b1101.tark

import android.content.Intent
import com.b1101.tark.audio.AudioSessionHandler
import com.b1101.tark.audio.MediaControlHandler
import com.b1101.tark.audio.SystemAudioHandler
import com.b1101.tark.billing.BazaarBillingHandler
import com.b1101.tark.bluetooth.BluetoothServerHandler
import com.b1101.tark.diagnostics.DiagnosticsHandler
import com.b1101.tark.hotspot.HotspotHandler
import com.b1101.tark.hotspot.WifiJoinHandler
import com.b1101.tark.keepalive.KeepAliveHandler
import com.b1101.tark.network.NetworkBindingHandler
import com.b1101.tark.network.TransportCapabilityHandler
import com.b1101.tark.security.AppSecureStorageHandler
import com.b1101.tark.security.RoomIdentitySecureStorageHandler
import com.b1101.tark.update.StoreHandler
import com.b1101.tark.widget.WidgetControlBridge
import com.wearemobilefirst.audio_io.AudioIoDevices
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
    private var networkBindingHandler: NetworkBindingHandler? = null
    private var bazaarBillingHandler: BazaarBillingHandler? = null

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

        val networkBinding = NetworkBindingHandler(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
        networkBindingHandler = networkBinding
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NetworkBindingHandler.METHOD_CHANNEL,
        ).setMethodCallHandler(networkBinding)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            TransportCapabilityHandler.METHOD_CHANNEL,
        ).setMethodCallHandler(TransportCapabilityHandler(applicationContext))

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            RoomIdentitySecureStorageHandler.METHOD_CHANNEL,
        ).setMethodCallHandler(RoomIdentitySecureStorageHandler(applicationContext))

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AppSecureStorageHandler.METHOD_CHANNEL,
        ).setMethodCallHandler(AppSecureStorageHandler(applicationContext))

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

        // Where the on-device diagnostic log lives, and the share sheet that
        // gets it off the phone. Registered early on purpose: Dart asks for the
        // directory in main(), before the first frame.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tark/diagnostics",
        ).setMethodCallHandler(
            DiagnosticsHandler(applicationContext, activityProvider = { this }),
        )

        // Cafe Bazaar subscriptions (Poolakey). Talks to the Bazaar app only;
        // the server decides whether a purchase counts.
        val bazaarBilling = BazaarBillingHandler(
            applicationContext,
            activityProvider = { this },
        )
        bazaarBillingHandler = bazaarBilling
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BazaarBillingHandler.METHOD_CHANNEL,
        ).setMethodCallHandler(bazaarBilling)

        // The update prompt's button: Bazaar's listing, or the web page.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            StoreHandler.METHOD_CHANNEL,
        ).setMethodCallHandler(StoreHandler(activityProvider = { this }))

        // Outbound only: the home-screen widget's mute/end buttons call INTO
        // Dart through this, from TarkWidgetControlReceiver. Registering the
        // channel here is what makes those buttons work without opening the
        // app — while a session is live the process is held up by the
        // keep-alive service, so this engine is still around to receive them.
        WidgetControlBridge.attach(
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                WidgetControlBridge.CHANNEL,
            ),
        )
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
        // Leaves the widget's control taps with nothing to dispatch to, which
        // is what tells TarkWidgetControlReceiver the session is gone.
        WidgetControlBridge.detach()
        bluetoothServerHandler?.stopHosting()
        hotspotHandler?.stop()
        wifiJoinHandler?.leave()
        networkBindingHandler?.dispose()
        keepAliveHandler?.stop()
        audioSessionHandler?.dispose()
        bazaarBillingHandler?.dispose()
        // The engine and its Dart side go with this screen, but the sound
        // device they opened lives in the native library and the process can
        // outlast them (the app swiped away mid-call). Left open it keeps the
        // microphone, and the session started when the app is reopened can't
        // open its own: the other phone stops hearing this one. Off the main
        // thread, since closing a device can block on the audio service.
        if (!isChangingConfigurations) {
            Thread { runCatching { AudioIoDevices.releaseAll() } }.start()
        }
        super.onDestroy()
    }
}
