import Foundation
import TogoCore

public typealias TogoValue = TogoCore.TogoValue
public typealias TogoProperties = TogoCore.TogoProperties
public typealias TogoConsent = TogoCore.TogoConsent
public typealias TogoError = TogoCore.TogoError
public typealias TogoErrorCode = TogoCore.TogoErrorCode
public typealias PersonPropertyUpdate = TogoCore.PersonPropertyUpdate

/// What to do once consent is refused. Only `.drop` exists, and the type says
/// so rather than accepting a value it would ignore (`consent.ts`).
public enum TogoOnDenied: String, Sendable {
  case drop
}

/// `Togo.setup(_:)`'s options.
///
/// Deliberately absent: a batch size and flush interval (fixed on a device,
/// 50 events or 5 seconds), the 24-hour session cap (not configurable on any
/// platform), `cookieDomain` and `pageContext` (web only), a `deviceId` (the
/// SDK owns its identifiers), and `appGroupIdentifier`
/// (extensions are out of scope).
public struct TogoConfig: Sendable {
  /// The project's write key, `togo_pkl_…` or `togo_pkt_…`. Use the test key
  /// in DEBUG builds, so `verify_tracking` sees a simulator's events.
  public var writeKey: String
  /// Ingest origin. Defaults to the production edge.
  public var endpoint: URL
  /// The idle window. Default 30 minutes. **`<= 0` disables sessions** and
  /// sends no `sessionId` at all — never read as instant expiry.
  public var sessionTimeout: TimeInterval
  /// Default `.notRequired`. `.pending` holds events in memory, stores and
  /// sends nothing, until `setConsent(.granted)`.
  public var consent: TogoConsent
  public var onDenied: TogoOnDenied
  /// The pending buffer's bound, oldest dropped. Default 100.
  public var consentBufferMaxEvents: Int
  /// Properties on every `track()` event, such as `["source": "ios_app"]`.
  /// Set once; an event's own value for a key wins, and the collision is logged once.
  public var defaultProperties: TogoProperties
  /// Your app's version and build. Read from the bundle
  /// (`CFBundleShortVersionString`, `CFBundleVersion`) when not set; set them
  /// when your bundle's numbers are not your release numbers.
  public var appVersion: String?
  public var appBuild: String?
  /// Called once for every event — or part of one — that will not be
  /// recorded, in production too. Never for consent `.denied`. Called off the
  /// SDK's queue, after the call that caused it returns.
  public var onError: (@Sendable (TogoError) -> Void)?

  public static let defaultEndpoint = URL(string: "https://in.togohq.ai")!

  /// For an SDK built over this one — the Solar2D plugin — and nothing else: its
  /// events name the wrapper (`sdk-solar2d`) instead of `sdk-ios`, so the
  /// wrapper is what an SDK breakdown counts. A name or version the edge would
  /// refuse is ignored with one log line and the batch names `sdk-ios`. Behind
  /// the `Wrapper` SPI (`@_spi(Wrapper) import Togo`), so an app never sees it.
  @_spi(Wrapper) public var wrapper: TogoWrapper?

  public init(
    writeKey: String,
    endpoint: URL = TogoConfig.defaultEndpoint,
    sessionTimeout: TimeInterval = 1800,
    consent: TogoConsent = .notRequired,
    onDenied: TogoOnDenied = .drop,
    consentBufferMaxEvents: Int = 100,
    defaultProperties: TogoProperties = [:],
    appVersion: String? = nil,
    appBuild: String? = nil,
    onError: (@Sendable (TogoError) -> Void)? = nil
  ) {
    self.writeKey = writeKey
    self.endpoint = endpoint
    self.sessionTimeout = sessionTimeout
    self.consent = consent
    self.onDenied = onDenied
    self.consentBufferMaxEvents = consentBufferMaxEvents
    self.defaultProperties = defaultProperties
    self.appVersion = appVersion
    self.appBuild = appBuild
    self.onError = onError
  }
}

/// A wrapper SDK's own name and version (`TogoConfig.wrapper`).
@_spi(Wrapper) public struct TogoWrapper: Sendable, Equatable {
  public var name: String
  public var version: String

  public init(name: String, version: String) {
    self.name = name
    self.version = version
  }
}
