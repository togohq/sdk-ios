import XCTest

@testable import TogoCore

/// The app's lifecycle, decided in the core and driven here by the signals the
/// UIKit adapter forwards: launches, scenes coming forward and going back, the
/// device unlocking. Runs under `swift test` on macOS and Linux. Every "does not fire"
/// assertion has its positive half beside it, so a rule that never fires at all
/// cannot pass.
final class LifecycleTests: XCTestCase {
  let minute: Int64 = 60_000

  final class DeviceIds: DeviceIdProvider, @unchecked Sendable {
    var value: String?
    var asked = 0
    init(_ value: String?) { self.value = value }
    func deviceId() -> (id: String, mode: String)? {
      asked += 1
      return value.map { ($0, "idfv") }
    }
  }

  func event(_ h: Harness, _ name: String) -> JSONValue? {
    h.network.events.first { $0["eventName"]?.stringValue == name }
  }

  func count(_ h: Harness, _ name: String) -> Int {
    h.network.names.filter { $0 == name }.count
  }

  // MARK: - D4: installed, updated, opened

  /// The first launch: `$app_installed` at the launch, with no session — nobody
  /// is known to be looking — then the first foreground opens the session with
  /// `$app_opened`, `from_background: false`.
  func testTheFirstLaunchSendsAppInstalledThenTheFirstForegroundOpensTheApp() {
    let h = Harness(lifecycle: true)
    h.foreground()
    h.flushAll()

    XCTAssertEqual(h.network.names, ["$app_installed", "$session_started", "$app_opened"])
    let installed = event(h, "$app_installed")!
    XCTAssertEqual(installed["properties"], .object([:]), "D4: no properties; the row's context says which build")
    XCTAssertNil(installed["sessionId"], "a launch is not a human: it never opens a session")
    let opened = event(h, "$app_opened")!
    XCTAssertEqual(opened["properties"], .object(["from_background": .bool(false)]))
    XCTAssertNotNil(opened["sessionId"])
    XCTAssertEqual(h.identity.stored?.appVersion, "1.2.0")
    XCTAssertEqual(h.identity.stored?.appBuild, "12")
  }

  /// A relaunch of the same build sends neither, and the first launch's install
  /// above is the positive half.
  func testASecondLaunchOfTheSameBuildSendsNoInstallAndNoUpdate() {
    let h = Harness(lifecycle: true)
    h.flushAll()
    XCTAssertEqual(h.network.names, ["$app_installed"])

    h.start()
    h.engine.track("screen_viewed")
    h.flushAll()
    XCTAssertEqual(h.network.names, ["$app_installed", "screen_viewed"])
  }

  /// A version bump between launches sends ONE
  /// `$app_updated`, with the previous values; the new ones are the row's
  /// context. Never `$app_installed` on that launch.
  func testAVersionBumpSendsOneAppUpdatedWithThePreviousValues() {
    let h = Harness(lifecycle: true)
    h.relaunch(version: "1.3.0", build: "13")
    h.relaunch(version: "1.3.0", build: "13")
    h.flushAll()

    XCTAssertEqual(h.network.names, ["$app_installed", "$app_updated"])
    let updated = event(h, "$app_updated")!
    XCTAssertEqual(
      updated["properties"],
      .object(["previous_app_version": .string("1.2.0"), "previous_app_build": .string("12")]))
    XCTAssertEqual(h.network.sent.last?["app"], .object(["version": "1.3.0", "build": "13"]))
    XCTAssertEqual(h.identity.stored?.appVersion, "1.3.0")
  }

  /// A build-only change is an update too: TestFlight builds share a version.
  func testABuildOnlyChangeIsAnUpdate() {
    let h = Harness(lifecycle: true)
    h.relaunch(version: "1.2.0", build: "13")
    h.flushAll()
    XCTAssertEqual(h.network.names, ["$app_installed", "$app_updated"])
    XCTAssertEqual(event(h, "$app_updated")?["properties"]?["previous_app_build"], .string("12"))
  }

