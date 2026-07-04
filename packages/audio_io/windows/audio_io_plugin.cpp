#include "include/audio_io/audio_io_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <sstream>

namespace audio_io {

// static
void AudioIoPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "com.wearemobilefirst.audio_io",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<AudioIoPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

AudioIoPlugin::AudioIoPlugin() {}

AudioIoPlugin::~AudioIoPlugin() {}

void AudioIoPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // This plugin uses FFI, so method calls are not expected
  result->NotImplemented();
}

}  // namespace audio_io