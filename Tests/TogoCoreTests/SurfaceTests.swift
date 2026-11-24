import XCTest

@testable import TogoCore

/// The public calls' rules, shared with every SDK.
final class SurfaceTests: XCTestCase {
  let testKey = "togo_pkt_test0000000000"

  func testIdentifySendsOnceAndADifferentUserResetsFirst() {
    let h = Harness()
    h.engine.track("a")
    let anonymous = h.engine.anonymousId
    XCTAssertNotNil(h.engine.identify("user_1"))
    XCTAssertNil(h.engine.identify("user_1"), "the same user again sends nothing")
    h.engine.identify("user_2")
    h.flush()

    XCTAssertEqual(h.network.names, ["$session_started", "a", "$identify", "$session_started", "$identify"])
    let events = h.network.events
    XCTAssertEqual(events[2]["userId"], "user_1")
    XCTAssertEqual(events[2]["anonymousId"], .string(anonymous!))
    XCTAssertNil(events[2]["timezone"], "$identify is a claim, not an event: no device context")
    XCTAssertEqual(events[4]["userId"], "user_2")
    XCTAssertNotEqual(events[4]["anonymousId"], .string(anonymous!), "a different user is a missed logout")
  }

  /// A logout while consent is pending is still a logout: the grant after it
  /// starts a new visitor, and nothing of the last user is written back.
  func testAResetWhilePendingIsAFullLogoutOnTheNextGrant() {
    let h = Harness()
    h.engine.identify("user_1")
    h.engine.track("a")
    let anonymous = h.engine.anonymousId
    let session = h.engine.sessionId
    h.engine.setConsent(.pending)
    h.engine.reset()
    XCTAssertNil(h.identity.stored?.userId)
    XCTAssertNil(h.identity.stored?.anonymousId)
    h.engine.track("b")
    h.engine.setConsent(.granted)
    h.flush()

    let b = h.network.events.last!
    XCTAssertEqual(b["eventName"], "b")
    XCTAssertNil(b["userId"])
    XCTAssertNotEqual(b["anonymousId"], .string(anonymous!))
    XCTAssertNotEqual(b["sessionId"], .string(session!))
    XCTAssertNil(h.identity.stored?.userId, "the last user is not written back")
    XCTAssertNotEqual(h.identity.stored?.anonymousId, anonymous)
  }

  /// An empty or over-long userId would fail every later batch at the edge
  /// (RawEventSchema: 1–128), so identify() refuses it and changes nothing.
  func testIdentifyRefusesAUserIdTheEdgeWouldRefuse() {
    let h = Harness()
    XCTAssertNil(h.engine.identify(""))
    XCTAssertNil(h.engine.identify(String(repeating: "u", count: Wire.maxUserIdLength + 1)))
    XCTAssertEqual(h.sink.errors.map(\.code), [.userIdInvalid, .userIdInvalid])
    h.engine.track("a")
    XCTAssertNotNil(h.engine.identify(String(repeating: "u", count: Wire.maxUserIdLength)))
    h.flush()
    XCTAssertNil(h.network.events[1]["userId"], "the refused ids never rode an event")
    XCTAssertEqual(h.network.names, ["$session_started", "a", "$identify"])
  }

  func testTheUserIdIsRememberedAcrossARelaunch() {
    let h = Harness()
    h.engine.identify("user_1")
    h.start()
    h.engine.track("a")
    h.flush()
    XCTAssertEqual(h.network.events.last?["userId"], "user_1")
    XCTAssertNil(h.engine.identify("user_1"))
  }

  /// `email` and `name` are typed and written as `$email` and `$name`; `.some(nil)` removes.
  func testPersonPropertiesWriteTheTypedFieldsAsReservedKeys() {
    let h = Harness()
    h.engine.setPersonProperties(
      PersonPropertyUpdate(email: "ada@example.com", name: .some(nil), set: ["plan": "pro"], unset: ["legacy"]))
    XCTAssertNil(h.engine.setPersonProperties(PersonPropertyUpdate()), "an empty update sends nothing")
    h.flush()
    let carrier = h.network.events.last!
    XCTAssertEqual(carrier["eventName"], "$set_person_properties")
    XCTAssertEqual(
      carrier["personProperties"],
      ["set": ["$email": "ada@example.com", "$name": nil, "plan": "pro"], "unset": ["legacy"]])
    XCTAssertEqual(carrier["properties"], [:])
  }

