import Flutter
import UIKit

/// iOS half of the on-device diagnostic log (see
/// lib/core/diagnostics/diagnostic_log.dart): a private directory to keep the
/// log in, and the share sheet to get it off the phone.
///
/// Channel "tark/diagnostics":
///   logsDirectory() -> String   Application Support, created if missing
///   shareFile(path, mimeType, subject) -> Bool   true if a share sheet opened
///
/// Application Support rather than Caches: the OS may purge Caches whenever it
/// is short of space, which is exactly the sort of moment worth having a log
/// for. It is excluded from iCloud backup here — a diagnostic log has no
/// business being restored onto a new phone.
public class DiagnosticsHandler: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "tark/diagnostics",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(DiagnosticsHandler(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "logsDirectory":
      result(logsDirectory())
    case "shareFile":
      let args = call.arguments as? [String: Any] ?? [:]
      result(share(path: args["path"] as? String ?? "",
                   subject: args["subject"] as? String ?? ""))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func logsDirectory() -> String? {
    let manager = FileManager.default
    guard var url = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return nil }
    do {
      try manager.createDirectory(at: url, withIntermediateDirectories: true)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try url.setResourceValues(values)
    } catch {
      // A directory we could not create or mark is still worth returning if it
      // happens to exist; Dart treats an unwritable one as "memory only".
      NSLog("TarkDiagnostics: preparing Application Support failed: \(error)")
    }
    return url.path
  }

  private func share(path: String, subject: String) -> Bool {
    guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
      NSLog("TarkDiagnostics: nothing to share at '\(path)'")
      return false
    }
    guard let presenter = Self.topViewController() else {
      NSLog("TarkDiagnostics: no view controller to present the share sheet from")
      return false
    }

    let sheet = UIActivityViewController(
      activityItems: [URL(fileURLWithPath: path)],
      applicationActivities: nil
    )
    if !subject.isEmpty { sheet.setValue(subject, forKey: "subject") }
    // iPad presents this as a popover and crashes without an anchor. There is
    // no sensible source rect for a share raised from a settings row, so the
    // sheet is anchored to the middle of the presenting view — which is where
    // a popover with no arrow belongs.
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(
        x: presenter.view.bounds.midX,
        y: presenter.view.bounds.midY,
        width: 0,
        height: 0
      )
      popover.permittedArrowDirections = []
    }
    presenter.present(sheet, animated: true)
    return true
  }

  /// The controller currently on screen — walking past any sheet Flutter or a
  /// plugin already put up, since presenting from underneath one is silently
  /// ignored.
  private static func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
      ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
      ?? scene?.windows.first?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
