import Foundation

/// The checks every call passes through before anything is queued: the write
/// key's class, a `$` name or key, the structural caps, and the default
/// properties. Each mirrors a file of the browser SDK's (named in its doc
/// comment), because what a developer is told must not depend on the platform.

// MARK: - Write keys (`keys.ts`)

enum WriteKeys {
  static let writePrefixes = ["togo_pkl_", "togo_pkt_", "pk_test_", "pk_live_"]
  static let secretPrefixes = ["togo_sk", "sk_"]

  static func isTest(_ key: String) -> Bool { key.hasPrefix(Wire.testWriteKeyPrefix) }

  /// Why this string cannot be a write key, or `nil` if it can be. Checked
  /// locally at `setup()`, so a missing build setting or a secret key pasted
  /// into an app is named at once rather than as a 401.
  static func problem(_ key: String) -> String? {
    if writePrefixes.contains(where: key.hasPrefix) { return nil }
    if secretPrefixes.contains(where: key.hasPrefix) {
      return "writeKey is a SECRET key, not a write key. Never ship it in an app — rotate it if "
        + "this build has shipped — and use the project's write key (togo_pkt_… or togo_pkl_…). "
        + "No events will be captured."
    }
    return "writeKey is not a write key (togo_pkt_… or togo_pkl_…). Check for an unsubstituted "
      + "build setting. No events will be captured."
  }
}

/// Why this string cannot be a write key, or `nil`. `Togo.setup()` disables
/// the client with this message rather than crashing (`writeKeyProblem()` in
/// the browser SDK's `client.ts`).
public func writeKeyProblem(_ key: String) -> String? { WriteKeys.problem(key) }

// MARK: - Reserved names and keys (`reserved.ts`)

struct ReservedName {
  /// Whether `track()` sends the event anyway, for the edge to refuse.
  let send: Bool
  let message: String
}

enum Reserved {
  /// `$` names are ours. Under a test key a name the edge does not accept is
  /// SENT, so its refusal reaches `verify_tracking`; under a live key it is
  /// dropped here. A name the edge does accept is dropped under both: it would
  /// be read as our own signal.
  static func checkName(_ name: String, writeKey: String) -> ReservedName? {
    guard name.hasPrefix(Wire.reservedEventPrefix) else { return nil }
    let send = !Wire.reservedEventNames.contains(name) && WriteKeys.isTest(writeKey)
    return ReservedName(
      send: send,
      message: "\"\(name)\" \(send ? "is sent for verify_tracking to report, and refused" : "was not sent"): "
        + "\"$\" names are reserved for Togo (event_name_reserved). If another tool forwards its "
        + "events to Togo, stop it; otherwise rename the event without the \"$\"."
    )
  }
}

/// The name rule the registry holds a customer's property name to — the
/// server's, copied rather than imported and held equal to it by the monorepo's
/// name-rules contract test: 1 to 255 UTF-16 code units, no control character,
/// no email address.
enum Names {
  static let maxLength = 255
  /// How much of a refused name a message shows: enough to find it in code.
  static let shownLength = 64
  static let emailPattern = #"[^\s@<>()\[\]",;:]+@[^\s@<>()\[\]",;:]+\.[a-z]{2,}"#
  private static let email = try! NSRegularExpression(
    pattern: emailPattern, options: [.caseInsensitive])

  static func isControl(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value <= 0x1F || (0x7F...0x9F).contains(scalar.value)
  }

  static func containsEmail(_ name: String) -> Bool {
    email.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
  }

  /// Whether the registry can hold this name.
  static func isHoldable(_ name: String) -> Bool {
    let length = name.utf16.count
    return length > 0 && length <= maxLength && !name.unicodeScalars.contains(where: isControl)
      && !containsEmail(name)
  }

  /// The name as a developer can find it in their code: cut to `shownLength` code units,
  /// never an address in it.
  static func shown(_ name: String) -> String {
    let cut = String(decoding: Array(name.utf16.prefix(shownLength)), as: UTF16.self)
    return email.stringByReplacingMatches(
      in: cut, range: NSRange(cut.startIndex..., in: cut), withTemplate: "<email>")
  }
}

