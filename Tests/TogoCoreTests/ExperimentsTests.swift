import Foundation
import XCTest

@testable import TogoCore

/// `getExperiment()` on a device: a stored answer offline, the synchronous
/// read, the exposure once, the stamp, and the session pin.
/// A result a completion handler fills, read back on the same thread.
final class Box<T>: @unchecked Sendable {
  var value: T?
}

final class ExperimentsTests: XCTestCase {
  typealias Answer = (status: String, variant: String?, participating: Bool)
  static let inB: [String: Answer] = ["checkout": ("active", "b", true)]

  private func get(_ h: Harness, _ name: String = "checkout") -> TogoExperiment? {
    let result = Box<TogoExperiment>()
    h.engine.getExperiment(name) { result.value = $0 }
    return result.value
  }

  private func entered(_ h: Harness) -> [JSONValue] {
    h.network.events.filter { $0["eventName"]?.stringValue == "$experiment_entered" }
  }

  private func online(_ h: Harness, _ answers: [String: Answer] = inB, maxAgeSeconds: Int64 = 3600) {
    h.network.assign = { _ in Harness.Network.assignments(answers, maxAgeSeconds: maxAgeSeconds) }
  }

  private func offline(_ h: Harness) {
    h.network.assign = { _ in TransportResponse(status: nil) }
  }

  // 1 and 2

  func testAStoredAnswerIsReturnedOfflineAtAnyAgeAndRefreshed() {
    let h = Harness()
    online(h, maxAgeSeconds: 60)
    XCTAssertEqual(get(h)?.variant, "b")
    offline(h)
    h.clock.advance(30 * 24 * 3_600_000)  // A month offline.
    let before = h.network.assignRequests.count
    let result = get(h)
    XCTAssertEqual(result?.status, .active)
    XCTAssertEqual(result?.variant, "b")
    XCTAssertEqual(h.network.assignRequests.count, before + 1, "an old answer is refreshed")
  }

  func testNoStoredAnswerAndNoNetworkIsUnavailableAndStoresNothing() {
    let h = Harness()
    let result = get(h)
    XCTAssertEqual(result, .unavailable("checkout"))
    XCTAssertTrue(entered(h).isEmpty)
    h.flush()
    XCTAssertTrue(entered(h).isEmpty)
    XCTAssertNil(h.engine.cachedExperiment("checkout"))
  }

  func testASlowNetworkAnswersUnavailableAndStillFillsTheStore() {
    let h = Harness()
    online(h)
    h.network.holdsAssign = true
    let result = Box<TogoExperiment>()
    let calls = Box<Int>()
    h.engine.getExperiment("checkout") {
      result.value = $0
      calls.value = (calls.value ?? 0) + 1
    }
    XCTAssertNil(result.value)
    h.executor.fire(0.8)
    XCTAssertEqual(result.value, .unavailable("checkout"))
    h.network.answerAssign()
    XCTAssertEqual(calls.value, 1, "answered once")
    XCTAssertEqual(h.engine.cachedExperiment("checkout")?.variant, "b")
  }

  // 3

  func testTheExposureIsSentOncePerUnitAcrossAKillAndRelaunch() {
    let h = Harness()
    online(h)
    _ = get(h)
    _ = get(h)
    h.start()  // Killed and relaunched over the same stores.
    _ = get(h)
    _ = h.engine.cachedExperiment("checkout")
    h.flushAll()
    let exposures = entered(h)
    XCTAssertEqual(exposures.count, 1)
    XCTAssertEqual(exposures.first?["properties"]?["experiment"], .string("checkout"))
    XCTAssertEqual(exposures.first?["properties"]?["variant"], .string("b"))
    XCTAssertNil(exposures.first?["experiments"], "a $ event carries no stamp")
  }

  func testANonParticipantIsNotEnteredOrStamped() {
    let h = Harness()
    online(h, ["checkout": ("active", nil, false)])
    let result = get(h)
    XCTAssertEqual(result?.status, .active)
    XCTAssertNil(result?.variant)
    XCTAssertFalse(result?.participating ?? true)
    h.engine.track("paid")
    h.flush()
    XCTAssertTrue(entered(h).isEmpty)
    XCTAssertNil(h.network.events.last?["experiments"])
  }

  // 4

  func testALaterEventCarriesTheStampAndAQueuedEventKeepsIt() {
    let h = Harness()
    online(h)
    _ = get(h)
    h.network.answers = [TransportResponse(status: nil)]  // The upload fails: queued offline.
    h.engine.track("paid")
    h.flush()
    // The experiment finishes before the queued event goes; it keeps the stamp it was tracked with.
    online(h, ["checkout": ("finished", nil, false)])
    h.engine.preloadExperiments(["checkout"])
    h.clock.advance(3_600_001)
    h.engine.preloadExperiments(["checkout"])
    h.start()
    h.flushAll()
    let paid = h.network.events.last { $0["eventName"]?.stringValue == "paid" }
    XCTAssertEqual(paid?["experiments"], .object(["checkout": .string("b")]))
  }

  // 5