  /// The other half: a prewarmed launch — and any
  /// background launch, a push or `BGAppRefreshTask` — brings no scene
  /// forward, so it sends no `$app_opened`, and an event from it opens no
  /// session. The positive half: when the user does open the app, that
  /// is the process's first foreground, `from_background: false`.
  func testAPrewarmedOrBackgroundLaunchSendsNoAppOpenedUntilTheUserOpensTheApp() {
    let h = Harness(lifecycle: true)
    h.engine.track("push_received")
    h.flushAll()
    XCTAssertEqual(h.network.names, ["$app_installed", "push_received"])
    XCTAssertNil(event(h, "push_received")?["sessionId"], "no human: no session")

    h.clock.advance(5 * minute)
    h.foreground()
    h.flushAll()
    XCTAssertEqual(
      h.network.names, ["$app_installed", "push_received", "$session_started", "$app_opened"])
    XCTAssertEqual(event(h, "$app_opened")?["properties"]?["from_background"], .bool(false))
  }

  /// A return from the background: `from_background: true`, and inside the
  /// window the same session.
  func testAReturnFromTheBackgroundIsAnOpenFromBackgroundInTheSameSession() {
    let h = Harness(lifecycle: true)
    h.foreground()
    h.background()
    h.clock.advance(10 * minute)
    h.foreground()
    h.flushAll()

    let opens = h.network.events.filter { $0["eventName"]?.stringValue == "$app_opened" }
    XCTAssertEqual(opens.map { $0["properties"]?["from_background"] }, [.bool(false), .bool(true)])
    XCTAssertEqual(opens[0]["sessionId"], opens[1]["sessionId"])
    XCTAssertEqual(count(h, "$session_started"), 1)
  }

  /// Background time is idle time, and the clock starts at the move to
  /// the background — not at the last event. Twenty quiet minutes in front, then
  /// fifteen in the background, is fifteen idle minutes: the same session. The
  /// positive half: forty in the background is a new one.
  func testBackgroundTimeIsIdleTimeFromTheMoveToTheBackground() {
    let h = Harness(lifecycle: true)
    h.foreground()
    h.clock.advance(20 * minute)
    h.background()
    h.clock.advance(15 * minute)
    h.foreground()
    h.flushAll()
    XCTAssertEqual(count(h, "$session_started"), 1, "35 minutes since the last event, 15 idle")

    h.background()
    h.clock.advance(40 * minute)
    h.foreground()
    h.flushAll()
    XCTAssertEqual(count(h, "$session_started"), 2)
  }

  /// The move to the background writes `lastActivityAt` and flushes; after a
  /// kill in the background, the relaunch measures idle from that write.
  func testTheMoveToTheBackgroundPersistsTheSessionAndFlushes() {
    let h = Harness(lifecycle: true)
    h.foreground()
    let started = h.identity.stored!.session!
    h.clock.advance(20 * minute)
    h.background()
    XCTAssertEqual(h.identity.stored?.session?.lastActivityAtMs, started.lastActivityAtMs + 20 * minute)
    XCTAssertEqual(h.network.names, ["$app_installed", "$session_started", "$app_opened"], "flushed")

    // Killed while suspended; relaunched by the user 25 minutes later.
    h.clock.wall += 25 * minute
    h.clock.monotonic = 1_000
    h.start()
    h.foreground()
    h.flushAll()
    XCTAssertEqual(count(h, "$session_started"), 1, "25 idle minutes, not 45")
  }

  /// A background event joins an open session, and does not extend it.
  func testABackgroundEventJoinsTheOpenSessionWithoutExtendingIt() {
    let h = Harness(lifecycle: true)
    h.foreground()
    h.background()
    let last = h.identity.stored!.session!.lastActivityAtMs
    h.clock.advance(5 * minute)
    h.engine.track("push_received")
    h.flushAll()
    XCTAssertEqual(event(h, "push_received")?["sessionId"], event(h, "$app_opened")?["sessionId"])
    XCTAssertEqual(h.identity.stored?.session?.lastActivityAtMs, last)
  }

