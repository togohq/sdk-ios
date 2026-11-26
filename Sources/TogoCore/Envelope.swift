/// The wire format, hand-written.
///
/// This DELIBERATELY duplicates the server's definition of the envelope, as the
/// browser SDK's `envelope.ts` does, so the package lives in its own repository
/// (`togohq/sdk-ios`) with no refactor: it shares no code with the server, only
/// a wire format. Do not "fix" it with an import.
///
/// Where the SDK is developed beside the server, a contract test reads THIS FILE
/// and fails the build when a constant here and the server's disagree, or when
/// the server exports a cap this file never learned. So every number below is a plain
/// literal — the test parses them, and `7 * 24 * …` is not a literal.

/// Which SDK sent a batch. **Wire format, permanent once published**: the
/// server maps it to `event_source = "ios"`.
public let SDK_NAME = "sdk-ios"
/// The package's own semver, set by the release, which also tags the public
/// repository with it. The first published version is 1.0.0.
public let SDK_VERSION = "1.2.0"

/// The `sdk` a batch names: this SDK's own, or a wrapper's built over it.
///
/// A wrapper is an SDK for another runtime that calls this one underneath —
/// the Solar2D plugin, `sdk-solar2d`. Its events name the wrapper, because that
/// is what a developer installed and what a breakdown by SDK should count; the
/// server reads the platform of a wrapper's batch from its `device`, which this
/// SDK still fills. Set only through the `Wrapper` SPI (`TogoConfig.wrapper`),
/// never by an app.
public struct SdkIdentity: Sendable, Equatable {
  public let name: String
  public let version: String

  /// This SDK, as it names itself.
  public static let native = SdkIdentity(uncheckedName: SDK_NAME, version: SDK_VERSION)

  /// A wrapper's name and version, or nil when they would not be read as one —
  /// then the batch keeps naming this SDK. The name is one the server reads a
  /// wrapper's platform for (`Wire.wrapperSdkNames`): any other would land as
  /// `unknown` and lose its device. The version is non-empty, holds no
  /// whitespace, and is at most `Wire.maxSdkVersionLength` UTF-16 code units,
  /// as the edge counts — `count` counts characters, and an emoji or a
  /// combining mark would pass it while the edge refused every batch.
  public init?(wrapperName name: String, version: String) {
    guard Wire.wrapperSdkNames.contains(name), !version.isEmpty,
      version.utf16.count <= Wire.maxSdkVersionLength,
      version.allSatisfy({ !$0.isWhitespace })
    else { return nil }
    self.init(uncheckedName: name, version: version)
  }

  private init(uncheckedName name: String, version: String) {
    self.name = name
    self.version = version
  }
}

public enum Wire {
  public static let envelopeVersion = 2
  /// The edge's bound on `sdk.version`, in UTF-16 code units.
  public static let maxSdkVersionLength = 32
  /// The wrapper SDKs the server reads a platform for from the batch's
  /// `device.os`; a wrapper not listed here names this SDK instead.
  public static let wrapperSdkNames = ["sdk-solar2d"]
  public static let maxBatchSize = 500
  /// How old an event may be when it is UPLOADED. The edge rejects anything
  /// older, so the queue drops it locally and logs the count. A data-loss dial:
  /// never tighter than the server's.
  public static let maxEventAgeMs: Int64 = 604_800_000
  public static let maxEnvelopePropertyValueLength = 1024
  public static let maxEnvelopePropertiesPerEvent = 256
  /// How many dropped names an `envelope_properties_too_many` report carries.
  public static let maxReportedDroppedProperties = 10
  /// The property names this SDK writes into a map itself — `setPersonProperties`'s `email` and
  /// `name` as `$email` and `$name` — which the property cap always keeps, first.
  public static let platformPropertyNames = ["$email", "$name"]
  public static let maxBatchBytes = 5_242_880
  public static let maxEventBytes = 262_144
  public static let maxEnvelopeExperimentsPerEvent = 64
  public static let maxEnvelopeExperimentKeyLength = 64
  public static let maxTimezoneLength = 64
  public static let maxEventNameLength = 255
  public static let maxAppDeviceFieldLength = 64
  /// The edge's bound on `userId` (`RawEventSchema`: 1–128). Not a named
  /// constant on the server, so the contract test does not enumerate it; an id
  /// outside it fails the WHOLE batch, which is why `identify()` refuses it.
  public static let maxUserIdLength = 128

