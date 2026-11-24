import Foundation
import XCTest

@testable import TogoCore

/// What one more event costs on a long offline backlog. Counted in bytes
/// written rather than timed alone: on a fast SSD a whole-file rewrite per
/// event passed a timing bound, and on a phone's flash it is megabytes per
/// `track()` on the queue the getters wait on.
final class QueueCostTests: XCTestCase {
  /// A store that counts what it is asked to write, by kind.
  final class CountingStore: QueueStore, @unchecked Sendable {
    let inner: MemoryQueueStore
    var rewrittenBytes = 0
    var appendedBytes = 0
    init(_ data: Data? = nil) { inner = MemoryQueueStore(data) }
    func read() -> Data? { inner.read() }
    func write(_ data: Data) {
      rewrittenBytes += data.count
      inner.write(data)
    }
    func append(_ data: Data) {
      appendedBytes += data.count
      inner.append(data)
    }
    func remove() { inner.remove() }
  }

  func event(_ index: Int, padding: Int = 0) -> EventQueue.Entry {
    var properties: TogoProperties = ["screen": "home", "index": .int(index)]
    if padding > 0 { properties["note"] = .string(String(repeating: "x", count: padding)) }
    return .init(
      event: RawEvent(
        eventName: "screen_viewed", clientEventMs: 1_792_584_000_000, eventId: "e\(index)",
        anonymousId: "anon", deviceId: "dev", userId: "user_1", sessionId: "s1",
        properties: properties, personProperties: nil, timezone: "Europe/Berlin"),
      app: AppInfo(version: "1.2.0"), device: nil)
  }

  func file(_ entries: [EventQueue.Entry]) -> Data {
    Data(entries.map { $0.line + "\n" }.joined().utf8)
  }

  /// A 3.6 MB backlog, read back as at a relaunch: 55 more events append 55
  /// lines and rewrite nothing, and the file reads back as the same queue.
  func testOneMoreEventAppendsItsLineAndRewritesNothing() {
    let backlog = (0..<4_000).map { event($0, padding: 700) }
    let store = CountingStore(file(backlog))
    XCTAssertGreaterThan(store.inner.read()!.count, 3_500_000)
    let queue = EventQueue(store: store) { _, _ in }
    queue.hydrate()
    XCTAssertEqual(queue.count, 4_000)

    let start = Date()
    let added = (0..<55).map { event(4_000 + $0) }
    for entry in added { queue.add(entry) }
    let perAdd = Date().timeIntervalSince(start) / 55

    XCTAssertEqual(store.rewrittenBytes, 0, "no add rewrites the backlog")
    XCTAssertEqual(store.appendedBytes, added.map { $0.line.utf8.count + 1 }.reduce(0, +))
    // Far from both an append (well under 1 ms) and a rewrite of the backlog,
    // so a slow CI runner does not make it flaky.
    XCTAssertLessThan(perAdd, 0.040, "per add: \(perAdd * 1000) ms")
    let reread = EventQueue(store: store) { _, _ in }
    reread.hydrate()
    XCTAssertEqual(reread.entries, queue.entries)
  }

  /// An answer rewrites the file once, for the whole batch: the delivered
  /// events leave it, and a retry writes nothing, since the file already
  /// holds them in place.
  func testAnAnswerRewritesOnceAndARetryWritesNothing() {
    let store = CountingStore()
    let queue = EventQueue(store: store) { _, _ in }
    queue.hydrate()
    for index in 0..<60 { queue.add(event(index)) }
    _ = queue.take(limit: 50, nowMs: 1_792_584_000_000)
    queue.retryInFlight()
    XCTAssertEqual(store.rewrittenBytes, 0, "a retry writes nothing")
    _ = queue.take(limit: 50, nowMs: 1_792_584_000_000)
    queue.acknowledge()
    XCTAssertEqual(store.rewrittenBytes, file(Array(queue.entries)).count, "one rewrite: the ten left")
    let reread = EventQueue(store: store) { _, _ in }
    reread.hydrate()
    XCTAssertEqual(reread.entries.map(\.event.eventId), (50..<60).map { "e\($0)" })
  }