  /// With two scenes, one going to the
  /// background while the other is in front starts no idle time, flushes
  /// nothing and sends no `$app_opened` when it returns. The positive half:
  /// when the LAST one goes, the background rules apply, and the next one to
  /// come forward is an open.
  func testASecondSceneMovingNeitherStartsIdleTimeNorOpensTheApp() {
    let h = Harness(lifecycle: true)
    h.foreground("left")
    h.foreground("right")
    let session = h.identity.stored!.session!
    h.clock.advance(10 * minute)
    h.background("left")
    XCTAssertTrue(h.network.sent.isEmpty, "no background flush while a scene is in front")
    XCTAssertEqual(h.identity.stored?.session, session, "no idle time started")
    h.foreground("left")
    XCTAssertEqual(h.engine.queuedCount, 3, "no second $app_opened")

    h.background("left")
    h.background("right")
    XCTAssertEqual(h.network.names, ["$app_installed", "$session_started", "$app_opened"])
    XCTAssertEqual(h.identity.stored?.session?.lastActivityAtMs, session.lastActivityAtMs + 10 * minute)
    h.foreground("right")
    h.flushAll()
    XCTAssertEqual(count(h, "$app_opened"), 2)
  }

  /// A scene leaving twice, or one that was never in front, changes nothing.
  func testAnUnknownSceneLeavingIsIgnored() {
    let h = Harness(lifecycle: true)
    h.foreground("a")
    h.background("b")
    XCTAssertTrue(h.network.sent.isEmpty)
    h.background("a")
    XCTAssertFalse(h.network.sent.isEmpty)
  }

  /// `setup()` called late, with a scene already in front: the install is the
  /// launch's first event and the open follows it, both in the session the
  /// human in front of the app opened.
  func testALateSetupWithASceneInFrontInstallsThenOpens() {
    let h = Harness(lifecycle: true, foregroundAtLaunch: ["main"])
    h.flushAll()
    XCTAssertEqual(h.network.names, ["$session_started", "$app_installed", "$app_opened"])
    XCTAssertEqual(Set(h.network.events.map { $0["sessionId"] }).count, 1)
  }

  /// D4's "does not fire" for `reset()`: logout keeps the install. The
  /// positive half is the withdrawal: it deletes the file, so a later grant is
  /// a fresh install (documented).
  func testResetIsNotAReinstallButAConsentWithdrawalIs() {
    let h = Harness(lifecycle: true)
    h.engine.reset()
    h.start()
    h.flushAll()
    XCTAssertEqual(h.network.names, ["$app_installed"])

    h.engine.setConsent(.denied)
    h.engine.setConsent(.granted)
    h.flushAll()
    XCTAssertEqual(h.network.names, ["$app_installed", "$app_installed"])
    let ids = h.network.events.map { $0["anonymousId"] }
    XCTAssertNotEqual(ids[0], ids[1], "nothing is stitched")
  }

  /// Under `pending` nothing is read or stored, so the decision waits; the
  /// grant makes it, at the launch's time and ahead of what was held.
  func testUnderPendingConsentTheInstallWaitsForTheGrantAndGoesFirst() {
    let h = Harness(consent: .pending, lifecycle: true)
    let launchedAt = h.clock.wall
    h.foreground()
    h.clock.advance(minute)
    h.engine.track("onboarding_started")
    XCTAssertNil(h.identity.stored)

    h.engine.setConsent(.granted)
    h.flushAll()
    XCTAssertEqual(
      h.network.names, ["$session_started", "$app_installed", "$app_opened", "onboarding_started"])
    XCTAssertEqual(event(h, "$app_installed")?["clientEventTs"], .string(ISOTime.format(launchedAt)))
  }

  // MARK: - D1: the device id

  /// The first launch takes the IDFV with mode
  /// `idfv`; a later launch where the IDFV reads differently still sends the
  /// stored one, and the IDFV is not even read (D1 step 2).
  func testTheIdfvIsReadOnceAndTheStoredValueWinsOnEveryLaterLaunch() {
    let ids = DeviceIds("IDFV-1")
    let h = Harness(deviceIds: ids, lifecycle: true)
    h.flushAll()
    XCTAssertEqual(h.network.events[0]["deviceId"], .string("IDFV-1"))
    XCTAssertEqual(h.network.sent[0]["deviceIdMode"], .string("idfv"))

    ids.value = "IDFV-2"
    h.start()
    h.engine.track("screen_viewed")
    h.flushAll()
    XCTAssertEqual(h.network.events.last?["deviceId"], .string("IDFV-1"))
    XCTAssertEqual(ids.asked, 1)
  }

