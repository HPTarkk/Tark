//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <bluetooth_low_energy_linux/bluetooth_low_energy_linux_plugin.h>
#include <flutter_webrtc/flutter_web_r_t_c_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) bluetooth_low_energy_linux_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "BluetoothLowEnergyLinuxPlugin");
  bluetooth_low_energy_linux_plugin_register_with_registrar(bluetooth_low_energy_linux_registrar);
  g_autoptr(FlPluginRegistrar) flutter_webrtc_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "FlutterWebRTCPlugin");
  flutter_web_r_t_c_plugin_register_with_registrar(flutter_webrtc_registrar);
}
