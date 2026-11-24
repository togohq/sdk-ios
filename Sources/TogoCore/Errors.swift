import Foundation

/// Why an event — or part of one — will not be recorded. The same codes as
/// the browser SDK's `errors.ts`: the diagnostic catalog's where one exists, and
/// a few only an SDK can see. A struct rather than an enum because a code from
/// the edge may be one added after this SDK was built; treat an unknown code
/// as a drop.
public struct TogoErrorCode: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public var description: String { rawValue }

  public static let eventNameReserved = Self(rawValue: "event_name_reserved")
  public static let eventNameTooLong = Self(rawValue: "event_name_too_long")
  public static let eventNameEmpty = Self(rawValue: "event_name_empty")
  public static let propertyReserved = Self(rawValue: "property_reserved")
  public static let personPropertyReserved = Self(rawValue: "person_property_reserved")
  public static let propertyNameInvalid = Self(rawValue: "property_name_invalid")
  public static let personPropertyNameInvalid = Self(rawValue: "person_property_name_invalid")
  /// A string value over 1,024 characters, cut to its first 1,024 — under a
  /// test key, sent whole for the server to cut. The event is kept.
  public static let envelopePropertyValueTooLong = Self(rawValue: "envelope_property_value_too_long")
  /// A map over 256 properties, which kept its first 256 in UTF-16 code-unit order and dropped the
  /// rest — under a test key, sent whole for the server to drop the same ones. The event is kept.
  public static let envelopePropertiesTooMany = Self(rawValue: "envelope_properties_too_many")
  public static let timestampTooOld = Self(rawValue: "timestamp_too_old")
  public static let queueFull = Self(rawValue: "queue_full")
  /// An event whose JSON is over 256 KiB, dropped at `track()` and never sent.
  public static let eventTooLarge = Self(rawValue: "event_too_large")
  /// `identify()` given an empty id or one over 128 characters. Only an SDK
  /// sees it: the edge would refuse the whole batch the id rode in.
  public static let userIdInvalid = Self(rawValue: "user_id_invalid")
  public static let writeKeyInvalid = Self(rawValue: "write_key_invalid")
  public static let writeKeyRejected = Self(rawValue: "write_key_rejected")
  public static let batchTooLarge = Self(rawValue: "batch_too_large")
  public static let batchRejected = Self(rawValue: "batch_rejected")
  /// The endpoint cannot be reached from this app however often it is tried:
  /// App Transport Security blocks it, or it is not a URL the app can open.
  /// Only an SDK sees it. The client stops for this process and keeps the
  /// queue.
  public static let endpointInvalid = Self(rawValue: "endpoint_invalid")
}

/// What `onError` receives. Never thrown: no call on this SDK throws.
public struct TogoError: Sendable, Equatable {
  public let code: TogoErrorCode
  /// What the log shows, without the `[togo] ` prefix: the problem and the fix.
  public let message: String
  /// The events this is about, by the id `track()` returned: the events lost, or for
  /// `envelopePropertyValueTooLong` and `envelopePropertiesTooMany` the event that was kept with a
  /// value cut or properties dropped. Empty when it is about the client.
  public let eventIds: [String]
  /// The raw event name, when it concerns one event.
  public let eventName: String?
  /// The property name when it concerns one property — a reserved or unusable name, or a value
  /// cut to the length cap — as the message shows it: its first 64 characters, with an email
  /// address in it replaced. Never the value.
  public let property: String?

  public init(
    code: TogoErrorCode, message: String, eventIds: [String] = [], eventName: String? = nil,
    property: String? = nil
  ) {
    self.code = code
    self.message = message
    self.eventIds = eventIds
    self.eventName = eventName
    self.property = property
  }
}

/// The SDK's console. Every line is prefixed `[togo] `. Injected so a test or
/// the scenario runner can read what a developer would see.
public typealias TogoLogger = @Sendable (String) -> Void

public let standardErrorLogger: TogoLogger = { message in
  FileHandleLog.write("[togo] \(message)\n")
}

enum FileHandleLog {
  static func write(_ line: String) {
    FileHandle.standardError.write(Data(line.utf8))
  }
}