  /// Conformance 12, live key: a `$` key is dropped with one log per key, and
  /// the event is still sent.
  func testReservedPropertyKeysAreDroppedUnderALiveKey() {
    let h = Harness(defaultProperties: ["$app": "x", "source": "ios"])
    h.engine.track("x", properties: ["$os": "y", "plan": "pro"])
    h.engine.track("x", properties: ["$os": "y"])
    h.engine.setPersonProperties(PersonPropertyUpdate(set: ["$email": "a@b.co", "plan": "pro"]))
    h.flush()
    XCTAssertEqual(h.network.events[1]["properties"], ["plan": "pro", "source": "ios"])
    XCTAssertEqual(h.network.events.last?["personProperties"], ["set": ["plan": "pro"]])
    XCTAssertEqual(h.sink.logs.filter { $0.contains("\"$os\" was not sent") }.count, 1)
    XCTAssertEqual(
      Set(h.sink.errors.map(\.code)), [.propertyReserved, .personPropertyReserved])
  }

  /// …and under a test key the same call SENDS `$os`, so the server's
  /// `property_reserved` reaches verify_tracking — and reports it here too.
  func testReservedPropertyKeysAreSentUnderATestKey() {
    let h = Harness(writeKey: testKey)
    h.engine.track("x", properties: ["$os": "y", "plan": "pro"])
    h.flush()
    XCTAssertEqual(h.network.events[1]["properties"], ["$os": "y", "plan": "pro"])
    XCTAssertEqual(h.sink.errors.map(\.code), [.propertyReserved])
    XCTAssertEqual(h.sink.errors.first?.property, "$os", "onError names the property")
  }

  /// Conformance 13: a name the registry cannot hold is reported under every
  /// key, dropped under a live key, sent under a test key; any other name is
  /// kept exactly as sent.
  func testPropertyNamesTheRegistryCannotHold() {
    let long = String(repeating: "p", count: 256)
    let bad: TogoProperties = [long: 1, "tab\there": 2, "ada@customer.io": 3, "": 4, "Plan Type": "pro"]
    let live = Harness()
    live.engine.track("Plan Selected", properties: bad)
    live.engine.track("Plan Selected", properties: bad)
    live.engine.setPersonProperties(PersonPropertyUpdate(set: [long: 1, "Tier": "gold"]))
    live.flush()
    XCTAssertEqual(live.network.events[1]["properties"], ["Plan Type": "pro"])
    XCTAssertEqual(live.network.events.last?["personProperties"], ["set": ["Tier": "gold"]])
    XCTAssertEqual(
      live.sink.errors.map(\.code),
      Array(repeating: .propertyNameInvalid, count: 4) + [.personPropertyNameInvalid])
    XCTAssertFalse(live.sink.logs.joined().contains("ada@customer.io"))
    XCTAssertTrue(
      live.sink.logs.contains {
        $0.contains(
          "\"\(String(repeating: "p", count: 64))\" was not sent: a property name is 1 to 255 characters, with no control character or email address (property_name_invalid).")
      })

    let test = Harness(writeKey: testKey)
    test.engine.track("Plan Selected", properties: bad)
    test.flush()
    XCTAssertEqual(
      test.network.events[1]["properties"],
      [long: 1, "tab\there": 2, "ada@customer.io": 3, "": 4, "Plan Type": "pro"])
    XCTAssertEqual(test.sink.errors.map(\.code), Array(repeating: .propertyNameInvalid, count: 4))
  }

  func testDollarEventNamesAreRefused() {
    let live = Harness()
    XCTAssertNil(live.engine.track("$pageview"))
    XCTAssertEqual(live.sink.errors.map(\.code), [.eventNameReserved])

    let test = Harness(writeKey: testKey)
    XCTAssertNotNil(test.engine.track("$pageview"), "sent for the edge to refuse into the inspector")
    // A name the edge accepts is ours, and dropped under BOTH key classes.
    for name in ["$identify", "$session_started", "$app_opened"] {
      XCTAssertNil(test.engine.track(name), name)
    }
  }

