import XCTest

@testable import TogoCore

/// The durable queue, batching and the transport.
final class DeliveryTests: XCTestCase {
  func ids(_ batch: JSONValue) -> [String] {
    batch["events"]!.arrayValue!.map { $0["eventId"]!.stringValue! }
  }

  func testABatchCarriesTheAppTheDeviceAndBothModes() {
    let h = Harness()
    h.engine.track("screen_viewed", properties: ["plan": "pro"])
    h.flush()
    let batch = h.network.sent[0]
    XCTAssertEqual(h.network.urls[0].absoluteString, "https://in.example.test/v1/events")
    XCTAssertEqual(h.network.keys[0], "togo_pkl_live0000000000")
    XCTAssertEqual(batch["envelopeVersion"], .int(2))
    XCTAssertEqual(batch["app"], ["version": "1.2.0", "build": "12"])
    XCTAssertEqual(batch["device"]?["osVersion"], "18.1")
    XCTAssertEqual(batch["deviceIdMode"], "install")
    XCTAssertEqual(batch["sessionIdMode"], "sdk")
    XCTAssertEqual(batch["clientSentTs"], .string(ISOTime.format(h.clock.wall)))
    let event = batch["events"]!.arrayValue![1]
    XCTAssertEqual(event["sdk"]?["name"], "sdk-ios")
    XCTAssertEqual(event["timezone"], "Europe/Berlin")
    XCTAssertNil(event["page"])
    XCTAssertNil(event["projectId"], "project_id is never held or sent")
  }

  /// D5: events recorded on 1.2 and flushed after an update to 1.3 keep 1.2.
  /// The uploader never puts two app versions — or two OS versions — in one
  /// batch.
  func testABatchIsCutWhereTheAppOrOsVersionChanges() {
    let queue = MemoryQueueStore()
    let identity = MemoryIdentityStore()
    let old = Harness(identity: identity, queueStore: queue)
    old.network.answers = [TransportResponse(status: nil)]
    old.engine.track("on_1_2")
    old.flush()  // offline

    // The app updated, and the OS with it.
    let new = Harness(
      app: AppInfo(version: "1.3.0", build: "13"),
      device: DeviceInfo(os: "iOS", osVersion: "18.2", model: "iPhone16,1", deviceType: "mobile"),
      identity: identity, queueStore: queue)
    new.engine.track("on_1_3")
    new.flush()
    new.flush()

    XCTAssertEqual(new.network.sent.count, 2)
    let (first, second) = (new.network.sent[0], new.network.sent[1])
    XCTAssertEqual(first["app"]?["version"], "1.2.0")
    XCTAssertEqual(first["device"]?["osVersion"], "18.1")
    XCTAssertEqual(first["events"]!.arrayValue!.map { $0["eventName"]! }, ["$session_started", "on_1_2"])
    XCTAssertEqual(second["app"]?["version"], "1.3.0")
    XCTAssertEqual(second["device"]?["osVersion"], "18.2")
    XCTAssertEqual(second["events"]!.arrayValue!.map { $0["eventName"]! }, ["on_1_3"])
  }

  /// A relaunch that uploads before its first event — `flush()` at start-up —
  /// still says where the queued events' device id came from.
  func testAStartUpFlushCarriesTheQueuedEventsDeviceIdMode() {
    let h = Harness()
    h.network.answers = [TransportResponse(status: nil)]
    h.engine.track("a")
    h.flush()  // offline: queued
    h.start()  // a new launch, nothing tracked yet
    h.flush()
    XCTAssertEqual(h.network.sent.count, 2)
    XCTAssertEqual(h.network.sent[1]["deviceIdMode"], "install")
  }

  /// Every 5xx — not only 503 — is retried with the SAME eventIds, so the edge
  /// dedupes a batch that did land; backoff is scheduled, never a spin.
  func testEveryServerErrorIsRetriedWithTheSameEventIds() {
    for status in [500, 502, 503, 504] {
      let h = Harness()
      h.network.answers = [TransportResponse(status: status)]
      h.engine.track("checkout_started")
      h.flush()
      XCTAssertEqual(h.engine.queuedCount, 2, "\(status): the batch is back in the queue")
      XCTAssertGreaterThan(h.executor.timers.last ?? 0, 0, "\(status): a retry is scheduled")
      h.flush()
      guard h.network.sent.count == 2 else {
        XCTFail("\(status): \(h.network.sent.count) upload(s), expected the retry")
        continue
      }
      XCTAssertEqual(ids(h.network.sent[0]), ids(h.network.sent[1]), "\(status)")
      XCTAssertEqual(h.engine.queuedCount, 0)
      XCTAssertTrue(h.sink.errors.isEmpty)
    }
  }

