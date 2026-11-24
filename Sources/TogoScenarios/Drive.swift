import Foundation
import TogoCore

/// Perform planned visitors through the core, and record what each device
/// would upload. A port of the browser SDK's scenario driver (`drive.mjs`) in
/// its record mode, and the same two phases, because the edge dates an event by
/// the device clock corrected at upload:
///
/// 1. **Offline.** Every step runs at its planned time on a virtual clock with
///    the network held — an upload answers as offline, which the SDK re-queues
///    — and the flush timer never fires, so events accumulate with their real
///    `clientEventTs`.
/// 2. **Release.** The clock reads now, the network opens, and every device
///    flushes; each upload is answered 202 and recorded. A `flush` step is the
///    same release for one device, mid-scenario.
///
/// **A `server` step is skipped.** It is what a real product sends from its
/// backend, through `@togohq/sdk-node` — never through a device SDK — so a
/// device SDK replays the device steps only.
public enum ScenarioDriver {
  public static let goldenNowMs: Int64 = 1_792_584_000_000  // 2026-10-21T12:00:00.000Z
  public static let goldenSeed: UInt32 = 1
  public static let goldenRunId = "golden"
  /// Every device's zone, pinned as the browser runner pins it.
  public static let siteTimezone = "America/New_York"
  static let writeKey = "togo_pkt_scenarioRecordingKey00"
  static let endpoint = URL(string: "https://in.example.test")!
  /// One upload per device, as in the browser runner.
  static let maxEventsPerDevice = 500
  /// The app and device every recording device reports. Not in the browser's
  /// goldens, so the comparison removes them (`Projection`).
  public static let app = AppInfo(version: "1.4.0", build: "140")
  public static let device = DeviceInfo(
    os: "iOS", osVersion: "18.1", model: "iPhone16,1", deviceType: "mobile")

  public struct Upload: Sendable {
    public var client: String
    public var body: JSONValue
    /// What the edge answered, when the upload went to a real one (`sendNative`).
    public var status: Int? = nil
    public var response: JSONValue? = nil
  }

  /// One scenario's batches under the golden clock and seed, normalized.
  public static func record(_ name: String, root: URL = ScenarioFormat.defaultRoot) throws
    -> [Upload]
  {
    let scenario = try ScenarioFormat.loadScenario(name, root: root)
    let plan = ScenarioFormat.planVisitor(
      scenario, seed: goldenSeed, n: 1, nowMs: goldenNowMs, runId: goldenRunId)
    return Normalize.placeholders(drive([plan], nowMs: goldenNowMs))
  }

  /// The raw uploads, in the order each device first appeared.
  static func drive(_ plans: [Plan], nowMs: Int64) -> [Upload] {
    let clock = VirtualClock(at: nowMs)
    let network = HeldNetwork()
    let executor = InlineExecutor()
    var clients: [(label: String, engine: TogoEngine, skew: Int64)] = []

    func upload(_ entry: (label: String, engine: TogoEngine, skew: Int64)) {
      let saved = (clock.at, clock.skew)
      network.released = true
      network.label = entry.label
      clock.at = nowMs
      clock.skew = entry.skew
      // One upload per call; a second only for a batch the SDK itself cut.
      for _ in 0..<4 {
        let before = network.sent.count
        entry.engine.flush()
        if network.sent.count == before { break }
      }
      (clock.at, clock.skew) = saved
      network.released = false
    }

    for plan in plans {
      var own: [String: Int] = [:]
      for item in plan.ordered where item.actor != "server" {
        clock.at = item.timeMs
        clock.skew = plan.deviceClockOffsetMs
        let device = item.device ?? "browser"
        let index: Int
        if let existing = own[device] {
          index = existing
        } else {
          var options = EngineOptions(
            writeKey: writeKey, endpoint: endpoint,
            sessionTimeoutSeconds: plan.initOptions["sessionTimeoutSeconds"].flatMap(doubleValue),
            consent: plan.initOptions["consent"]?.stringValue.flatMap { TogoConsent(rawValue: $0) }
              ?? .notRequired,
            defaultProperties: properties(plan.initOptions["defaultProperties"]),
            app: app, device: Self.device,
            timezone: siteTimezone)
          options.batchSize = maxEventsPerDevice
          options.flushIntervalSeconds = 86_400
          let engine = TogoEngine(
            options: options, transport: network, executor: executor, callbacks: executor,
            clock: clock, log: { _ in })
          index = clients.count
          clients.append(("\(plan.scenario)#\(plan.n):\(device)", engine, plan.deviceClockOffsetMs))
          own[device] = index
        }
        let engine = clients[index].engine
        let call = item.call
        if let name = call["track"]?.stringValue {
          engine.track(name, properties: properties(call["properties"]) ?? [:])
        } else if let userId = call["identify"]?.stringValue {
          engine.identify(userId)
        } else if let ops = call["setPersonProperties"] {
          engine.setPersonProperties(personUpdate(ops))
        } else if let state = call["setConsent"]?.stringValue, let consent = TogoConsent(rawValue: state) {
          engine.setConsent(consent)
        } else if call["reset"] != nil {
          engine.reset()
        } else if call["flush"] != nil {
          upload(clients[index])
        }
      }
    }
    for entry in clients { upload(entry) }
    return network.sent
  }

