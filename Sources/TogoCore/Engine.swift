import Foundation

/// Everything `Togo.setup(_:)` configures, resolved: the public module reads the
/// bundle, the device and the time zone and hands the core plain values.
public struct EngineOptions: Sendable {
  public var writeKey: String
  public var endpoint: URL
  public var sessionTimeoutSeconds: Double?
  public var consent: TogoConsent
  public var consentBufferMaxEvents: Int
  public var defaultProperties: TogoProperties?
  /// The app build: the bundle's numbers, or the `appVersion`/`appBuild` options.
  public var app: AppInfo?
  /// The device as the OS reports it. `nil` off a native platform.
  public var device: DeviceInfo?
  /// The device's IANA zone, read once.
  public var timezone: String?
  public var onError: (@Sendable (TogoError) -> Void)?
  /// The `sdk` every event names: this SDK's own unless a wrapper set its own.
  public var sdk: SdkIdentity = .native
  /// Where `getExperiment()` asks: the assignment service.
  public var assignEndpoint: URL = Experiments.defaultEndpoint
  /// Experiment names fetched at each `$app_opened` without an exposure, so the
  /// first `getExperiment()` of a launch does not wait.
  public var experiments: [String] = []
  /// Fixed on a device, not options, because batching is the SDK's to set:
  /// 50 events or 5 seconds. Only the scenario runner changes them.
  public var batchSize: Int = 50
  public var flushIntervalSeconds: Double = 5

  public init(
    writeKey: String, endpoint: URL, sessionTimeoutSeconds: Double? = nil,
    consent: TogoConsent = .notRequired, consentBufferMaxEvents: Int = 100,
    defaultProperties: TogoProperties? = nil, app: AppInfo? = nil, device: DeviceInfo? = nil,
    timezone: String? = nil, onError: (@Sendable (TogoError) -> Void)? = nil
  ) {
    self.writeKey = writeKey
    self.endpoint = endpoint
    self.sessionTimeoutSeconds = sessionTimeoutSeconds
    self.consent = consent
    self.consentBufferMaxEvents = consentBufferMaxEvents
    self.defaultProperties = defaultProperties
    self.app = app
    self.device = device
    self.timezone = timezone
    self.onError = onError
  }
}

/// The SDK's behaviour, platform-free: a port of the browser SDK's `client.ts`
/// for a device that is an app rather than a page.
///
/// **Confined to one serial executor.** Every method must be called on the
/// executor it was given, which is what `Togo` does; that is what keeps calls
/// in the order they were made and the state free of locks. The scenario runner
/// and the tests call it directly, on one thread, with an executor that runs
/// work inline. Hence `@unchecked Sendable`: the confinement is the guarantee.
///
/// **Nothing here throws.** A refusal is a log line naming the problem and the
/// fix, and an `onError` call, never an exception: an analytics call must not
/// be able to take down the handler it sits in.
public final class TogoEngine: @unchecked Sendable {
  public let options: EngineOptions
  private let identityStore: IdentityStore
  private var assignments: Experiments!
  private let deviceIds: DeviceIdProvider
  private let transport: TogoTransport
  private let executor: TogoExecutor
  private let callbacks: TogoExecutor
  private let clock: TogoClock
  private let log: TogoLogger
  private let humanPresent: @Sendable () -> Bool

  private let sessions: Sessions
  private let defaults: DefaultProperties
  private let reservedKeys: ReservedKeys
  private let valueCaps: ValueCaps
  private let app: AppInfo?
  private let device: DeviceInfo?
  private var queue: EventQueue!

  private(set) public var consent: TogoConsent
  /// The signed-in user. Remembered in the identity record when consent
  /// permits a write; kept in memory otherwise, and written at the first
  /// moment it does.
  private var userId: String?
  /// The working copy of the identity record. Loaded at the first moment
  /// consent permits reading the device — never under `pending` or `denied`.
  private var record = IdentityRecord()
  private var loaded = false
  /// `identify()` and `reset()` calls in this process. A held event made
  /// before any inherits the stored user.
  private var identityCalls = 0
  /// The user the identity record named when it was first read, before
  /// anything this process did to it, and the anonymous id beside it.
  private var storedUserId: String?
  private var storedAnonymousId: String?
  private var storedUserRead = false
  /// `reset()` was called before the record could be read: applied to it at
  /// the load.
  private var logoutBeforeLoad = false
  /// `identify()` was called before the record could be read: a different
  /// stored user is reset at the load.
  private var identifiedBeforeLoad = false
  /// Held in memory: under `pending` consent, or while the identity store is
  /// unavailable (before the first unlock) or the device id
  /// is not available yet (D1 step 4). Bounded; never persisted.
  private var held: [HeldEvent] = []
  /// The launch's `$app_installed` / `$app_updated` decision is owed: it needs
  /// the identity record, which waits for consent and for the device to be
  /// unlocked. The wall time of the launch it is about.
  private var launchOwedAtMs: Int64?
  /// The last load found no record — a first launch, or a withdrawal deleted
  /// it. What `$app_installed` means (D4).
  private var foundNoRecord = false
  /// `start()` was called: this client reports the app's lifecycle. A client
  /// that never starts — the scenario runner's browser-parity replay, a test
  /// of the rest of the surface — sends no lifecycle event at all.
  private var reportsLaunches = false