  /// The edge only ever answers 202, 4xx or 5xx. Anything else — a redirect
  /// from a custom endpoint, a 304, a 1xx, a captive portal's 200 — is not
  /// delivery: the batch stays
  /// in the queue and the file, is retried under the same eventIds, and is
  /// said once.
  func testARedirectOrAnyNonEdgeStatusIsKeptAndRetried() {
    for status in [301, 302, 307, 308, 304, 100, 200, 201, 204] {
      let h = Harness()
      h.network.answers = [TransportResponse(status: status), TransportResponse(status: status)]
      h.engine.track("checkout_started")
      h.flush()
      XCTAssertEqual(h.engine.queuedCount, 2, "\(status): kept in the queue")
      XCTAssertEqual(storedNames(h), ["$session_started", "checkout_started"], "\(status): kept in the file")
      XCTAssertGreaterThan(h.executor.timers.last ?? 0, 0, "\(status): a retry is scheduled")
      h.flush()
      h.flush()
      XCTAssertEqual(h.network.sent.count, 3, "\(status)")
      XCTAssertEqual(ids(h.network.sent[0]), ids(h.network.sent[2]), "\(status): the same eventIds")
      XCTAssertEqual(h.engine.queuedCount, 0, "\(status): delivered once the endpoint answers")
      XCTAssertEqual(h.sink.logs.filter { $0.contains("answered \(status)") }.count, 1, "\(status): said once")
      XCTAssertTrue(h.sink.errors.isEmpty, "\(status): nothing is lost, so no onError")
    }
  }

  /// Offline is normal operation: re-queued, and stamped afresh at the
  /// upload that finally reaches the edge.
  func testAnOfflineBatchIsDeliveredLaterWithClientSentTsOfThatUpload() {
    let h = Harness()
    h.network.answers = [TransportResponse(status: nil)]
    h.engine.track("a")
    h.flush()
    h.clock.advance(3_600_000)
    h.flush()
    XCTAssertEqual(h.network.sent[1]["clientSentTs"], .string(ISOTime.format(h.clock.wall)))
    XCTAssertEqual(ids(h.network.sent[0]), ids(h.network.sent[1]))
  }

  func testRetryAfterIsHonouredOnA429() {
    let h = Harness()
    h.network.answers = [TransportResponse(status: 429, retryAfterSeconds: 42)]
    h.engine.track("a")
    h.flush()
    XCTAssertEqual(h.executor.timers.last, 42)
    XCTAssertEqual(h.engine.queuedCount, 2)
  }

  /// A 4xx is never retried: it would fail identically forever.
  func testA400IsDroppedAndReportedNotRetried() {
    let h = Harness()
    h.network.answers = [TransportResponse(status: 400)]
    let id = h.engine.track("a")
    h.flush()
    XCTAssertEqual(h.engine.queuedCount, 0)
    XCTAssertEqual(h.sink.errors.map(\.code), [.batchRejected])
    XCTAssertTrue(h.sink.errors[0].eventIds.contains(id!))
  }

  /// A batch refused for good — a 413 or another 4xx — is dropped, and the
  /// rest of the backlog behind it is sent next, not left on the device until
  /// the app's next call.
  func testTheBacklogBehindARefusedBatchIsSentNext() {
    for status in [413, 400, 422] {
      let h = Harness()
      h.network.holds = true
      // With $session_started, 120 events: a batch of 50 went out at the 50th.
      for index in 0..<119 { h.engine.track("e\(index)") }
      XCTAssertEqual(h.network.held.count, 1, "\(status)")
      h.flush()  // The flush timer fires while the upload is out, and finds it in flight.
      h.executor.timers.removeAll()
      h.network.answer(TransportResponse(status: status))
      XCTAssertEqual(h.executor.timers, [0], "\(status): the rest is scheduled at once")
      h.network.holds = false
      h.flush()  // That timer firing.
      h.flush()
      XCTAssertEqual(h.network.sent.count, 3, "\(status)")
      XCTAssertEqual(
        h.network.sent.dropFirst().map { ids($0).count }.reduce(0, +), 70,
        "\(status): everything after the refused batch")
      XCTAssertEqual(h.engine.queuedCount, 0, "\(status)")
    }
  }

