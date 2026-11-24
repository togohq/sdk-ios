import XCTest

@testable import TogoCore

/// Consent: four states, `setup()` never delayed,
/// nothing stored or sent while `pending`, and withdrawal deletes.
final class ConsentTests: XCTestCase {
  func testPendingHoldsInMemoryStoresNothingAndSendsNothing() {
    let h = Harness(consent: .pending)
    let id = h.engine.track("screen_viewed")
    XCTAssertNotNil(id, "the caller gets the id the released event will carry")
    h.engine.identify("user_1")
    h.flush()

    XCTAssertTrue(h.network.sent.isEmpty)
    XCTAssertNil(h.identity.stored, "no identifier minted or stored while pending")
    XCTAssertNil(h.queueStore.read(), "no queue file while pending")
    XCTAssertNil(h.engine.anonymousId)
    XCTAssertNil(h.engine.sessionId)
    XCTAssertEqual(h.engine.heldCount, 2)
  }

  /// Granting releases what was held, under ids minted NOW, in one session
  /// whose start takes the first held event's time.
  func testGrantingReleasesTheBufferUnderFreshIdsInOneSession() {
    let h = Harness(consent: .pending)
    let first = h.engine.track("screen_viewed")
    let heldAt = h.clock.wall
    h.clock.advance(30_000)
    h.engine.track("paywall_viewed")
    h.clock.advance(10_000)
    h.engine.setConsent(.granted)
    h.flush()

    XCTAssertEqual(h.network.names, ["$session_started", "screen_viewed", "paywall_viewed"])
    let events = h.network.events
    XCTAssertEqual(events[1]["eventId"], .string(first!))
    XCTAssertEqual(events[0]["clientEventTs"], .string(ISOTime.format(heldAt)))
    XCTAssertEqual(Set(events.map { $0["sessionId"]! }).count, 1)
    XCTAssertNotNil(h.identity.stored?.anonymousId)
  }

  /// Withdrawal DELETES: the identity record and the queue, not merely stops.
  func testDenyingDeletesTheStoredIdentityAndTheQueue() {
    let h = Harness()
    h.network.answers = [TransportResponse(status: nil)]
    h.engine.track("screen_viewed")
    h.flush()  // offline: the event stays queued
    XCTAssertNotNil(h.identity.stored)
    XCTAssertNotNil(h.queueStore.read())

    h.engine.setConsent(.denied)
    XCTAssertNil(h.identity.stored)
    XCTAssertNil(h.queueStore.read())
    XCTAssertNil(h.engine.track("after_denial"))
    XCTAssertNil(h.engine.anonymousId)
    h.flush()
    XCTAssertEqual(h.network.sent.count, 1, "nothing is sent after a denial")
  }

  /// Ids written while consent was permitted are deleted by a denial that
  /// comes through `pending` — a consent tool re-asking, then a refusal.
  func testDenyingAfterPendingStillDeletesTheStoredIdentity() {
    let h = Harness()
    h.engine.track("screen_viewed")
    XCTAssertNotNil(h.identity.stored?.anonymousId)
    h.engine.setConsent(.pending)
    h.engine.setConsent(.denied)
    XCTAssertNil(h.identity.stored)
    h.engine.setConsent(.granted)
    XCTAssertNil(h.engine.anonymousId, "nothing restored from memory either")
  }

  /// A client started with `denied` deletes a queue an earlier process left,
  /// rather than uploading events from before the refusal.
  func testAQueueLeftFromBeforeADenialIsDeletedAtStartUp() {
    let h = Harness()
    h.network.answers = [TransportResponse(status: nil)]
    h.engine.track("screen_viewed")
    h.flush()
    XCTAssertNotNil(h.queueStore.read())

    h.options.consent = .denied
    h.start()
    XCTAssertNil(h.queueStore.read())
  }

  func testDenyingWhilePendingDiscardsTheBuffer() {
    let h = Harness(consent: .pending)
    h.engine.track("screen_viewed")
    h.engine.setConsent(.denied)
    h.engine.setConsent(.granted)
    h.flush()
    XCTAssertTrue(h.network.sent.isEmpty)
  }