  private(set) public var disabled = false
  private var cancelTimer: (@Sendable () -> Void)?
  /// Consecutive failed uploads. Reset by any outcome that is not a retry.
  private var attempt = 0
  /// An upload has been posted and not answered yet. One at a time, so a
  /// backlog drains in order and a retry's backoff is not undercut.
  private var inFlight = false
  /// A non-edge status (a redirect) was logged once; the next ones are only
  /// retried.
  private var warnedUnexpectedStatus = false

  /// Past this many consecutive automatic retries the SDK stops rescheduling.
  /// Not a retention limit: the events stay queued for the next `track()`,
  /// `flush()` or launch.
  static let maxFlushAttempts = 8
  static let maxBackoffSeconds: Double = 300

  public init(
    options: EngineOptions,
    identityStore: IdentityStore = MemoryIdentityStore(),
    deviceIds: DeviceIdProvider = GeneratedDeviceIdProvider(),
    queueStore: QueueStore = MemoryQueueStore(),
    experimentStore: ExperimentStore = MemoryExperimentStore(),
    transport: TogoTransport = URLSessionTransport(),
    executor: TogoExecutor,
    callbacks: TogoExecutor,
    clock: TogoClock = SystemClock(),
    log: @escaping TogoLogger = standardErrorLogger,
    humanPresent: @escaping @Sendable () -> Bool = { true }
  ) {
    self.options = options
    self.identityStore = identityStore
    self.deviceIds = deviceIds
    self.transport = transport
    self.executor = executor
    self.callbacks = callbacks
    self.clock = clock
    self.log = log
    self.humanPresent = humanPresent
    consent = options.consent
    sessions = Sessions(timeoutSeconds: options.sessionTimeoutSeconds, log: log)
    defaults = DefaultProperties(options.defaultProperties, log: log)
    reservedKeys = ReservedKeys(writeKey: options.writeKey)
    valueCaps = ValueCaps(writeKey: options.writeKey)
    app = validatedApp(options.app, log: log)
    device = validatedDevice(options.device)
    queue = EventQueue(store: queueStore) { [unowned self] events, code in
      let reason =
        code == .queueFull ? "queue full (long offline, or one huge event)" : "older than 7 days"
      self.report(code, "\(events.count) event(s) dropped: \(reason)", events.map(\.eventId))
    }
    assignments = Experiments(
      writeKey: options.writeKey, endpoint: options.assignEndpoint, store: experimentStore,
      transport: transport, executor: executor, clock: clock,
      ids: { [unowned self] in
        guard !disabled, let ids = identity() else { return nil }
        return Experiments.Ids(anonymousId: ids.anonymousId, deviceId: ids.deviceId, userId: userId)
      },
      sessionId: { [unowned self] in sessionId }, humanPresent: humanPresent,
      enter: { [unowned self] name, variant in
        _ = submit(
          Wire.experimentEnteredEvent,
          ["experiment": .string(name), "variant": .string(variant)], personProperties: nil,
          timezone: options.timezone)
      })
    // A queue left on the device by a client whose consent is now `denied` is
    // deleted rather than read: those events predate the refusal.
    if consent == .denied {
      queue.clear()
      experimentStore.remove()
    }
  }

  // MARK: - The public surface

  /// Send an event. Returns the `eventId` it queued (or holds), or `nil` when
  /// nothing will be sent: a refused name, consent denied, a disabled client.
  @discardableResult
  public func track(_ eventName: String, properties: TogoProperties = [:]) -> String? {
    if eventName.isEmpty || eventName.utf16.count > Wire.maxEventNameLength {
      let named = !eventName.isEmpty
      report(
        named ? .eventNameTooLong : .eventNameEmpty,
        "an event was not sent: its name must be 1 to \(Wire.maxEventNameLength) characters "
          + "(got \(eventName.utf16.count)).", [], named ? eventName : nil)
      return nil
    }
    if !disabled, let reserved = Reserved.checkName(eventName, writeKey: options.writeKey) {
      if reserved.send {
        log(reserved.message)
      } else {
        report(.eventNameReserved, reserved.message, [], eventName)
        return nil
      }
    }
    let merged = defaults.merge(eventName, properties)
    // The property count first, on the merged map as sent, so the name checks see what the edge
    // would (`ValueCaps.capCount`).
    var drops: [(once: String, message: String)] = []
    let checked =
      disabled
      ? merged
      : reservedKeys.check(
        valueCaps.capCount(eventName, merged) { drops.append(($0, $1)) }
      ) { code, message, property in
        report(code, message, [], eventName, property)
      } ?? [:]
    return submit(
      eventName, checked, personProperties: nil, timezone: options.timezone, drops: drops)
  }