/// A customer's property names the platform cannot use: a `$` name
/// (`property_reserved`) or one the registry cannot hold
/// (`property_name_invalid`), and their person-property twins. **Reported under
/// every key class**, once per name for the life of the client; **dropped
/// under a live key**, **sent unchanged under a test key** so the server's
/// diagnostic reaches `verify_tracking`.
final class ReservedKeys {
  private var logged = Set<String>()
  private let writeKey: String

  init(writeKey: String) { self.writeKey = writeKey }

  func check(
    _ properties: TogoProperties?, person: Bool = false,
    report: (TogoErrorCode, String, String) -> Void
  ) -> TogoProperties? {
    guard let properties else { return nil }
    return properties.filter { key, _ in keep(key, person: person, report: report) }
  }

  func check(
    _ keys: [String]?, person: Bool, report: (TogoErrorCode, String, String) -> Void
  ) -> [String]? {
    guard let keys else { return nil }
    return keys.filter { keep($0, person: person, report: report) }
  }

  private func keep(_ key: String, person: Bool, report: (TogoErrorCode, String, String) -> Void)
    -> Bool
  {
    let reserved = key.hasPrefix(Wire.reservedEventPrefix)
    if !reserved && Names.isHoldable(key) { return true }
    let code =
      reserved
      ? (person ? TogoErrorCode.personPropertyReserved : .propertyReserved)
      : (person ? .personPropertyNameInvalid : .propertyNameInvalid)
    let test = WriteKeys.isTest(writeKey)
    if logged.insert(code.rawValue + key).inserted {
      let why =
        reserved
        ? "names starting with \"$\" are reserved for Togo"
        : "a property name is 1 to \(Names.maxLength) characters, with no control character or email address"
      report(
        code,
        "\"\(Names.shown(key))\" \(test ? "is sent for verify_tracking to report" : "was not sent"): \(why) (\(code)).",
        Names.shown(key)
      )
    }
    return test
  }
}

/// What `setPersonProperties()` takes: `email` and `name` typed — written as
/// the reserved `$email` and `$name`, `.null` removes — beside `set`
/// (overwrite), `setOnce` (keep the earliest) and `unset` for the project's own
/// keys.
public struct PersonPropertyUpdate: Sendable, Equatable {
  /// `nil` leaves it alone; `.some(nil)` removes it.
  public var email: String??
  public var name: String??
  public var set: TogoProperties?
  public var setOnce: TogoProperties?
  public var unset: [String]?

  public init(
    email: String?? = nil, name: String?? = nil, set: TogoProperties? = nil,
    setOnce: TogoProperties? = nil, unset: [String]? = nil
  ) {
    self.email = email
    self.name = name
    self.set = set
    self.setOnce = setOnce
    self.unset = unset
  }
}

extension ReservedKeys {
  /// The wire's `personProperties`: names checked, then the typed fields
  /// written as their `$` names, after the check so the SDK's own are never
  /// dropped. `nil` when nothing is left to send.
  func personOps(_ update: PersonPropertyUpdate, report: (TogoErrorCode, String, String) -> Void)
    -> PersonPropertyOps?
  {
    var set = check(update.set, person: true, report: report)
    for (field, value) in [("email", update.email), ("name", update.name)] {
      guard let value else { continue }
      set = set ?? [:]
      set![Wire.reservedEventPrefix + field] = value.map(TogoValue.string) ?? .null
    }
    let ops = PersonPropertyOps(
      set: set, setOnce: check(update.setOnce, person: true, report: report),
      unset: check(update.unset, person: true, report: report))
    let nonEmpty =
      !(ops.set ?? [:]).isEmpty || !(ops.setOnce ?? [:]).isEmpty || !(ops.unset ?? []).isEmpty
    return nonEmpty ? ops : nil
  }
}

// MARK: - Structural caps (`limits.ts`)

enum Limits {
  /// The keys that survive the property cap and the ones dropped, or `nil` within it — the
  /// server's rule and every SDK's, in two tiers. **First every name in
  /// `Wire.platformPropertyNames`**, so a profile write never loses the email or name this SDK
  /// wrote for it, whatever sorts before them; **then the rest in ascending UTF-16 code-unit order**
  /// until 256 are kept. Compared as `utf16` views, never with `<`, which compares Unicode scalars
  /// and disagrees for a character outside the Basic Multilingual Plane; and never in a
  /// dictionary's order, which Swift does not keep, so the same call would lose different keys from
  /// one launch to the next.
  static func keep(_ keys: [String]) -> (kept: [String], dropped: [String])? {
    let max = Wire.maxEnvelopePropertiesPerEvent
    guard keys.count > max else { return nil }
    // Distinct names, in first-seen order: an `unset` list may repeat one, and a repeat is not a key.
    var seen = Set<String>()
    let unique = keys.filter { seen.insert($0).inserted }
    guard unique.count > max else { return nil }
    let platform = unique.filter(Wire.platformPropertyNames.contains)
    let rest = unique.filter { !Wire.platformPropertyNames.contains($0) }
      .sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    let room = max - platform.count
    return (platform + rest.prefix(room), Array(rest.dropFirst(room)))
  }

