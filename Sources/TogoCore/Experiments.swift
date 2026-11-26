import Foundation

/// What `getExperiment()` answers. The same five statuses as the web and server
/// SDKs: a report cannot tell which SDK a participant came from.
public enum TogoExperimentStatus: String, Sendable {
  case draft
  case active
  case finished
  case notFound = "not_found"
  case unavailable
}

/// One experiment's answer for this device. `variant == nil` means: run what
/// you would run without Togo. `participating` is true only when an exposure
/// is recorded for this unit.
public struct TogoExperiment: Sendable, Equatable {
  public let experiment: String
  public let status: TogoExperimentStatus
  public let variant: String?
  public let participating: Bool

  public init(experiment: String, status: TogoExperimentStatus, variant: String?, participating: Bool)
  {
    self.experiment = experiment
    self.status = status
    self.variant = variant
    self.participating = participating
  }

  public static func unavailable(_ name: String) -> TogoExperiment {
    TogoExperiment(experiment: name, status: .unavailable, variant: nil, participating: false)
  }
}

/// Where the stored answers live: `experiments.json`, beside the identity file,
/// written the same way (`ProtectedFile`: atomic, excluded from backup,
/// `completeUntilFirstUserAuthentication`). Never `UserDefaults`: a restored
/// backup would carry one device's assignments onto another.
public protocol ExperimentStore: Sendable {
  func read() -> Data?
  func write(_ data: Data)
  func remove()
}

public final class MemoryExperimentStore: ExperimentStore, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?

  /// When true, `read()` finds nothing, as a locked device's protected file reads.
  public var unreadable = false

  public init(_ data: Data? = nil) { self.data = data }

  public func read() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return unreadable ? nil : data
  }

  public func write(_ data: Data) {
    lock.lock()
    self.data = data
    lock.unlock()
  }

  public func remove() {
    lock.lock()
    data = nil
    lock.unlock()
  }
}

public final class FileExperimentStore: ExperimentStore, @unchecked Sendable {
  public let url: URL

  public init(url: URL) { self.url = url }

  public func read() -> Data? { try? Data(contentsOf: url) }

  public func write(_ data: Data) {
    // A full disk is expected operation on a device: the answers stay in
    // memory for this process, and the next answer writes the file again.
    try? ProtectedFile.write(data, to: url)
  }

  public func remove() { try? FileManager.default.removeItem(at: url) }
}

/// `getExperiment()` on a device: a port of the browser SDK's `experiments.ts`
/// with the three things a phone needs:
///
/// - **A stored answer never expires into `unavailable`.** Past its
///   `maxAgeSeconds` it is still returned, and refreshed in the background. A
///   phone is offline in normal operation, and the answer for a unit is
///   deterministic, so the old variant is the better failure than flipping a
///   returning user onto the default path.
/// - **A synchronous read** (`cached`), so an app can choose its first screen
///   before any network call returns. It records the exposure like the async
///   call: the answer an app branched on is the answer counted. Answered before
///   anyone is in front — a launch before its first screen, or a push — the
///   exposure and the stamp wait for the next `$app_opened`, and a launch that
///   never comes to the front records neither.
/// - **A refresh on every `$app_opened`**, and an answer pinned for the
///   session, so a refresh that lands mid-session changes the next one.
///
/// Confined to the engine's executor, like the engine — hence
/// `@unchecked Sendable`: the confinement is the guarantee.
final class Experiments: @unchecked Sendable {
  struct Ids: Equatable {
    var anonymousId: String
    var deviceId: String
    var userId: String?
  }

  struct Entry: Equatable {
    var status: TogoExperimentStatus
    var variant: String?
    var participating: Bool
    var unit: String?
    /// Wall-clock milliseconds when it was fetched.
    var at: Int64
    var ttlSeconds: Int64
  }