  /// The authenticated identity. The same user again sends nothing; a new one
  /// sends one `$identify`; a different one is a missed logout, so it resets
  /// first.
  @discardableResult
  public func identify(_ id: String) -> String? {
    // Refused here, per call: the edge's schema bounds `userId` to 1–128
    // characters for the WHOLE batch, so an empty id from an account not yet
    // loaded would ride every later event and lose each upload with a 400.
    if id.isEmpty || id.utf16.count > Wire.maxUserIdLength {
      report(
        .userIdInvalid,
        "identify() was given a userId of \(id.utf16.count) characters; it must be 1 to "
          + "\(Wire.maxUserIdLength). Nothing changed: pass your account's own id once it exists.")
      return nil
    }
    loadIfPermitted()
    if id == userId { return nil }
    identityCalls += 1
    if userId != nil { resetIdentity() }
    userId = id
    // Compared with the stored user once the record can be read.
    if !loaded { identifiedBeforeLoad = true }
    if consent.permitted {
      record.userId = id
      save()
    }
    return submit(Wire.identifyEvent, [:], personProperties: nil, timezone: nil)
  }

  /// One `$set_person_properties` carrier through the consent gate; an empty
  /// update sends nothing.
  @discardableResult
  public func setPersonProperties(_ update: PersonPropertyUpdate) -> String? {
    guard !disabled else { return nil }
    // The property count first, on each map as sent — `set` with the `$email` and `$name` the SDK
    // adds — before the name checks.
    var drops: [(once: String, message: String)] = []
    let carrier = Wire.personPropertiesCarrierEvent
    let typed = [("email", update.email), ("name", update.name)].filter { $0.1 != nil }
      .map { Wire.reservedEventPrefix + $0.0 }
    var capped = update
    capped.set = valueCaps.capCount(carrier, update.set, map: "set", extra: typed) {
      drops.append(($0, $1))
    }
    capped.setOnce = valueCaps.capCount(carrier, update.setOnce, map: "setOnce") {
      drops.append(($0, $1))
    }
    capped.unset = valueCaps.capCount(carrier, update.unset, map: "unset") {
      drops.append(($0, $1))
    }
    guard
      let ops = reservedKeys.personOps(
        capped, report: { code, message, property in report(code, message, [], nil, property) })
    else { return nil }
    return submit(carrier, [:], personProperties: ops, timezone: nil, drops: drops)
  }

  /// Which variant of an experiment this device gets. The stored answer when
  /// there is one — at any age, offline included, refreshed in the background
  /// when old — or the network's, within 800 ms; `unavailable` otherwise. A
  /// participant's first answer records `$experiment_entered`, once per unit
  /// per experiment, and later events carry the variant. `completion` runs on
  /// the engine's executor.
  public func getExperiment(
    _ name: String, completion: @escaping @Sendable (TogoExperiment) -> Void
  ) {
    if disabled { return completion(.unavailable(name)) }
    assignments.get(name, completion: completion)
  }

  /// The stored answer, now, with no network: `nil` when this device has none.
  /// Records the exposure as `getExperiment()` does.
  public func cachedExperiment(_ name: String) -> TogoExperiment? {
    if disabled { return nil }
    return assignments.cached(name)
  }

  /// Fetch these names without recording an exposure.
  public func preloadExperiments(_ names: [String]) {
    if disabled { return }
    assignments.preload(names)
  }

  /// Logout: a new anonymous visitor and a new session; the device id stays.
  public func reset() {
    loadIfPermitted()
    resetIdentity()
  }

  public func setConsent(_ next: TogoConsent) {
    let from = consent
    if from == next { return }
    consent = next
    if next == .denied {
      // Delete the stored queue before anything can read it.
      queue.clear()
      held.removeAll()
      // Withdrawal DELETES, it does not merely stop — from any state.
      // Ids written while consent was permitted are still on the device after
      // a pass through `pending`, and deleting is not writing, so it needs no
      // permission of its own.
      identityStore.erase()
      assignments.clear()
      record = IdentityRecord()
      loaded = true
      sessions.forget()
      // The signed-in user goes too. Kept in memory, a later grant in this
      // process would write it back to the device and stamp it on every new
      // event, linking traffic after the withdrawal to the person before it.
      // The app identifies again after a new grant if it wants to.
      userId = nil
      // The record that said "installed" is gone, and keeping a marker would be
      // storage the user just refused: a later grant is a fresh install (D4).
      foundNoRecord = true
    }
    // A userId asserted while writes were not permitted is persisted at the
    // first moment they are, like the ids minted then.
    if let userId, consent.permitted {
      loadIfPermitted()
      record.userId = userId
      save()
    }
    if next.permitted {
      // After a withdrawal the grant is the install, at the grant's time.
      if from == .denied, reportsLaunches, launchOwedAtMs == nil { launchOwedAtMs = clock.wallMs() }
      decideLaunch()
      if !from.permitted { releaseHeld() }
    }
  }

