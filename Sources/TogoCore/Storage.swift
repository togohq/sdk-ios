import Foundation

/// Where the SDK keeps what it remembers on the device.
///
/// **Three protocols, so the core never names a platform.** On iOS the
/// identity is `FileIdentityStore` and the queue `FileQueueStore` — two files in
/// Application Support, excluded from backup, under
/// `completeUntilFirstUserAuthentication` — and the device id
/// comes from the IDFV through the UIKit adapter (D1). The memory stores are
/// what the tests and the scenario runner use.

// MARK: - Identity

/// The session record, written as a unit.
/// Wall-clock milliseconds, because it outlives the process.
public struct SessionRecord: Sendable, Equatable {
  public var id: String
  public var startedAtMs: Int64
  public var lastActivityAtMs: Int64

  public init(id: String, startedAtMs: Int64, lastActivityAtMs: Int64) {
    self.id = id
    self.startedAtMs = startedAtMs
    self.lastActivityAtMs = lastActivityAtMs
  }
}

/// Everything the SDK remembers about this install, as one record so it is
/// written as one file (D3). `nil` fields are not yet minted: identifiers are
/// minted lazily, at the first write consent permits, never at `setup()`.
public struct IdentityRecord: Sendable, Equatable {
  public var deviceId: String?
  public var deviceIdMode: String?
  public var anonymousId: String?
  public var userId: String?
  public var session: SessionRecord?
  /// The app version and build the last launch ran: what `$app_updated`
  /// compares against. Not identity, but stored with it so
  /// "no file" and "first launch" are one fact.
  public var appVersion: String?
  public var appBuild: String?

  public init(
    deviceId: String? = nil, deviceIdMode: String? = nil, anonymousId: String? = nil,
    userId: String? = nil, session: SessionRecord? = nil, appVersion: String? = nil,
    appBuild: String? = nil
  ) {
    self.deviceId = deviceId
    self.deviceIdMode = deviceIdMode
    self.anonymousId = anonymousId
    self.userId = userId
    self.session = session
    self.appVersion = appVersion
    self.appBuild = appBuild
  }
}

/// What a load found. **`unavailable` is not `absent`** (D3): before the first
/// unlock after a reboot the identity file cannot be read, and treating that
/// as "no identity" would mint a second one for the same install. The core
/// holds events in memory while it is `unavailable` and never mints.
public enum IdentityLoad: Sendable, Equatable {
  case absent
  case unavailable
  case found(IdentityRecord)
}

/// The store owns write coalescing (keep the record in memory, write on a
/// short debounce and on the transition to background), so `save` may be
/// called on every event.
public protocol IdentityStore: AnyObject, Sendable {
  func load() -> IdentityLoad
  func save(_ record: IdentityRecord)
  /// Write anything pending now: the app is moving to the background, after
  /// which it can be killed with no callback.
  func persistNow()
  /// Consent withdrawal: delete what is stored, not merely stop.
  func erase()
}

extension IdentityStore {
  /// A store that writes on every `save` has nothing pending.
  public func persistNow() {}
}

/// Identity in memory. Phase 3's default, and what a test uses to stand for a
/// file that survives a relaunch: hand the same instance to a second client.
public final class MemoryIdentityStore: IdentityStore, @unchecked Sendable {
  private let lock = NSLock()
  private var record: IdentityRecord?
  private var isLocked = false

  /// When true, `load()` answers `unavailable`, as a locked device would.
  public var locked: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return isLocked
    }
    set {
      lock.lock()
      isLocked = newValue
      lock.unlock()
    }
  }

  public init(_ record: IdentityRecord? = nil) { self.record = record }

  public func load() -> IdentityLoad {
    lock.lock()
    defer { lock.unlock() }
    if isLocked { return .unavailable }
    return record.map(IdentityLoad.found) ?? .absent
  }

  public func save(_ record: IdentityRecord) {
    lock.lock()
    self.record = record
    lock.unlock()
  }

  public func erase() {
    lock.lock()
    record = nil
    lock.unlock()
  }

  public var stored: IdentityRecord? {
    lock.lock()
    defer { lock.unlock() }
    return record
  }
}

/// Where `device_id` comes from, and so how long it lasts (`device_id_mode`).
/// Asked once per install, at the first permitted write; the answer is stored
/// in the identity record and never asked again (D1 step 2). `nil` means "not
/// now" — an IDFV that is nil before the first unlock — and the core then
/// holds events rather than falling back to another id (D1 step 4).
public protocol DeviceIdProvider: Sendable {
  func deviceId() -> (id: String, mode: String)?
}

/// A random id per install, mode `install` — D1 step 3's rule for a platform
/// with no IDFV. An install keeps the mode it started with (D1 step 5): the
/// mode is stored with the id and the provider is never asked again.
public struct GeneratedDeviceIdProvider: DeviceIdProvider {
  public init() {}
  public func deviceId() -> (id: String, mode: String)? { (randomId(), "install") }
}

// MARK: - The queue's bytes

/// The durable queue's persistence: one entry per line, read once, appended
/// to per event and rewritten whole when the queue changes otherwise.
public protocol QueueStore: Sendable {
  func read() -> Data?
  func write(_ data: Data)
  func append(_ data: Data)
  func remove()
}

public final class MemoryQueueStore: QueueStore, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?

  public init(_ data: Data? = nil) { self.data = data }

  public func read() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return data
  }

  public func write(_ data: Data) {
    lock.lock()
    self.data = data
    lock.unlock()
  }

  public func append(_ data: Data) {
    lock.lock()
    self.data = (self.data ?? Data()) + data
    lock.unlock()
  }

  public func remove() {
    lock.lock()
    data = nil
    lock.unlock()
  }
}

/// The queue as a file, `queue.jsonl`, written the way the identity file is
/// (`ProtectedFile`: atomic, excluded from backup,
/// `completeUntilFirstUserAuthentication`). An append opens the file that
/// write made, so it keeps that file's protection class and backup
/// exclusion; with no file yet, the append creates it through
/// `ProtectedFile` too. It
/// survives the app being killed, for days. It is read only once the
/// identity has been read: before the first unlock it cannot be, and reading
/// it as empty would let the next write replace the queue (`TogoEngine.flush`).
public final class FileQueueStore: QueueStore, @unchecked Sendable {
  public let url: URL

  public init(url: URL) { self.url = url }

  public func read() -> Data? { try? Data(contentsOf: url) }

  public func write(_ data: Data) {
    do {
      try ProtectedFile.write(data, to: url)
    } catch {
      // A full disk or a missing container is expected operation on a device
      // (expected operation, so not an error): the events stay in memory for this process.
    }
  }

  /// An append is not synced to the disk: a killed process loses nothing the
  /// kernel already holds, and syncing every event is the cost the append
  /// exists to avoid. A power cut can lose the last few; a rewrite, once per
  /// batch, is atomic.
  ///
  /// Only a file that is NOT there is created; one that is there and does not
  /// open is left alone. Creating it then would replace the whole queue with
  /// one line. A write that fails part-way is cut back, so the next append
  /// does not land on a broken line. Either way the events stay in memory for
  /// this process, and the next rewrite puts them in the file.
  public func append(_ data: Data) {
    if !FileManager.default.fileExists(atPath: url.path) {
      try? ProtectedFile.write(data, to: url)
      return
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    guard let end = try? handle.seekToEnd() else { return }
    do {
      try handle.write(contentsOf: data)
    } catch {
      try? handle.truncate(atOffset: end)
    }
  }

  public func remove() { try? FileManager.default.removeItem(at: url) }
}
