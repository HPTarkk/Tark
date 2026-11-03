import Flutter
import XCTest

final class RoomIdentitySecureStorageTests: XCTestCase {
  private func call(_ handler: RoomIdentitySecureStorageHandler, _ method: String, _ args: [String: Any]? = nil) -> Any? {
    let done = expectation(description: method)
    var response: Any?
    handler.handle(FlutterMethodCall(methodName: method, arguments: args)) { value in
      response = value
      done.fulfill()
    }
    wait(for: [done], timeout: 5)
    return response
  }

  func testIdentitySurvivesNewHandlerAndCanBeUpdatedAndDeleted() {
    let room = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let member = String(room.prefix(24))
    var args: [String: Any] = ["roomId": room, "memberId": member]
    let handler = RoomIdentitySecureStorageHandler()
    defer { _ = call(handler, "delete", args) }
    XCTAssertNil(call(handler, "read", args))
    args["material"] = ["memberPrivateKey": "test-private", "certificate": "گواهی تست"]
    XCTAssertNil(call(handler, "write", args))
    let fresh = RoomIdentitySecureStorageHandler()
    let restored = call(fresh, "read", args) as? [String: Any]
    XCTAssertEqual(restored?["memberPrivateKey"] as? String, "test-private")
    XCTAssertEqual(restored?["certificate"] as? String, "گواهی تست")
    args["material"] = ["memberPrivateKey": "updated"]
    XCTAssertNil(call(fresh, "write", args))
    XCTAssertEqual((call(handler, "read", args) as? [String: Any])?["memberPrivateKey"] as? String, "updated")
    let other: [String: Any] = ["roomId": room, "memberId": String(repeating: "f", count: 24)]
    XCTAssertNil(call(handler, "read", other))
    XCTAssertNil(call(handler, "delete", args))
    XCTAssertNil(call(fresh, "read", args))
  }

  func testRejoinTicketRoundTripAndDelete() {
    let handler = RoomIdentitySecureStorageHandler()
    // Test only the ticket on this development install; no production data.
    let prior = call(handler, "readRejoin") as? [String: Any]
    defer {
      if let prior = prior { _ = call(handler, "writeRejoin", ["material": prior]) }
      else { _ = call(handler, "deleteRejoin") }
    }
    XCTAssertNil(call(handler, "writeRejoin", ["material": ["roomId": "test-room", "ssid": "test-network"]]))
    XCTAssertEqual((call(RoomIdentitySecureStorageHandler(), "readRejoin") as? [String: Any])?["ssid"] as? String, "test-network")
    XCTAssertNil(call(handler, "deleteRejoin"))
    XCTAssertNil(call(handler, "readRejoin"))
  }

  func testInvalidScopeIsRejected() {
    let error = call(RoomIdentitySecureStorageHandler(), "write", ["roomId": "../invalid", "memberId": "invalid", "material": [:]]) as? FlutterError
    XCTAssertEqual(error?.code, "secure_storage_failed")
  }
}
