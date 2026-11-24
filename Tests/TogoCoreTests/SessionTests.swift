import XCTest

@testable import TogoCore

final class SessionTests: XCTestCase {
  let minute: Int64 = 60_000

  func sessionIds(_ h: Harness) -> [String?] {
    h.network.events.map { $0["sessionId"]?.stringValue }
  }

  /// iOS kills a
  /// suspended app with no callback. A session held only in memory would end
  /// there and the relaunch would start a new one — inflating session counts.
  /// The record is persisted and restored while inside both windows.
  func testAProcessKilledMidSessionAndRelaunchedInsideTheWindowKeepsItsSession() {
    let h = Harness()
    h.engine.track("screen_viewed")
    let before = h.engine.sessionId
    XCTAssertNotNil(before)

    // Killed. Ten minutes later, a new process over the same stores, with a
    // monotonic clock that restarted from a new baseline.
    h.clock.wall += 10 * minute
    h.clock.monotonic = 1_000
    h.start()
    XCTAssertEqual(h.engine.sessionId, before)
    h.engine.track("screen_viewed")
    h.flush()

    XCTAssertEqual(h.network.names, ["$session_started", "screen_viewed", "screen_viewed"])
    XCTAssertEqual(Set(sessionIds(h)), [before])
  }

  /// The positive half: past the idle window, the relaunch does start a new one.
  func testARelaunchPastTheIdleWindowStartsANewSession() {
    let h = Harness()
    h.engine.track("screen_viewed")
    let before = h.engine.sessionId

    h.clock.wall += 31 * minute
    h.clock.monotonic = 1_000
    h.start()
    XCTAssertNil(h.engine.sessionId, "a read never reports a session that has ended")
    h.engine.track("screen_viewed")
    h.flush()

    XCTAssertEqual(
      h.network.names, ["$session_started", "screen_viewed", "$session_started", "screen_viewed"])
    let ids = sessionIds(h)
    XCTAssertEqual(ids[0], before)
    XCTAssertNotEqual(ids[2], before)
    XCTAssertEqual(ids[2], ids[3])
  }

  /// The queue survives the kill too, and the relaunch sends what was left.
  func testEventsQueuedBeforeAKillAreSentAfterTheRelaunch() {
    let h = Harness()
    h.network.answers = [TransportResponse(status: nil)]
    h.engine.track("checkout_started")
    h.flush()
    XCTAssertEqual(h.network.sent.count, 1)

    h.start()
    h.flush()
    XCTAssertEqual(h.network.sent.count, 2)
    XCTAssertEqual(
      h.network.sent[1]["events"]!.arrayValue!.map { $0["eventName"]!.stringValue! },
      ["$session_started", "checkout_started"])
  }

  func testThirtyMinutesIdleCutsAndActivityExtends() {
    let h = Harness()
    h.engine.track("a")
    h.clock.advance(29 * minute)
    h.engine.track("b")
    h.clock.advance(29 * minute)
    h.engine.track("c")  // 58 minutes after the start, 29 after the last event
    h.clock.advance(31 * minute)
    h.engine.track("d")
    h.flush()
    XCTAssertEqual(h.network.names, ["$session_started", "a", "b", "c", "$session_started", "d"])
  }

  /// The 24-hour cap is not configurable: a session kept alive by activity
  /// still ends.
  func testTheTwentyFourHourCapEndsASessionThatNeverIdles() {
    let h = Harness()
    h.engine.track("a")
    for _ in 0..<50 {  // 50 × 29 min = 24 h 10 min
      h.clock.advance(29 * minute)
      h.engine.track("tick")
    }
    h.flush()
    let starts = h.network.names.filter { $0 == "$session_started" }
    XCTAssertEqual(starts.count, 2)
  }

  /// Rule 13: `<= 0` DISABLES sessions — no sessionId at all — and is never
  /// read as instant expiry, which would mint one session per event.
  func testATimeoutOfZeroOrLessSendsNoSessionAtAll() {
    for timeout in [0.0, -1.0] {
      let h = Harness(sessionTimeoutSeconds: timeout)
      h.engine.track("a")
      h.engine.track("b")
      h.flush()
      XCTAssertEqual(h.network.names, ["a", "b"])
      XCTAssertEqual(sessionIds(h), [nil, nil])
      XCTAssertEqual(h.network.sent[0]["sessionIdMode"], .string("disabled"))
      XCTAssertNil(h.engine.sessionId)
    }
  }

  /// A mis-read setting must neither crash setup() nor flip the rule: a huge
  /// or infinite value behaves as the 24-hour cap, minus infinity disables,
  /// and NaN gets the default.
  func testExtremeTimeoutsNeitherCrashNorTurnSessionsOn() {
    for timeout in [1e16, .greatestFiniteMagnitude, .infinity] {
      let h = Harness(sessionTimeoutSeconds: timeout)
      h.engine.track("a")
      h.clock.advance(23 * 60 * minute)
      h.engine.track("b")
      h.flush()
      XCTAssertEqual(h.network.names, ["$session_started", "a", "b"], "\(timeout)")
      XCTAssertTrue(h.sink.logs.contains("sessionTimeout is seconds, max 86400"))
    }
    let off = Harness(sessionTimeoutSeconds: -.infinity)
    off.engine.track("a")
    off.flush()
    XCTAssertEqual(off.network.sent[0]["sessionIdMode"], "disabled")
    XCTAssertEqual(off.network.names, ["a"])

    let nan = Harness(sessionTimeoutSeconds: .nan)
    nan.engine.track("a")
    nan.clock.advance(29 * minute)
    nan.engine.track("b")
    nan.flush()
    XCTAssertEqual(nan.network.names, ["$session_started", "a", "b"])
  }

  /// Within one process idle is measured on the monotonic clock, so a
  /// wall clock moved forward (travel, NTP) does not cut the session…
  func testAWallClockJumpInsideOneProcessDoesNotCutTheSession() {
    let h = Harness()
    h.engine.track("a")
    h.clock.wall += 2 * 60 * minute  // the wall jumped two hours
    h.clock.monotonic += minute  // one real minute passed
    h.engine.track("b")
    h.flush()
    XCTAssertEqual(h.network.names, ["$session_started", "a", "b"])
  }

  /// …and a clock that moved BACKWARDS is never trusted to extend one.
  func testAWallClockThatMovedBackwardsCutsTheSession() {
    let h = Harness()
    h.engine.track("a")
    h.clock.wall -= 5 * minute
    h.clock.monotonic += minute
    h.engine.track("b")
    h.flush()
    XCTAssertEqual(h.network.names, ["$session_started", "a", "$session_started", "b"])
  }

  func testResetEndsTheSessionAndRotatesTheAnonymousIdButKeepsTheDevice() {
    let h = Harness()
    h.engine.track("a")
    let anonymous = h.engine.anonymousId
    let device = h.engine.deviceId
    h.engine.reset()
    XCTAssertNil(h.engine.sessionId, "reset mints nothing: the next event opens the session")
    h.engine.track("b")
    h.flush()
    XCTAssertEqual(h.network.names, ["$session_started", "a", "$session_started", "b"])
    let events = h.network.events
    XCTAssertNotEqual(events[3]["anonymousId"], .string(anonymous!))
    XCTAssertEqual(events[3]["deviceId"], .string(device!))
    XCTAssertNotEqual(events[3]["sessionId"], events[1]["sessionId"])
  }
}
