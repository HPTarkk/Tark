package com.wearemobilefirst.audio_io

import io.flutter.embedding.engine.plugins.FlutterPlugin

class AudioIoPlugin: FlutterPlugin {
  override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    // FFI plugin, no method channel setup needed
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    // FFI plugin, no cleanup needed
  }
}