  /// What is persisted, keyed by the ids, as the browser's `Doc`: a new
  /// anonymous id starts over, a new `userId` drops the answers and keeps the
  /// stamps, and the once-only record outlives both.
  struct Doc {
    var anonymousId: String?
    var userId: String?
    var entries: [String: Entry] = [:]
    /// Entered and still stamped: name → variant.
    var entered: [String: String] = [:]
    /// The once-only record, `name:hash of the unit's value`, oldest first.
    /// Hashed so that a `userId` is not left on the device after logout.
    var once: [String] = []
  }

  /// Past this a call answers `unavailable`; a later answer still fills the cache.
  static let timeoutSeconds = 0.8
  /// The Worker's `ASSIGNMENT_MAX_EXPERIMENTS`: above it the request is refused whole.
  static let maxNamesPerRequest = 50
  /// Enough that a shared device keeps its record; few enough to stay small.
  static let maxOnceRecords = 200
  static let defaultEndpoint = URL(string: "https://assign.togohq.ai")!

  private let writeKey: String
  private let endpoint: URL
  private let store: ExperimentStore
  private let transport: TogoTransport
  private let executor: TogoExecutor
  private let clock: TogoClock
  private let ids: () -> Ids?
  private let sessionId: () -> String?
  private let humanPresent: () -> Bool
  private let enter: (String, String) -> Void
  private let test: Bool

  /// The working document: read from the store once, then kept in step with it.
  private var doc: Doc?
  /// A test key caches nothing, so a forced variant is seen at once; its stamps
  /// last the process.
  private var memory = Doc()
  private var seenThisProcess = Set<String>()
  /// The answers this session returned, so a refresh never flips a variant
  /// inside one session. Cleared when the session or the ids change.
  private var pinned: [String: Entry] = [:]
  private var pinnedFor: (session: String?, ids: Ids)?
  /// Callbacks per name waiting on a request, which is one per name in flight.
  private var waiting: [String: [(Entry?) -> Void]] = [:]
  /// Names asked in this turn of the executor, sent as one request.
  private var batch: [String] = []
  /// Exposures answered while nobody was in front — a launch before its first
  /// screen, or a push — recorded at the next `$app_opened`, under the ids they
  /// were answered for. A launch that never comes to the front records none.
  private var pending: [(name: String, variant: String, unit: String?, ids: Ids)] = []

  init(
    writeKey: String, endpoint: URL, store: ExperimentStore, transport: TogoTransport,
    executor: TogoExecutor, clock: TogoClock, ids: @escaping () -> Ids?,
    sessionId: @escaping () -> String?, humanPresent: @escaping () -> Bool,
    enter: @escaping (String, String) -> Void
  ) {
    self.writeKey = writeKey
    self.endpoint = endpoint
    self.store = store
    self.transport = transport
    self.executor = executor
    self.clock = clock
    self.ids = ids
    self.sessionId = sessionId
    self.humanPresent = humanPresent
    self.enter = enter
    test = WriteKeys.isTest(writeKey)
  }

  // MARK: - The surface

  /// The answer, from the stored one when there is one — refreshed in the
  /// background when it is old — or from the network, within 800 ms.
  /// `completion` runs on the executor.
  func get(_ name: String, completion: @escaping @Sendable (TogoExperiment) -> Void) {
    if !valid(name) {
      completion(
        TogoExperiment(experiment: name, status: .notFound, variant: nil, participating: false))
      return
    }
    // Locked (no unit) or consent withholding. With nobody in front yet — a
    // launch choosing its first screen — it still answers; the exposure waits
    // for the foreground (`answer`).
    guard let ids = ids() else { return completion(.unavailable(name)) }
    if !test, let entry = current(name, ids) {
      if stale(entry) { refresh([name]) }
      return completion(answer(name, entry, ids))
    }
    // Whichever comes first answers: the timer or the network. Both run on the executor.
    let done = CancelFlag()
    let cancel = executor.after(Experiments.timeoutSeconds) {
      if done.isCancelled { return }
      done.cancel()
      completion(.unavailable(name))
    }
    ask(name) { [self] entry in
      if done.isCancelled { return }
      done.cancel()
      cancel()
      guard let entry, let ids = self.ids() else { return completion(.unavailable(name)) }
      completion(answer(name, entry, ids))
    }
  }