  /// Send what is queued now. `completion` runs after one upload attempt —
  /// never throws, and a failure stays queued for the retry.
  public func flush(completion: (@Sendable () -> Void)? = nil) {
    cancelTimer?()
    cancelTimer = nil
    // The queue file is protected like the identity file: while the identity
    // cannot be read (before the first unlock), neither can the queue, and
    // reading it as empty would let the next write replace it (D3).
    loadIfPermitted()
    guard !disabled, consent.permitted, loaded, !inFlight else {
      // In flight: that upload's answer schedules the next one.
      completion?()
      return
    }
    queue.hydrate()
    let entries = queue.take(limit: options.batchSize, nowMs: clock.wallMs())
    guard let first = entries.first else {
      completion?()
      return
    }
    // Stamped HERE, at upload: the device clock at the moment the edge can
    // measure its offset. A retry gets a fresh reading.
    let batch = RawBatch(
      clientSentMs: clock.wallMs(), deviceIdMode: first.deviceIdMode,
      sessionIdMode: sessions.mode, app: first.app, device: first.device,
      events: entries.map(\.event))
    let body = Data(batch.json.serialized().utf8)
    let url = options.endpoint.appendingPathComponent("v1/events")
    inFlight = true
    transport.post(url: url, writeKey: options.writeKey, body: body) { [self] response in
      executor.async { [self] in
        inFlight = false
        handle(response, entries: entries)
        completion?()
      }
    }
  }

  /// Read-only, never mints.
  public var anonymousId: String? {
    loadIfPermitted()
    return consent.permitted ? record.anonymousId : nil
  }

  public var deviceId: String? {
    loadIfPermitted()
    return consent.permitted ? record.deviceId : nil
  }

  public var sessionId: String? {
    loadIfPermitted()
    guard consent.permitted else { return nil }
    return sessions.current(record.session, wallMs: clock.wallMs(), monotonicMs: clock.monotonicMs())
  }

  /// Stop for the rest of this process: one error, every later call a no-op.
  /// The queue is KEPT — a 401 can be a key minted seconds ago that has not
  /// reached the edge yet — and retried at the next launch.
  public func disable(_ message: String, code: TogoErrorCode? = nil) {
    if disabled { return }
    disabled = true
    if let code { report(code, message) } else { log(message) }
    cancelTimer?()
    cancelTimer = nil
  }

  /// The identity store can be read again (the device was unlocked), or the
  /// device id has arrived: load, decide the launch, and send what was held,
  /// under the stored ids.
  public func identityBecameAvailable() {
    if !loaded { loadIfPermitted() }
    guard consent.permitted else { return }
    decideLaunch()
    releaseHeld()
  }

  // MARK: - The app's lifecycle

  /// The process started. Owes the launch's `$app_installed` or
  /// `$app_updated`, sent as soon as the identity record can be read — now,
  /// or when consent permits, or when the device is unlocked. Starts no
  /// session: nobody is necessarily looking (a prewarm, a push).
  public func start() {
    reportsLaunches = true
    launchOwedAtMs = clock.wallMs()
    guard consent.permitted else { return }
    decideLaunch()
    releaseHeld()
  }

  /// A scene came to the foreground with none in front before
  /// (`AppLifecycle`). The event a human is present for, so it opens a session
  /// when none is open, or continues the one inside the window.
  public func appOpened(fromBackground: Bool) {
    _ = submit(
      Wire.appOpenedEvent, ["from_background": .bool(fromBackground)], personProperties: nil,
      timezone: options.timezone)
    // Every foreground refreshes the stored answers: a finished experiment ends
    // its stamp here, and the next session gets a changed answer.
    if !disabled { assignments.appOpened(preload: options.experiments) }
  }

  /// The last scene went to the background: background time is idle time, so
  /// the session's `lastActivityAt` is now, and it is written at once,
  /// since a suspended app can be killed with no callback. Then the
  /// queue is flushed; `completion` runs after that attempt.
  public func appBackgrounded(completion: (@Sendable () -> Void)? = nil) {
    loadIfPermitted()
    if consent.permitted, loaded, var session = record.session,
      sessions.markActivity(&session, wallMs: clock.wallMs(), monotonicMs: clock.monotonicMs())
    {
      record.session = session
      save()
    }
    identityStore.persistNow()
    flush(completion: completion)
  }