  /// The buffer is bounded; the OLDEST is dropped and reported.
  func testThePendingBufferIsBoundedOldestFirst() {
    let h = Harness(consent: .pending)
    h.options.consentBufferMaxEvents = 2
    h.start()
    let first = h.engine.track("one")
    h.engine.track("two")
    h.engine.track("three")
    XCTAssertEqual(h.engine.heldCount, 2)
    XCTAssertEqual(h.sink.errors.map(\.code), [.queueFull])
    XCTAssertEqual(h.sink.errors.first?.eventIds, [first!])
    h.engine.setConsent(.granted)
    h.flush()
    XCTAssertEqual(h.network.names, ["$session_started", "two", "three"])
  }

  /// A userId asserted under `pending` rides the events held with it, and is
  /// stored at the first moment a write is permitted.
  func testAUserIdAssertedWhilePendingIsKeptAndStoredOnGrant() {
    let h = Harness(consent: .pending)
    h.engine.identify("user_1")
    h.engine.track("screen_viewed")
    h.engine.setConsent(.granted)
    h.flush()
    XCTAssertEqual(h.network.names, ["$session_started", "$identify", "screen_viewed"])
    XCTAssertEqual(Set(h.network.events.map { $0["userId"] }), [.string("user_1")])
    XCTAssertEqual(h.identity.stored?.userId, "user_1")
  }

  /// A relaunch under `pending` with a user signed in from the last launch:
  /// what was held carries that user once the grant reads the record, rather
  /// than going out anonymous.
  func testEventsHeldBeforeTheRecordIsReadCarryTheStoredUser() {
    let identity = MemoryIdentityStore(
      IdentityRecord(deviceId: "dev-1", deviceIdMode: "idfv", anonymousId: "anon-1", userId: "u1"))
    let h = Harness(consent: .pending, identity: identity)
    h.engine.track("screen_viewed")
    h.engine.setConsent(.granted)
    h.engine.track("after_grant")
    h.flush()
    XCTAssertEqual(h.network.names, ["$session_started", "screen_viewed", "after_grant"])
    XCTAssertEqual(h.network.events.map { $0["userId"] }, ["u1", "u1", "u1"])
  }

  /// ...but an event held after a logout in this process is the next
  /// person's, and one held before it the user's.
  func testALogoutWhileHeldSplitsTheBufferAtTheLogout() {
    let identity = MemoryIdentityStore(
      IdentityRecord(deviceId: "dev-1", deviceIdMode: "idfv", anonymousId: "anon-1", userId: "u1"))
    let h = Harness(consent: .pending, identity: identity)
    h.engine.track("before_logout")
    h.engine.reset()
    h.engine.track("after_logout")
    h.engine.setConsent(.granted)
    h.flush()
    let user = Dictionary(
      uniqueKeysWithValues: h.network.events.map { ($0["eventName"]!.stringValue!, $0["userId"]) })
    XCTAssertEqual(user["before_logout"], .some("u1"))
    XCTAssertEqual(user["after_logout"], .some(nil))
    XCTAssertNil(identity.stored?.userId, "the logout reached the device")
    assertTheTwoPeopleAreNotLinked(h, previous: "before_logout", next: ["after_logout"])
  }

  /// The two people either side of a logout share no id but the device's:
  /// the event from before it keeps the stored anonymous id and no session,
  /// and no event pairs the last user with the next anonymous id.
  func assertTheTwoPeopleAreNotLinked(
    _ h: Harness, previous: String, next: [String], file: StaticString = #filePath, line: UInt = #line
  ) {
    let events = h.network.events
    guard let before = events.first(where: { $0["eventName"] == .string(previous) }) else {
      return XCTFail("no \(previous)", file: file, line: line)
    }
    XCTAssertEqual(before["userId"], "u1", file: file, line: line)
    XCTAssertEqual(before["anonymousId"], "anon-1", "the last user's own anonymous id", file: file, line: line)
    XCTAssertNil(before["sessionId"], "neither the last user's session nor the next one", file: file, line: line)
    for name in next {
      guard let after = events.first(where: { $0["eventName"] == .string(name) }) else {
        return XCTFail("no \(name)", file: file, line: line)
      }
      XCTAssertNotEqual(after["anonymousId"], "anon-1", name, file: file, line: line)
    }
    let fresh = Set(events.compactMap { $0["anonymousId"] }).subtracting(["anon-1"])
    XCTAssertTrue(
      events.allSatisfy { !($0["userId"] == "u1" && fresh.contains($0["anonymousId"]!)) },
      "u1 never rides the next anonymous id: \(events)", file: file, line: line)
  }