  /// A timer that fired while an upload was out is not lost: the answer
  /// schedules the next batch.
  func testATimerThatFiredDuringAnUploadIsNotLost() {
    let h = Harness()
    h.network.holds = true
    for index in 0..<49 { h.engine.track("e\(index)") }  // The batch of 50 is out.
    h.engine.track("late")  // Its timer fires while the upload is in flight.
    h.flush()
    XCTAssertEqual(h.network.sent.count, 1)
    h.executor.timers.removeAll()
    h.network.answer()
    XCTAssertEqual(h.executor.timers, [0])
  }

  /// A 401 disables the client and KEEPS the queue for the next launch.
  func testA401DisablesTheClientAndKeepsTheQueue() {
    let h = Harness()
    h.network.answers = [TransportResponse(status: 401)]
    h.engine.track("a")
    h.flush()
    XCTAssertTrue(h.engine.disabled)
    XCTAssertEqual(h.sink.errors.map(\.code), [.writeKeyRejected])
    XCTAssertNil(h.engine.track("b"))
    XCTAssertEqual(h.engine.queuedCount, 2)
  }

  /// A refusal no retry can change (App Transport Security, a URL the app
  /// cannot open) is said once with endpoint_invalid, stops the client for the
  /// process and keeps the queue — never retried in silence as offline.
  func testAPermanentTransportFailureDisablesAndKeepsTheQueue() {
    let h = Harness()
    h.network.answers = [TransportResponse(status: nil, failure: "App Transport Security blocked it")]
    let id = h.engine.track("a")
    h.flush()
    XCTAssertTrue(h.engine.disabled)
    XCTAssertEqual(h.sink.errors.map(\.code), [.endpointInvalid])
    XCTAssertTrue(h.sink.errors[0].message.contains("App Transport Security"))
    XCTAssertEqual(h.engine.queuedCount, 2, "kept for a build that can reach the endpoint")
    XCTAssertEqual(storedNames(h), ["$session_started", "a"])
    h.executor.timers.removeAll()
    XCTAssertNil(h.engine.track("b"))
    h.flush()
    XCTAssertEqual(h.network.sent.count, 1, "no retry")
    XCTAssertTrue(h.executor.timers.isEmpty, "nothing scheduled")
    XCTAssertNotNil(id)

    // The next launch tries again, with the same events.
    h.start()
    h.flush()
    XCTAssertEqual(ids(h.network.sent[0]), ids(h.network.sent[1]))
  }

  /// The edge rejects events older than seven days, so the queue drops them
  /// locally and says how many.
  func testEventsOlderThanSevenDaysAreDroppedLocallyWithTheirCount() {
    let h = Harness()
    h.network.answers = [TransportResponse(status: nil)]
    h.engine.track("old")
    h.flush()
    h.clock.advance(Wire.maxEventAgeMs + 1)
    h.flush()
    XCTAssertEqual(h.network.sent.count, 1, "nothing left to upload")
    XCTAssertEqual(h.sink.errors.map(\.code), [.timestampTooOld])
    XCTAssertEqual(h.sink.errors[0].eventIds.count, 2)
    XCTAssertTrue(h.sink.logs.contains("2 event(s) dropped: older than 7 days"))
  }

