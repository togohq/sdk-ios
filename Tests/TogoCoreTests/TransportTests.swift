import Foundation
import XCTest

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

@testable import TogoCore

/// The real `URLSessionTransport` against a server on the loopback
/// interface: what the engine's fakes cannot show is what URLSession itself
/// does with an answer.
final class TransportTests: XCTestCase {
  /// A redirect comes back as the redirect, never followed: a 301 or 302
  /// followed turns the POST into a GET, and the 200 it lands on would read
  /// as delivered.
  func testARedirectIsAnsweredNotFollowed() throws {
    for status in [301, 302, 307, 308] {
      let server = try LoopbackServer { path in
        path == "/v1/events"
          ? (status, ["Location": "/elsewhere"]) : (200, [:])
      }
      defer { server.stop() }
      let response = post(URLSessionTransport(), to: server.url.appendingPathComponent("v1/events"))
      XCTAssertEqual(response.status, status, "\(status) is reported as itself")
      XCTAssertEqual(server.paths, ["/v1/events"], "\(status): the redirect was not followed")
    }
  }

  /// The positive half: the same server answers a plain upload, so the
  /// redirect assertion above is about the redirect, not a dead server.
  func testAnAcceptedUploadIsReadAsItsStatus() throws {
    let server = try LoopbackServer { _ in (202, [:]) }
    defer { server.stop() }
    let response = post(URLSessionTransport(), to: server.url.appendingPathComponent("v1/events"))
    XCTAssertEqual(response.status, 202)
    XCTAssertEqual(server.paths, ["/v1/events"])
  }

  /// The refusals no retry can change carry a failure; every other error —
  /// the network being away, a TLS handshake a wrong clock can fail, cellular
  /// data off for the app, an error this SDK does not know — is offline.
  func testAFailedUploadIsSortedIntoOfflineOrPermanent() {
    let permanent: [URLError.Code] = [
      TransportResponse.appTransportSecurityBlocked, .badURL, .unsupportedURL,
    ]
    for code in permanent {
      let response = TransportResponse.classify(URLError(code))
      XCTAssertNil(response.status)
      XCTAssertNotNil(response.failure, "\(code.rawValue) is permanent")
    }
    let offline: [URLError.Code] = [
      .timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
      .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed, .serverCertificateUntrusted,
      .dataNotAllowed, .internationalRoamingOff, .cancelled, URLError.Code(rawValue: -1999),
    ]
    for code in offline {
      let response = TransportResponse.classify(URLError(code))
      XCTAssertNil(response.status)
      XCTAssertNil(response.failure, "\(code.rawValue) is offline")
    }
    XCTAssertNil(TransportResponse.classify(nil).failure)
    XCTAssertNil(TransportResponse.classify(NSError(domain: "other", code: 1)).failure)
  }

  /// The real session's error, not a constructed one: a scheme no app can
  /// open is permanent…
  func testAnEndpointTheAppCannotOpenIsAFailure() {
    let response = post(URLSessionTransport(), to: URL(string: "togo://in.example.test/v1/events")!)
    XCTAssertNil(response.status)
    XCTAssertNotNil(response.failure)
  }

  /// …and a refused connection is offline.
  func testARefusedConnectionIsOffline() throws {
    let server = try LoopbackServer { _ in (202, [:]) }
    let url = server.url.appendingPathComponent("v1/events")
    server.stop()
    let response = post(URLSessionTransport(), to: url)
    XCTAssertNil(response.status)
    XCTAssertNil(response.failure)
  }

  func post(_ transport: URLSessionTransport, to url: URL) -> TransportResponse {
    let done = expectation(description: "answered")
    let box = ResponseBox()
    transport.post(url: url, writeKey: "togo_pkl_live0000000000", body: Data("{}".utf8)) { response in
      box.response = response
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
    return box.response!
  }
}

final class ResponseBox: @unchecked Sendable {
  var response: TransportResponse?
}

/// An HTTP/1.1 server on 127.0.0.1 and a free port, one request per
/// connection, answering each path as `answer` says. Records the paths it saw.
final class LoopbackServer: @unchecked Sendable {
  let url: URL
  private let socketFD: Int32
  private let answer: @Sendable (String) -> (Int, [String: String])
  private let lock = NSLock()
  private var seen: [String] = []
  private let finished = DispatchSemaphore(value: 0)

  var paths: [String] {
    lock.lock()
    defer { lock.unlock() }
    return seen
  }

  init(answer: @escaping @Sendable (String) -> (Int, [String: String])) throws {
    self.answer = answer
    #if canImport(Darwin)
      let fd = socket(AF_INET, SOCK_STREAM, 0)
    #else
      let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard fd >= 0 else { throw POSIXError(.EIO) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
    }
    guard bound == 0, listen(fd, 8) == 0 else { throw POSIXError(.EADDRINUSE) }
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    socketFD = fd
    url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))")!
    let thread = Thread { [self] in serve() }
    thread.start()
  }

  func stop() {
    shutdown(socketFD, Int32(SHUT_RDWR))
    close(socketFD)
    _ = finished.wait(timeout: .now() + 5)
  }

  private func serve() {
    defer { finished.signal() }
    while true {
      let client = accept(socketFD, nil, nil)
      if client < 0 { return }
      handle(client)
      close(client)
    }
  }

  private func handle(_ client: Int32) {
    var request = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    // Headers, then as much body as Content-Length says.
    while true {
      let count = read(client, &buffer, buffer.count)
      if count <= 0 { return }
      request.append(contentsOf: buffer[0..<count])
      guard let text = String(data: request, encoding: .utf8),
        let end = text.range(of: "\r\n\r\n")
      else { continue }
      let head = text[..<end.lowerBound]
      let length =
        head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
        .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
      if text.utf8.count - text.utf8.distance(from: text.startIndex, to: end.upperBound) < length {
        continue
      }
      let path = String(head.split(separator: " ")[1])
      lock.lock()
      seen.append(path)
      lock.unlock()
      let (status, headers) = answer(path)
      var reply = "HTTP/1.1 \(status) Status\r\nContent-Length: 2\r\nConnection: close\r\n"
      for (name, value) in headers { reply += "\(name): \(value)\r\n" }
      reply += "\r\n{}"
      _ = reply.utf8CString.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count - 1) }
      return
    }
  }
}
