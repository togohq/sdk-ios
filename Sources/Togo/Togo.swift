import Foundation
import TogoCore

#if canImport(UIKit) && !os(watchOS)
  import UIKit
#endif

/// The Togo AI iOS SDK: the same surface as the web and server SDKs, in Swift.
///
/// ```swift
/// #if DEBUG
///   let key = "togo_pkt_…"  // test key: verify_tracking sees the simulator
/// #else
///   let key = "togo_pkl_…"
/// #endif
/// Togo.setup(TogoConfig(writeKey: key))
/// Togo.track("plan_selected", properties: ["plan_id": "pro"])
/// ```
///
/// **Every method can be called from any thread and never blocks on the
/// network.** Calls are queued, in order, onto one serial queue that owns the
/// SDK's state; the getters wait only for the calls made before them. No
/// method throws: a refusal is a `[togo]` log line and an `onError` call.
public enum Togo {
  private static let shared = SharedClient()

  /// Configure the SDK, once, as early as possible — in `App.init` or
  /// `application(_:didFinishLaunchingWithOptions:)`, before a consent decision
  /// exists if need be (`consent: .pending`). Stores nothing and sends nothing
  /// until consent permits. It sends the launch's `$app_installed` or
  /// `$app_updated`, and never starts a session: the app coming to the
  /// foreground does, with `$app_opened`.
  public static func setup(_ config: TogoConfig) {
    shared.setup(config)
  }

  /// Send an event: `Togo.track("Sign Up", properties: ["plan": "pro"])`. The
  /// name is stored as given and becomes queryable by its registry key. A name
  /// starting with `$` is Togo's and is refused (sent under a test key, so
  /// `verify_tracking` reports it). A property key starting with `$` is dropped
  /// under a live key, with a log.
  public static func track(_ eventName: String, properties: TogoProperties = [:]) {
    shared.client { $0.track(eventName, properties: properties) }
  }

  /// The signed-in user: your opaque account id, never an email address. Call
  /// it at login; the same id again does nothing, and a different one first
  /// does what `reset()` does.
  public static func identify(_ userId: String) {
    shared.client { $0.identify(userId) }
  }

  /// Update the person's profile: `email` and `name` are Togo's typed
  /// fields; `set`, `setOnce` and `unset` take your own keys.
  public static func setPersonProperties(_ update: PersonPropertyUpdate) {
    shared.client { $0.setPersonProperties(update) }
  }

  /// Convenience for the common case.
  public static func setPersonProperties(
    email: String?? = nil, name: String?? = nil, set: TogoProperties? = nil,
    setOnce: TogoProperties? = nil, unset: [String]? = nil
  ) {
    setPersonProperties(
      PersonPropertyUpdate(email: email, name: name, set: set, setOnce: setOnce, unset: unset))
  }

  /// Call at logout. A new anonymous visitor and a new session on this device;
  /// the device id stays.
  public static func reset() {
    shared.client { $0.reset() }
  }

  /// Set the consent state. Idempotent, callable at any time. `.granted` after
  /// `.pending` sends what was held; `.denied` deletes what is stored.
  public static func setConsent(_ consent: TogoConsent) {
    shared.client { $0.setConsent(consent) }
  }

  public static func getConsent() -> TogoConsent {
    shared.read(default: .notRequired) { $0.consent }
  }

  /// Read-only, never mints: `nil` before the first event consent permits.
  public static func getAnonymousId() -> String? {
    shared.read(default: nil) { $0.anonymousId }
  }

  public static func getDeviceId() -> String? {
    shared.read(default: nil) { $0.deviceId }
  }

  /// Read-only, never mints: `nil` when there is no session.
  public static func getSessionId() -> String? {
    shared.read(default: nil) { $0.sessionId }
  }

  /// Send what is queued now. `completion` runs after the attempt, off the
  /// SDK's queue, so it may call any `Togo` method; a failure stays queued and
  /// is retried.
  public static func flush(completion: (@Sendable () -> Void)? = nil) {
    shared.flush(completion: completion)
  }
}

