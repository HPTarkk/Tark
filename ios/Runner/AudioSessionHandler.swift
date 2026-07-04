import AVFoundation
import Flutter

/// Configures the shared AVAudioSession for two-way voice while a walkie
/// session is active.
///
/// audio_io (miniaudio) activates a plain play-and-record session, which
/// keeps capture on the built-in mic even when AirPods or a wired headset
/// are attached. Re-applying the category with `.voiceChat` mode and the
/// Bluetooth options routes mic + playback to the handsfree device (HFP)
/// the way a phone call does, and enables the system's voice processing.
enum AudioSessionHandler {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "tark/audio_session",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "configureVoice":
        do {
          let session = AVAudioSession.sharedInstance()
          try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
          )
          try session.setActive(true)
          result(true)
        } catch {
          result(
            FlutterError(
              code: "AUDIO_SESSION",
              message: error.localizedDescription,
              details: nil
            ))
        }
      case "releaseVoice":
        try? AVAudioSession.sharedInstance().setActive(
          false, options: .notifyOthersOnDeactivation)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
