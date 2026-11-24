import Foundation
import XCTest

@testable import TogoCore

/// The identity file and the queue file: what they hold,
/// how they are written, and the one distinction that keeps a locked device
/// from splitting an install in two — unreadable is not absent.
final class IdentityFileTests: XCTestCase {
  /// Records the debounced write instead of waiting for it.
  final class Scheduler: TogoExecutor, @unchecked Sendable {
    var pending: [@Sendable () -> Void] = []
    func async(_ work: @escaping @Sendable () -> Void) { work() }
    func after(_ seconds: Double, _ work: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
      pending.append(work)
      return {}
    }
    func fire() {
      let due = pending
      pending = []
      due.forEach { $0() }
    }
  }

  final class Flag: @unchecked Sendable {
    var value: Bool
    init(_ value: Bool) { self.value = value }
  }

  var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("togo-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  var url: URL { directory.appendingPathComponent("ai.togohq.sdk/identity.json") }

  func store(_ scheduler: Scheduler = Scheduler(), available: Flag = Flag(true)) -> FileIdentityStore {
    FileIdentityStore(
      url: url, protectedDataAvailable: { available.value }, scheduler: scheduler, log: { _ in })
  }

  let full = IdentityRecord(
    deviceId: "IDFV-1", deviceIdMode: "idfv", anonymousId: "anon-1", userId: "user_1",
    session: SessionRecord(id: "session-1", startedAtMs: 1_000, lastActivityAtMs: 2_000),
    appVersion: "1.2.0", appBuild: "12")

  /// Every field survives the file: a relaunch is a new store reading it.
  func testTheIdentityFileRoundTrips() {
    let first = store()
    XCTAssertEqual(first.load(), .absent)
    first.save(full)
    first.persistNow()

    XCTAssertEqual(store().load(), .found(full))
    let empty = IdentityRecord(deviceId: "d", deviceIdMode: "install")
    let second = store()
    second.save(empty)
    second.persistNow()
    XCTAssertEqual(store().load(), .found(empty), "absent fields stay absent")
  }

  /// Writes are coalesced: a save writes nothing until the debounce
  /// fires, many saves are one write, and `persistNow()` — the move to the
  /// background — writes at once.
  func testWritesAreDebouncedAndPersistNowWritesAtOnce() {
    let scheduler = Scheduler()
    let file = store(scheduler)
    file.save(full)
    var later = full
    later.session?.lastActivityAtMs = 3_000
    file.save(later)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(scheduler.pending.count, 1, "one write for both saves")
    scheduler.fire()
    XCTAssertEqual(store().load(), .found(later))

    later.session?.lastActivityAtMs = 4_000
    file.save(later)
    file.persistNow()
    XCTAssertEqual(store().load(), .found(later))
  }

  /// D3: with protected data unavailable, a file that is not there might be
  /// one that cannot be seen yet — `unavailable`, never `absent`. The positive
  /// half: once it is available, not there means absent.
  func testNoFileWhileProtectedDataIsUnavailableIsUnavailableNotAbsent() {
    let available = Flag(false)
    XCTAssertEqual(store(available: available).load(), .unavailable)
    available.value = true
    XCTAssertEqual(store(available: available).load(), .absent)
  }

  /// A file that is there and does not read is `unavailable`, whatever the
  /// platform says: the file's own protection is the authority.
  func testAFileThatIsThereButDoesNotReadIsUnavailable() throws {
    // A directory where the file should be: it exists, and reading it fails.
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    XCTAssertEqual(store().load(), .unavailable)
  }

  /// A file someone else wrote garbage into starts the install again, with a log.
  func testACorruptFileIsAbsentAndIsReplacedByTheNextSave() throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: url)
    let file = store()
    XCTAssertEqual(file.load(), .absent)
    file.save(full)
    file.persistNow()
    XCTAssertEqual(store().load(), .found(full))
  }

  /// Withdrawal deletes the file, and a write that was pending does not bring
  /// it back.
  func testEraseDeletesTheFileAndCancelsAPendingWrite() {
    let scheduler = Scheduler()
    let file = store(scheduler)
    file.save(full)
    file.persistNow()
    file.save(full)
    file.erase()
    scheduler.fire()
    file.persistNow()
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(file.load(), .absent)
  }

  /// Both files are excluded from backup — set
  /// after every write, since an atomic write replaces the file. The queue's
  /// appends keep it: one onto the file a write made, and one that creates
  /// the file.
  func testBothFilesAreExcludedFromBackup() throws {
    #if canImport(Darwin)
      let file = store()
      file.save(full)
      file.persistNow()
      file.save(full)
      file.persistNow()
      let queueURL = directory.appendingPathComponent("ai.togohq.sdk/queue.jsonl")
      FileQueueStore(url: queueURL).write(Data("{}\n".utf8))
      FileQueueStore(url: queueURL).append(Data("{}\n".utf8))
      XCTAssertEqual(try Data(contentsOf: queueURL), Data("{}\n{}\n".utf8))
      let appendedURL = directory.appendingPathComponent("ai.togohq.sdk/appended.jsonl")
      FileQueueStore(url: appendedURL).append(Data("{}\n".utf8))
      for target in [url, queueURL, appendedURL] {
        let values = try target.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true, target.lastPathComponent)
      }
    #else
      throw XCTSkip("no backup attribute off Darwin; checked by swift test on macOS")
    #endif
  }

  /// D3: every write asks for `completeUntilFirstUserAuthentication`. Neither
  /// macOS nor the simulator stores the class — both report none on the file —
  /// so this checks the request; that a file is unreadable before the first
  /// unlock is only observable on a device after a reboot.
  func testEveryWriteAsksForCompleteUntilFirstUserAuthentication() throws {
    #if canImport(Darwin)
      XCTAssertTrue(ProtectedFile.options.contains(.completeFileProtectionUntilFirstUserAuthentication))
      XCTAssertTrue(ProtectedFile.options.contains(.atomic))
    #else
      throw XCTSkip("no data protection off Darwin; checked by swift test on macOS")
    #endif
  }

  /// The engine over the file: what one process wrote, the next one reads —
  /// the same device, the same anonymous visitor, the session inside its window.
  func testAnEngineOverTheFileKeepsItsIdentityAcrossARelaunch() {
    let scheduler = Scheduler()
    let h = Harness(identityStore: store(scheduler), lifecycle: true)
    h.foreground()
    h.background()  // persistNow, at once
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

    let relaunched = Harness(identityStore: store(scheduler), lifecycle: true)
    relaunched.clock.advance(60_000)
    relaunched.foreground()
    relaunched.flushAll()
    h.flushAll()
    let before = h.network.events.last!
    let after = relaunched.network.events.first { $0["eventName"]?.stringValue == "$app_opened" }!
    XCTAssertEqual(after["deviceId"], before["deviceId"])
    XCTAssertEqual(after["anonymousId"], before["anonymousId"])
    XCTAssertEqual(after["sessionId"], before["sessionId"])
    XCTAssertFalse(relaunched.network.names.contains("$app_installed"))
  }
}
