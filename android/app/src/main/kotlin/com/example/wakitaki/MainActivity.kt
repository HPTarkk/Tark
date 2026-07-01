package com.example.wakitaki

import com.example.wakitaki.bluetooth.BluetoothServerHandler
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var bluetoothServerHandler: BluetoothServerHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val handler = BluetoothServerHandler(
            flutterEngine.dartExecutor.binaryMessenger,
            activityProvider = { this },
        )
        bluetoothServerHandler = handler
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "wakitaki/bluetooth_server/methods",
        ).setMethodCallHandler(handler)
    }

    override fun onDestroy() {
        bluetoothServerHandler?.stopHosting()
        super.onDestroy()
    }
}
