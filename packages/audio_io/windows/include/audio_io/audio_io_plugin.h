#ifndef FLUTTER_PLUGIN_AUDIO_IO_PLUGIN_H_
#define FLUTTER_PLUGIN_AUDIO_IO_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace audio_io {

class AudioIoPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  AudioIoPlugin();

  virtual ~AudioIoPlugin();

  // Disallow copy and assign.
  AudioIoPlugin(const AudioIoPlugin&) = delete;
  AudioIoPlugin& operator=(const AudioIoPlugin&) = delete;

 private:
  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace audio_io

#endif  // FLUTTER_PLUGIN_AUDIO_IO_PLUGIN_H_