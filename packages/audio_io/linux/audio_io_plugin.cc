#include "include/audio_io/audio_io_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <sys/utsname.h>

#include <cstring>

#define AUDIO_IO_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), audio_io_plugin_get_type(), \
                               AudioIoPlugin))

struct _AudioIoPlugin {
  GObject parent_instance;
};

G_DEFINE_TYPE(AudioIoPlugin, audio_io_plugin, g_object_get_type())

// Called when a method call is received from Flutter.
static void audio_io_plugin_handle_method_call(
    AudioIoPlugin* self,
    FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar* method = fl_method_call_get_name(method_call);

  // This plugin uses FFI, so method calls are not expected
  response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());

  fl_method_call_respond(method_call, response, nullptr);
}

static void audio_io_plugin_dispose(GObject* object) {
  G_OBJECT_CLASS(audio_io_plugin_parent_class)->dispose(object);
}

static void audio_io_plugin_class_init(AudioIoPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = audio_io_plugin_dispose;
}

static void audio_io_plugin_init(AudioIoPlugin* self) {}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  AudioIoPlugin* plugin = AUDIO_IO_PLUGIN(user_data);
  audio_io_plugin_handle_method_call(plugin, method_call);
}

void audio_io_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  AudioIoPlugin* plugin = AUDIO_IO_PLUGIN(
      g_object_new(audio_io_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                           "com.wearemobilefirst.audio_io",
                           FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel,
                                            method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  g_object_unref(plugin);
}