  /// D4's table. Once per process (and again after a withdrawal), at the first
  /// moment the record reads: no record → `$app_installed`; a stored version or
  /// build that differs → `$app_updated` with the previous ones; otherwise
  /// nothing. The event takes the launch's time and goes FIRST among what is
  /// held, so it precedes what the app did on that launch.
  private func decideLaunch() {
    guard let launchedAtMs = launchOwedAtMs, !disabled, consent.permitted else { return }
    loadIfPermitted()
    guard loaded else { return }  // Unreadable: decide after the unlock.
    launchOwedAtMs = nil
    let previous = (version: record.appVersion, build: record.appBuild)
    let current = (version: app?.version, build: app?.build)
    var event: (name: String, properties: TogoProperties)?
    if foundNoRecord {
      event = (Wire.appInstalledEvent, [:])
    } else if previous.version != nil || previous.build != nil,
      previous.version != current.version || previous.build != current.build
    {
      var properties: TogoProperties = [:]
      if let version = previous.version { properties["previous_app_version"] = .string(version) }
      if let build = previous.build { properties["previous_app_build"] = .string(build) }
      event = (Wire.appUpdatedEvent, properties)
    }
    foundNoRecord = false
    if previous != current {
      record.appVersion = current.version
      record.appBuild = current.build
      // A first launch writes at the first minted id, never a record holding
      // nothing but a version: that would read as "installed" next launch even
      // if no `$app_installed` was ever sent.
      if record.deviceId != nil { save() }
    }
    guard let event else { return }
    held.insert(
      HeldEvent(
        eventName: event.name, properties: event.properties, clientEventMs: launchedAtMs,
        eventId: randomId(), userId: userId, personProperties: nil, timezone: options.timezone,
        app: app, device: device), at: 0)
  }

  /// What is held in memory, for a test.
  public var heldCount: Int { held.count }
  /// What is queued on the device, for a test.
  public var queuedCount: Int {
    queue.hydrate()
    return queue.count
  }

  // MARK: - The gate

  /// The one gate every event goes through, ours and the customer's: held
  /// (`pending`, or identity unreadable), dropped (`denied`), or stamped and
  /// queued.
  private func submit(
    _ eventName: String, _ properties: TogoProperties, personProperties: PersonPropertyOps?,
    timezone: String?, drops: [(once: String, message: String)] = []
  ) -> String? {
    if disabled { return nil }
    // Before the event takes its userId: after a relaunch the signed-in user
    // is in the stored record, and an event stamped first would carry none.
    loadIfPermitted()
    // An over-long value: cut under a live key, sent whole under a test key
    // for the inspector to show the server's cut (`ValueCaps`), and reported
    // with the id of the event that was kept.
    var cuts: [(once: String, property: String, message: String)] = []
    let cap = { [unowned self] (values: TogoProperties?) in
      valueCaps.cap(eventName, values) { cuts.append(($0, $1, $2)) }
    }
    let properties = cap(properties) ?? [:]
    let personProperties = personProperties.map {
      PersonPropertyOps(set: cap($0.set), setOnce: cap($0.setOnce), unset: $0.unset)
    }
    let heldEvent = HeldEvent(
      eventName: eventName, properties: properties, clientEventMs: clock.wallMs(),
      eventId: randomId(), userId: userId, personProperties: personProperties, timezone: timezone,
      app: app, device: device,
      inheritsStoredUser: !loaded && userId == nil && identityCalls == 0)
    // Denied is a choice: nothing is sent, so nothing is reported.
    guard consent == .pending || consent.permitted else { return nil }
    // The drops the caller collected past 256 properties, claimed like a cut.
    for drop in drops where valueCaps.claim(drop.once) {
      report(.envelopePropertiesTooMany, drop.message, [heldEvent.eventId], eventName)
    }
    for cut in cuts where valueCaps.claim(cut.once) {
      report(
        .envelopePropertyValueTooLong, cut.message, [heldEvent.eventId], eventName, cut.property)
    }
    if consent == .pending { return hold(heldEvent) }
    guard let ids = identity() else { return hold(heldEvent) }
    let event = stamp(heldEvent, ids: ids, held: nil)
    guard enqueue(event, app: app, device: device) else { return nil }
    return event.eventId
  }

  /// Hold with no identifier attached. Oldest dropped past the bound.
  private func hold(_ event: HeldEvent) -> String {
    held.append(event)
    if held.count > options.consentBufferMaxEvents {
      let evicted = held.removeFirst()
      report(
        .queueFull, "\"\(evicted.eventName)\" dropped: over consentBufferMaxEvents awaiting consent",
        [evicted.eventId], evicted.eventName)
    }
    return event.eventId
  }