  /// The stored answer, now, never from the network: `nil` when there is none.
  /// Records the exposure when it says `participating`.
  func cached(_ name: String) -> TogoExperiment? {
    guard valid(name), let ids = ids(), let entry = current(name, ids) else {
      return nil
    }
    return answer(name, entry, ids)
  }

  /// Fetch without recording an exposure: what has no answer, or an old one.
  func preload(_ names: [String]) {
    // Nothing to fetch mints nothing: `ids()` is the first permitted write.
    guard names.contains(where: valid), humanPresent(), let ids = ids() else { return }
    let doc = load(ids)
    refresh(
      names.filter { name in
        guard valid(name) else { return false }
        guard !test, let entry = doc.entries[name] else { return true }
        return stale(entry)
      })
  }

  /// `$app_opened`: refresh everything this device holds an answer or a stamp
  /// for, and the names the app preloads. A finished experiment comes back
  /// `finished`, which is what ends its stamp.
  func appOpened(preload names: [String]) {
    guard let ids = ids() else { return }
    // What was answered before anyone was in front is an exposure now, unless
    // the ids changed meanwhile (a reset or another user).
    let due = pending
    pending = []
    for exposure in due where exposure.ids == ids {
      record(exposure.name, exposure.variant, unit: exposure.unit, ids: ids)
    }
    let doc = load(ids)
    var all = Set(doc.entries.keys).union(doc.entered.keys)
    all.formUnion(names.filter(valid))
    refresh(all.sorted())
  }

  /// The stamp for an ordinary event tracked now, or `nil` for none. A `$`
  /// event carries none.
  func stamp(for eventName: String) -> [String: String]? {
    if eventName.hasPrefix(Wire.reservedEventPrefix) { return nil }
    guard let ids = ids() else { return nil }
    let entered = load(ids).entered
    if entered.isEmpty { return nil }
    let names = entered.keys.sorted().prefix(Wire.maxEnvelopeExperimentsPerEvent)
    return Dictionary(uniqueKeysWithValues: names.map { ($0, entered[$0]!) })
  }

  /// Consent withdrawal: everything goes, the file included.
  func clear() {
    memory = Doc()
    pending = []
    seenThisProcess.removeAll()
    pinned.removeAll()
    pinnedFor = nil
    doc = nil
    store.remove()
  }

  /// `reset()`: answers and stamps go, the record of who has entered stays.
  func forgetIdentity() {
    memory = Doc()
    pending = []
    seenThisProcess.removeAll()
    pinned.removeAll()
    pinnedFor = nil
    if test { return }
    // Unreadable — protected data before the first unlock — or absent: leave the
    // file. Removing what could not be read would lose the once-only record and
    // count the same unit twice; the next load under the new anonymous id drops
    // its answers and stamps anyway.
    guard let current = doc ?? read() else {
      doc = nil
      return
    }
    let once = current.once
    if once.isEmpty {
      doc = nil
      store.remove()
    } else {
      let kept = Doc(once: once)
      doc = kept
      save(kept)
    }
  }

  // MARK: - Answers

  private func valid(_ name: String) -> Bool {
    !name.isEmpty && name.utf16.count <= Wire.maxEnvelopeExperimentKeyLength
  }

  /// The answer this session returns for `name`: the pinned one, or the stored
  /// one, which is then pinned.
  private func current(_ name: String, _ ids: Ids) -> Entry? {
    let session = sessionId()
    if let pinnedFor, pinnedFor.session == session, pinnedFor.ids == ids {
      if let entry = pinned[name] { return entry }
    } else {
      pinned.removeAll()
      pinnedFor = (session, ids)
    }
    guard let entry = load(ids).entries[name] else { return nil }
    pinned[name] = entry
    return entry
  }

