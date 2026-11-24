import TogoCore

/// What makes a recording comparable to `expected/`.
public enum Normalize {
  static let idKeys: Set<String> = ["eventId", "anonymousId", "deviceId", "sessionId"]
  public static let sdkVersionPlaceholder = "<sdk.version>"

  /// The ids the SDK mints at random — `eventId`, `anonymousId`, `deviceId`,
  /// `sessionId` — replaced by placeholders in order of first appearance, and
  /// `sdk.version` by one placeholder. `drive.mjs` → `normalize()`; applied
  /// again to an already-normalized recording it renumbers, which is what the
  /// projection below relies on once it has removed batches.
  public static func placeholders(_ uploads: [ScenarioDriver.Upload]) -> [ScenarioDriver.Upload] {
    var seen: [String: [String: String]] = [:]
    func walk(_ value: JSONValue) -> JSONValue {
      switch value {
      case .array(let items): return .array(items.map(walk))
      case .object(let object):
        var out: [String: JSONValue] = [:]
        // Keys in a fixed order, so first appearance does not depend on a
        // dictionary's iteration order.
        for key in object.keys.sorted(by: walkOrder) {
          let inner = object[key]!
          if idKeys.contains(key), case .string(let id) = inner {
            var ids = seen[key, default: [:]]
            let placeholder = ids[id] ?? "<\(key):\(ids.count + 1)>"
            ids[id] = placeholder
            seen[key] = ids
            out[key] = .string(placeholder)
          } else if key == "sdk", var sdk = inner.objectValue, sdk["version"] != nil {
            sdk["version"] = .string(sdkVersionPlaceholder)
            out[key] = .object(sdk)
          } else {
            out[key] = walk(inner)
          }
        }
        return .object(out)
      default: return value
      }
    }
    return uploads.map { .init(client: $0.client, body: walk($0.body)) }
  }

  /// `events` last, so a batch's own fields never number before its events.
  private static func walkOrder(_ a: String, _ b: String) -> Bool {
    if (a == "events") != (b == "events") { return b == "events" }
    return a < b
  }
}

/// The comparison a device SDK makes against goldens the BROWSER recorded
/// (`scenarios/README.md` → "A second SDK"). Everything that says what the
/// app did must match exactly — which events, in what order, at what times,
/// in which sessions, under which ids, with which properties and profile
/// writes, under consent. What differs because a phone is not a page is
/// removed from both sides, and only that:
///
/// - **`server` batches**, from the expected side. `@togohq/sdk-node` sends
///   them; a device SDK replays the device steps only.
/// - **`page`**, from the expected events: only the web has a URL.
/// - **`deviceIdMode`**, from both batches: `cookie` on the web, the adapter's
///   `idfv` or `install` here.
/// - **`app` and `device`**, from the recorded batches: the browser's goldens
///   carry neither, and this SDK always sends them.
/// - **`sdk.name`**, compared as `sdk-ios` rather than `sdk-browser`.
///
/// Then both sides are renumbered, since removing a batch shifts the
/// placeholders after it.
public enum Projection {
  public static func expected(_ golden: JSONValue) -> [ScenarioDriver.Upload] {
    let batches = golden["batches"]?.arrayValue ?? []
    let device = batches.compactMap { batch -> ScenarioDriver.Upload? in
      guard let client = batch["client"]?.stringValue, !client.hasSuffix(":server"),
        var body = batch["body"]?.objectValue
      else { return nil }
      body.removeValue(forKey: "deviceIdMode")
      body["events"] = .array(
        (body["events"]?.arrayValue ?? []).map { event in
          guard var object = event.objectValue else { return event }
          object.removeValue(forKey: "page")
          if var sdk = object["sdk"]?.objectValue {
            sdk["name"] = .string(SDK_NAME)
            object["sdk"] = .object(sdk)
          }
          return .object(object)
        })
      return .init(client: client, body: .object(body))
    }
    return Normalize.placeholders(device)
  }

  /// A native golden (`expected-native/`), read as recorded: this runner wrote
  /// it, so nothing is removed. A second native SDK projects its own
  /// differences — `device`, `deviceIdMode`, `sdk.name` — the way this runner
  /// projects the browser's.
  public static func native(_ golden: JSONValue) -> [ScenarioDriver.Upload] {
    (golden["batches"]?.arrayValue ?? []).compactMap { batch in
      guard let client = batch["client"]?.stringValue, let body = batch["body"] else { return nil }
      return .init(client: client, body: body)
    }
  }

  public static func recorded(_ uploads: [ScenarioDriver.Upload]) -> [ScenarioDriver.Upload] {
    Normalize.placeholders(
      uploads.map { upload in
        guard var body = upload.body.objectValue else { return upload }
        for key in ["deviceIdMode", "app", "device"] { body.removeValue(forKey: key) }
        return .init(client: upload.client, body: .object(body))
      })
  }

  /// `nil` when they agree; otherwise the first difference, as a path.
  public static func difference(_ expected: [ScenarioDriver.Upload], _ actual: [ScenarioDriver.Upload])
    -> String?
  {
    if expected.map(\.client) != actual.map(\.client) {
      return "batches: expected \(expected.map(\.client)), recorded \(actual.map(\.client))"
    }
    for (index, pair) in zip(expected, actual).enumerated() {
      if let path = firstDifference(pair.0.body, pair.1.body, path: "batches[\(index)]") {
        return path
      }
    }
    return nil
  }

  static func firstDifference(_ a: JSONValue, _ b: JSONValue, path: String) -> String? {
    switch (a, b) {
    case (.object(let left), .object(let right)):
      for key in Set(left.keys).union(right.keys).sorted() {
        guard let l = left[key] else { return "\(path).\(key): not expected, recorded \(right[key]!.serialized())" }
        guard let r = right[key] else { return "\(path).\(key): expected \(l.serialized()), not recorded" }
        if let found = firstDifference(l, r, path: "\(path).\(key)") { return found }
      }
      return nil
    case (.array(let left), .array(let right)):
      for (index, pair) in zip(left, right).enumerated() {
        if let found = firstDifference(pair.0, pair.1, path: "\(path)[\(index)]") { return found }
      }
      return left.count == right.count
        ? nil : "\(path): expected \(left.count) items, recorded \(right.count)"
    default:
      return a == b ? nil : "\(path): expected \(a.serialized()), recorded \(b.serialized())"
    }
  }
}