  /// Release what was held, under the identifiers minted now. One session for
  /// the whole buffer: the events are contiguous by construction, and cutting
  /// them by a clock that was not running would be an invention. A new
  /// session's `$session_started` takes the first held event's time.
  ///
  /// **An event that inherits the stored user keeps the stored anonymous id
  /// too**, once a logout or a different user's `identify()` has replaced it.
  /// Under the new anonymous id it would carry the last user's `userId` next
  /// to the id of whoever came after, and link the two people. It goes with
  /// no session: the stored one was that user's, and the new one is the next
  /// person's.
  private func releaseHeld() {
    guard !held.isEmpty, let ids = identity() else { return }
    let events = held
    held = []
    let separated = storedAnonymousId != nil && storedAnonymousId != ids.anonymousId
    let previousIds = (deviceId: ids.deviceId, anonymousId: storedAnonymousId ?? ids.anonymousId)
    var sessionId: String?
    var touched = false
    for event in events {
      if separated, event.inheritsStoredUser {
        enqueue(
          stamp(event, ids: previousIds, held: (nil, storedUserId)), app: event.app,
          device: event.device)
        continue
      }
      if !touched {
        touched = true
        sessionId = touchSession { id in
          sessionStarted(
            id, occurredMs: event.clientEventMs, userId: heldUser(event), ids: ids, app: event.app,
            device: event.device)
        }
      }
      enqueue(stamp(event, ids: ids, held: (sessionId, heldUser(event))), app: event.app, device: event.device)
    }
  }

  /// The user a held event belongs to: the one asserted at the call, or —
  /// for an event held before the record was read and before any
  /// `identify()` or `reset()` — the user the record says was signed in when
  /// it was read.
  private func heldUser(_ event: HeldEvent) -> String? {
    event.inheritsStoredUser ? storedUserId : event.userId
  }

  private func stamp(
    _ event: HeldEvent, ids: (deviceId: String, anonymousId: String),
    held: (sessionId: String?, userId: String?)?
  ) -> RawEvent {
    let eventUserId = held.map(\.userId) ?? event.userId
    let sessionId =
      held.map(\.sessionId)
      ?? touchSession { id in
        sessionStarted(id, occurredMs: event.clientEventMs, userId: eventUserId, ids: ids, app: event.app, device: event.device)
      }
    var raw = RawEvent(
      eventName: event.eventName, clientEventMs: event.clientEventMs, eventId: event.eventId,
      anonymousId: ids.anonymousId, deviceId: ids.deviceId, userId: eventUserId,
      sessionId: sessionId, properties: event.properties,
      personProperties: event.personProperties, timezone: event.timezone)
    // Stamped now, so a queued event keeps it. A released event has none: it
    // was held because nothing could be read or stored yet.
    if held == nil { raw.experiments = assignments.stamp(for: event.eventName) }
    return named(raw)
  }

  /// The event naming the SDK this engine runs as — a wrapper's, when one set it.
  private func named(_ event: RawEvent) -> RawEvent {
    var event = event
    event.sdkName = options.sdk.name
    event.sdkVersion = options.sdk.version
    return event
  }

  /// `$session_started`, queued immediately before the event that opened the
  /// session, with that event's time.
  private func sessionStarted(
    _ sessionId: String, occurredMs: Int64, userId: String?,
    ids: (deviceId: String, anonymousId: String), app: AppInfo?, device: DeviceInfo?
  ) {
    let started = named(
      RawEvent(
        eventName: Wire.sessionStartedEvent, clientEventMs: occurredMs, eventId: randomId(),
        anonymousId: ids.anonymousId, deviceId: ids.deviceId, userId: userId,
        sessionId: sessionId, properties: [:], personProperties: nil,
        timezone: options.timezone))
    enqueue(started, app: app, device: device)
  }

  private func touchSession(onStart: (String) -> Void) -> String? {
    var session = record.session
    let result = sessions.touch(
      &session, wallMs: clock.wallMs(), monotonicMs: clock.monotonicMs(),
      canStart: humanPresent(), mintId: randomId)
    if session != record.session {
      record.session = session
      save()
    }
    if result.started, let id = result.id { onStart(id) }
    return result.id
  }

  /// Queue one event, unless it is over 256 KiB as UTF-8 JSON: then it is
  /// dropped here, never sent, and reported under every key — an event that
  /// large is a payload, not a fact about what a person did. False when it was
  /// not queued.
  @discardableResult
  private func enqueue(_ event: RawEvent, app: AppInfo?, device: DeviceInfo?) -> Bool {
    if disabled { return false }
    let entry = EventQueue.Entry(
      event: event, app: app, device: device, deviceIdMode: record.deviceIdMode)
    // `eventBytes` counts the line's newline too.
    if entry.eventBytes - 1 > Wire.maxEventBytes {
      report(
        .eventTooLarge,
        "\"\(event.eventName)\" was not sent: its JSON is \(entry.eventBytes - 1) bytes, over the "
          + "\(Wire.maxEventBytes)-byte limit. Send only the few values a chart needs, not a whole object.",
        [event.eventId], event.eventName)
      return false
    }
    queue.hydrate()
    queue.add(entry)
    // A full batch goes at once — unless an upload is in flight or a retry is
    // waiting out its backoff. Then the backlog waits for that, or every
    // track() during an outage would be a request, and every device with a
    // backlog would hit the edge together when it recovered.
    if queue.count >= options.batchSize, attempt == 0, !inFlight {
      flush()
    } else {
      scheduleFlush(after: options.flushIntervalSeconds)
    }
    return true
  }