  /// `value` cut to `maxEnvelopePropertyValueLength` UTF-16 code units — the
  /// server's count, not Swift's `Character`s — never through a surrogate pair,
  /// so the result is always well-formed text. No ellipsis: that would store a
  /// value nobody sent.
  static func truncate(_ value: String) -> String {
    let units = Array(value.utf16)
    var end = Wire.maxEnvelopePropertyValueLength
    if units.count <= end { return value }
    if UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
    return String(decoding: units[..<end], as: UTF16.self)
  }
}

/// A string value over `maxEnvelopePropertyValueLength` is **truncated, never
/// refused** — the edge cuts it to the same length and keeps the event.
///
/// Why, because it is not the obvious answer: the value that crosses the cap is
/// nearly always one the developer does not control and will not see in testing
/// — a real user's URL with a long tracking query string, or text they typed.
/// No test run can rule it out, so what matters is what it costs in production
/// with nobody watching. Refusing the event lost the whole event; cutting the
/// value loses its tail, in a known way.
///
/// **Reported through `onError` under every key class**, once per event name
/// and key for the life of the client, with the kept event's id. **Cut here under a live key**, so a long
/// value never fills the queue; **sent whole under a test key**, so the edge's
/// cut reaches `verify_tracking` as `envelope_property_value_too_long`.
final class ValueCaps {
  private var logged = Set<String>()
  private let writeKey: String

  init(writeKey: String) { self.writeKey = writeKey }

  /// Cuts under a live key and hands each cut to `collect` as its once-only key, the property as
  /// the message shows it, and the message — the caller reports it once the event has its id and
  /// is really being sent, claiming the key then (`claim`). Claimed at report time, never here, so
  /// a cut on an event consent denied is never counted as told. The message names the property and
  /// the value's length, never the value: `onError` feeds error trackers, and a long value is the
  /// likeliest to hold a token or typed text.
  func cap(
    _ name: String, _ properties: TogoProperties?, collect: (String, String, String) -> Void
  ) -> TogoProperties? {
    guard var properties else { return nil }
    let test = WriteKeys.isTest(writeKey)
    let limit = Wire.maxEnvelopePropertyValueLength
    // A map still over the property cap is a test key's, sent whole: the edge drops these keys
    // before it cuts a value, so none of them is reported as cut — one loss, one report, the same
    // under either key. A live key's map is already within the cap.
    let dropped = Set(Limits.keep(Array(properties.keys))?.dropped ?? [])
    for key in properties.keys.sorted() where !dropped.contains(key) {
      guard case .string(let value) = properties[key]!, value.utf16.count > limit else { continue }
      let shown = Names.shown(key)
      collect(
        // `=` here and `#` on a drop: a different first character, so a cut's once-only key can
        // never equal a drop's, whatever the names hold.
        "=" + name + "\n" + key, shown,
        "\"\(name)\" property \"\(shown)\" is \(value.utf16.count) characters: "
          + (test ? "sent whole for verify_tracking; Togo keeps" : "cut to")
          + " its first \(limit) (envelope_property_value_too_long).")
      if !test { properties[key] = .string(Limits.truncate(value)) }
    }
    return properties
  }

  /// Whether this cut is still to be reported — true once per event name and key.
  func claim(_ once: String) -> Bool { logged.insert(once).inserted }