  /// What the edge accepts as a `sessionId`. The SDK only ever sends its own
  /// UUIDs, which match; held equal to the server's by the contract test.
  public static let sessionIdPattern = "^[A-Za-z0-9_.:@+%-]{1,128}$"

  public static let personPropertiesCarrierEvent = "$set_person_properties"
  public static let identifyEvent = "$identify"
  public static let experimentEnteredEvent = "$experiment_entered"
  public static let sessionStartedEvent = "$session_started"
  public static let appInstalledEvent = "$app_installed"
  public static let appUpdatedEvent = "$app_updated"
  public static let appOpenedEvent = "$app_opened"

  /// Reserved events: a row like any other. The three app events are sent by
  /// the engine as `AppLifecycle` drives it; the names are here because the edge accepts
  /// them and `track()` must refuse them under both key classes.
  public static let sentReservedEvents = [
    "$session_started",
    "$experiment_entered",
    "$app_installed",
    "$app_updated",
    "$app_opened",
    "$page_viewed",
    "$page_left",
  ]

  public static let reservedEventPrefix = "$"

  /// Every `$` name the server accepts: the two control events and the
  /// reserved events.
  public static let reservedEventNames = [
    "$set_person_properties",
    "$identify",
    "$session_started",
    "$experiment_entered",
    "$app_installed",
    "$app_updated",
    "$app_opened",
    "$page_viewed",
    "$page_left",
  ]

  /// The prefix the edge reads as a test key (`togo_pkt_`).
  public static let testWriteKeyPrefix = "togo_pkt_"
}

/// Person-property operations, on the PERSON rather than the event. See
/// the browser SDK's `envelope.ts` → `PersonPropertyOps`.
public struct PersonPropertyOps: Sendable, Equatable {
  public var set: TogoProperties?
  public var setOnce: TogoProperties?
  public var unset: [String]?

  public init(set: TogoProperties? = nil, setOnce: TogoProperties? = nil, unset: [String]? = nil)
  {
    self.set = set
    self.setOnce = setOnce
    self.unset = unset
  }

  var json: JSONValue {
    var object: [String: JSONValue] = [:]
    if let set { object["set"] = set.json }
    if let setOnce { object["setOnce"] = setOnce.json }
    if let unset { object["unset"] = .array(unset.map(JSONValue.string)) }
    return .object(object)
  }

  init?(json: JSONValue?) {
    guard let json, json.objectValue != nil else { return nil }
    set = TogoProperties(json: json["set"])
    setOnce = TogoProperties(json: json["setOnce"])
    unset = json["unset"]?.arrayValue?.compactMap(\.stringValue)
  }
}

/// The customer's app build. Read from the bundle by `Togo`, or the
/// `appVersion`/`appBuild` options. Each 1–64 characters.
public struct AppInfo: Sendable, Equatable {
  public var version: String?
  public var build: String?

  public init(version: String? = nil, build: String? = nil) {
    self.version = version
    self.build = build
  }

  var json: JSONValue {
    var object: [String: JSONValue] = [:]
    if let version { object["version"] = .string(version) }
    if let build { object["build"] = .string(build) }
    return .object(object)
  }

  init?(json: JSONValue?) {
    guard let object = json?.objectValue else { return nil }
    version = object["version"]?.stringValue
    build = object["build"]?.stringValue
  }
}

/// The device as a native SDK knows it: `os` (`iOS`), `osVersion` (`18.1`),
/// `model` (`iPhone16,1`) and `deviceType` (`mobile` or `tablet`, the web's
/// vocabulary). Each value wins over what curation parses from the User-Agent.
public struct DeviceInfo: Sendable, Equatable {
  public var os: String?
  public var osVersion: String?
  public var model: String?
  public var deviceType: String?

  public init(
    os: String? = nil, osVersion: String? = nil, model: String? = nil, deviceType: String? = nil
  ) {
    self.os = os
    self.osVersion = osVersion
    self.model = model
    self.deviceType = deviceType
  }

  var json: JSONValue {
    var object: [String: JSONValue] = [:]
    if let os { object["os"] = .string(os) }
    if let osVersion { object["osVersion"] = .string(osVersion) }
    if let model { object["model"] = .string(model) }
    if let deviceType { object["deviceType"] = .string(deviceType) }
    return .object(object)
  }

  init?(json: JSONValue?) {
    guard let object = json?.objectValue else { return nil }
    os = object["os"]?.stringValue
    osVersion = object["osVersion"]?.stringValue
    model = object["model"]?.stringValue
    deviceType = object["deviceType"]?.stringValue
  }
}