  // MARK: - Identity

  /// Read the identity record at the first moment consent permits it. A read
  /// is not a write, but under `pending` the SDK does not touch the device at
  /// all.
  private func loadIfPermitted() {
    guard !loaded, consent.permitted else { return }
    switch identityStore.load() {
    case .unavailable:
      return  // Try again later; never mint over an unreadable record.
    case .absent:
      noteStored(nil)
      loaded = true
      foundNoRecord = true
      logoutBeforeLoad = false
      identifiedBeforeLoad = false
    case .found(let stored):
      noteStored(stored)
      loaded = true
      record = stored
      // What the app said while the record could not be read is applied to
      // it now, as if it had been read then. A logout ends the stored user,
      // its anonymous id and its session; a different user identified is a
      // missed logout, as identify() on a read record. Without this the
      // stored user came back at the unlock and the next person's events
      // went out under it.
      let differentUser =
        identifiedBeforeLoad && stored.userId != nil && stored.userId != userId
      if logoutBeforeLoad || differentUser {
        record.userId = nil
        record.anonymousId = nil
        record.session = nil
      } else if userId == nil {
        userId = stored.userId
      }
      logoutBeforeLoad = false
      identifiedBeforeLoad = false
      if record != stored { save() }
    }
  }

  /// The device and anonymous ids, minted LAZILY at the first permitted write.
  /// `nil` while the record is unreadable or the device id is not available
  /// yet — the caller holds the event rather than inventing an id.
  private func identity() -> (deviceId: String, anonymousId: String)? {
    guard consent.permitted else { return nil }
    loadIfPermitted()
    guard loaded else { return nil }
    var changed = false
    if record.deviceId == nil {
      guard let minted = deviceIds.deviceId() else { return nil }
      record.deviceId = minted.id
      record.deviceIdMode = minted.mode
      changed = true
    }
    if record.anonymousId == nil {
      record.anonymousId = randomId()
      changed = true
    }
    if let userId, record.userId != userId {
      record.userId = userId
      changed = true
    }
    if changed { save() }
    return (record.deviceId!, record.anonymousId!)
  }

  /// Keep the device id, rotate the anonymous id, end the session, forget the
  /// user. Nothing is minted for the session: the NEXT event opens it.
  private func resetIdentity() {
    identityCalls += 1
    userId = nil
    // The record has not been read — the store is unavailable, or consent
    // withholds reading it — so the logout is remembered and applied to the
    // record once it is.
    if !loaded {
      logoutBeforeLoad = true
      identifiedBeforeLoad = false
    }
    sessions.forget()
    assignments.forgetIdentity()
    // In memory first, whatever consent says: a grant after this must mint a
    // new anonymous id and open a new session, never reuse the last user's.
    record.userId = nil
    record.session = nil
    if consent.permitted, loaded {
      record.anonymousId = randomId()
      save()
      return
    }
    // Not permitted to write: forget the anonymous id (the next permitted
    // write mints one), and REMOVE what is stored that would put the next
    // person's events on this user. Removing is not writing.
    record.anonymousId = nil
    if case .found(var stored) = identityStore.load() {
      noteStored(stored)
      stored.userId = nil
      stored.anonymousId = nil
      stored.session = nil
      identityStore.save(stored)
    }
  }

  private func noteStored(_ stored: IdentityRecord?) {
    if storedUserRead { return }
    storedUserRead = true
    storedUserId = stored?.userId
    storedAnonymousId = stored?.anonymousId
  }

  /// Only a record that was READ may be written back. While the store is
  /// unavailable (a locked device) `record` is a blank stand-in, and saving it
  /// would replace the stored device and anonymous ids with nothing — a second
  /// identity for the same install once the device unlocks (D3). What changed
  /// meanwhile, a userId, is in memory and reaches the record at the next
  /// permitted write after the load.
  private func save() {
    guard loaded else { return }
    identityStore.save(record)
  }

  // MARK: - Upload outcomes

  private func scheduleFlush(after seconds: Double) {
    if cancelTimer != nil { return }
    cancelTimer = executor.after(seconds) { [self] in
      cancelTimer = nil
      flush()
    }
  }

  /// Exponential backoff with JITTER, so every device that queued through one
  /// outage does not retry on the same schedule into the recovery.
  private func backoffSeconds() -> Double {
    let exponential = min(
      options.flushIntervalSeconds * pow(2, Double(attempt)), TogoEngine.maxBackoffSeconds)
    return exponential * (0.5 + Double.random(in: 0..<0.5))
  }

