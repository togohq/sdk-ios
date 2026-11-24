import Foundation
import XCTest

@testable import TogoCore

final class WireTests: XCTestCase {
  /// The JSON a property value becomes must survive as the SAME value: an
  /// integer stays an integer, a boolean never becomes 1, on every platform.
  func testPropertyValuesKeepTheirTypes() throws {
    let properties: TogoProperties = [
      "amount_minor": 5999, "price": 9.99, "trial": true, "coupon": nil, "plan": "pro",
      "whole": 2.0,
    ]
    let text = properties.json.serialized()
    XCTAssertEqual(
      text, #"{"amount_minor":5999,"coupon":null,"plan":"pro","price":9.99,"trial":true,"whole":2}"#)
    let parsed = try JSONValue.parse(text)
    XCTAssertEqual(parsed["amount_minor"], .int(5999))
    XCTAssertEqual(parsed["trial"], .bool(true))
    XCTAssertEqual(parsed["price"], .double(9.99))
  }

  func testStringsEscapeAndRoundTrip() throws {
    let tricky = "quote \" backslash \\ newline \n tab \t bell \u{07} é 🦊"
    let text = JSONValue.string(tricky).serialized()
    XCTAssertTrue(text.contains(#"\u0007"#))
    XCTAssertEqual(try JSONValue.parse(text), .string(tricky))
    XCTAssertEqual(try JSONValue.parse(#""🦊""#), .string("🦊"))
  }

  /// A broken surrogate pair — from a 202 body or a damaged queue file — is
  /// replaced, never a crash.
  func testAnUnpairedSurrogateIsReplacedNotACrash() throws {
    XCTAssertEqual(try JSONValue.parse(#""\uD800\u0041""#), .string("\u{FFFD}A"))
    XCTAssertEqual(try JSONValue.parse(#""\uD800x""#), .string("\u{FFFD}x"))
    XCTAssertEqual(try JSONValue.parse(#""\uDC00""#), .string("\u{FFFD}"))
    XCTAssertEqual(try JSONValue.parse(#""\uD83E\uDD8A""#), .string("🦊"))
  }

  func testMalformedJsonIsAnErrorNotACrash() {
    for bad in ["", "{", #"{"a":}"#, "[1,]", "tru", #""open"#, "{} x"] {
      XCTAssertThrowsError(try JSONValue.parse(bad), bad)
    }
  }

  /// UTC ISO-8601 with milliseconds and a `Z`, always.
  func testTimestampsAreUtcWithMilliseconds() {
    XCTAssertEqual(ISOTime.format(1_792_584_000_000), "2026-10-21T12:00:00.000Z")
    XCTAssertEqual(ISOTime.format(0), "1970-01-01T00:00:00.000Z")
    XCTAssertEqual(ISOTime.format(951_782_400_007), "2000-02-29T00:00:00.007Z")
    XCTAssertEqual(ISOTime.format(-1), "1969-12-31T23:59:59.999Z")
    for ms: Int64 in [0, 1_792_584_000_123, 951_782_400_007, 4_102_444_799_999] {
      XCTAssertEqual(ISOTime.parse(ISOTime.format(ms)), ms)
    }
    XCTAssertEqual(ISOTime.parse("2026-10-21T12:00:00Z"), 1_792_584_000_000)
    XCTAssertNil(ISOTime.parse("2026-10-21 12:00:00"))
  }

  /// The fixture the server's contract test parses with the SERVER's schema,
  /// where the SDK is developed beside it. This half pins that it is what this SDK serialises, so
  /// the two halves meet at one file rather than at two descriptions of it.
  func testTheWireFixtureIsWhatThisSdkSerialises() throws {
    var event = RawEvent(
      eventName: "plan_selected", clientEventMs: 1_792_580_400_000,
      eventId: "3f1b2c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
      anonymousId: "6a1d0e2c-7b3f-4c5d-9e8f-0a1b2c3d4e5f",
      deviceId: "0b9c8d7e-6f5a-4b3c-8d2e-1f0a9b8c7d6e", userId: "user_9",
      sessionId: "d4c3b2a1-0f9e-4d8c-b7a6-5e4d3c2b1a09",
      properties: ["plan_id": "pro", "seats": 5, "trial": false, "coupon": nil],
      personProperties: PersonPropertyOps(set: ["$email": "ada@example.com"], unset: ["legacy"]),
      timezone: "Europe/Berlin")
    // Pinned, so a release that moves SDK_VERSION does not move the fixture.
    event.sdkVersion = "0.1.0"
    let batch = RawBatch(
      clientSentMs: 1_792_584_000_000, deviceIdMode: "install", sessionIdMode: "sdk",
      app: AppInfo(version: "1.4.0", build: "140"),
      device: DeviceInfo(os: "iOS", osVersion: "18.1", model: "iPhone16,1", deviceType: "mobile"),
      events: [event])
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/wire-batch.json")
    let stored = try JSONValue.parse(try Data(contentsOf: fixture))
    XCTAssertEqual(batch.json, stored)
    XCTAssertEqual(RawEvent(json: event.json), event)
  }

  func testTheSessionIdThisSdkMintsMatchesTheEdgesPattern() throws {
    let pattern = try NSRegularExpression(pattern: Wire.sessionIdPattern)
    let id = randomId()
    XCTAssertEqual(
      pattern.numberOfMatches(in: id, range: NSRange(id.startIndex..., in: id)), 1)
  }
}
