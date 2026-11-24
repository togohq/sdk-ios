import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// What came back from one upload. `nil` status means the request never got
/// an answer — offline, a timeout, a dropped connection — unless `failure`
/// says why no upload can ever succeed from this process.
public struct TransportResponse: Sendable {
  public var status: Int?
  public var retryAfterSeconds: Double?
  public var body: Data?
  /// A refusal on this side of the network that a retry cannot change: App
  /// Transport Security blocking an `http://` endpoint, a URL the app cannot
  /// open. Not offline — read as offline it would be retried in silence until
  /// the events aged out.
  public var failure: String?

  public init(
    status: Int?, retryAfterSeconds: Double? = nil, body: Data? = nil, failure: String? = nil
  ) {
    self.status = status
    self.retryAfterSeconds = retryAfterSeconds
    self.body = body
    self.failure = failure
  }

  /// A failed upload, sorted: offline — normal operation, retried later — or
  /// a refusal no retry can change, which the engine reports.
  ///
  /// **Only the refusals named here are permanent; every other error is
  /// offline**, an unknown one included. A wrong "permanent" stops the client
  /// and loses every event the rest of the process tracks; a wrong "offline"
  /// costs a retry. So a TLS failure (a wrong device clock, a captive portal)
  /// and `dataNotAllowed` (cellular data off for the app, which Wi-Fi undoes)
  /// stay offline. iOS has no permission for the network to refuse.
  static func classify(_ error: Error?) -> TransportResponse {
    guard let error = error as? URLError else { return TransportResponse(status: nil) }
    switch error.code {
    case appTransportSecurityBlocked:
      return TransportResponse(
        status: nil, failure: "App Transport Security blocked the connection (\(error.code.rawValue))")
    case .badURL, .unsupportedURL:
      return TransportResponse(
        status: nil, failure: "the endpoint is not a URL this app can open (\(error.code.rawValue))")
    default:
      return TransportResponse(status: nil)
    }
  }

  /// `NSURLErrorAppTransportSecurityRequiresSecureConnection`, by its number,
  /// which every Foundation shares.
  static let appTransportSecurityBlocked = URLError.Code(rawValue: -1022)
}

/// The network, as one call. A protocol so the scenario runner can hold it
/// offline and record what would have been sent, and a test can answer 503.
public protocol TogoTransport: Sendable {
  func post(
    url: URL, writeKey: String, body: Data,
    completion: @escaping @Sendable (TransportResponse) -> Void)
}

/// `URLSession`, ephemeral: no cookies, no cache, no credential storage —
/// an analytics upload has no use for any of them, and a shared session's
/// cookie jar is the host app's, not ours.
///
/// **A redirect is answered, never followed.** Followed, a 301 or 302 turns
/// the POST into a GET, and a 200 from the page it lands on would read as
/// delivered for a batch nobody received. The engine keeps and retries
/// whatever a redirect answers.
public final class URLSessionTransport: TogoTransport, @unchecked Sendable {
  private let session: URLSession

  public init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
  }

  public func post(
    url: URL, writeKey: String, body: Data,
    completion: @escaping @Sendable (TransportResponse) -> Void
  ) {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(writeKey, forHTTPHeaderField: "X-Write-Key")
    request.httpBody = body
    session.dataTask(with: request) { data, response, error in
      guard let http = response as? HTTPURLResponse else {
        completion(TransportResponse.classify(error))
        return
      }
      let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
      completion(TransportResponse(status: http.statusCode, retryAfterSeconds: retryAfter, body: data))
    }.resume()
  }
}

/// Refuses every redirect, so the task completes with the redirect's own
/// response.
final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

/// Where the engine's work runs. Every method of the engine is called on ONE
/// serial executor, which is what makes it safe without locks and keeps calls
/// in the order they were made — a `Task {}` per call would not.
public protocol TogoExecutor: Sendable {
  func async(_ work: @escaping @Sendable () -> Void)
  /// Run `work` after `seconds`. Returns a cancel function.
  func after(_ seconds: Double, _ work: @escaping @Sendable () -> Void) -> @Sendable () -> Void
}

public final class DispatchExecutor: TogoExecutor, @unchecked Sendable {
  public let queue: DispatchQueue

  private let key = DispatchSpecificKey<Bool>()

  public init(label: String = "ai.togohq.sdk") {
    queue = DispatchQueue(label: label, qos: .utility)
    queue.setSpecific(key: key, value: true)
  }

  /// Whether the caller is already running on this queue — where a
  /// `queue.sync` would trap rather than wait.
  public var isCurrent: Bool { DispatchQueue.getSpecific(key: key) == true }

  public func async(_ work: @escaping @Sendable () -> Void) { queue.async(execute: work) }

  public func after(_ seconds: Double, _ work: @escaping @Sendable () -> Void)
    -> @Sendable () -> Void
  {
    let flag = CancelFlag()
    queue.asyncAfter(deadline: .now() + seconds) {
      if !flag.isCancelled { work() }
    }
    return { flag.cancel() }
  }
}

/// A timer's cancellation, readable from the queue it fires on.
final class CancelFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
}