  private func stale(_ entry: Entry) -> Bool {
    let now = clock.wallMs()
    return now < entry.at || now - entry.at >= entry.ttlSeconds * 1000
  }

  private func answer(_ name: String, _ entry: Entry, _ ids: Ids) -> TogoExperiment {
    if pinnedFor == nil || pinnedFor?.ids != ids || pinnedFor?.session != sessionId() {
      pinned.removeAll()
      pinnedFor = (sessionId(), ids)
    }
    pinned[name] = entry
    if entry.participating, let variant = entry.variant {
      if humanPresent() {
        record(name, variant, unit: entry.unit, ids: ids)
      } else if !pending.contains(where: { $0.name == name && $0.ids == ids }) {
        pending.append((name, variant, entry.unit, ids))
      }
    }
    return TogoExperiment(
      experiment: name, status: entry.status, variant: entry.variant,
      participating: entry.participating)
  }

  /// The exposure, once per unit per experiment — across launches, since the
  /// record is in the file — and the stamp on every later event.
  private func record(_ name: String, _ variant: String, unit: String?, ids: Ids) {
    if test {
      memory.entered[name] = variant
      if !seenThisProcess.insert("\(name)\u{0}\(variant)").inserted { return }
      enter(name, variant)
      return
    }
    var doc = load(ids)
    // A refresh that said `finished` ended the stamp: the answer pinned for this
    // session is still returned, but it must not bring the stamp back.
    if doc.entries[name]?.status == .finished { return }
    doc.entered[name] = variant
    let value: String? =
      switch unit {
      case "user_id": ids.userId
      case "device_id": ids.deviceId
      default: ids.anonymousId
      }
    let key = "\(name):\(Experiments.hashUnit(value ?? ""))"
    if doc.once.contains(key) {
      save(doc)
      return
    }
    doc.once.append(key)
    if doc.once.count > Experiments.maxOnceRecords { doc.once.removeFirst() }
    save(doc)
    enter(name, variant)
  }

  /// The browser's `hashUnit`: djb2 over UTF-16, base 36. Not a security
  /// boundary — only so that the raw id is not what the file holds.
  static func hashUnit(_ value: String) -> String {
    var hash: Int32 = 5381
    for unit in value.utf16 { hash = hash &* 33 &+ Int32(unit) }
    return String(UInt32(bitPattern: hash), radix: 36)
  }

  // MARK: - Requests

  private func refresh(_ names: [String]) {
    for name in names { ask(name) { _ in } }
  }

  /// One request per turn of the executor, and one in flight per name.
  private func ask(_ name: String, _ callback: @escaping (Entry?) -> Void) {
    if waiting[name] != nil {
      waiting[name]!.append(callback)
      return
    }
    waiting[name] = [callback]
    batch.append(name)
    if batch.count == 1 { executor.async { [self] in send() } }
  }

  private func send() {
    let names = batch
    batch = []
    guard let ids = ids() else { return resolve(names, [:]) }
    stride(from: 0, to: names.count, by: Experiments.maxNamesPerRequest).forEach { start in
      let chunk = Array(names[start..<min(start + Experiments.maxNamesPerRequest, names.count)])
      var body: [String: JSONValue] = [
        "anonymousId": .string(ids.anonymousId), "deviceId": .string(ids.deviceId),
        "experiments": .array(chunk.map(JSONValue.string)),
      ]
      if let userId = ids.userId { body["userId"] = .string(userId) }
      let data = Data(JSONValue.object(body).serialized().utf8)
      transport.post(
        url: endpoint.appendingPathComponent("v1/assignments"), writeKey: writeKey, body: data
      ) { [self] response in
        executor.async { [self] in received(response, names: chunk, askedFor: ids) }
      }
    }
  }