  private func handle(_ response: TransportResponse, entries: [EventQueue.Entry]) {
    let ids = entries.map(\.event.eventId)
    func retry(_ seconds: Double) {
      // Back in the queue — unless `setConsent(.denied)` cleared it while the
      // upload was out, which `retryInFlight` sees for itself.
      queue.retryInFlight()
      guard consent.permitted else { return }
      attempt += 1
      if attempt <= TogoEngine.maxFlushAttempts { scheduleFlush(after: seconds) }
    }
    if let failure = response.failure {
      // A refusal no retry can change. Said, once, with the fix — a retry
      // loop would stay silent until the seven-day bound dropped every event
      // — and the queue is kept for a build that can reach the endpoint.
      queue.retryInFlight()
      disable(
        "events cannot be sent to \(options.endpoint.absoluteString): \(failure). No more events "
          + "will be sent until the app restarts; \(entries.count) queued event(s) are kept on this "
          + "device. An http:// endpoint needs an App Transport Security exception for its host in "
          + "the app's Info.plist; the default endpoint is https.", code: .endpointInvalid)
      return
    }
    guard let status = response.status else {
      // Offline is normal operation, so not an error: re-queue, retry later.
      retry(backoffSeconds())
      return
    }
    if status == 429 {
      retry(response.retryAfterSeconds.flatMap { $0 > 0 ? $0 : nil } ?? backoffSeconds())
      return
    }
    if status >= 500 {
      // EVERY 5xx, not only 503, and with the same eventIds so the edge
      // dedupes a batch that did land: the edge answers 500 when a failure is
      // above our code, and retrying only 503 would drop those events.
      retry(backoffSeconds())
      return
    }
    if status != 202, !(400..<500).contains(status) {
      // Not an answer from the edge, which only ever says 202, 4xx or 5xx: a
      // redirect (a custom endpoint behind http→https, a proxy that moved), a
      // captive portal's 200 with its own page, or something stranger. Never
      // read as delivered — that would drop the batch with no error anywhere,
      // and a portal would swallow the whole backlog behind it. Kept and
      // retried, and said once, since a retry only helps if the cause was
      // transient.
      if !warnedUnexpectedStatus {
        warnedUnexpectedStatus = true
        log(
          "the ingest endpoint answered \(status), not 202; \(entries.count) event(s) are kept and "
            + "retried. Point endpoint at the URL that answers, not one that redirects.")
      }
      retry(backoffSeconds())
      return
    }
    attempt = 0
    // Answered: delivered (202) or refused for good (413, another 4xx). Out
    // of the file. A 401 keeps them for the next launch, below.
    if status != 401 { queue.acknowledge() }
    if status == 401 {
      queue.retryInFlight()
      disable(
        "the write key was rejected (401). No more events will be captured until the app "
          + "restarts; \(entries.count) queued event(s) are kept on this device and retried then. "
          + "Check the key.", code: .writeKeyRejected)
      return
    }
    if status == 413 {
      report(
        .batchTooLarge,
        "the ingest endpoint refused a batch as too large (413); \(entries.count) event(s) dropped. "
          + "Usually one very large property value: check what you pass to track().", ids)
    } else if status >= 400 {
      report(
        .batchRejected,
        "a batch was rejected (\(status)); \(entries.count) event(s) dropped. A bug in sdk-ios, "
          + "not in your code.", ids)
    } else {
      surfaceRejections(response.body, entries: entries)
    }
    // Whatever the answer, the rest of the backlog goes next. flush()
    // cancelled the pending timer when it started, and a timer that fired
    // while this upload was out found it in flight and did nothing, so nothing
    // else will: without this, what is left waits for the app's next call,
    // which after a background launch can be days — past the seven-day bound.
    if queue.count > 0 { scheduleFlush(after: 0) }
  }

  /// The per-event refusals a 202 can carry. These events are GONE (refused, never held for later),
  /// and `track()` never throws, so this is the only notice anyone gets.
  private func surfaceRejections(_ body: Data?, entries: [EventQueue.Entry]) {
    guard let body, let json = try? JSONValue.parse(body),
      let rejected = json["rejected"]?.arrayValue
    else { return }
    for item in rejected {
      guard let eventId = item["eventId"]?.stringValue, let reason = item["reason"]?.stringValue
      else { continue }
      let name = entries.first { $0.event.eventId == eventId }?.event.eventName
      report(
        TogoErrorCode(rawValue: reason),
        "\"\(name ?? "?")\" was rejected (\(reason)): "
          + "https://togohq.ai/docs/reference/event-diagnostics#\(reason)", [eventId], name)
    }
  }

  /// Log, then tell `onError` — after the call that caused it returns, on the
  /// callback executor, so a handler that calls back into the SDK cannot
  /// deadlock it.
  private func report(
    _ code: TogoErrorCode, _ message: String, _ eventIds: [String] = [], _ eventName: String? = nil,
    _ property: String? = nil
  ) {
    log(message)
    guard let onError = options.onError else { return }
    let error = TogoError(
      code: code, message: message, eventIds: eventIds, eventName: eventName, property: property)
    callbacks.async { onError(error) }
  }
}