  func testIdentifyDropsTheAnswersAndKeepsTheStampAndTheOnceRecord() {
    let h = Harness()
    online(h)
    _ = get(h)
    h.engine.identify("u_1")
    let requests = h.network.assignRequests.count
    online(h, ["checkout": ("active", "a", true)])
    XCTAssertEqual(get(h)?.variant, "a", "asked again for the signed-in user")
    XCTAssertEqual(h.network.assignRequests.count, requests + 1)
    XCTAssertEqual(h.network.assignRequests.last?["userId"], .string("u_1"))
  }

  func testResetStartsAnEmptyStoreAndNeverCountsTheSameUnitTwice() {
    let h = Harness()
    h.network.assign = { _ in Harness.Network.assignments(ExperimentsTests.inB, unit: "device_id") }
    _ = get(h)
    h.engine.reset()
    XCTAssertNil(h.engine.cachedExperiment("checkout"), "the answers went with the visitor")
    h.engine.track("after_reset")
    _ = get(h)
    h.flushAll()
    XCTAssertEqual(entered(h).count, 1, "the device is the same unit after reset()")
    let after = h.network.events.first { $0["eventName"]?.stringValue == "after_reset" }
    XCTAssertNil(after?["experiments"], "the stamps went with the visitor")
  }

  func testAResetWhileTheFileCannotBeReadKeepsTheOnceRecord() {
    let h = Harness()
    h.network.assign = { _ in Harness.Network.assignments(ExperimentsTests.inB, unit: "device_id") }
    _ = get(h)
    h.start()  // A new process: nothing of the file in memory.
    h.experimentStore.unreadable = true  // Before the first unlock.
    h.engine.reset()
    h.experimentStore.unreadable = false
    _ = get(h)
    h.flushAll()
    XCTAssertEqual(entered(h).count, 1, "the device is the same unit, entered once")
  }

  // 6

  func testARefreshMidSessionChangesNothingUntilTheNextSession() {
    let h = Harness()
    online(h, maxAgeSeconds: 60)
    h.engine.track("opened")
    XCTAssertEqual(get(h)?.variant, "b")
    online(h, ["checkout": ("active", "c", true)], maxAgeSeconds: 60)
    h.clock.advance(61_000)
    h.engine.track("still_here")
    XCTAssertEqual(get(h)?.variant, "b", "the stored one, refreshed behind it")
    XCTAssertEqual(get(h)?.variant, "b", "pinned for the session")
    XCTAssertEqual(h.engine.cachedExperiment("checkout")?.variant, "b")
    h.clock.advance(31 * 60_000)
    h.engine.track("next_visit")
    XCTAssertEqual(get(h)?.variant, "c")
  }

  // 7

  func testFinishedFromARefreshEndsTheStamp() {
    let h = Harness(lifecycle: true)
    h.foreground()
    online(h)
    _ = get(h)
    online(h, ["checkout": ("finished", nil, false)])
    h.background()
    h.foreground()  // `$app_opened` refreshes what is stored, inside the same session.
    XCTAssertEqual(get(h)?.variant, "b", "the session's pinned answer still")
    _ = h.engine.cachedExperiment("checkout")
    h.engine.track("later")
    h.flushAll()
    let later = h.network.events.last { $0["eventName"]?.stringValue == "later" }
    XCTAssertNotNil(later)
    XCTAssertNil(later?["experiments"])
  }

  func testAppOpenedFetchesTheConfiguredNamesWithoutAnExposure() {
    let h = Harness(lifecycle: true)
    h.options.experiments = ["onboarding"]
    h.start()
    online(h, ["onboarding": ("active", "short", true)])
    h.foreground()
    XCTAssertEqual(h.network.assignRequests.last?["experiments"], .array([.string("onboarding")]))
    h.flushAll()
    XCTAssertTrue(entered(h).isEmpty, "a preload is not an exposure")
    offline(h)
    XCTAssertEqual(h.engine.cachedExperiment("onboarding")?.variant, "short")
  }

  // 8

  func testTheSynchronousReadNeverAsksAndRecordsTheExposure() {
    let h = Harness()
    online(h)
    XCTAssertNil(h.engine.cachedExperiment("checkout"))
    XCTAssertTrue(h.network.assignRequests.isEmpty, "never the network")
    h.engine.preloadExperiments(["checkout"])
    let requests = h.network.assignRequests.count
    XCTAssertEqual(h.engine.cachedExperiment("checkout")?.variant, "b")
    XCTAssertEqual(h.network.assignRequests.count, requests)
    h.engine.track("paid")
    h.flushAll()
    XCTAssertEqual(entered(h).count, 1)
    let paid = h.network.events.last { $0["eventName"]?.stringValue == "paid" }
    XCTAssertEqual(paid?["experiments"], .object(["checkout": .string("b")]))
  }

  // 9

  func testConsentPendingOrDeniedIsUnavailableAndWithdrawalDeletesTheFile() {
    let pending = Harness(consent: .pending)
    online(pending)
    XCTAssertEqual(get(pending), .unavailable("checkout"))
    XCTAssertTrue(pending.network.assignRequests.isEmpty)
    XCTAssertNil(pending.experimentStore.read())

    let h = Harness()
    online(h)
    _ = get(h)
    XCTAssertNotNil(h.experimentStore.read())
    h.engine.setConsent(.denied)
    XCTAssertNil(h.experimentStore.read())
    XCTAssertEqual(get(h), .unavailable("checkout"))
    XCTAssertNil(h.engine.cachedExperiment("checkout"))
  }

