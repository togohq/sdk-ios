import Foundation
import XCTest

@testable import TogoCore

/// A client wired to fakes: a clock the test moves, a network the test
/// answers, work run inline, timers recorded rather than fired.
final class Harness: @unchecked Sendable {
  final class Clock: TogoClock, @unchecked Sendable {
    var wall: Int64 = 1_792_584_000_000  // 2026-10-21T12:00:00.000Z
    var monotonic: Int64 = 50_000
    func wallMs() -> Int64 { wall }
    func monotonicMs() -> Int64 { monotonic }
    /// Time passing on a device nobody touched: both clocks move.
    func advance(_ ms: Int64) {
      wall += ms
      monotonic += ms
    }
  }

  final class Network: TogoTransport, @unchecked Sendable {
    /// Answers in order; once used up, every upload is a 202.
    var answers: [TransportResponse] = []
    var sent: [JSONValue] = []
    var urls: [URL] = []
    var keys: [String] = []
    /// Uploads go out and are not answered until `answer(_:)` — or never, when
    /// the process is killed first.
    var holds = false
    var held: [@Sendable (TransportResponse) -> Void] = []

    func answer(_ response: TransportResponse = TransportResponse(status: 202, body: Data("{}".utf8))) {
      held.removeFirst()(response)
    }

    func post(
      url: URL, writeKey: String, body: Data,
      completion: @escaping @Sendable (TransportResponse) -> Void
    ) {
      sent.append(try! JSONValue.parse(body))
      urls.append(url)
      keys.append(writeKey)
      if holds {
        held.append(completion)
        return
      }
      completion(answers.isEmpty ? TransportResponse(status: 202, body: Data("{}".utf8)) : answers.removeFirst())
    }

    var events: [JSONValue] { sent.flatMap { $0["events"]!.arrayValue! } }
    var names: [String] { events.map { $0["eventName"]!.stringValue! } }
  }

  final class Executor: TogoExecutor, @unchecked Sendable {
    var timers: [Double] = []
    func async(_ work: @escaping @Sendable () -> Void) { work() }
    func after(_ seconds: Double, _ work: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
      timers.append(seconds)
      return {}
    }
  }

  final class Sink: @unchecked Sendable {
    var logs: [String] = []
    var errors: [TogoError] = []
  }

  let clock = Clock()
  let network = Network()
  let executor = Executor()
  let sink = Sink()
  let identity: MemoryIdentityStore
  /// What the engine reads: `identity`, unless a test passes a file store.
  let identityStore: IdentityStore
  let queueStore: MemoryQueueStore
  let deviceIds: DeviceIdProvider
  /// The lifecycle of the current process when the harness drives one: the
  /// engine then sees a human only while a scene is in front, as on a device.
  /// `nil` is phase 3's client, which always does.
  private(set) var lifecycle: AppLifecycle?
  let drivesLifecycle: Bool
  private(set) var engine: TogoEngine!
  var options: EngineOptions

  init(
    writeKey: String = "togo_pkl_live0000000000",
    consent: TogoConsent = .notRequired,
    sessionTimeoutSeconds: Double? = nil,
    defaultProperties: TogoProperties? = nil,
    app: AppInfo? = AppInfo(version: "1.2.0", build: "12"),
    device: DeviceInfo? = DeviceInfo(os: "iOS", osVersion: "18.1", model: "iPhone16,1", deviceType: "mobile"),
    identity: MemoryIdentityStore = MemoryIdentityStore(),
    identityStore: IdentityStore? = nil,
    queueStore: MemoryQueueStore = MemoryQueueStore(),
    deviceIds: DeviceIdProvider = GeneratedDeviceIdProvider(),
    lifecycle: Bool = false,
    foregroundAtLaunch: Set<String> = []
  ) {
    self.identity = identity
    self.identityStore = identityStore ?? identity
    self.queueStore = queueStore
    self.deviceIds = deviceIds
    drivesLifecycle = lifecycle
    let sink = self.sink
    options = EngineOptions(
      writeKey: writeKey, endpoint: URL(string: "https://in.example.test")!,
      sessionTimeoutSeconds: sessionTimeoutSeconds, consent: consent,
      defaultProperties: defaultProperties, app: app, device: device, timezone: "Europe/Berlin",
      onError: { sink.errors.append($0) })
    start(foreground: foregroundAtLaunch)
  }

  /// A new process over the same stores: the app was killed and relaunched.
  /// With a lifecycle, the launch is the adapter's — `foreground` names the
  /// scenes already in front when the SDK starts (a late `setup()`).
  @discardableResult
  func start(foreground: Set<String> = []) -> TogoEngine {
    let sink = self.sink
    let lifecycle = drivesLifecycle ? AppLifecycle() : nil
    engine = TogoEngine(
      options: options, identityStore: identityStore, deviceIds: deviceIds, queueStore: queueStore,
      transport: network, executor: executor, callbacks: executor, clock: clock,
      log: { sink.logs.append($0) },
      humanPresent: { lifecycle?.isForeground ?? true })
    self.lifecycle = lifecycle
    lifecycle?.launched(engine, foregroundScenes: foreground)
    return engine
  }

  /// A relaunch of a new build of the app: same stores, new bundle numbers.
  @discardableResult
  func relaunch(version: String?, build: String?, foreground: Set<String> = []) -> TogoEngine {
    options.app = AppInfo(version: version, build: build)
    return start(foreground: foreground)
  }

  func foreground(_ scene: String = "main") { lifecycle!.sceneForegrounded(scene) }
  func background(_ scene: String = "main") { lifecycle!.sceneBackgrounded(scene) }

  func flush() { engine.flush() }

  /// Flush until nothing more goes: a backlog that spans two app builds is two
  /// batches, and the harness never fires the timer that sends the second.
  func flushAll() {
    while true {
      let before = network.sent.count
      engine.flush()
      if network.sent.count == before { return }
    }
  }
}