  // MARK: - Native scenarios

  /// One native scenario's batches under the golden clock and seed,
  /// normalized: what `expected-native/` holds. Unlike `record`, nothing is
  /// projected away — this runner is the one that records these goldens.
  public static func recordNative(_ name: String, root: URL = ScenarioFormat.defaultRoot) throws
    -> [Upload]
  {
    let scenario = try ScenarioFormat.loadNativeScenario(name, root: root)
    let plan = ScenarioFormat.planVisitor(
      scenario, seed: goldenSeed, n: 1, nowMs: goldenNowMs, runId: goldenRunId)
    return Normalize.placeholders(driveNative(plan, nowMs: goldenNowMs))
  }

  /// One native scenario performed through the core and uploaded to a REAL
  /// edge at `endpoint` — the stage journey's sender. The same two phases as a
  /// recording: every step at its planned time on a virtual clock with the
  /// network held, so each event keeps its real `clientEventTs`, then the clock
  /// reads now and the device uploads, so the edge's skew correction lands each
  /// event in the past it happened in (inside the seven-day clamp: the planner
  /// places a visit within the last six and a half days). Nothing is
  /// normalized: the batches are as sent, with the edge's answers.
  public static func sendNative(
    _ name: String, endpoint: URL, writeKey: String, nowMs: Int64, runId: String,
    transport: TogoTransport = URLSessionTransport(), root: URL = ScenarioFormat.defaultRoot
  ) throws -> [Upload] {
    let scenario = try ScenarioFormat.loadNativeScenario(name, root: root)
    let plan = ScenarioFormat.planVisitor(
      scenario, seed: goldenSeed, n: 1, nowMs: nowMs, runId: runId)
    let network = HeldNetwork()
    network.forward = transport
    return driveNative(plan, nowMs: nowMs, network: network, writeKey: writeKey, endpoint: endpoint)
  }

  /// One app on one device, through its launches. A `launch` is a new process
  /// over the same identity and queue stores — the last one was killed, with no
  /// callback, as iOS kills a suspended app — with the build the step names.
  /// The lifecycle is the core's `AppLifecycle`, driven as the UIKit adapter
  /// drives it. The network is held until the end, as for the device scenarios,
  /// so the background flushes fail like an offline phone's and every event is
  /// uploaded at the end with its real `clientEventTs`.
  static func driveNative(
    _ plan: Plan, nowMs: Int64, network: HeldNetwork = HeldNetwork(),
    writeKey: String = ScenarioDriver.writeKey, endpoint: URL = ScenarioDriver.endpoint
  ) -> [Upload] {
    let clock = VirtualClock(at: nowMs)
    clock.skew = plan.deviceClockOffsetMs
    network.label = "\(plan.scenario)#\(plan.n):app"
    let executor = InlineExecutor()
    let identity = MemoryIdentityStore()
    let queue = MemoryQueueStore()
    let deviceIds = FixedIdfv()
    var engine: TogoEngine?
    var lifecycle: AppLifecycle?

    for item in plan.ordered {
      clock.at = item.timeMs
      let call = item.call
      if let launch = call["launch"] {
        var options = EngineOptions(
          writeKey: writeKey, endpoint: endpoint,
          sessionTimeoutSeconds: plan.initOptions["sessionTimeoutSeconds"].flatMap(doubleValue),
          consent: plan.initOptions["consent"]?.stringValue.flatMap { TogoConsent(rawValue: $0) }
            ?? .notRequired,
          defaultProperties: properties(plan.initOptions["defaultProperties"]),
          app: AppInfo(version: launch["appVersion"]?.stringValue, build: launch["appBuild"]?.stringValue),
          device: device, timezone: siteTimezone)
        options.batchSize = maxEventsPerDevice
        options.flushIntervalSeconds = 86_400
        let next = AppLifecycle()
        let started = TogoEngine(
          options: options, identityStore: identity, deviceIds: deviceIds, queueStore: queue,
          transport: network, executor: executor, callbacks: executor, clock: clock, log: { _ in },
          humanPresent: { next.isForeground })
        next.launched(started)
        (engine, lifecycle) = (started, next)
        continue
      }
      guard let engine, let lifecycle else { continue }  // The loader requires a launch first.
      if let scene = call["foreground"]?.stringValue {
        lifecycle.sceneForegrounded(scene)
      } else if let scene = call["background"]?.stringValue {
        lifecycle.sceneBackgrounded(scene)
      } else if let name = call["track"]?.stringValue {
        engine.track(name, properties: properties(call["properties"]) ?? [:])
      } else if let userId = call["identify"]?.stringValue {
        engine.identify(userId)
      } else if let ops = call["setPersonProperties"] {
        engine.setPersonProperties(personUpdate(ops))
      } else if let state = call["setConsent"]?.stringValue, let consent = TogoConsent(rawValue: state) {
        engine.setConsent(consent)
      } else if call["reset"] != nil {
        engine.reset()
      } else if call["flush"] != nil {
        release(engine, network: network, clock: clock, nowMs: nowMs)
      }
    }
    if let engine { release(engine, network: network, clock: clock, nowMs: nowMs) }
    return network.sent
  }

