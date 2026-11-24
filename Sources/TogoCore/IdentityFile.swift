import Foundation

/// How the SDK writes a file of its own on the device:
/// atomically, so a kill mid-write leaves the previous file rather than half
/// of one; under `completeUntilFirstUserAuthentication`, the default data
/// protection class, so a background launch after the first unlock can still
/// read it; and **excluded from backup**, so a restore onto new hardware starts
/// a fresh install rather than cloning this one's ids.
///
/// The exclusion is set after every write, because an atomic write replaces the
/// file and a resource value belongs to the file it was set on. Off Darwin
/// (Linux, where the core is tested) there is no protection class and no
/// backup, and the write is only atomic.
enum ProtectedFile {
  #if canImport(Darwin)
    /// What every write asks for. A simulator stores no protection class, so a
    /// test can only check the request; the class itself is a device's.
    static let options: Data.WritingOptions = [
      .atomic, .completeFileProtectionUntilFirstUserAuthentication,
    ]
  #endif

  static func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    #if canImport(Darwin)
      try data.write(to: url, options: options)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var target = url
      try target.setResourceValues(values)
    #else
      try data.write(to: url, options: .atomic)
    #endif
  }
}

/// The identity file: `device_id` and its mode,
/// `anonymous_id`, `user_id`, the session record and the last-seen app version
/// and build, as one small JSON file in Application Support. Never
/// `UserDefaults`, which cannot be excluded from backup and is a required-reason
/// API, and never the Keychain, which outlives the app.
///
/// **`unavailable` is not `absent`.** Before the first unlock after a reboot the
/// file exists but cannot be read, and a background launch (a push, a
/// `BGAppRefreshTask`) that took that for "no identity" would mint a second
/// identity for the same install. So:
///
/// - the file is there and reads → `found`;
/// - the file is there and does not read → `unavailable`, whatever the reason;
/// - the file is not there → `absent` only when protected data is available.
///   With it unavailable, "not there" cannot be told from "not readable yet",
///   and only the first launch of an install can be in that state, so it waits.
///
/// **Writes are coalesced**. The record is kept in memory and written
/// `debounceSeconds` after the first change, and `persistNow()` — the move to
/// the background — writes at once. `lastActivityAt` changes on every event, so
/// a write per `save()` would be a disk write per event.
public final class FileIdentityStore: IdentityStore, @unchecked Sendable {
  public let url: URL
  public static let debounceSeconds: Double = 1
  private let protectedDataAvailable: @Sendable () -> Bool
  private let scheduler: TogoExecutor
  private let log: TogoLogger
  private let lock = NSLock()
  /// What was last read or saved. Once set, the file is never read again in
  /// this process: the memory copy is newer.
  private var current: IdentityRecord?
  private var dirty = false
  private var scheduled = false
  private var cancelWrite: (@Sendable () -> Void)?

  /// - Parameters:
  ///   - protectedDataAvailable: the platform's answer; consulted only when the
  ///     file is not there. `true` off a device.
  ///   - scheduler: where the debounced write runs.
  public init(
    url: URL, protectedDataAvailable: @escaping @Sendable () -> Bool = { true },
    scheduler: TogoExecutor, log: @escaping TogoLogger = standardErrorLogger
  ) {
    self.url = url
    self.protectedDataAvailable = protectedDataAvailable
    self.scheduler = scheduler
    self.log = log
  }

  public func load() -> IdentityLoad {
    lock.lock()
    defer { lock.unlock() }
    if let current { return .found(current) }
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      if FileManager.default.fileExists(atPath: url.path) { return .unavailable }
      return protectedDataAvailable() ? .absent : .unavailable
    }
    guard let json = try? JSONValue.parse(data), let record = IdentityRecord(json: json) else {
      // Written atomically, so this is not a torn write: something else wrote
      // the file. Starting again is the only way forward, and the next save
      // replaces it.
      log("the identity file could not be read and was replaced: this install starts as new.")
      return .absent
    }
    current = record
    return .found(record)
  }

  public func save(_ record: IdentityRecord) {
    lock.lock()
    current = record
    dirty = true
    let schedule = !scheduled
    scheduled = true
    lock.unlock()
    guard schedule else { return }
    // Outside the lock: a scheduler may run the write inline.
    let cancel = scheduler.after(FileIdentityStore.debounceSeconds) { [self] in persistNow() }
    lock.lock()
    if scheduled { cancelWrite = cancel }
    lock.unlock()
  }

  /// Write what is pending, now. The move to the background calls it: a
  /// suspended app can be killed with no callback.
  public func persistNow() {
    lock.lock()
    defer { lock.unlock() }
    cancelWrite?()
    cancelWrite = nil
    scheduled = false
    guard dirty, let current else { return }
    do {
      try ProtectedFile.write(Data(current.json.serialized().utf8), to: url)
      dirty = false
    } catch {
      // A full disk is expected operation, so not an error: the record is
      // still in memory, and the next save or background move tries again.
      log("the identity file could not be written (\(error)); retrying at the next change.")
    }
  }

  public func erase() {
    lock.lock()
    defer { lock.unlock() }
    cancelWrite?()
    cancelWrite = nil
    scheduled = false
    current = nil
    dirty = false
    try? FileManager.default.removeItem(at: url)
  }
}

extension IdentityRecord {
  /// The file's shape. `v` lets a later SDK read an older file.
  var json: JSONValue {
    var object: [String: JSONValue] = ["v": .int(1)]
    if let deviceId { object["deviceId"] = .string(deviceId) }
    if let deviceIdMode { object["deviceIdMode"] = .string(deviceIdMode) }
    if let anonymousId { object["anonymousId"] = .string(anonymousId) }
    if let userId { object["userId"] = .string(userId) }
    if let appVersion { object["appVersion"] = .string(appVersion) }
    if let appBuild { object["appBuild"] = .string(appBuild) }
    if let session {
      object["session"] = .object([
        "id": .string(session.id), "startedAtMs": .int(session.startedAtMs),
        "lastActivityAtMs": .int(session.lastActivityAtMs),
      ])
    }
    return .object(object)
  }

  init?(json: JSONValue) {
    guard json.objectValue != nil, json["v"]?.int64Value == 1 else { return nil }
    self.init(
      deviceId: json["deviceId"]?.stringValue, deviceIdMode: json["deviceIdMode"]?.stringValue,
      anonymousId: json["anonymousId"]?.stringValue, userId: json["userId"]?.stringValue,
      appVersion: json["appVersion"]?.stringValue, appBuild: json["appBuild"]?.stringValue)
    if let session = json["session"], let id = session["id"]?.stringValue,
      let started = session["startedAtMs"]?.int64Value,
      let last = session["lastActivityAtMs"]?.int64Value
    {
      self.session = SessionRecord(id: id, startedAtMs: started, lastActivityAtMs: last)
    }
  }
}