/// What the client stores to and listens to. `nil` at `setup()` is the
/// device's own (`DeviceEnvironment.current`); a test passes `.memory()`.
struct DeviceEnvironment {
  var identityStore: IdentityStore
  var queueStore: QueueStore
  var deviceIds: DeviceIdProvider
  /// Reports the app's lifecycle — `AppLifecycle` driven by the UIKit adapter.
  /// Without it — AppKit macOS, a test — there are no lifecycle events, and every event
  /// may open a session.
  var reportsLifecycle: Bool
  /// Starts what sends the lifecycle's signals into the sink: UIKit's
  /// notifications, through `UIKitAdapter`. Called once, AFTER `setup()` has
  /// released its lock, since it may signal at once and on the same thread.
  /// `nil` in a test that drives `lifecycleSink()` itself.
  var observe: (@Sendable (LifecycleSink) -> Void)?

  /// Memory stores and a generated id, and no lifecycle: the rest of the
  /// surface, testable on any platform.
  static func memory(
    identity: IdentityStore = MemoryIdentityStore(), queue: QueueStore = MemoryQueueStore(),
    deviceIds: DeviceIdProvider = GeneratedDeviceIdProvider(), reportsLifecycle: Bool = false
  ) -> DeviceEnvironment {
    DeviceEnvironment(
      identityStore: identity, queueStore: queue, deviceIds: deviceIds,
      reportsLifecycle: reportsLifecycle)
  }
}

/// The one client behind `Togo`: an engine confined to a serial queue.
final class SharedClient: @unchecked Sendable {
  private let lock = NSLock()
  private var engine: TogoEngine?
  private var executor: DispatchExecutor?
  private var callbacks: TogoExecutor?
  private var warnedNotSetUp = false
  private var warnedServer = false
  private var inert = false
  /// The lifecycle the UIKit adapter drives; confined to the SDK's queue.
  private var lifecycle: AppLifecycle?
  /// Kept alive for the process: it owns the notification observers.
  private var adapter: AnyObject?
  let protectedData = ProtectedDataState(available: !SharedClient.onUIKitDevice)
  let log: TogoLogger

  static var onUIKitDevice: Bool {
    #if canImport(UIKit) && !os(watchOS)
      return true
    #else
      return false
    #endif
  }

  init(log: @escaping TogoLogger = standardErrorLogger) { self.log = log }

  func setup(
    _ config: TogoConfig, transport: TogoTransport = URLSessionTransport(),
    device: DeviceEnvironment? = nil,
    callbacks: TogoExecutor = DispatchExecutor(label: "ai.togohq.sdk.callbacks"),
    serverRuntime: String? = Platform.serverRuntime()
  ) {
    lock.lock()
    let observe = configure(
      config, transport: transport, device: device, callbacks: callbacks,
      serverRuntime: serverRuntime)
    lock.unlock()
    // Outside the lock: the adapter signals into the sink at once when it
    // starts — on the main thread, the thread `setup()` usually runs on — and
    // the sink takes this lock. Inside it, an app's first launch hung on a
    // blank screen (found on the simulator, 2026-11-19).
    observe?(lifecycleSink())
  }