  /// The same on a locked device, logged out before the unlock.
  func testAnEventHeldBeforeALockedLogoutKeepsTheStoredIds() {
    let identity = MemoryIdentityStore(
      IdentityRecord(deviceId: "dev-1", deviceIdMode: "idfv", anonymousId: "anon-1", userId: "u1"))
    identity.locked = true
    let h = Harness(identity: identity)
    h.engine.track("before_logout")
    h.engine.reset()
    h.engine.track("after_logout")
    identity.locked = false
    h.engine.identityBecameAvailable()
    h.flush()
    XCTAssertNil(h.network.events.first { $0["eventName"] == "after_logout" }!["userId"])
    assertTheTwoPeopleAreNotLinked(h, previous: "before_logout", next: ["after_logout"])
  }

  /// ...and a different user identified on a locked device: u2's $identify
  /// and the event from before it are on different anonymous ids.
  func testAnEventHeldBeforeALockedIdentifyOfAnotherUserKeepsTheStoredIds() {
    let identity = MemoryIdentityStore(
      IdentityRecord(deviceId: "dev-1", deviceIdMode: "idfv", anonymousId: "anon-1", userId: "u1"))
    identity.locked = true
    let h = Harness(identity: identity)
    h.engine.track("before_identify")
    h.engine.identify("u2")
    identity.locked = false
    h.engine.identityBecameAvailable()
    h.flush()
    XCTAssertEqual(h.network.events.first { $0["eventName"] == "$identify" }?["userId"], "u2")
    assertTheTwoPeopleAreNotLinked(h, previous: "before_identify", next: ["$identify"])
  }

  /// The same on a locked device: held until the unlock, then sent as the
  /// stored user.
  func testEventsHeldWhileTheStoreIsUnreadableCarryTheStoredUser() {
    let identity = MemoryIdentityStore(
      IdentityRecord(deviceId: "dev-1", deviceIdMode: "idfv", anonymousId: "anon-1", userId: "u1"))
    identity.locked = true
    let h = Harness(identity: identity)
    h.engine.track("push_received")
    identity.locked = false
    h.engine.identityBecameAvailable()
    h.flush()
    XCTAssertEqual(h.network.names, ["$session_started", "push_received"])
    XCTAssertEqual(h.network.events.map { $0["userId"] }, ["u1", "u1"])
  }

  /// A withdrawal forgets the signed-in user in memory too: a later grant in
  /// the same process neither sends nor stores it.
  func testAWithdrawalForgetsTheUserIdForALaterGrant() {
    let h = Harness()
    h.engine.identify("u1")
    h.engine.setConsent(.denied)
    h.engine.setConsent(.granted)
    h.engine.track("after_grant")
    h.flush()
    XCTAssertEqual(h.network.events.last!["eventName"], "after_grant")
    XCTAssertTrue(h.network.events.allSatisfy { $0["userId"] == nil }, "\(h.network.events)")
    XCTAssertNil(h.identity.stored?.userId)
  }

  /// The same through `pending` on the way back.
  func testAWithdrawalThenPendingThenGrantSendsNoUserId() {
    let h = Harness()
    h.engine.identify("u1")
    h.engine.setConsent(.denied)
    h.engine.setConsent(.pending)
    h.engine.track("held")
    h.engine.setConsent(.granted)
    h.flush()
    XCTAssertEqual(h.network.events.last!["eventName"], "held")
    XCTAssertTrue(h.network.events.allSatisfy { $0["userId"] == nil }, "\(h.network.events)")
    XCTAssertNil(h.identity.stored?.userId)
  }
}
