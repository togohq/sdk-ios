import Foundation
import TogoCore
import XCTest

@testable import TogoScenarios

/// Every scenario in
/// the shared scenarios (`scenarios/`) re-records through the Swift core to its `expected/`
/// batches, on macOS and on Linux. The goldens are the browser's; `Projection`
/// says exactly what a phone is allowed to differ in.
final class ScenarioGoldenTests: XCTestCase {
  func golden(_ name: String) throws -> JSONValue {
    let url = ScenarioFormat.defaultRoot.appendingPathComponent("expected/\(name).json")
    return try JSONValue.parse(try Data(contentsOf: url))
  }

  func testEveryScenarioReRecordsToItsExpectedBatches() throws {
    let names = try ScenarioFormat.scenarioNames()
    // Guard the guard: an empty or moved directory must fail, not pass vacuously.
    XCTAssertGreaterThanOrEqual(names.count, 17, "no scenarios found under \(ScenarioFormat.defaultRoot.path)")
    var withDevice = 0
    for name in names {
      let recorded = Projection.recorded(try ScenarioDriver.record(name))
      // Three scenarios are server-only (`actor: "server"` throughout): they
      // compare as empty on both sides, which is the honest answer.
      let expected = Projection.expected(try golden(name))
      if !expected.isEmpty { withDevice += 1 }
      XCTAssertNil(Projection.difference(expected, recorded), name)
    }
    XCTAssertGreaterThanOrEqual(withDevice, 14, "most scenarios have a device to replay")
  }

  /// The native profile (`scenarios/README.md` → Native scenarios): every
  /// scenario under `native/` re-records to its `expected-native/` batches.
  /// This runner recorded them, so this is a regression check on the lifecycle
  /// a second native SDK will be held to.
  func testEveryNativeScenarioReRecordsToItsExpectedNativeBatches() throws {
    let names = try ScenarioFormat.nativeScenarioNames()
    XCTAssertGreaterThanOrEqual(names.count, 3, "no native scenarios under \(ScenarioFormat.defaultRoot.path)")
    for name in names {
      let url = ScenarioFormat.defaultRoot.appendingPathComponent("expected-native/\(name).json")
      let golden = Projection.native(try JSONValue.parse(try Data(contentsOf: url)))
      XCTAssertFalse(golden.isEmpty, name)
      XCTAssertNil(Projection.difference(golden, try ScenarioDriver.recordNative(name)), name)
    }
  }

  /// What the native goldens pin, read off them, so a re-recording that lost a
  /// rule is visible in review and not only as a changed file.
  func testTheNativeGoldensCarryTheLifecycleRules() throws {
    func events(_ name: String) throws -> [JSONValue] {
      try ScenarioDriver.recordNative(name).flatMap { $0.body["events"]!.arrayValue! }
    }
    func names(_ list: [JSONValue]) -> [String] { list.map { $0["eventName"]!.stringValue! } }

    let installed = try events("app_installed_then_opened")
    XCTAssertEqual(
      names(installed), ["$app_installed", "$session_started", "$app_opened", "screen_viewed"])
    XCTAssertNil(installed[0]["sessionId"])

    let updated = try ScenarioDriver.recordNative("app_updated")
    XCTAssertEqual(updated.map { $0.body["app"]?["build"] }, [.string("140"), .string("150")])
    let afterUpdate = updated[1].body["events"]!.arrayValue!
    XCTAssertEqual(names(afterUpdate).filter { $0.hasPrefix("$app_") }, ["$app_updated", "$app_opened", "$app_opened"])
    XCTAssertEqual(
      afterUpdate[0]["properties"],
      .object(["previous_app_version": .string("1.4.0"), "previous_app_build": .string("140")]))

    let day = try events("app_background_return")
    let opens = day.filter { $0["eventName"] == .string("$app_opened") }
    XCTAssertEqual(
      opens.map { $0["properties"]!["from_background"]! },
      [.bool(false), .bool(false), .bool(true), .bool(true)],
      "one per move into the foreground; the second window and the push launches send none")
    XCTAssertEqual(names(day).filter { $0 == "$session_started" }.count, 3)
    let pushes = day.filter { $0["eventName"] == .string("push_received") }
    XCTAssertNotNil(pushes[0]["sessionId"], "inside the window: joins")
    XCTAssertNil(pushes[1]["sessionId"], "outside it: none, never a new one")
    XCTAssertNil(pushes[2]["sessionId"])
  }