  func testAnEmptyOrOverlongNameIsRefusedPerEvent() {
    let h = Harness()
    XCTAssertNil(h.engine.track(""))
    XCTAssertNil(h.engine.track(String(repeating: "a", count: Wire.maxEventNameLength + 1)))
    XCTAssertNotNil(h.engine.track(String(repeating: "a", count: Wire.maxEventNameLength)))
    XCTAssertEqual(h.sink.errors.map(\.code), [.eventNameEmpty, .eventNameTooLong])
  }

  /// An over-long value is reported through `onError` once per event and key,
  /// cut to the cap under a live key, and the event sent: a long value is
  /// usually a real user's, which no test run shows the developer.
  func testAnOverLongValueIsReportedAndCutUnderALiveKey() {
    let h = Harness()
    let limit = Wire.maxEnvelopePropertyValueLength
    let long = String(repeating: "x", count: limit + 1)
    let eventId = h.engine.track("x", properties: ["note": .string(long), "plan": "pro"])
    h.engine.track("x", properties: ["note": .string(long)])
    let writeId = h.engine.setPersonProperties(PersonPropertyUpdate(set: ["bio": .string(long)]))
    h.flush()
    XCTAssertEqual(h.network.events[1]["properties"]?["note"], .string(String(long.prefix(limit))))
    XCTAssertEqual(h.network.events[1]["properties"]?["plan"], .string("pro"))
    XCTAssertEqual(
      h.network.events.last?["personProperties"]?["set"]?["bio"], .string(String(long.prefix(limit))))
    // Once for the event's key, once for the profile write's: never per call.
    XCTAssertEqual(
      h.sink.errors.map(\.code), [.envelopePropertyValueTooLong, .envelopePropertyValueTooLong])
    // The kept event's id, so the report leads to it in Live View.
    XCTAssertEqual(h.sink.errors.map(\.eventIds), [[eventId!], [writeId!]])
    XCTAssertEqual(h.sink.errors.map(\.property), ["note", "bio"])
    // The length, never the value.
    XCTAssertTrue(h.sink.errors[0].message.contains("is \(limit + 1) characters"))
    XCTAssertFalse(h.sink.errors[0].message.contains(String(repeating: "x", count: 50)))
  }

  /// Under a test key the value is sent whole, so the server's cut reaches
  /// `verify_tracking`; it is reported here as well.
  func testAnOverLongValueIsSentWholeUnderATestKey() {
    let h = Harness(writeKey: testKey)
    let long = String(repeating: "x", count: Wire.maxEnvelopePropertyValueLength + 1)
    h.engine.track("x", properties: ["note": .string(long)])
    h.flush()
    XCTAssertEqual(h.network.events[1]["properties"]?["note"], .string(long))
    XCTAssertEqual(h.sink.errors.map(\.code), [.envelopePropertyValueTooLong])
  }

  /// A cut on an event consent denied is not counted as reported, so the first one sent after a
  /// grant is (code-review on PR #231).
  func testACutOnADeniedEventDoesNotUseUpItsReport() {
    let h = Harness(consent: .denied)
    let long = String(repeating: "x", count: Wire.maxEnvelopePropertyValueLength + 1)
    XCTAssertNil(h.engine.track("x", properties: ["note": .string(long)]))
    h.engine.setConsent(.granted)
    let id = h.engine.track("x", properties: ["note": .string(long)])
    h.flush()
    XCTAssertEqual(h.sink.errors.map(\.code), [.envelopePropertyValueTooLong])
    XCTAssertEqual(h.sink.errors.first?.eventIds, [id!])
  }

  /// `n` properties named `p000`, `p001`, … so sort order is numeric order.
  private func wide(_ n: Int) -> TogoProperties {
    Dictionary(uniqueKeysWithValues: (0..<n).map { (pad("p", $0, 3), TogoValue.int($0)) })
  }

  private func pad(_ prefix: String, _ i: Int, _ width: Int) -> String {
    let digits = String(i)
    return prefix + String(repeating: "0", count: max(0, width - digits.count)) + digits
  }