/// One event on the wire. Field meanings: the browser SDK's `envelope.ts` →
/// `RawEvent`. This SDK never sends `page` (a web field) or `eventVersion` (the
/// defined tier has no Swift codegen, by design).
public struct RawEvent: Sendable, Equatable {
  public var eventName: String
  /// Device clock when the event OCCURRED, epoch milliseconds; ISO-8601 UTC on
  /// the wire.
  public var clientEventMs: Int64
  public var eventId: String
  public var anonymousId: String?
  public var deviceId: String?
  public var userId: String?
  public var sessionId: String?
  public var properties: TogoProperties
  public var personProperties: PersonPropertyOps?
  public var timezone: String?
  /// Experiment name → variant: the still-active experiments this device
  /// entered, stamped at `track()` so a queued event keeps the stamp it was
  /// tracked with. `nil` when there are none.
  public var experiments: [String: String]?
  public var sdkName: String
  public var sdkVersion: String

  public var json: JSONValue {
    var object: [String: JSONValue] = [
      "eventName": .string(eventName),
      "clientEventTs": .string(ISOTime.format(clientEventMs)),
      "eventId": .string(eventId),
      "properties": properties.json,
      "sdk": .object(["name": .string(sdkName), "version": .string(sdkVersion)]),
    ]
    if let anonymousId { object["anonymousId"] = .string(anonymousId) }
    if let deviceId { object["deviceId"] = .string(deviceId) }
    if let userId { object["userId"] = .string(userId) }
    if let sessionId { object["sessionId"] = .string(sessionId) }
    if let personProperties { object["personProperties"] = personProperties.json }
    if let timezone { object["timezone"] = .string(timezone) }
    if let experiments { object["experiments"] = .object(experiments.mapValues(JSONValue.string)) }
    return .object(object)
  }

  public init?(json: JSONValue) {
    guard let eventName = json["eventName"]?.stringValue,
      let ts = json["clientEventTs"]?.stringValue, let clientEventMs = ISOTime.parse(ts),
      let eventId = json["eventId"]?.stringValue,
      let properties = TogoProperties(json: json["properties"])
    else { return nil }
    self.eventName = eventName
    self.clientEventMs = clientEventMs
    self.eventId = eventId
    self.anonymousId = json["anonymousId"]?.stringValue
    self.deviceId = json["deviceId"]?.stringValue
    self.userId = json["userId"]?.stringValue
    self.sessionId = json["sessionId"]?.stringValue
    self.properties = properties
    self.personProperties = PersonPropertyOps(json: json["personProperties"])
    self.timezone = json["timezone"]?.stringValue
    self.experiments = json["experiments"]?.objectValue?.compactMapValues(\.stringValue)
    self.sdkName = json["sdk"]?["name"]?.stringValue ?? SDK_NAME
    self.sdkVersion = json["sdk"]?["version"]?.stringValue ?? SDK_VERSION
  }

  public init(
    eventName: String, clientEventMs: Int64, eventId: String, anonymousId: String?,
    deviceId: String?, userId: String?, sessionId: String?, properties: TogoProperties,
    personProperties: PersonPropertyOps?, timezone: String?
  ) {
    self.eventName = eventName
    self.clientEventMs = clientEventMs
    self.eventId = eventId
    self.anonymousId = anonymousId
    self.deviceId = deviceId
    self.userId = userId
    self.sessionId = sessionId
    self.properties = properties
    self.personProperties = personProperties
    self.timezone = timezone
    self.sdkName = SDK_NAME
    self.sdkVersion = SDK_VERSION
  }
}

/// One upload. Consent is deliberately NOT on the wire; `app` and `device` are batch-level because one upload is one build on
/// one device, which is why the queue cuts a batch where either changes.
public struct RawBatch: Sendable, Equatable {
  public var clientSentMs: Int64
  public var deviceIdMode: String?
  public var sessionIdMode: String?
  public var app: AppInfo?
  public var device: DeviceInfo?
  public var events: [RawEvent]

  public var json: JSONValue {
    var object: [String: JSONValue] = [
      "envelopeVersion": .int(Int64(Wire.envelopeVersion)),
      "clientSentTs": .string(ISOTime.format(clientSentMs)),
      "events": .array(events.map(\.json)),
    ]
    if let deviceIdMode { object["deviceIdMode"] = .string(deviceIdMode) }
    if let sessionIdMode { object["sessionIdMode"] = .string(sessionIdMode) }
    if let app { object["app"] = app.json }
    if let device { object["device"] = device.json }
    return .object(object)
  }
}
