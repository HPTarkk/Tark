package com.wearemobilefirst.rnnoise

import io.flutter.embedding.engine.plugins.FlutterPlugin

class RnnoisePlugin: FlutterPlugin {
  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    // FFI plugin, no method channel setup needed
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    // FFI plugin, no cleanup needed
  }
}