  func testALockedDeviceAnswersUnavailableAndAsksNothing() {
    let identity = MemoryIdentityStore()
    identity.locked = true
    let locked = Harness(identity: identity)
    online(locked)
    XCTAssertEqual(get(locked), .unavailable("checkout"))
    XCTAssertTrue(locked.network.assignRequests.isEmpty)
    XCTAssertNil(locked.engine.cachedExperiment("checkout"))
  }

  /// A launch choosing its first screen: nothing in front yet, the stored answer at once.
  private func storedThenRelaunched() -> Harness {
    let h = Harness(lifecycle: true)
    h.foreground()
    online(h)
    h.engine.preloadExperiments(["checkout"])  // Stored, nobody entered.
    h.background()
    offline(h)
    h.start()  // Killed; launched again, no scene in front yet.
    return h
  }

  func testBeforeTheFirstScreenTheStoredAnswerIsReadAndEnteredAtTheForeground() {
    let h = storedThenRelaunched()
    XCTAssertEqual(h.engine.cachedExperiment("checkout")?.variant, "b", "for the first screen")
    XCTAssertEqual(get(h)?.variant, "b")
    h.engine.track("launch_screen")
    h.foreground()
    h.engine.track("home")
    h.flushAll()
    XCTAssertEqual(entered(h).count, 1, "entered once, at the foreground")
    let names = h.network.names
    XCTAssertEqual(
      names.firstIndex(of: "$experiment_entered").map { $0 > names.firstIndex(of: "$app_opened")! },
      true, "after the open")
    let launch = h.network.events.last { $0["eventName"]?.stringValue == "launch_screen" }
    XCTAssertNil(launch?["experiments"], "no stamp before the exposure")
    let home = h.network.events.last { $0["eventName"]?.stringValue == "home" }
    XCTAssertEqual(home?["experiments"], .object(["checkout": .string("b")]))
  }

  func testALaunchThatNeverComesToTheFrontEntersNobody() {
    let h = storedThenRelaunched()  // A push launch, say.
    XCTAssertEqual(get(h)?.variant, "b")
    h.engine.track("push_received")
    h.flushAll()
    XCTAssertTrue(entered(h).isEmpty)
    h.start()
    h.foreground()  // The next process opening does not inherit the last one's.
    h.flushAll()
    XCTAssertTrue(entered(h).isEmpty)
  }

  func testAResetBeforeTheForegroundDropsWhatWaited() {
    let h = storedThenRelaunched()
    _ = h.engine.cachedExperiment("checkout")
    h.engine.reset()
    h.foreground()
    h.flushAll()
    XCTAssertTrue(entered(h).isEmpty, "the answer was the last visitor's")
  }

  // 10

  func testATestKeyAsksEveryTimeAndEntersPerVariantPerProcess() {
    let h = Harness(writeKey: "togo_pkt_test0000000000")
    online(h)
    _ = get(h)
    _ = get(h)
    XCTAssertEqual(h.network.assignRequests.count, 2, "a test key caches nothing")
    online(h, ["checkout": ("active", "c", true)])
    _ = get(h)
    h.flushAll()
    XCTAssertEqual(entered(h).map { $0["properties"]?["variant"] }, [.string("b"), .string("c")])
    XCTAssertNil(h.experimentStore.read(), "nothing stored")
  }

  // The request and the edges

  func testTheRequestCarriesTheUnitsAndTheKey() {
    let h = Harness()
    online(h)
    h.engine.identify("u_9")
    _ = get(h)
    let body = h.network.assignRequests.last
    XCTAssertNotNil(body?["anonymousId"]?.stringValue)
    XCTAssertNotNil(body?["deviceId"]?.stringValue)
    XCTAssertEqual(body?["userId"], .string("u_9"))
    XCTAssertEqual(body?["experiments"], .array([.string("checkout")]))
  }

  func testANameTheServerCannotHoldIsNotFoundWithNoRequest() {
    let h = Harness()
    online(h)
    XCTAssertEqual(get(h, "")?.status, .notFound)
    XCTAssertEqual(get(h, String(repeating: "x", count: 65))?.status, .notFound)
    XCTAssertTrue(h.network.assignRequests.isEmpty)
  }

  func testACorruptFileIsARefetchNotACrash() {
    let store = MemoryExperimentStore(Data("{not json".utf8))
    let h = Harness(experimentStore: store)
    online(h)
    XCTAssertEqual(get(h)?.variant, "b")
  }

  func testTheUnitHashMatchesTheBrowsers() {
    // The browser's `hashUnit("abc")`: djb2 over UTF-16, base 36.
    XCTAssertEqual(Experiments.hashUnit("abc"), String(UInt32(193_485_963), radix: 36))
    XCTAssertEqual(Experiments.hashUnit(""), String(5381, radix: 36))
  }
}
