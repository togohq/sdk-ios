import Foundation
import TogoCore
import XCTest

@testable import TogoScenarios

/// `sendNative`, the stage journey's sender, against a stand-in edge: the
/// scenario's events go out in the past they were planned in, a batch per app
/// build, uploaded at now, and the edge's answer is what the run reports.
final class SendTests: XCTestCase {
  final class Edge: TogoTransport, @unchecked Sendable {
    let status: Int?
    var bodies: [JSONValue] = []
    init(status: Int?) { self.status = status }
    func post(
      url: URL, writeKey: String, body: Data,
      completion: @escaping @Sendable (TransportResponse) -> Void
    ) {
      let json = try! JSONValue.parse(body)
      bodies.append(json)
      let count = json["events"]?.arrayValue?.count ?? 0
      // Answered from another queue, as URLSession answers.
      let status = self.status
      DispatchQueue.global().async {
        completion(
          TransportResponse(status: status, body: Data("{\"accepted\":\(count),\"rejected\":[]}".utf8)))
      }
    }
  }

  let now: Int64 = 1_800_000_000_000

  func testSendsEachBuildsEventsInThePastAndReportsTheEdgesAnswer() throws {
    let edge = Edge(status: 202)
    let uploads = try ScenarioDriver.sendNative(
      "app_updated", endpoint: URL(string: "https://in.example.test")!, writeKey: "togo_pkl_k",
      nowMs: now, runId: "t", transport: edge)
    XCTAssertEqual(uploads.count, edge.bodies.count)
    XCTAssertEqual(uploads.map(\.status), Array(repeating: 202, count: uploads.count))
    XCTAssertEqual(
      uploads.first?.response?["accepted"]?.int64Value,
      edge.bodies.first?["events"]?.arrayValue.map { Int64($0.count) })
    // One batch per build, never mixed, and both builds present.
    let builds = uploads.compactMap { $0.body["app"]?["build"]?.stringValue }
    XCTAssertEqual(Set(builds), ["140", "150"])
    XCTAssertEqual(builds.count, uploads.count)
    for upload in uploads {
      XCTAssertEqual(upload.body["clientSentTs"]?.stringValue, ISOTime.format(now))
      for event in upload.body["events"]?.arrayValue ?? [] {
        XCTAssertEqual(event["sdk"]?["name"]?.stringValue, "sdk-ios")
        let at = try XCTUnwrap(event["clientEventTs"]?.stringValue.flatMap(ISOTime.parse))
        XCTAssertLessThan(at, now, "planned in the past")
        XCTAssertGreaterThan(at, now - 7 * 86_400_000, "inside the edge's seven-day clamp")
      }
    }
    let names = uploads.flatMap { $0.body["events"]?.arrayValue ?? [] }.compactMap { $0["eventName"]?.stringValue }
    XCTAssertTrue(names.contains("$app_installed"))
    XCTAssertTrue(names.contains("$app_updated"))
  }

  /// A refusal, a 503 or no answer at all is the run's answer, after ONE try:
  /// retrying resends the same batch and, against a hanging edge, waits out
  /// the timeout each time, until the caller's own timeout hides the status.
  func testAnEdgeThatRefusesOrDoesNotAnswerIsWhatTheRunReportsAfterOneTry() throws {
    for status in [401, 503, nil] as [Int?] {
      let edge = Edge(status: status)
      let uploads = try ScenarioDriver.sendNative(
        "app_updated", endpoint: URL(string: "https://in.example.test")!, writeKey: "togo_pkl_k",
        nowMs: now, runId: "t", transport: edge)
      XCTAssertEqual(uploads.count, 1, "\(String(describing: status))")
      XCTAssertEqual(edge.bodies.count, 1, "\(String(describing: status))")
      XCTAssertEqual(uploads.first?.status, status)
    }
  }
}