  /// Every batch the device holds, at `now`: one per app build, since a batch
  /// never mixes two.
  static func release(_ engine: TogoEngine, network: HeldNetwork, clock: VirtualClock, nowMs: Int64) {
    let saved = clock.at
    network.released = true
    clock.at = nowMs
    for _ in 0..<20 {
      let before = network.sent.count
      engine.flush()
      if network.sent.count == before { break }
      // A real edge that refused or did not answer is the run's answer: retrying
      // would only resend the same batch, each try waiting out the timeout, and
      // bury the status the caller needs under twenty of them.
      if network.forward != nil, !(200..<300).contains(network.sent.last?.status ?? 0) { break }
    }
    clock.at = saved
    network.released = false
  }

  static func doubleValue(_ value: JSONValue) -> Double? {
    switch value {
    case .int(let number): return Double(number)
    case .double(let number): return number
    default: return nil
    }
  }

  static func properties(_ value: JSONValue?) -> TogoProperties? {
    guard let object = value?.objectValue else { return nil }
    return object.compactMapValues { json -> TogoValue? in
      switch json {
      case .string(let text): return .string(text)
      case .int(let number): return .int(Int(number))
      case .double(let number): return .double(number)
      case .bool(let flag): return .bool(flag)
      case .null: return .null
      default: return nil
      }
    }
  }

  static func personUpdate(_ ops: JSONValue) -> PersonPropertyUpdate {
    func optional(_ key: String) -> String?? {
      guard let value = ops[key] else { return nil }
      if case .null = value { return .some(nil) }
      return .some(value.stringValue)
    }
    return PersonPropertyUpdate(
      email: optional("email"), name: optional("name"), set: properties(ops["set"]),
      setOnce: properties(ops["setOnce"]),
      unset: ops["unset"]?.arrayValue?.compactMap(\.stringValue))
  }
}

/// The device clock: the step's planned time plus the scenario's skew. The
/// monotonic clock moves with it, so idle time within the run is the same on
/// both, as it is on a device whose wall clock nobody touched.
final class VirtualClock: TogoClock, @unchecked Sendable {
  var at: Int64
  var skew: Int64 = 0

  init(at: Int64) { self.at = at }

  func wallMs() -> Int64 { at + skew }
  func monotonicMs() -> Int64 { at + skew }
}

/// Offline until released; then every upload is recorded and answered 202 —
/// or, with `forward` set, sent there and answered with what it answered.
/// Forwarding WAITS for the answer, so the run stays single-threaded: the
/// engine sees its upload finish before `post` returns, as with the fake.
final class HeldNetwork: TogoTransport, @unchecked Sendable {
  var released = false
  var label = ""
  var sent: [ScenarioDriver.Upload] = []
  var forward: TogoTransport?

  func post(
    url: URL, writeKey: String, body: Data,
    completion: @escaping @Sendable (TransportResponse) -> Void
  ) {
    guard released, let json = try? JSONValue.parse(body) else {
      completion(TransportResponse(status: nil))
      return
    }
    if let forward {
      let done = DispatchSemaphore(value: 0)
      let answer = Answer()
      forward.post(url: url, writeKey: writeKey, body: body) { response in
        answer.value = response
        done.signal()
      }
      done.wait()
      let response = answer.value ?? TransportResponse(status: nil)
      sent.append(
        .init(
          client: label, body: json, status: response.status,
          response: response.body.flatMap { try? JSONValue.parse($0) }))
      completion(response)
      return
    }
    sent.append(.init(client: label, body: json))
    let count = json["events"]?.arrayValue?.count ?? 0
    completion(TransportResponse(status: 202, body: Data("{\"accepted\":\(count)}".utf8)))
  }
}

/// The answer a forwarded upload got, handed from URLSession's queue to the
/// waiting caller (the semaphore orders the two).
final class Answer: @unchecked Sendable {
  var value: TransportResponse?
}

/// Runs work at once, on the caller's thread; a timer never fires. The run is
/// single-threaded, and its uploads happen only where the scenario says.
final class InlineExecutor: TogoExecutor, @unchecked Sendable {
  func async(_ work: @escaping @Sendable () -> Void) { work() }
  func after(_ seconds: Double, _ work: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
    {}
  }
}

/// The IDFV, as a device with one reports it: one value, mode `idfv`. The
/// placeholders hide the value; the mode is what the golden records.
final class FixedIdfv: DeviceIdProvider, @unchecked Sendable {
  let id = randomId()
  func deviceId() -> (id: String, mode: String)? { (id, "idfv") }
}
