import SwiftUI

@main
struct TarkWatchApp: App {
  @StateObject private var session = WatchSessionModel()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(session)
        .onAppear { session.startPolling() }
        .onDisappear { session.stopPolling() }
    }
  }
}
