import Flutter
import NetworkExtension

/// iOS join side of the cross-platform "Hotspot Bridge": joins the Android
/// host's local Wi-Fi hotspot programmatically so both phones land on the same
/// LAN and the app's ordinary Wi-Fi transport carries the audio.
///
/// Uses `NEHotspotConfiguration`, which requires the **Hotspot Configuration**
/// capability to be enabled in Xcode (entitlement
/// `com.apple.developer.networking.HotspotConfiguration`). When it isn't
/// available the `apply` call fails and we report `false`, and the Flutter UI
/// falls back to showing the SSID/password for a manual join.
enum HotspotJoinHandler {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "tark/hotspot_join",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "join":
        guard let args = call.arguments as? [String: Any],
          let ssid = args["ssid"] as? String, !ssid.isEmpty
        else {
          result(FlutterError(code: "invalid_args", message: "ssid is required", details: nil))
          return
        }
        let passphrase = args["passphrase"] as? String ?? ""

        let config: NEHotspotConfiguration
        if passphrase.isEmpty {
          config = NEHotspotConfiguration(ssid: ssid)
        } else {
          config = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        }
        // Keep the network joined for the whole session, not just once.
        config.joinOnce = false

        NEHotspotConfigurationManager.shared.apply(config) { error in
          guard let error = error as NSError? else {
            result(true)
            return
          }
          // Already connected to this network counts as success.
          if error.domain == NEHotspotConfigurationErrorDomain,
            error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
            result(true)
          } else {
            result(false)
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
