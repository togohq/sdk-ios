import Foundation
import TogoCore
import XCTest

@testable import Togo

/// `Togo.getExperiment` and `Togo.cachedExperiment` through the shared client:
/// the queue hop, the callback queue and the configuration.
final class ExperimentTests: XCTestCase {
  /// Answers every assignment request with variant `b`, and records where it went.
  final class Assign: TogoTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func post(
      url: URL, writeKey: String, body: Data,
      completion: @escaping @Sendable (TransportResponse) -> Void
    ) {
      lock.lock()
      urls.append(url)
      lock.unlock()
      guard url.path.hasSuffix("v1/assignments") else {
        return completion(TransportResponse(status: 202, body: Data("{}".utf8)))
      }
      let body = #"{"maxAgeSeconds":3600,"assignments":{"checkout":{"status":"active","variant":"b","participating":true,"unit":"anonymous_id"}}}"#
      completion(TransportResponse(status: 200, body: Data(body.utf8)))
    }
    var assignURLs: [URL] {
      lock.lock()
      defer { lock.unlock() }
      return urls.filter { $0.path.hasSuffix("v1/assignments") }
    }
  }

  func testGetExperimentAnswersOnTheCallbackQueueFromTheConfiguredEndpoint() async {
    let client = SharedClient(log: { _ in })
    let network = Assign()
    let endpoint = URL(string: "https://assign.example.test")!
    var config = TogoConfig(writeKey: "togo_pkl_live0000000000")
    config.assignEndpoint = endpoint
    client.setup(config, transport: network, device: .memory(), serverRuntime: nil)
    let result = await withCheckedContinuation { continuation in
      client.getExperiment("checkout") { continuation.resume(returning: $0) }
    }
    XCTAssertEqual(result.variant, "b")
    XCTAssertTrue(result.participating)
    XCTAssertEqual(network.assignURLs.first?.host, "assign.example.test")
    XCTAssertEqual(client.read(default: nil) { $0.cachedExperiment("checkout") }?.variant, "b")
  }

  func testWithoutALifecycleTheConfiguredNamesAreFetchedAtSetup() {
    let client = SharedClient(log: { _ in })
    let network = Assign()
    var config = TogoConfig(writeKey: "togo_pkl_live0000000000")
    config.experiments = ["checkout"]
    client.setup(config, transport: network, device: .memory(), serverRuntime: nil)
    // The answer lands on the SDK's queue a moment after setup() returns.
    var cached: TogoExperiment?
    let deadline = Date().addingTimeInterval(5)
    while cached == nil, Date() < deadline {
      cached = client.read(default: nil) { $0.cachedExperiment("checkout") }
      if cached == nil { Thread.sleep(forTimeInterval: 0.01) }
    }
    XCTAssertEqual(cached?.variant, "b")
    XCTAssertEqual(network.assignURLs.count, 1)
  }

  func testSetupWithNoExperimentsMintsNothing() {
    let client = SharedClient(log: { _ in })
    client.setup(
      TogoConfig(writeKey: "togo_pkl_live0000000000"), transport: Assign(), device: .memory(),
      serverRuntime: nil)
    XCTAssertNil(client.read(default: nil) { $0.anonymousId }, "a getter never mints, nor does setup()")
  }

  func testBeforeSetupTheAnswerIsUnavailable() async {
    let client = SharedClient(log: { _ in })
    let result = await withCheckedContinuation { continuation in
      client.getExperiment("checkout") { continuation.resume(returning: $0) }
    }
    XCTAssertEqual(result, .unavailable("checkout"))
    XCTAssertNil(client.read(default: nil) { $0.cachedExperiment("checkout") })
  }
}