  /// Per-event refusals in a 202 are the only notice anyone gets.
  func testRejectionsInAnAcceptedBatchAreReported() {
    let h = Harness()
    let id = h.engine.track("page_viewed")!
    h.network.answers = [
      TransportResponse(
        status: 202,
        body: Data(#"{"rejected":[{"eventId":"\#(id)","reason":"timestamp_too_far_future"}]}"#.utf8))
    ]
    h.flush()
    XCTAssertEqual(h.sink.errors.map(\.code.rawValue), ["timestamp_too_far_future"])
    XCTAssertEqual(h.sink.errors[0].eventName, "page_viewed")
  }

  /// Fifty events is a batch: the fiftieth uploads without waiting.
  func testFiftyEventsFlushWithoutWaitingForTheTimer() {
    let h = Harness()
    for index in 0..<49 { h.engine.track("e\(index)") }  // + $session_started = 50
    XCTAssertEqual(h.network.sent.count, 1)
    XCTAssertEqual(h.network.events.count, 50)
  }

  /// A backlog during an outage waits for the backoff: tracking more events
  /// does not turn each one into a request.
  func testABacklogWaitsForTheBackoffInsteadOfFlushingOnEveryTrack() {
    let h = Harness()
    h.network.answers = [TransportResponse(status: 503)]
    for index in 0..<49 { h.engine.track("e\(index)") }  // + $session_started = 50
    XCTAssertEqual(h.network.sent.count, 1, "the full batch went, and was refused")
    for index in 0..<20 { h.engine.track("more\(index)") }
    XCTAssertEqual(h.network.sent.count, 1, "no request per track() while backing off")
    h.flush()  // the backoff timer firing
    XCTAssertEqual(h.network.sent.count, 2)
  }

  /// One upload at a time: a flush while one is in flight sends nothing new.
  func testOnlyOneUploadIsInFlight() {
    final class Slow: TogoTransport, @unchecked Sendable {
      var pending: [@Sendable (TransportResponse) -> Void] = []
      func post(url: URL, writeKey: String, body: Data, completion: @escaping @Sendable (TransportResponse) -> Void) {
        pending.append(completion)
      }
    }
    let slow = Slow()
    let h = Harness()
    let engine = TogoEngine(
      options: h.options, transport: slow, executor: h.executor, callbacks: h.executor, clock: h.clock,
      log: { _ in })
    for index in 0..<60 { engine.track("e\(index)") }
    engine.flush()
    XCTAssertEqual(slow.pending.count, 1)
    slow.pending[0](TransportResponse(status: 202, body: Data("{}".utf8)))
    engine.flush()
    XCTAssertEqual(slow.pending.count, 2, "the next upload once the first was answered")
  }

  /// The queue file: JSON Lines, re-read by a new process.
  func testTheQueueSurvivesAsAFileOnDisk() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.jsonl")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = FileQueueStore(url: url)
    let queue = EventQueue(store: store) { _, _ in }
    let event = RawEvent(
      eventName: "a", clientEventMs: 1, eventId: "e1", anonymousId: "an", deviceId: "d", userId: nil,
      sessionId: nil, properties: ["n": 1], personProperties: nil, timezone: nil)
    queue.add(.init(event: event, app: AppInfo(version: "1"), device: nil))
    let reread = EventQueue(store: FileQueueStore(url: url)) { _, _ in }
    reread.hydrate()
    XCTAssertEqual(reread.entries, [.init(event: event, app: AppInfo(version: "1"), device: nil)])

    try Data("not json".utf8).write(to: url)
    let garbled = EventQueue(store: FileQueueStore(url: url)) { _, _ in }
    garbled.hydrate()
    XCTAssertEqual(garbled.count, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "an unreadable queue is removed")
  }

  /// The byte bound evicts the OLDEST event, like the count: an eviction by size
  /// would drop the same kinds of event every time.
  func testTheByteBoundEvictsTheOldestEvent() {
    var dropped: [String] = []
    let queue = EventQueue(store: MemoryQueueStore()) { events, _ in dropped += events.map(\.eventName) }
    func event(_ name: String, _ size: Int) -> EventQueue.Entry {
      .init(
        event: RawEvent(
          eventName: name, clientEventMs: 1, eventId: name, anonymousId: nil, deviceId: nil,
          userId: nil, sessionId: nil, properties: ["v": .string(String(repeating: "x", count: size))],
          personProperties: nil, timezone: nil), app: nil, device: nil)
    }
    queue.add(event("old", EventQueue.maxBytes / 2))
    queue.add(event("middle", EventQueue.maxBytes / 2))
    queue.add(event("new", 10))
    XCTAssertEqual(dropped, ["old"])
    XCTAssertEqual(queue.entries.map(\.event.eventName), ["middle", "new"])
  }

  /// An event over 256 KiB is dropped at `track()`, never sent, and reported
  /// — an event that large is a payload — and the event beside it is sent.
  func testAnEventOver256KiBIsDroppedAtTrackAndReported() {
    let h = Harness()
    var properties: TogoProperties = [:]
    for i in 0..<256 { properties["p\(i)"] = .string(String(repeating: "x", count: 1_024)) }
    XCTAssertNil(h.engine.track("report_exported", properties: properties))
    XCTAssertNotNil(h.engine.track("order_paid"))
    XCTAssertEqual(h.sink.errors.map(\.code), [.eventTooLarge])
    XCTAssertEqual(h.sink.errors.first?.eventName, "report_exported")
  }

  // MARK: - A kill mid-upload

  /// iOS kills a suspended app with no callback, and the flush on the move to
  /// the background is an upload that can be cut off that way. Taken events
  /// stay in the file until the upload is answered, so the next launch sends
  /// them again under the same eventIds (the edge dedupes one that did land).
  func testEventsInAnUploadCutOffByAKillAreSentAgainAtTheNextLaunch() {
    let h = Harness()
    h.network.holds = true
    h.engine.track("checkout_started")
    h.engine.track("checkout_completed")
    h.flush()
    XCTAssertEqual(h.network.sent.count, 1, "out, and never answered")
    let firstIds = h.network.events.map { $0["eventId"] }

    // Killed. A new process over the same files; the network answers now.
    h.network.holds = false
    h.start()
    h.flush()
    XCTAssertEqual(h.network.sent.count, 2)
    let resent = h.network.sent[1]["events"]!.arrayValue!
    XCTAssertEqual(
      resent.map { $0["eventName"] }, [.string("$session_started"), .string("checkout_started"), .string("checkout_completed")])
    XCTAssertEqual(resent.map { $0["eventId"] }, firstIds, "the same eventIds, for the edge to dedupe")
  }

  /// The positive half: an answered upload is out of the file, and events
  /// tracked while it was out are kept after it, in order.
  func testAnAnsweredUploadLeavesTheFileAndWhatCameAfterItStays() {
    let h = Harness()
    h.network.holds = true
    h.engine.track("first")
    h.flush()
    h.engine.track("second")
    XCTAssertEqual(storedNames(h), ["$session_started", "first", "second"], "in flight, still on disk")
    h.network.answer()
    XCTAssertEqual(storedNames(h), ["second"])

    h.network.holds = false
    h.start()
    h.flush()
    XCTAssertEqual(h.network.names, ["$session_started", "first", "second"], "nothing sent twice")
  }

  /// A refusal for good is an answer too: a 400 is out of the file.
  func testARefusedUploadLeavesTheFile() {
    let h = Harness()
    h.network.answers = [TransportResponse(status: 400)]
    h.engine.track("first")
    h.flush()
    XCTAssertNil(h.queueStore.read())
  }

  /// Consent moving to `pending` while an upload is out, then the upload
  /// failing: the events go back in the queue — sent once consent permits
  /// again — rather than vanish from memory, as they did before.
  func testAFailedUploadUnderPendingConsentKeepsItsEvents() {
    let h = Harness()
    h.network.holds = true
    h.engine.track("first")
    h.flush()
    h.engine.setConsent(.pending)
    h.network.answer(TransportResponse(status: 503))
    XCTAssertEqual(h.engine.queuedCount, 2)

    h.network.holds = false
    h.engine.setConsent(.granted)
    h.flush()
    XCTAssertEqual(h.network.names, ["$session_started", "first", "$session_started", "first"])
  }

  /// …and a withdrawal while it is out deletes them, answered or not.
  func testAWithdrawalWhileAnUploadIsOutDeletesItsEvents() {
    let h = Harness()
    h.network.holds = true
    h.engine.track("first")
    h.flush()
    h.engine.setConsent(.denied)
    h.network.answer(TransportResponse(status: 503))
    XCTAssertNil(h.queueStore.read())
    XCTAssertEqual(h.engine.queuedCount, 0)
  }

  func storedNames(_ h: Harness) -> [String] {
    guard let data = h.queueStore.read() else { return [] }
    return data.split(separator: UInt8(ascii: "\n")).compactMap {
      try? JSONValue.parse(Data($0))["event"]?["eventName"]?.stringValue
    }
  }
}
