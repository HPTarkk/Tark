import Flutter
import Foundation
import Security

/// Private, device-local room identity and rejoin persistence. Uses the app's
/// own Keychain access group, so Personal Team signing needs no App Groups.
final class RoomIdentitySecureStorageHandler: NSObject, FlutterPlugin {
  private let service = (Bundle.main.bundleIdentifier ?? "com.b1101.tark") + ".room-identity.v1"
  private let queue = DispatchQueue(label: "tark.room-identity.keychain")

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "tark/room_identity_secure_storage", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(RoomIdentitySecureStorageHandler(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    queue.async {
      let response: Any?
      do { response = try self.execute(call) }
      catch let error as StoreError {
        response = FlutterError(code: error.code, message: error.message, details: nil)
      } catch {
        response = FlutterError(code: "secure_storage_unavailable", message: "Room Keychain is temporarily unavailable", details: nil)
      }
      DispatchQueue.main.async { result(response) }
    }
  }

  private struct StoreError: Error {
    let code: String
    let message: String
  }

  private func execute(_ call: FlutterMethodCall) throws -> Any? {
    let rejoin = ["writeRejoin", "readRejoin", "deleteRejoin"].contains(call.method)
    guard rejoin || ["write", "read", "delete"].contains(call.method) else { return FlutterMethodNotImplemented }
    let args = call.arguments as? [String: Any] ?? [:]
    let account: String
    if rejoin {
      account = "rejoin-ticket:v1"
    } else {
      guard let room = args["roomId"] as? String,
            let member = args["memberId"] as? String,
            room.count == 32, member.count == 24,
            room.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
            member.range(of: "^[0-9a-f]{24}$", options: .regularExpression) != nil else {
        throw StoreError(code: "secure_storage_failed", message: "Invalid Room identity scope")
      }
      account = room + ":" + member
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecAttrSynchronizable as String: false,
    ]
    switch call.method {
    case "write", "writeRejoin":
      guard let material = args["material"] as? [String: Any], JSONSerialization.isValidJSONObject(material) else {
        throw StoreError(code: "secure_storage_failed", message: "Invalid Room identity material")
      }
      let data = try JSONSerialization.data(withJSONObject: material)
      let attributes: [String: Any] = [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      ]
      var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
      if status == errSecItemNotFound {
        status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
      }
      try check(status)
      return nil
    case "read", "readRejoin":
      var read = query
      read[kSecReturnData as String] = true
      read[kSecMatchLimit as String] = kSecMatchLimitOne
      var item: CFTypeRef?
      let status = SecItemCopyMatching(read as CFDictionary, &item)
      if status == errSecItemNotFound { return nil }
      try check(status)
      guard let data = item as? Data,
            let object = try? JSONSerialization.jsonObject(with: data),
            let material = object as? [String: Any] else {
        // Corrupt payloads have no plaintext fallback. Do not remove an entry
        // on transient Keychain errors; those were handled by check above.
        try check(SecItemDelete(query as CFDictionary))
        throw StoreError(code: "secure_storage_failed", message: "Unreadable Room identity removed")
      }
      return material
    default:
      let status = SecItemDelete(query as CFDictionary)
      if status != errSecItemNotFound { try check(status) }
      return nil
    }
  }

  private func check(_ status: OSStatus) throws {
    if status != errSecSuccess {
      // Preserve existing entries on all Keychain availability/auth failures.
      throw StoreError(code: "secure_storage_unavailable", message: "Room Keychain is temporarily unavailable")
    }
  }
}
