import Foundation
import WatchConnectivity

struct TarkRoomState: Equatable {
  var session = "idle"
  var callsign = ""
  var peerCount = 0
  var talker = ""
  var modeLabel = ""
  var statusLine = "گوشی را باز کن"

  var isLive: Bool { !["idle", "setup"].contains(session.lowercased()) }
  var isMuted: Bool { session.lowercased().replacingOccurrences(of: "_", with: "") == "muted" }
  var isReconnecting: Bool { session.lowercased().contains("reconnecting") }

  init() {}

  init(_ value: [String: Any]) {
    session = value["session"] as? String ?? "idle"
    callsign = value["callsign"] as? String ?? ""
    peerCount = value["peerCount"] as? Int ?? 0
    talker = value["talker"] as? String ?? ""
    modeLabel = value["modeLabel"] as? String ?? ""
    statusLine = value["statusLine"] as? String ?? ""
  }
}

@MainActor
final class WatchSessionModel: NSObject, ObservableObject {
  @Published private(set) var room = TarkRoomState()
  @Published private(set) var phoneReachable = false

  private let session = WCSession.default
  private var timer: Timer?

  override init() {
    super.init()
    guard WCSession.isSupported() else { return }
    session.delegate = self
    session.activate()
  }

  func startPolling() {
    timer?.invalidate()
    requestState()
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.requestState() }
    }
  }

  func stopPolling() {
    timer?.invalidate()
    timer = nil
  }

  func requestState() {
    phoneReachable = session.isReachable
    guard session.activationState == .activated, session.isReachable else { return }
    session.sendMessage(
      ["type": "state_request"],
      replyHandler: { [weak self] reply in
        Task { @MainActor in self?.room = TarkRoomState(reply) }
      },
      errorHandler: { _ in }
    )
  }

  func send(_ action: String) {
    guard session.activationState == .activated, session.isReachable else { return }
    session.sendMessage(["type": "action", "action": action], replyHandler: nil) { _ in }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      self?.requestState()
    }
  }
}

extension WatchSessionModel: WCSessionDelegate {
  nonisolated func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    Task { @MainActor in
      phoneReachable = session.isReachable
      requestState()
    }
  }

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    Task { @MainActor in
      phoneReachable = session.isReachable
      if session.isReachable { requestState() }
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    Task { @MainActor in room = TarkRoomState(applicationContext) }
  }
}
