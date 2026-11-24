import Foundation
import TogoCore
import XCTest

@testable import Togo

final class TogoTests: XCTestCase {
  final class Network: TogoTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [JSONValue] = []
    func post(
      url: URL, writeKey: String, body: Data,
      completion: @escaping @Sendable (TransportResponse) -> Void
    ) {
      lock.lock()
      bodies.append(try! JSONValue.parse(body))
      lock.unlock()
      completion(TransportResponse(status: 202, body: Data("{}".utf8)))
    }
    var names: [String] {
      lock.lock()
      defer { lock.unlock() }
      return bodies.flatMap { $0["events"]!.arrayValue!.map { $0["eventName"]!.stringValue! } }
    }
  }

  final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func append(_ line: String) {
      lock.lock()
      all.append(line)
      lock.unlock()
    }
    var lines: [String] {
      lock.lock()
      defer { lock.unlock() }
      return all
    }
  }

  /// Waits for one upload attempt. The completion runs on the SDK's queue,
  /// never the test's thread, so a semaphore cannot deadlock here.
  func flushed(_ client: SharedClient) {
    let done = DispatchSemaphore(value: 0)
    client.flush { done.signal() }
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "flush never completed")
  }

  /// Every method can be called from any thread, and calls made on one thread
  /// keep their order through the SDK's serial queue.
  func testCallsFromManyThreadsAreAllDeliveredAndEachThreadKeepsItsOrder() {
    let network = Network()
    let client = SharedClient(log: { _ in })
    client.setup(
      TogoConfig(writeKey: "togo_pkl_live0000000000"), transport: network,
      device: .memory(), serverRuntime: nil)
    let group = DispatchGroup()
    for thread in 0..<4 {
      DispatchQueue.global().async(group: group) {
        for index in 0..<10 {
          client.client { $0.track("t\(thread)_\(index)") }
        }
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
    flushed(client)
    let names = network.names.filter { !$0.hasPrefix("$") }
    XCTAssertEqual(names.count, 40)
    for thread in 0..<4 {
      XCTAssertEqual(names.filter { $0.hasPrefix("t\(thread)_") }, (0..<10).map { "t\(thread)_\($0)" })
    }
  }

  /// A getter called from the flush completion must not sync onto the queue
  /// it is running on — that traps the host app.
  func testAGetterInsideAFlushCompletionDoesNotDeadlock() {
    let client = SharedClient(log: { _ in })
    client.setup(
      TogoConfig(writeKey: "togo_pkl_live0000000000"), transport: Network(),
      device: .memory(), serverRuntime: nil)
    client.client { $0.track("a") }
    let done = DispatchSemaphore(value: 0)
    let seen = Lines()
    client.flush {
      seen.append(client.read(default: nil) { $0.sessionId } ?? "none")
      done.signal()
    }
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    XCTAssertNotEqual(seen.lines, ["none"])
    XCTAssertEqual(seen.lines.count, 1)
  }

  /// And a read made ON the SDK's queue runs inline rather than trapping.
  func testAReadOnTheSdksOwnQueueRunsInline() {
    let client = SharedClient(log: { _ in })
    client.setup(
      TogoConfig(writeKey: "togo_pkl_live0000000000"), transport: Network(),
      device: .memory(), serverRuntime: nil)
    let done = DispatchSemaphore(value: 0)
    client.client { _ in
      _ = client.read(default: TogoConsent.denied) { $0.consent }
      done.signal()
    }
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
  }

  /// A malformed key is named once and the client is inert — never a crash.
  func testAMalformedKeyDisablesTheClientWithOneError() {
    let network = Network()
    let lines = Lines()
    let reported = Lines()
    let client = SharedClient(log: { lines.append($0) })
    client.setup(
      TogoConfig(writeKey: "$(TOGO_WRITE_KEY)", onError: { reported.append($0.code.rawValue) }),
      transport: network, device: .memory(),
      callbacks: DispatchExecutor(label: "test.callbacks"), serverRuntime: nil)
    client.client { $0.track("a") }
    flushed(client)
    XCTAssertTrue(network.names.isEmpty)
    XCTAssertEqual(lines.lines.filter { $0.contains("not a write key") }.count, 1)
    let deadline = Date().addingTimeInterval(2)
    while reported.lines.isEmpty && Date() < deadline { usleep(10_000) }
    XCTAssertEqual(reported.lines, ["write_key_invalid"])
  }

  func testACallBeforeSetupIsDroppedWithOneLine() {
    let lines = Lines()
    let client = SharedClient(log: { lines.append($0) })
    client.client { $0.track("a") }
    client.client { $0.track("b") }
    XCTAssertEqual(lines.lines.count, 1)
    XCTAssertNil(client.read(default: nil) { $0.anonymousId })
  }

  func testASecondSetupIsIgnored() {
    let lines = Lines()
    let client = SharedClient(log: { lines.append($0) })
    let config = TogoConfig(writeKey: "togo_pkl_live0000000000")
    client.setup(config, transport: Network(), device: .memory(), serverRuntime: nil)
    client.setup(config, transport: Network(), device: .memory(), serverRuntime: nil)
    XCTAssertEqual(lines.lines.filter { $0.contains("called again") }.count, 1)
  }

  /// Conformance 9: on a server the SDK is inert — nothing stored, scheduled
  /// or sent — and says so once, never by throwing…
  func testOnAServerTheSdkIsInertAndWarnsOnce() {
    let network = Network()
    let lines = Lines()
    let client = SharedClient(log: { lines.append($0) })
    let config = TogoConfig(writeKey: "togo_pkl_live0000000000")
    client.setup(config, transport: network, device: .memory(), serverRuntime: "Linux")
    client.setup(config, transport: network, device: .memory(), serverRuntime: "Linux")
    client.client { $0.track("a") }
    flushed(client)
    XCTAssertTrue(network.names.isEmpty)
    XCTAssertEqual(lines.lines.filter { $0.contains("running on a server") }.count, 1)
    XCTAssertNil(client.read(default: nil) { $0.anonymousId })
  }

  /// …and the positive half: where there is a device, the same setup runs.
  func testWhereThereIsADeviceTheSdkRuns() {
    #if os(Linux) || os(Windows)
      XCTAssertNotNil(Platform.serverRuntime())
    #else
      XCTAssertNil(Platform.serverRuntime())
    #endif
    let network = Network()
    let client = SharedClient(log: { _ in })
    client.setup(
      TogoConfig(writeKey: "togo_pkl_live0000000000"), transport: network,
      device: .memory(), serverRuntime: nil)
    client.client { $0.track("a") }
    flushed(client)
    XCTAssertEqual(network.names, ["$session_started", "a"])
  }

  func testTheOsVersionReadsLikeUIDevice() {
    XCTAssertEqual(Platform.osVersion(OperatingSystemVersion(majorVersion: 18, minorVersion: 1, patchVersion: 0)), "18.1")
    XCTAssertEqual(Platform.osVersion(OperatingSystemVersion(majorVersion: 17, minorVersion: 6, patchVersion: 1)), "17.6.1")
  }

  /// `mobile` or `tablet` — the web's vocabulary, never `phone`.
  func testTheDeviceTypeComesFromTheModel() {
    XCTAssertEqual(Platform.deviceType("iPhone16,1"), "mobile")
    XCTAssertEqual(Platform.deviceType("iPod9,1"), "mobile")
    XCTAssertEqual(Platform.deviceType("iPad13,4"), "tablet")
    XCTAssertNil(Platform.deviceType("arm64"))
  }

  /// The options override what the bundle says.
  func testAppVersionAndBuildOptionsOverrideTheBundle() {
    XCTAssertEqual(
      Platform.app(version: "2.4.0", build: "412"), AppInfo(version: "2.4.0", build: "412"))
  }

  func testTheConfigDefaultsMatchTheOtherSdks() {
    let config = TogoConfig(writeKey: "togo_pkl_x")
    XCTAssertEqual(config.endpoint.absoluteString, "https://in.togohq.ai")
    XCTAssertEqual(config.sessionTimeout, 1800)
    XCTAssertEqual(config.consent, .notRequired)
    XCTAssertEqual(config.consentBufferMaxEvents, 100)
  }

  // MARK: - The lifecycle through the client

  /// The client's half of the lifecycle, driven through the same sink the
  /// UIKit adapter forwards into, on any platform: the launch sends
  /// `$app_installed` and opens no session; the first scene in front opens the
  /// app; the last one leaving flushes, and its completion — where the adapter
  /// ends its background task — runs after that flush.
  func testTheLifecycleSinkDrivesTheClientInOrder() {
    let network = Network()
    let client = SharedClient(log: { _ in })
    client.setup(
      TogoConfig(writeKey: "togo_pkl_live0000000000"), transport: network,
      device: .memory(reportsLifecycle: true), serverRuntime: nil)
    let sink = client.lifecycleSink()
    sink.foreground("main")
    sink.foreground("side")
    sink.background("side") {}
    let done = DispatchSemaphore(value: 0)
    sink.background("main") { done.signal() }
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "the background completion never ran")
    XCTAssertEqual(network.names, ["$app_installed", "$session_started", "$app_opened"])
  }

  /// With no lifecycle — a server, or a client that is not a device's — the
  /// background completion still runs, so a background task always ends.
  func testABackgroundCompletionRunsEvenWithNoLifecycle() {
    let client = SharedClient(log: { _ in })
    client.setup(
      TogoConfig(writeKey: "togo_pkl_live0000000000"), transport: Network(),
      device: .memory(), serverRuntime: "Linux")
    let ran = DispatchSemaphore(value: 0)
    client.lifecycleSink().background("main") { ran.signal() }
    XCTAssertEqual(ran.wait(timeout: .now()), .success)
  }

  /// Found on the simulator: the UIKit adapter signals into the sink as soon as
  /// it starts, on the thread `setup()` runs on — protected data, the scenes
  /// already in front. `setup()` held its lock across that, and the sink takes
  /// the lock, so an app's first launch hung on a blank screen. The observer
  /// here signals exactly that way; the setup must return, and the signals
  /// must arrive.
  func testAnObserverThatSignalsDuringSetupDoesNotDeadlock() {
    let network = Network()
    let client = SharedClient(log: { _ in })
    var environment = DeviceEnvironment.memory(reportsLifecycle: true)
    environment.observe = { sink in
      sink.protectedDataAvailable()
      sink.foreground("main")
    }
    let device = environment
    let returned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      client.setup(
        TogoConfig(writeKey: "togo_pkl_live0000000000"), transport: network, device: device,
        serverRuntime: nil)
      returned.signal()
    }
    guard returned.wait(timeout: .now() + 5) == .success else {
      // Anything more would wait on the same lock and hang the suite.
      return XCTFail("setup() deadlocked")
    }
    flushed(client)
    XCTAssertEqual(network.names, ["$app_installed", "$session_started", "$app_opened"])
  }
}