  /// Past 256 properties the first 256 in sort order are kept under a live key and the event is
  /// sent; reported once per event name, with the kept event's id and the first ten dropped names.
  func testPropertiesPast256AreDroppedAndReportedUnderALiveKey() {
    let h = Harness()
    let eventId = h.engine.track("x", properties: wide(300))
    h.engine.track("x", properties: wide(300))
    h.flush()
    let sent = h.network.events[1]["properties"]?.objectValue ?? [:]
    XCTAssertEqual(Set(sent.keys), Set(wide(256).keys))
    XCTAssertEqual(h.sink.errors.map(\.code), [.envelopePropertiesTooMany])
    XCTAssertEqual(h.sink.errors.first?.eventIds, [eventId!])
    XCTAssertNil(h.sink.errors.first?.property, "about many properties, so no one property")
    XCTAssertTrue(
      h.sink.errors[0].message.contains(
        "\"x\" has 300 properties: kept the first 256 in sort order and dropped p256, p257"),
      h.sink.errors[0].message)
    XCTAssertTrue(h.sink.errors[0].message.contains("p265 and 34 more (envelope_properties_too_many)."))
  }

  /// Under a test key all of them are sent, so the edge drops the same keys where
  /// `verify_tracking` shows it; reported here as well.
  func testPropertiesPast256AreSentWholeUnderATestKey() {
    let h = Harness(writeKey: testKey)
    h.engine.track("x", properties: wide(300))
    h.flush()
    XCTAssertEqual(h.network.events[1]["properties"]?.objectValue?.count, 300)
    XCTAssertEqual(h.sink.errors.map(\.code), [.envelopePropertiesTooMany])
  }

  /// Counted before the name checks, as the edge counts: a `$` key sorts first, takes a slot, and
  /// is then dropped as reserved.
  func testThePropertyCountIsTakenBeforeTheNameChecks() {
    let h = Harness()
    var properties = wide(256)
    properties["$a"] = 1
    h.engine.track("x", properties: properties)
    h.flush()
    let sent = h.network.events[1]["properties"]?.objectValue ?? [:]
    XCTAssertEqual(sent.count, 255)
    XCTAssertNil(sent["p255"])
    XCTAssertEqual(
      Set(h.sink.errors.map(\.code)), [.envelopePropertiesTooMany, .propertyReserved])
  }

  /// Each profile map is cut on its own; `set` is counted with the `$email` the SDK adds.
  func testAProfileWriteCutsEachMapCountingTheTypedFields() {
    let h = Harness()
    let names = (0..<300).map { pad("p", $0, 3) }
    let writeId = h.engine.setPersonProperties(
      PersonPropertyUpdate(email: "a@b.co", set: wide(256), unset: names))
    h.flush()
    let ops = h.network.events.last?["personProperties"]
    let set = ops?["set"]?.objectValue ?? [:]
    XCTAssertEqual(set.count, 256)
    XCTAssertEqual(set["$email"], "a@b.co")
    XCTAssertNil(set["p255"])
    XCTAssertEqual(ops?["unset"]?.arrayValue?.compactMap(\.stringValue), Array(names[..<256]))
    XCTAssertEqual(h.sink.errors.map(\.code), [.envelopePropertiesTooMany, .envelopePropertiesTooMany])
    XCTAssertEqual(h.sink.errors.map(\.eventIds), [[writeId!], [writeId!]])
  }

  /// The email and name a profile write sets are kept, however many names sort before them.
  func testTheTypedFieldsSurviveThePropertyCap() {
    let h = Harness()
    let set = Dictionary(uniqueKeysWithValues: (0..<300).map { (pad("#", $0, 4), TogoValue.int($0)) })
    h.engine.setPersonProperties(PersonPropertyUpdate(email: "a@b.co", name: "Ada", set: set))
    h.flush()
    let kept = h.network.events.last?["personProperties"]?["set"]?.objectValue ?? [:]
    XCTAssertEqual(kept.count, 256)
    XCTAssertEqual(kept["$email"], "a@b.co")
    XCTAssertEqual(kept["$name"], "Ada")
    XCTAssertNil(kept["#0254"])
  }