  /// A map over 256 properties **keeps its first 256 in sort order and drops the rest; the event
  /// is kept** — the edge's rule, applied here under a live key and left to the edge under a test
  /// key, so the drop reaches `verify_tracking`. The event that crosses the cap is nearly always a
  /// whole object passed as properties, whose width grows with a real user's data.
  ///
  /// **Counted on the map as it goes on the wire**, before the reserved and unusable-name checks,
  /// which the edge does not make: a test key's map must be cut exactly as a live key's. `extra`
  /// names the keys the SDK adds afterwards — a profile write's `$email` and `$name`. Collected
  /// like a cut, as the once-only key and the message, and reported once per event name and map
  /// with the kept event's id. The message names the first ten dropped names, never a value.
  func capCount(
    _ name: String, _ properties: TogoProperties?, map: String = "properties", extra: [String] = [],
    collect: (String, String) -> Void
  ) -> TogoProperties? {
    guard let properties,
      let kept = capCount(name, Array(Set(properties.keys).union(extra)), map: map, collect: collect)
    else { return properties }
    return properties.filter { kept.contains($0.key) }
  }

  /// The `unset` list, cut the same way. `nil` back means unchanged.
  func capCount(_ name: String, _ keys: [String]?, map: String, collect: (String, String) -> Void)
    -> [String]?
  {
    guard let keys, let kept = capCount(name, keys, map: map, collect: collect) else { return keys }
    return keys.filter(kept.contains)
  }

  /// The kept set under a live key, `nil` within the cap or under a test key.
  private func capCount(
    _ name: String, _ keys: [String], map: String, collect: (String, String) -> Void
  ) -> Set<String>? {
    guard let cap = Limits.keep(keys) else { return nil }
    let test = WriteKeys.isTest(writeKey)
    let names = cap.dropped.prefix(Wire.maxReportedDroppedProperties).map(Names.shown)
    let more = cap.dropped.count - names.count
    collect(
      "#" + name + "\n" + map,
      "\"\(name)\"\(map == "properties" ? "" : " " + map) has \(cap.kept.count + cap.dropped.count) properties: "
        + (test ? "sent whole for verify_tracking; Togo keeps" : "kept")
        + " the first \(Wire.maxEnvelopePropertiesPerEvent) in sort order and "
        + (test ? "drops " : "dropped ") + names.joined(separator: ", ")
        + (more > 0 ? " and \(more) more" : "") + " (envelope_properties_too_many).")
    return test ? nil : Set(cap.kept)
  }
}

// MARK: - Default properties (`defaults.ts`)

/// Set once at `setup()`, stamped on every `track()` event, never on
/// `$identify` or `$set_person_properties`. On a collision the event's value
/// wins and the SDK says so, once per key.
final class DefaultProperties {
  private let fixed: TogoProperties
  private var reported = Set<String>()
  private let log: TogoLogger

  init(_ defaults: TogoProperties?, log: @escaping TogoLogger) {
    fixed = defaults ?? [:]
    self.log = log
  }

  func merge(_ name: String, _ properties: TogoProperties) -> TogoProperties {
    if fixed.isEmpty { return properties }
    var merged = fixed
    for key in properties.keys.sorted() {
      if fixed[key] != nil, reported.insert(key).inserted {
        log("\"\(name)\" overrides default property \"\(key)\".")
      }
      merged[key] = properties[key]
    }
    return merged
  }
}

/// The batch's `app`: each value a 1–64 character string, or left out and
/// logged once (`app.ts`). `nil` when neither survives.
func validatedApp(_ app: AppInfo?, log: TogoLogger) -> AppInfo? {
  guard let app else { return nil }
  func valid(_ name: String, _ value: String?) -> String? {
    guard let value else { return nil }
    if !value.isEmpty, value.utf16.count <= Wire.maxAppDeviceFieldLength { return value }
    log("\(name) must be a string of 1–\(Wire.maxAppDeviceFieldLength) characters; not sent")
    return nil
  }
  let checked = AppInfo(version: valid("appVersion", app.version), build: valid("appBuild", app.build))
  return checked.version == nil && checked.build == nil ? nil : checked
}

/// The batch's `device`: a value past the edge's bound is left out, which is
/// what the edge would do anyway.
func validatedDevice(_ device: DeviceInfo?) -> DeviceInfo? {
  guard let device else { return nil }
  func bounded(_ value: String?) -> String? {
    guard let value, !value.isEmpty, value.utf16.count <= Wire.maxAppDeviceFieldLength else {
      return nil
    }
    return value
  }
  let checked = DeviceInfo(
    os: bounded(device.os), osVersion: bounded(device.osVersion), model: bounded(device.model),
    deviceType: bounded(device.deviceType))
  return checked == DeviceInfo() ? nil : checked
}
