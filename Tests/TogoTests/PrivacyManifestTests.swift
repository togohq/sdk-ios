import Foundation
import XCTest

@testable import Togo

/// The privacy manifest ships in the package's bundle and says what
/// `PrivacyManifest` documents: no tracking, three collected types for
/// Analytics, and the one required-reason API the SDK calls.
final class PrivacyManifestTests: XCTestCase {
  func manifest() throws -> [String: Any] {
    let url = try XCTUnwrap(PrivacyManifest.url, "PrivacyInfo.xcprivacy is not in the bundle")
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
    return try XCTUnwrap(plist as? [String: Any])
  }

  func testNoTracking() throws {
    let m = try manifest()
    XCTAssertEqual(m["NSPrivacyTracking"] as? Bool, false)
    XCTAssertEqual((m["NSPrivacyTrackingDomains"] as? [Any])?.count, 0)
  }

  func testCollectedDataTypes() throws {
    let types = try XCTUnwrap(try manifest()["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
    XCTAssertEqual(
      Set(types.compactMap { $0["NSPrivacyCollectedDataType"] as? String }),
      [
        "NSPrivacyCollectedDataTypeDeviceID", "NSPrivacyCollectedDataTypeUserID",
        "NSPrivacyCollectedDataTypeProductInteraction",
      ])
    XCTAssertEqual(types.count, 3)
    for type in types {
      XCTAssertEqual(type["NSPrivacyCollectedDataTypeLinked"] as? Bool, true)
      XCTAssertEqual(type["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
      XCTAssertEqual(
        type["NSPrivacyCollectedDataTypePurposes"] as? [String],
        ["NSPrivacyCollectedDataTypePurposeAnalytics"])
    }
  }

  /// The one API declared, with its reason. Where the SDK is developed beside
  /// the server, a contract test checks the sources call exactly these.
  func testRequiredReasonAPIs() throws {
    let apis = try XCTUnwrap(try manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
    let declared = Dictionary(
      uniqueKeysWithValues: apis.map {
        ($0["NSPrivacyAccessedAPIType"] as? String ?? "", $0["NSPrivacyAccessedAPITypeReasons"] as? [String] ?? [])
      })
    XCTAssertEqual(declared, ["NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"]])
  }
}