  func testANativeScenarioMustStartWithALaunch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("native"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"name":"x","steps":[{"foreground":"main"}]}"#.utf8)
      .write(to: root.appendingPathComponent("native/x.json"))
    XCTAssertThrowsError(try ScenarioFormat.loadNativeScenario("x", root: root))
  }

  /// The comparison has teeth: a recording that differs by one event, or by
  /// one millisecond, is caught.
  func testTheComparisonCatchesADroppedEventAndAMovedTimestamp() throws {
    let expected = Projection.expected(try golden("trial_converts"))
    let recorded = Projection.recorded(try ScenarioDriver.record("trial_converts"))
    XCTAssertNil(Projection.difference(expected, recorded))

    var dropped = recorded
    var body = dropped[0].body.objectValue!
    var events = body["events"]!.arrayValue!
    events.removeLast()
    body["events"] = .array(events)
    dropped[0].body = .object(body)
    XCTAssertNotNil(Projection.difference(expected, dropped))

    var moved = recorded
    body = moved[0].body.objectValue!
    events = body["events"]!.arrayValue!
    var event = events[1].objectValue!
    let ms = ISOTime.parse(event["clientEventTs"]!.stringValue!)!
    event["clientEventTs"] = .string(ISOTime.format(ms + 1))
    events[1] = .object(event)
    body["events"] = .array(events)
    moved[0].body = .object(body)
    XCTAssertNotNil(Projection.difference(expected, moved))
  }

  /// What is removed from the comparison is ONLY what a phone cannot match.
  func testTheRecordingCarriesTheNativeFieldsTheProjectionRemoves() throws {
    let raw = try ScenarioDriver.record("bounce")
    let body = raw[0].body
    XCTAssertEqual(body["app"], .object(["version": "1.4.0", "build": "140"]))
    XCTAssertEqual(body["device"]?["os"], .string("iOS"))
    XCTAssertEqual(body["deviceIdMode"], .string("install"))
    XCTAssertEqual(body["sessionIdMode"], .string("sdk"))
    let first = body["events"]!.arrayValue![0]
    XCTAssertEqual(first["sdk"]?["name"], .string("sdk-ios"))
    XCTAssertNil(first["page"])
  }

  /// A server step is `@togohq/sdk-node`'s, never a device SDK's.
  func testServerStepsAreNotReplayedThroughTheDeviceSdk() throws {
    let raw = try ScenarioDriver.record("direct_purchase")
    XCTAssertEqual(raw.map(\.client), ["direct_purchase#1:browser", "direct_purchase#1:phone"])
    let names = raw.flatMap { $0.body["events"]!.arrayValue!.map { $0["eventName"]!.stringValue! } }
    XCTAssertFalse(names.contains("subscription_started"))
  }

  /// mulberry32 is the same in every runtime — these are the browser
  /// runner's own outputs for the same seeds.
  func testTheSeededGeneratorMatchesTheJavaScriptOne() {
    let random = ScenarioFormat.prng(1)
    XCTAssertEqual(random(), 0.6270739405881613)
    XCTAssertEqual(random(), 0.002735721180215478)
    XCTAssertEqual(random(), 0.5274470399599522)
    XCTAssertEqual(ScenarioFormat.prng(3_735_928_559)(), 0.9413696140982211)
  }

  func testDurationsAndAtParse() {
    XCTAssertEqual(ScenarioFormat.parseDuration("1d2h30m"), 95_400_000)
    XCTAssertEqual(ScenarioFormat.parseDuration("500ms"), 500)
    XCTAssertNil(ScenarioFormat.parseDuration("5x"))
    if case .absolute(let ms) = ScenarioFormat.parseAt("now-5m") {
      XCTAssertEqual(ms, -300_000)
    } else {
      XCTFail("now-5m is absolute")
    }
  }

  /// A verb this runner cannot perform fails the load, rather than being
  /// skipped (README: "A verb is added when every SDK that reads the format
  /// can perform it").
  func testAnUnknownVerbIsRefused() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("scenarios"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"name":"x","steps":[{"getExperiment":"cta"}]}"#.utf8)
      .write(to: root.appendingPathComponent("scenarios/x.json"))
    XCTAssertThrowsError(try ScenarioFormat.loadScenario("x", root: root))
  }
}
