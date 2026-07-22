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
///
/// That happens once, when the streams open, so headsets that arrive (or
/// leave) mid-session need a second look: `tark/audio_session/events`
/// reports route changes to Dart, which re-opens the engine through
/// `reconfigureVoice`.
enum AudioSessionHandler {
  /// Held for the app's lifetime — the notification observer lives on it.
  private static var routeObserver: RouteChangeStreamHandler?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "tark/audio_session",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      // Re-applying the category is all a re-route needs on iOS: unlike
      // Android there is no pinned communication device to clear first.
      case "configureVoice", "reconfigureVoice":
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

    let observer = RouteChangeStreamHandler()
    routeObserver = observer
    FlutterEventChannel(
      name: "tark/audio_session/events",
      binaryMessenger: registrar.messenger()
    ).setStreamHandler(observer)
  }
}

/// Reports handsfree devices appearing and disappearing to Dart. Observing
/// starts when Dart subscribes (i.e. for the lifetime of a walkie session).
private final class RouteChangeStreamHandler: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?

  func onListen(
    withArguments _: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sink = events
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleRouteChange),
      name: AVAudioSession.routeChangeNotification, object: nil)
    return nil
  }

  func onCancel(withArguments _: Any?) -> FlutterError? {
    NotificationCenter.default.removeObserver(
      self, name: AVAudioSession.routeChangeNotification, object: nil)
    sink = nil
    return nil
  }

  @objc private func handleRouteChange(_ notification: Notification) {
    guard
      let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
      let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
    else { return }
    // Only plug/unplug matters. `.categoryChange` in particular fires from
    // our own setCategory call above, and acting on it would loop.
    switch reason {
    case .newDeviceAvailable, .oldDeviceUnavailable:
      DispatchQueue.main.async { [weak self] in self?.sink?("routeChanged") }
    default:
      break
    }
  }
}