  /// D1 step 4: an IDFV that is nil for now is waited for, never replaced. The
  /// events are held with no id; when it arrives they go under it, with the
  /// install first.
  func testAnIdfvThatIsNilForNowHoldsEventsAndNeverFallsBack() {
    let ids = DeviceIds(nil)
    let h = Harness(deviceIds: ids, lifecycle: true)
    h.engine.track("push_received")
    h.flushAll()
    XCTAssertTrue(h.network.sent.isEmpty)
    XCTAssertEqual(h.engine.heldCount, 2)
    XCTAssertNil(h.identity.stored?.deviceId)

    ids.value = "IDFV-1"
    h.engine.identityBecameAvailable()
    h.flushAll()
    XCTAssertEqual(h.network.names, ["$app_installed", "push_received"])
    XCTAssertEqual(Set(h.network.events.map { $0["deviceId"] }), [.string("IDFV-1")])
    XCTAssertEqual(h.network.sent[0]["deviceIdMode"], .string("idfv"))
  }

  /// With no IDFV on the platform, a generated id
  /// with mode `install`, and the same id after a relaunch.
  func testWithNoIdfvTheGeneratedIdIsModeInstallAndSurvivesARelaunch() {
    let h = Harness(lifecycle: true)
    h.flushAll()
    let first = h.network.events[0]["deviceId"]
    XCTAssertEqual(h.network.sent[0]["deviceIdMode"], .string("install"))

    h.start()
    h.engine.track("screen_viewed")
    h.flushAll()
    XCTAssertEqual(h.network.events.last?["deviceId"], first)
    XCTAssertEqual(h.network.sent.last?["deviceIdMode"], .string("install"))
  }

  // MARK: - D3: protected data

  /// An existing install launched in the background
  /// before the first unlock. Nothing is minted, no `$app_installed` is sent
  /// (the file is unreadable, not absent), events are held, and after the
  /// unlock the stored ids are used.
  func testBeforeTheFirstUnlockNothingIsMintedAndTheStoredIdsAreUsedAfter() {
    let h = Harness(lifecycle: true)
    h.flushAll()
    let stored = h.identity.stored!
    let sentBefore = h.network.sent.count

    h.identity.locked = true
    h.start()
    h.engine.track("push_received")
    h.flushAll()
    XCTAssertEqual(h.network.sent.count, sentBefore, "held, not sent")
    XCTAssertEqual(h.engine.heldCount, 1)
    XCTAssertEqual(h.identity.stored, stored, "nothing minted or written")

    h.identity.locked = false
    h.engine.identityBecameAvailable()
    h.flushAll()
    XCTAssertEqual(h.network.names, ["$app_installed", "push_received"])
    XCTAssertEqual(h.network.events.last?["deviceId"], .string(stored.deviceId!))
    XCTAssertEqual(h.network.events.last?["anonymousId"], .string(stored.anonymousId!))
  }

  /// The positive half: a first launch that is locked is held too, and is an
  /// install once the device unlocks and the file is truly absent.
  func testALockedFirstLaunchInstallsOnceTheDeviceUnlocks() {
    let identity = MemoryIdentityStore()
    identity.locked = true
    let h = Harness(identity: identity, lifecycle: true)
    h.flushAll()
    XCTAssertTrue(h.network.sent.isEmpty)
    XCTAssertNil(identity.stored)

    identity.locked = false
    h.engine.identityBecameAvailable()
    h.flushAll()
    XCTAssertEqual(h.network.names, ["$app_installed"])
  }

  /// While the identity cannot be read neither can the queue, which shares its
  /// protection class: reading it as empty would let the next write replace
  /// what an earlier launch left. A flush waits; after the unlock the old
  /// events go first.
  func testTheQueueIsNotReadWhileTheIdentityIsUnreadable() {
    let h = Harness(lifecycle: true)
    h.network.answers = [TransportResponse(status: nil)]
    h.flush()
    let leftOnDisk = h.queueStore.read()
    XCTAssertNotNil(leftOnDisk)

    h.identity.locked = true
    h.start()
    h.flush()
    XCTAssertEqual(h.network.sent.count, 1, "only the first, failed, attempt")
    XCTAssertEqual(h.queueStore.read(), leftOnDisk)

    h.identity.locked = false
    h.engine.identityBecameAvailable()
    h.flush()
    XCTAssertEqual(h.network.names, ["$app_installed", "$app_installed"], "the retry, after the unlock")
  }
}