  /// A long value on a key the cap drops is reported as dropped, never also as cut, under either
  /// key; a long value on a kept key is still cut.
  func testALongValueOnADroppedKeyIsNotAlsoReportedAsCut() {
    for key in [testKey, "togo_pkl_live0000000000"] {
      let h = Harness(writeKey: key)
      let long = TogoValue.string(String(repeating: "x", count: Wire.maxEnvelopePropertyValueLength + 1))
      var properties = wide(256)
      properties["a_url"] = long
      properties["zzz_url"] = long
      h.engine.track("x", properties: properties)
      h.flush()
      XCTAssertEqual(
        Set(h.sink.errors.map { "\($0.code)|\($0.property ?? "")" }),
        ["envelope_properties_too_many|", "envelope_property_value_too_long|a_url"], key)
    }
  }

  /// A drop on an event consent denied is not counted as reported.
  func testADropOnADeniedEventDoesNotUseUpItsReport() {
    let h = Harness(consent: .denied)
    XCTAssertNil(h.engine.track("x", properties: wide(257)))
    h.engine.setConsent(.granted)
    let id = h.engine.track("x", properties: wide(257))
    h.flush()
    XCTAssertEqual(h.sink.errors.map(\.code), [.envelopePropertiesTooMany])
    XCTAssertEqual(h.sink.errors.first?.eventIds, [id!])
  }

  /// The shared key sets every SDK and the edge are held to: the same keys kept, by UTF-16 code
  /// unit, whatever the insertion order.
  func testTheCapKeepsTheSameKeysAsEverySdkOnTheSharedKeySets() throws {
    let package = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // TogoCoreTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // the package
    // `scenarios/` inside the package where it is its own repository, else beside it.
    let own = package.appendingPathComponent("scenarios/fixtures/property-cap.json")
    let url =
      FileManager.default.fileExists(atPath: own.path)
      ? own
      : package.deletingLastPathComponent().appendingPathComponent(
        "scenarios/fixtures/property-cap.json")
    let fixture = try JSONValue.parse(try Data(contentsOf: url))
    XCTAssertEqual(fixture["max"]?.int64Value, Int64(Wire.maxEnvelopePropertiesPerEvent))
    XCTAssertEqual(
      fixture["platform"]?.arrayValue?.compactMap(\.stringValue), Wire.platformPropertyNames,
      "the names the cap keeps first are the ones every SDK and the edge keep first")
    let cases = fixture["cases"]?.arrayValue ?? []
    XCTAssertFalse(cases.isEmpty)
    for item in cases {
      let name = item["name"]?.stringValue ?? "?"
      let prefix = item["pad"]?["prefix"]?.stringValue ?? ""
      let count = Int(item["pad"]?["count"]?.int64Value ?? 0)
      let width = Int(item["pad"]?["width"]?.int64Value ?? 0)
      let keys =
        (0..<count).map { pad(prefix, $0, width) }
        + (item["keys"]?.arrayValue ?? []).compactMap(\.stringValue)
      let cap = Limits.keep(keys)
      XCTAssertEqual(cap?.dropped.count ?? 0, Int(item["droppedCount"]?.int64Value ?? -1), name)
      XCTAssertEqual(
        Array((cap?.dropped ?? []).prefix(10)),
        (item["droppedFirst"]?.arrayValue ?? []).compactMap(\.stringValue), name)
    }
  }

  /// The cut counts UTF-16 code units, as the server does, and never splits a
  /// surrogate pair.
  func testTruncationCountsCodeUnitsAndKeepsSurrogatePairsWhole() {
    let limit = Wire.maxEnvelopePropertyValueLength
    let split = String(repeating: "a", count: limit - 1) + "😀tail"
    XCTAssertEqual(Limits.truncate(split), String(repeating: "a", count: limit - 1))
    let inside = String(repeating: "a", count: limit - 2) + "😀tail"
    XCTAssertEqual(Limits.truncate(inside), String(repeating: "a", count: limit - 2) + "😀")
    let exact = String(repeating: "a", count: limit)
    XCTAssertEqual(Limits.truncate(exact), exact)
  }