  /// A kill mid-append leaves a cut-off last line: it is skipped, every whole
  /// line before it is kept, and the file is rewritten once so the next
  /// append does not land on the torn line.
  func testATornLastLineIsSkippedAndTheRestKept() {
    let whole = (0..<3).map { event($0) }
    let torn = Data(String(event(3).line.prefix(40)).utf8)
    let store = CountingStore(file(whole) + torn)
    let queue = EventQueue(store: store) { _, _ in }
    queue.hydrate()
    XCTAssertEqual(queue.entries, whole)
    XCTAssertEqual(store.inner.read(), file(whole), "the torn line is gone from the file")

    queue.add(event(4))
    let reread = EventQueue(store: store) { _, _ in }
    reread.hydrate()
    XCTAssertEqual(reread.entries, whole + [event(4)])
  }

  /// The bounds still hold with appends: past the count bound the oldest is
  /// evicted and reported, in memory and in the file.
  func testTheCountBoundStillEvicts() {
    var dropped: [String] = []
    let backlog = (0..<EventQueue.maxEvents).map { event($0) }
    let store = CountingStore(file(backlog))
    let queue = EventQueue(store: store) { events, _ in dropped += events.map(\.eventId) }
    queue.hydrate()
    queue.add(event(EventQueue.maxEvents))
    XCTAssertEqual(dropped, ["e0"])
    XCTAssertEqual(queue.count, EventQueue.maxEvents)
    let reread = EventQueue(store: store) { _, _ in }
    reread.hydrate()
    XCTAssertEqual(reread.entries, queue.entries)
  }

  /// A whole last line that lost its newline (a write cut just before it) is
  /// kept, and the file is rewritten so the next append starts a line of its
  /// own rather than joining the two into one that reads as neither.
  func testALastLineWithNoNewlineIsKeptAndNotJoinedToTheNext() {
    let whole = (0..<2).map { event($0) }
    let store = CountingStore(file(whole).dropLast())
    let queue = EventQueue(store: store) { _, _ in }
    queue.hydrate()
    XCTAssertEqual(queue.entries, whole)
    queue.add(event(2))
    let reread = EventQueue(store: store) { _, _ in }
    reread.hydrate()
    XCTAssertEqual(reread.entries, whole + [event(2)])
  }

  /// An append to a queue file that is there but will not open leaves it as
  /// it is: never replaced by a file holding only the new line.
  func testAnAppendThatCannotOpenTheFileNeverReplacesTheQueue() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("queue.jsonl")
    let store = FileQueueStore(url: url)
    let backlog = file((0..<3).map { event($0) })
    store.write(backlog)
    // Read-only: opening it for writing fails, as it would for a process out
    // of file descriptors.
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
    guard (try? FileHandle(forWritingTo: url)) == nil else {
      throw XCTSkip("this user can open a read-only file for writing (root?), so the case cannot be made")
    }
    store.append(Data((event(3).line + "\n").utf8))
    XCTAssertEqual(try Data(contentsOf: url), backlog, "the queue is untouched")
  }

  /// The positive half: with no file, an append creates it.
  func testAnAppendWithNoFileCreatesIt() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("queue.jsonl")
    let line = Data((event(0).line + "\n").utf8)
    FileQueueStore(url: url).append(line)
    FileQueueStore(url: url).append(line)
    XCTAssertEqual(try Data(contentsOf: url), line + line)
  }

  /// The events an upload took no longer count against the byte bound in
  /// memory: near the 8 MiB bound, adds during the upload append, and no add
  /// rewrites the file for a total the queue does not hold. Events of ~2 KB, so
  /// the byte bound is reached before the 5,000-event count.
  func testAddsDuringAnUploadNearTheByteBoundStillAppend() {
    var backlog: [EventQueue.Entry] = []
    var total = 0
    while true {
      let next = event(backlog.count, padding: 2_000)
      if total + next.line.utf8.count + 1 > EventQueue.maxBytes - 20_000 { break }
      total += next.line.utf8.count + 1
      backlog.append(next)
    }
    let store = CountingStore(file(backlog))
    let queue = EventQueue(store: store) { _, _ in }
    queue.hydrate()
    let taken = queue.take(limit: 50, nowMs: 1_792_584_000_000)
    let takenBytes = taken.map { $0.line.utf8.count + 1 }.reduce(0, +)
    let added = (0..<100).map { event(100_000 + $0) }
    let addedBytes = added.map { $0.line.utf8.count + 1 }.reduce(0, +)
    // Past the bound only if the taken events were still counted.
    XCTAssertGreaterThan(total + addedBytes, EventQueue.maxBytes)
    XCTAssertLessThan(total - takenBytes + addedBytes, EventQueue.maxBytes)
    for entry in added { queue.add(entry) }
    XCTAssertEqual(store.rewrittenBytes, 0, "every add appended")
  }
}