  /// Everything `setup()` does under the lock. Returns what starts the
  /// lifecycle's signals, when there is one.
  private func configure(
    _ config: TogoConfig, transport: TogoTransport, device: DeviceEnvironment?,
    callbacks: TogoExecutor, serverRuntime: String?
  ) -> (@Sendable (LifecycleSink) -> Void)? {
    if engine != nil || inert {
      log("Togo.setup() was called again and ignored: the first configuration stands.")
      return nil
    }
    // Before anything is created, stored or scheduled, a device SDK on a server
    // disables itself: inert, with one warning, never a throw.
    if let server = serverRuntime {
      inert = true
      if !warnedServer {
        warnedServer = true
        log(
          "sdk-ios is running on a server (\(server)) and is disabled here: nothing is stored or "
            + "sent. A server handles many people, and this SDK remembers one. To send events from "
            + "server code, use @togohq/sdk-node or the HTTP API, which take the user on each call.")
      }
      return nil
    }
    let executor = DispatchExecutor()
    var options = EngineOptions(
      writeKey: config.writeKey, endpoint: config.endpoint,
      sessionTimeoutSeconds: config.sessionTimeout, consent: config.consent,
      consentBufferMaxEvents: config.consentBufferMaxEvents,
      defaultProperties: config.defaultProperties,
      app: Platform.app(version: config.appVersion, build: config.appBuild),
      device: Platform.device(), timezone: Platform.timezone(), onError: config.onError)
    if let wrapper = config.wrapper {
      if let sdk = SdkIdentity(wrapperName: wrapper.name, version: wrapper.version) {
        options.sdk = sdk
      } else {
        log(
          "Togo.setup() was given a wrapper name or version the server would not read (a name is "
            + "one of \(Wire.wrapperSdkNames.joined(separator: ", ")); a version is 1 to "
            + "\(Wire.maxSdkVersionLength) characters with no spaces), so events name \(SDK_NAME) instead.")
      }
    }
    let log = self.log
    let environment = device ?? currentDevice(executor: executor)
    let problem = writeKeyProblem(config.writeKey)
    let lifecycle = environment.reportsLifecycle ? AppLifecycle() : nil
    let foregroundScenes = environment.observe != nil ? seedForeground() : []
    executor.queue.sync {
      let engine = TogoEngine(
        options: options, identityStore: environment.identityStore,
        deviceIds: environment.deviceIds, queueStore: environment.queueStore,
        transport: transport, executor: executor, callbacks: callbacks, log: log,
        humanPresent: { lifecycle?.isForeground ?? true })
      // A malformed key is a typo or an unsubstituted build setting: the
      // client is inert with one error that says why, never a crash.
      if let problem { engine.disable(problem, code: .writeKeyInvalid) }
      // The launch: owes `$app_installed`/`$app_updated`, opens no session
      // unless a scene is already in front (a prewarmed launch is not an open).
      lifecycle?.launched(engine, foregroundScenes: foregroundScenes)
      self.engine = engine
    }
    self.executor = executor
    self.callbacks = callbacks
    self.lifecycle = lifecycle
    return lifecycle == nil ? nil : environment.observe
  }

  // MARK: - The device

  /// The device's own stores: the two files (D3) and, under UIKit, the IDFV
  /// (D1) and the lifecycle. Elsewhere — AppKit macOS, which has no adapter
  /// yet — a generated id with mode `install` and no lifecycle events.
  private func currentDevice(executor: DispatchExecutor) -> DeviceEnvironment {
    let protectedData = self.protectedData
    let identity = FileIdentityStore(
      url: Platform.identityURL(), protectedDataAvailable: { protectedData.value },
      scheduler: executor, log: log)
    let queue = FileQueueStore(url: Platform.queueURL())
    #if canImport(UIKit) && !os(watchOS)
      let idfv = IdfvProvider()
      idfv.onRead = { [weak self] in self?.identityBecameAvailable() }
      return DeviceEnvironment(
        identityStore: identity, queueStore: queue, deviceIds: idfv, reportsLifecycle: true,
        observe: { [weak self] sink in self?.startAdapter(sink) })
    #else
      return DeviceEnvironment(
        identityStore: identity, queueStore: queue, deviceIds: GeneratedDeviceIdProvider(),
        reportsLifecycle: false)
    #endif
  }

  /// The scenes already in front, read now when `setup()` runs on the main
  /// thread — as it does from `App.init` or `didFinishLaunching`. Off it, the
  /// adapter reads them on the main thread a moment later and forwards them as
  /// notifications would. Protected data is NOT read here: this early in a
  /// launch UIKit says it is unavailable on an unlocked device
  /// (`UIKitAdapter.refreshProtectedData`).
  private func seedForeground() -> Set<String> {
    #if canImport(UIKit) && !os(watchOS)
      guard Thread.isMainThread else { return [] }
      return MainActor.assumeIsolated {
        UIKitAdapter.foregroundScenes(usesScenes: UIKitAdapter.usesScenes)
      }
    #else
      return []
    #endif
  }