  /// Conformance 10: defaults on every track() event, never on `$identify` or
  /// the carrier; the event's value wins and the collision is logged once.
  func testDefaultPropertiesAreOnTrackEventsOnly() {
    let h = Harness(defaultProperties: ["source": "ios_app"])
    h.engine.track("a", properties: ["source": "onboarding"])
    h.engine.track("a", properties: ["source": "onboarding"])
    h.engine.identify("user_1")
    h.engine.setPersonProperties(PersonPropertyUpdate(set: ["plan": "pro"]))
    h.engine.track("b")
    h.flush()
    let byName = h.network.events.map { ($0["eventName"]!.stringValue!, $0["properties"]!) }
    XCTAssertEqual(byName[1].1, ["source": "onboarding"])
    XCTAssertEqual(byName[3].1, [:], "$identify")
    XCTAssertEqual(byName[4].1, [:], "$set_person_properties")
    XCTAssertEqual(byName[5].1, ["source": "ios_app"])
    XCTAssertEqual(h.sink.logs.filter { $0.contains("overrides default property") }.count, 1)
  }

  /// The getters never mint.
  func testGettersNeverMint() {
    let h = Harness()
    XCTAssertNil(h.engine.anonymousId)
    XCTAssertNil(h.engine.deviceId)
    XCTAssertNil(h.engine.sessionId)
    XCTAssertNil(h.identity.stored)
    h.engine.track("a")
    XCTAssertNotNil(h.engine.anonymousId)
    XCTAssertEqual(h.engine.deviceId, h.identity.stored?.deviceId)
  }

  /// An app or device string the edge would drop is never sent.
  func testAnInvalidAppVersionIsLeftOutAndLogged() {
    let h = Harness(app: AppInfo(version: "", build: String(repeating: "9", count: 65)))
    h.engine.track("a")
    h.flush()
    XCTAssertNil(h.network.sent[0]["app"])
    XCTAssertEqual(h.sink.logs.filter { $0.contains("must be a string of 1–64") }.count, 2)
  }

  /// D3's rule, as the core sees it: while the identity store cannot be read
  /// (a locked device), nothing is minted and events are held in memory;
  /// once it can, they are sent under the STORED ids.
  func testAnUnreadableIdentityStoreHoldsEventsAndMintsNothing() {
    let stored = IdentityRecord(deviceId: "dev-1", deviceIdMode: "idfv", anonymousId: "anon-1")
    let identity = MemoryIdentityStore(stored)
    identity.locked = true
    let h = Harness(identity: identity)
    h.engine.track("push_received")
    h.flush()
    XCTAssertTrue(h.network.sent.isEmpty)
    XCTAssertEqual(h.engine.heldCount, 1)
    XCTAssertEqual(identity.stored?.anonymousId, "anon-1", "no id minted over an unreadable record")

    identity.locked = false
    h.engine.identityBecameAvailable()
    h.flush()
    XCTAssertEqual(h.network.names, ["$session_started", "push_received"])
    XCTAssertEqual(h.network.events[1]["anonymousId"], "anon-1")
    XCTAssertEqual(h.network.events[1]["deviceId"], "dev-1")
    XCTAssertEqual(h.network.sent[0]["deviceIdMode"], "idfv")
  }

  /// identify() on a locked device must not save a blank record over the
  /// stored one; the userId is applied once the record can be read.
  func testIdentifyWhileTheStoreIsUnreadableKeepsTheStoredIds() {
    let stored = IdentityRecord(deviceId: "dev-1", deviceIdMode: "idfv", anonymousId: "anon-1")
    let identity = MemoryIdentityStore(stored)
    identity.locked = true
    let h = Harness(identity: identity)
    h.engine.identify("user_1")
    identity.locked = false
    XCTAssertEqual(identity.stored?.deviceId, "dev-1", "the stored ids survive")
    XCTAssertEqual(identity.stored?.anonymousId, "anon-1")

    h.engine.identityBecameAvailable()
    h.flush()
    let event = h.network.events.last!
    XCTAssertEqual(event["eventName"], "$identify")
    XCTAssertEqual(event["anonymousId"], "anon-1")
    XCTAssertEqual(event["userId"], "user_1")
    XCTAssertEqual(identity.stored?.userId, "user_1")
  }