  private func received(_ response: TransportResponse, names: [String], askedFor ids: Ids) {
    // Offline, a 503 or a garbled body is `unavailable` for a name with
    // nothing stored, and the stored answer for one that has it. And the answer
    // belongs to the ids it was asked for: a reset() or identify() that landed
    // while it was in flight means someone else's variant.
    guard response.status.map({ (200..<300).contains($0) }) == true, let body = response.body,
      let json = try? JSONValue.parse(body), let assignments = json["assignments"]?.objectValue,
      self.ids() == ids
    else { return resolve(names, [:]) }
    let now = clock.wallMs()
    let ttl = json["maxAgeSeconds"]?.int64Value ?? 0
    var doc = load(ids)
    var answers: [String: Entry] = [:]
    for (name, value) in assignments {
      guard let raw = value["status"]?.stringValue, let status = TogoExperimentStatus(rawValue: raw)
      else { continue }  // A drifted body: `unavailable`.
      let participating: Bool = if case .bool(true) = value["participating"] { true } else { false }
      let entry = Entry(
        status: status, variant: value["variant"]?.stringValue, participating: participating,
        unit: value["unit"]?.stringValue, at: now, ttlSeconds: ttl)
      answers[name] = entry
      doc.entries[name] = entry
      // The only thing that ends a stamp.
      if status == .finished { doc.entered[name] = nil }
    }
    save(doc)
    resolve(names, answers)
  }

  private func resolve(_ names: [String], _ answers: [String: Entry]) {
    for name in names {
      let callbacks = waiting.removeValue(forKey: name) ?? []
      for callback in callbacks { callback(answers[name]) }
    }
  }

  // MARK: - The document

  private func load(_ ids: Ids) -> Doc {
    if test { return memory }
    var doc = self.doc ?? read() ?? Doc()
    if doc.anonymousId != ids.anonymousId {
      doc = Doc(anonymousId: ids.anonymousId, userId: ids.userId, once: doc.once)
    } else if doc.userId != ids.userId {
      doc.userId = ids.userId
      doc.entries = [:]
    }
    self.doc = doc
    return doc
  }

  private func save(_ doc: Doc) {
    if test {
      memory = doc
      return
    }
    self.doc = doc
    store.write(Data(doc.json.serialized().utf8))
  }

  /// A corrupt file is a refetch, never a crash.
  private func read() -> Doc? {
    guard let data = store.read(), let json = try? JSONValue.parse(data) else { return nil }
    return Doc(json: json)
  }
}

extension Experiments.Doc {
  /// The file's shape. `v` lets a later SDK read an older file.
  var json: JSONValue {
    var object: [String: JSONValue] = [
      "v": .int(1),
      "e": .object(entries.mapValues(\.json)),
      "x": .object(entered.mapValues(JSONValue.string)),
      "n": .array(once.map(JSONValue.string)),
    ]
    if let anonymousId { object["a"] = .string(anonymousId) }
    if let userId { object["u"] = .string(userId) }
    return .object(object)
  }

  init?(json: JSONValue) {
    guard let entries = json["e"]?.objectValue, let entered = json["x"]?.objectValue else {
      return nil
    }
    anonymousId = json["a"]?.stringValue
    userId = json["u"]?.stringValue
    self.entries = entries.compactMapValues(Experiments.Entry.init(json:))
    self.entered = entered.compactMapValues(\.stringValue)
    once = json["n"]?.arrayValue?.compactMap(\.stringValue) ?? []
  }
}

extension Experiments.Entry {
  var json: JSONValue {
    var object: [String: JSONValue] = [
      "status": .string(status.rawValue), "variant": variant.map(JSONValue.string) ?? .null,
      "participating": .bool(participating), "at": .int(at), "ttl": .int(ttlSeconds),
    ]
    if let unit { object["unit"] = .string(unit) }
    return .object(object)
  }

  init?(json: JSONValue) {
    guard let raw = json["status"]?.stringValue, let status = TogoExperimentStatus(rawValue: raw),
      let at = json["at"]?.int64Value
    else { return nil }
    self.status = status
    variant = json["variant"]?.stringValue
    participating = json["participating"] == .bool(true)
    unit = json["unit"]?.stringValue
    self.at = at
    ttlSeconds = json["ttl"]?.int64Value ?? 0
  }
}
