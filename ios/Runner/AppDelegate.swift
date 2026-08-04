import Flutter
import UIKit
import WatchConnectivity

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "tark.audio_session") {
      AudioSessionHandler.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "tark.hotspot_join") {
      HotspotJoinHandler.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "tark.watch_companion") {
      WatchCompanionCoordinator.start(messenger: registrar.messenger())
    }
  }
}

/// iPhone side of the Apple Watch remote.
///
/// The watch never becomes a second voice endpoint. It asks for the room facts
/// that Flutter already mirrors into the shared home-widget UserDefaults, and
/// sends small control messages into the same `tark/widget_control` channel as
/// Android's native widget. This keeps mute/end/reconnect on the live Flutter
/// session's single lifecycle.
final class WatchCompanionCoordinator: NSObject, WCSessionDelegate {
  private static var shared: WatchCompanionCoordinator?

  private let session = WCSession.default
  private let controlChannel: FlutterMethodChannel

  static func start(messenger: FlutterBinaryMessenger) {
    guard WCSession.isSupported(), shared == nil else { return }
    let coordinator = WatchCompanionCoordinator(messenger: messenger)
    shared = coordinator
    coordinator.session.delegate = coordinator
    coordinator.session.activate()
  }

  private init(messenger: FlutterBinaryMessenger) {
    controlChannel = FlutterMethodChannel(
      name: "tark/widget_control",
      binaryMessenger: messenger
    )
    super.init()
  }

  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {}

  func sessionDidBecomeInactive(_ session: WCSession) {}

  func sessionDidDeactivate(_ session: WCSession) {
    // The user may have switched between paired watches.
    session.activate()
  }

  func session(
    _ session: WCSession,
    didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    switch message["type"] as? String {
    case "state_request":
      replyHandler(currentRoomState())
    case "action":
      dispatch(message["action"] as? String)
      replyHandler(["accepted": true])
    default:
      replyHandler(["accepted": false])
    }
  }

  func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    guard message["type"] as? String == "action" else { return }
    dispatch(message["action"] as? String)
  }

  private func dispatch(_ action: String?) {
    let method: String?
    switch action {
    case "toggle_mute": method = "toggleMute"
    case "reconnect": method = "retryConnection"
    case "leave": method = "endSession"
    default: method = nil
    }
    guard let method else { return }
    DispatchQueue.main.async { [controlChannel] in
      controlChannel.invokeMethod(method, arguments: nil)
    }
  }

  private func currentRoomState() -> [String: Any] {
    let defaults = UserDefaults(suiteName: "group.com.b1101.tark")
    let session = defaults?.string(forKey: "wk_session") ?? "idle"
    return [
      "session": session,
      "isLive": session != "idle" && session != "setup",
      "callsign": defaults?.string(forKey: "wk_callsign") ?? "",
      "peerCount": defaults?.integer(forKey: "wk_peers") ?? 0,
      "talker": defaults?.string(forKey: "wk_talker") ?? "",
      "modeLabel": defaults?.string(forKey: "wk_mode_label") ?? "",
      "statusLine": defaults?.string(forKey: "wk_status_line") ?? "",
      "updatedAt": (defaults?.object(forKey: "wk_updated_at") as? NSNumber)?.int64Value ?? 0,
    ]
  }
}