  /// A logout on a locked device (a push, a background launch) is a logout:
  /// at the unlock the stored user, its anonymous id and its session are
  /// gone, and the next person's events never go out under them.
  func testAResetWhileTheStoreIsUnreadableStaysALogoutAfterTheUnlock() {
    let identity = MemoryIdentityStore(
      IdentityRecord(
        deviceId: "dev-1", deviceIdMode: "idfv", anonymousId: "anon-A", userId: "A",
        session: SessionRecord(id: "s-A", startedAtMs: 1_792_584_000_000, lastActivityAtMs: 1_792_584_000_000)))
    identity.locked = true
    let h = Harness(identity: identity)
    h.engine.reset()
    h.engine.track("next_person")
    identity.locked = false
    h.engine.identityBecameAvailable()
    h.flush()

    let event = h.network.events.last!
    XCTAssertEqual(event["eventName"], "next_person")
    XCTAssertNil(event["userId"], "the logged-out user is not restored")
    XCTAssertNotEqual(event["anonymousId"], "anon-A")
    XCTAssertNotEqual(event["sessionId"], "s-A")
    XCTAssertEqual(event["deviceId"], "dev-1", "the device stays")
    XCTAssertNil(identity.stored?.userId)
    XCTAssertNotEqual(identity.stored?.anonymousId, "anon-A")
  }

  /// identify() of a different user on a locked device is a missed logout at
  /// the unlock, never stitched onto the stored user's anonymous id.
  func testIdentifyingADifferentUserWhileUnreadableResetsAtTheUnlock() {
    let identity = MemoryIdentityStore(
      IdentityRecord(deviceId: "dev-1", deviceIdMode: "idfv", anonymousId: "anon-A", userId: "A"))
    identity.locked = true
    let h = Harness(identity: identity)
    h.engine.identify("B")
    identity.locked = false
    h.engine.identityBecameAvailable()
    h.flush()

    let event = h.network.events.last!
    XCTAssertEqual(event["eventName"], "$identify")
    XCTAssertEqual(event["userId"], "B")
    XCTAssertNotEqual(event["anonymousId"], "anon-A", "B is not stitched onto A's anonymous id")
    XCTAssertEqual(event["deviceId"], "dev-1")
    XCTAssertEqual(identity.stored?.userId, "B")
  }

  /// The positive half: the same user identified while locked keeps the
  /// stored ids.
  func testIdentifyingTheStoredUserWhileUnreadableKeepsItsIds() {
    let identity = MemoryIdentityStore(
      IdentityRecord(deviceId: "dev-1", deviceIdMode: "idfv", anonymousId: "anon-A", userId: "A"))
    identity.locked = true
    let h = Harness(identity: identity)
    h.engine.identify("A")
    identity.locked = false
    h.engine.identityBecameAvailable()
    h.engine.track("a")
    h.flush()

    XCTAssertEqual(h.network.events.last!["anonymousId"], "anon-A")
    XCTAssertEqual(h.network.events.last!["userId"], "A")
    XCTAssertEqual(identity.stored?.userId, "A")
  }

  /// The same missed logout under `pending`, where the record is not read
  /// either: B identified before the grant is never stitched onto A.
  func testIdentifyingADifferentUserWhilePendingResetsAtTheGrant() {
    let identity = MemoryIdentityStore(
      IdentityRecord(deviceId: "dev-1", deviceIdMode: "idfv", anonymousId: "anon-A", userId: "A"))
    let h = Harness(consent: .pending, identity: identity)
    h.engine.identify("B")
    h.engine.setConsent(.granted)
    h.flush()

    let event = h.network.events.last!
    XCTAssertEqual(event["userId"], "B")
    XCTAssertNotEqual(event["anonymousId"], "anon-A")
    XCTAssertEqual(identity.stored?.userId, "B")
  }

  func testAWriteKeyThatIsNotOneIsNamed() {
    XCTAssertNil(writeKeyProblem("togo_pkl_abc"))
    XCTAssertNil(writeKeyProblem("togo_pkt_abc"))
    XCTAssertTrue(writeKeyProblem("togo_sk_abc")!.contains("SECRET"))
    XCTAssertTrue(writeKeyProblem("$(TOGO_KEY)")!.contains("not a write key"))
  }
}