  private func startAdapter(_ sink: LifecycleSink) {
    #if canImport(UIKit) && !os(watchOS)
      let protectedData = self.protectedData
      let wasOnMain = Thread.isMainThread
      let install: @MainActor @Sendable () -> Void = { [self] in
        let adapter = UIKitAdapter(sink: sink, protectedData: protectedData)
        keep(adapter)
        adapter.start(usesScenes: UIKitAdapter.usesScenes)
        if !wasOnMain {
          // Set up off the main thread: read now the scenes a main-thread
          // setup read before the engine started.
          UIKitAdapter.foregroundScenes(usesScenes: UIKitAdapter.usesScenes).forEach(sink.foreground)
        }
      }
      if wasOnMain {
        MainActor.assumeIsolated { install() }
      } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { install() } }
      }
    #endif
  }

  private func keep(_ adapter: AnyObject) {
    lock.lock()
    self.adapter = adapter
    lock.unlock()
  }

  /// The adapter's signals, onto the SDK's queue in the order they happened.
  func lifecycleSink() -> LifecycleSink {
    LifecycleSink(
      foreground: { [weak self] scene in self?.onLifecycle { $0.sceneForegrounded(scene) } },
      background: { [weak self] scene, completion in
        guard let self else { return completion() }
        if !onLifecycle({ $0.sceneBackgrounded(scene, completion: completion) }) { completion() }
      },
      protectedDataAvailable: { [weak self] in self?.identityBecameAvailable() })
  }

  /// Runs `work` on the SDK's queue. `false` when there is no lifecycle — a
  /// server, a disabled setup — so the caller can finish what it began.
  @discardableResult
  private func onLifecycle(_ work: @escaping @Sendable (AppLifecycle) -> Void) -> Bool {
    lock.lock()
    let lifecycle = lifecycle
    let executor = executor
    lock.unlock()
    guard let lifecycle, let executor else { return false }
    executor.queue.async { work(lifecycle) }
    return true
  }

  func identityBecameAvailable() {
    client { $0.identityBecameAvailable() }
  }

  /// Run `work` on the SDK's queue, in call order. Before `setup()` the call
  /// is dropped with one log line, since there is no key to send it under.
  func client(_ work: @escaping @Sendable (TogoEngine) -> Void) {
    lock.lock()
    let engine = engine
    let executor = executor
    let inert = inert
    var warn = false
    if engine == nil, !inert, !warnedNotSetUp {
      warnedNotSetUp = true
      warn = true
    }
    lock.unlock()
    if warn { log("a call was made before Togo.setup() and was dropped. Call setup() first.") }
    guard let engine, let executor else { return }
    executor.queue.async { work(engine) }
  }

  /// A getter: waits for the calls queued before it, never for the network.
  func read<T: Sendable>(default fallback: T, _ value: @Sendable (TogoEngine) -> T) -> T {
    lock.lock()
    let engine = engine
    let executor = executor
    lock.unlock()
    guard let engine, let executor else { return fallback }
    // Already on the SDK's queue — an `onError` or completion an app routed
    // back onto it — a `sync` would trap; the state is ours to read here.
    if executor.isCurrent { return value(engine) }
    return executor.queue.sync { value(engine) }
  }

  func flush(completion: (@Sendable () -> Void)?) {
    lock.lock()
    let engine = engine
    let executor = executor
    let callbacks = callbacks
    lock.unlock()
    guard let engine, let executor, let callbacks else {
      completion?()
      return
    }
    // The engine finishes on its own queue; the app's completion runs on the
    // callback queue, where calling a getter (a `queue.sync`) is safe.
    var done: (@Sendable () -> Void)?
    if let completion {
      done = { callbacks.async(completion) }
    }
    let finish = done
    executor.queue.async { engine.flush(completion: finish) }
  }
}
