import Flutter

/// FFI plugin — Dart calls straight into the native rnnoise symbols compiled
/// into this pod. No method channel needed; this registration is only here
/// because Flutter's plugin loader expects one per platform.
public class SwiftRnnoisePlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        // No-op.
    }
}
