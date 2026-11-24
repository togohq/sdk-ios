import Foundation
import TogoCore

/// The scenario format, read by a second SDK (`scenarios/README.md`).
///
/// A port of the browser SDK's scenario module (`format.mjs`) — loading, `include`
/// expansion and the planner — and it has to be EXACT: the planner's seeded
/// gaps and start times decide every `clientEventTs` in `expected/`, so a
/// rounding difference here is a golden that never matches. `mulberry32` in
/// unsigned 32-bit arithmetic is the same in every runtime, which is why the
/// format chose it.
///
/// The browser runner's validator is the AUTHORITY on what a scenario may say;
/// this one refuses only what it cannot perform — an unknown verb, step key or
/// `init` option — so a verb added to the format before this SDK can perform it
/// fails here rather than being skipped.
public enum ScenarioFormat {
  static let second: Int64 = 1000
  static let minute: Int64 = 60 * second
  static let hour: Int64 = 60 * minute
  static let day: Int64 = 24 * hour
  public static let windowMs: Int64 = 6 * day + 12 * hour
  public static let endMarginMs: Int64 = minute
  static let gapMin: Int64 = 2 * second
  static let gapMax: Int64 = 20 * second

  static let verbs = ["track", "identify", "setPersonProperties", "setConsent", "reset", "flush"]
  static let stepKeys = Set(verbs + ["include", "properties", "at", "actor", "device", "expectRejected"])
  /// The native profile (`native/`, `scenarios/README.md` → Native scenarios):
  /// the device verbs plus the three only an app has. One device, no `server`
  /// actor and no includes, so the steps are one app's life and nothing else.
  static let nativeVerbs = verbs + ["launch", "foreground", "background"]
  static let nativeStepKeys = Set(nativeVerbs + ["properties", "at"])
  static let initKeys: Set<String> = ["consent", "onDenied", "sessionTimeoutSeconds", "defaultProperties"]

  /// The shared scenarios: `scenarios/` inside this package where the package
  /// is its own repository (the public `togohq/sdk-ios`, whose release copies
  /// them in), else `../scenarios` beside it, where the SDKs live together.
  /// Never both and never neither: a run that found no scenarios would check
  /// nothing, so with neither present the second path is returned and the
  /// first read fails, naming it.
  public static let defaultRoot: URL = {
    let package = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // TogoScenarios
      .deletingLastPathComponent()  // Sources
      .deletingLastPathComponent()  // the package
    let own = package.appendingPathComponent("scenarios", isDirectory: true)
    if FileManager.default.fileExists(atPath: own.appendingPathComponent("scenarios").path) {
      return own
    }
    return package.deletingLastPathComponent().appendingPathComponent("scenarios", isDirectory: true)
  }()

  public static func scenarioNames(root: URL = defaultRoot) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
      atPath: root.appendingPathComponent("scenarios").path
    )
    .filter { $0.hasSuffix(".json") }
    .map { String($0.dropLast(".json".count)) }
    .sorted()
  }

  public static func nativeScenarioNames(root: URL = defaultRoot) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("native").path)
      .filter { $0.hasSuffix(".json") }
      .map { String($0.dropLast(".json".count)) }
      .sorted()
  }

  /// A native scenario: the first step is a `launch`, every `launch` names the
  /// build it starts, and `foreground`/`background` name a scene.
  public static func loadNativeScenario(_ name: String, root: URL = defaultRoot) throws -> Scenario {
    let raw = try readJSON(root.appendingPathComponent("native/\(name).json"))
    var problems: [String] = []
    for key in (raw["init"]?.objectValue ?? [:]).keys where !initKeys.contains(key) {
      problems.append("init.\(key) is not an option this runner can pass")
    }
    let steps = (raw["steps"]?.arrayValue ?? []).enumerated().map {
      Step(json: $1, origin: "\(name).steps[\($0)]")
    }
    for (index, step) in steps.enumerated() {
      let object = step.json.objectValue ?? [:]
      let found = nativeVerbs.filter { object[$0] != nil }
      if found.count != 1 {
        problems.append("\(step.origin): exactly one verb this runner performs (found \(found))")
      }
      for key in object.keys where !nativeStepKeys.contains(key) {
        problems.append("\(step.origin): unknown key \"\(key)\"")
      }
      if index == 0, object["launch"] == nil {
        problems.append("\(step.origin): a native scenario starts with a launch")
      }
      if let launch = object["launch"], launch["appVersion"]?.stringValue == nil
        || launch["appBuild"]?.stringValue == nil
      {
        problems.append("\(step.origin): launch names its appVersion and appBuild")
      }
      for verb in ["foreground", "background"] where object[verb] != nil {
        if object[verb]?.stringValue?.isEmpty != false {
          problems.append("\(step.origin): \(verb) names a scene")
        }
      }
    }
    if !problems.isEmpty {
      throw ScenarioError("native scenario \(name): \(problems.joined(separator: "; "))")
    }
    return Scenario(
      name: name, initOptions: raw["init"]?.objectValue ?? [:],
      deviceClockOffsetMs: raw["deviceClockOffsetMs"]?.int64Value ?? 0, steps: steps)
  }

  public static func loadScenario(_ name: String, root: URL = defaultRoot) throws -> Scenario {
    let raw = try readJSON(root.appendingPathComponent("scenarios/\(name).json"))
    var problems: [String] = []
    for key in (raw["init"]?.objectValue ?? [:]).keys where !initKeys.contains(key) {
      problems.append("init.\(key) is not an option this runner can pass")
    }
    let steps = try expand(raw["steps"]?.arrayValue ?? [], root: root, chain: [name], problems: &problems)
    for step in steps {
      let object = step.json.objectValue ?? [:]
      let found = verbs.filter { object[$0] != nil }
      if found.count != 1 {
        problems.append("\(step.origin): exactly one verb this runner performs (found \(found))")
      }
      for key in object.keys where !stepKeys.contains(key) {
        problems.append("\(step.origin): unknown key \"\(key)\"")
      }
    }
    if !problems.isEmpty {
      throw ScenarioError("scenario \(name): \(problems.joined(separator: "; "))")
    }
    return Scenario(
      name: name, initOptions: raw["init"]?.objectValue ?? [:],
      deviceClockOffsetMs: raw["deviceClockOffsetMs"]?.int64Value ?? 0, steps: steps)
  }

  static func expand(_ steps: [JSONValue], root: URL, chain: [String], problems: inout [String])
    throws -> [Step]
  {
    var out: [Step] = []
    for (index, step) in steps.enumerated() {
      let origin = "\(chain.last!).steps[\(index)]"
      guard let include = step["include"]?.stringValue else {
        out.append(Step(json: step, origin: origin))
        continue
      }
      if chain.contains(include) {
        problems.append("\(origin): include \"\(include)\" is circular")
        continue
      }
      let candidates = [
        root.appendingPathComponent("fragments/\(include).json"),
        root.appendingPathComponent("scenarios/\(include).json"),
      ]
      guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
      else {
        problems.append("\(origin): no fragment or scenario named \"\(include)\"")
        continue
      }
      let included = try readJSON(path)
      out += try expand(
        included["steps"]?.arrayValue ?? [], root: root, chain: chain + [include],
        problems: &problems)
    }
    return out
  }

  static func readJSON(_ url: URL) throws -> JSONValue {
    do {
      return try JSONValue.parse(try Data(contentsOf: url))
    } catch {
      throw ScenarioError("\(url.path): \(error)")
    }
  }

  // MARK: - Time

  /// `1d2h30m`, `40s`, `500ms` → milliseconds.
  static func parseDuration(_ text: Substring) -> Int64? {
    guard !text.isEmpty else { return nil }
    var total: Int64 = 0
    var rest = text
    while !rest.isEmpty {
      let digits = rest.prefix { $0.isASCII && $0.isNumber }
      guard !digits.isEmpty, let value = Int64(digits) else { return nil }
      rest = rest.dropFirst(digits.count)
      let unit: Int64
      if rest.hasPrefix("ms") {
        unit = 1
        rest = rest.dropFirst(2)
      } else if let first = rest.first, let scale = ["s": second, "m": minute, "h": hour, "d": day][first] {
        unit = scale
        rest = rest.dropFirst()
      } else {
        return nil
      }
      total += value * unit
    }
    return total
  }

  enum At {
    case relative(Int64)
    case absolute(Int64)
  }

  static func parseAt(_ at: String) -> At? {
    if at.hasPrefix("+") { return parseDuration(at.dropFirst()).map(At.relative) }
    if at == "now" { return .absolute(0) }
    guard at.hasPrefix("now"), at.count > 4 else { return nil }
    let sign = at[at.index(at.startIndex, offsetBy: 3)]
    guard sign == "+" || sign == "-", let ms = parseDuration(at.dropFirst(4)) else { return nil }
    return .absolute(sign == "-" ? -ms : ms)
  }

  /// Each step's offset from the visitor's start, for the relative steps; an
  /// absolute step does not move the cursor.
  static func relativeOffsets(_ steps: [Step], gap: () -> Int64) -> [Int64?] {
    var cursor: Int64 = 0
    return steps.enumerated().map { index, step in
      let at = step.json["at"]?.stringValue.flatMap(parseAt)
      if case .absolute = at { return nil }
      if case .relative(let ms) = at {
        cursor += ms
      } else if index > 0 {
        cursor += gap()
      }
      return cursor
    }
  }

  // MARK: - Plans

  /// mulberry32 — small, seedable, and the same in every runtime.
  static func prng(_ seed: UInt32) -> () -> Double {
    var a = seed
    return {
      a = a &+ 0x6D2B_79F5
      var t = a
      t = (t ^ (t >> 15)) &* (t | 1)
      t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
      return Double(t ^ (t >> 14)) / 4_294_967_296
    }
  }

  static func visitorSeed(_ seed: UInt32, _ n: UInt32) -> UInt32 {
    (seed &* 0x9E37_79B1) ^ (n &* 0x85EB_CA6B)
  }

  /// One visitor's timeline: every step with its wall-clock time, device and
  /// actor, templates filled. `format.mjs` → `planVisitor`.
  public static func planVisitor(
    _ scenario: Scenario, seed: UInt32, n: Int, nowMs: Int64, runId: String
  ) -> Plan {
    let random = prng(visitorSeed(seed, UInt32(n)))
    let gap = { gapMin + Int64((random() * Double(gapMax - gapMin)).rounded(.down)) }
    let offsets = relativeOffsets(scenario.steps, gap: gap)
    let span = max(0, offsets.compactMap { $0 }.max() ?? 0)
    let latestStart = nowMs - endMarginMs - span
    let earliestStart = nowMs - windowMs
    let start =
      latestStart - Int64((random() * Double(latestStart - earliestStart)).rounded(.down))
    let userId = "u_\(runId)_\(n)"

    var items: [PlanItem] = []
    for (index, step) in scenario.steps.enumerated() {
      var call = step.json.objectValue ?? [:]
      let at = call.removeValue(forKey: "at")?.stringValue.flatMap(parseAt)
      let actor = call.removeValue(forKey: "actor")?.stringValue ?? "client"
      let device = call.removeValue(forKey: "device")?.stringValue
      call.removeValue(forKey: "expectRejected")
      let time: Int64
      if case .absolute(let ms) = at { time = nowMs + ms } else { time = start + offsets[index]! }
      items.append(
        PlanItem(
          timeMs: time, actor: actor, device: actor == "server" ? nil : (device ?? "browser"),
          call: fill(.object(call), userId: userId, n: n), order: index))
    }
    return Plan(
      scenario: scenario.name, n: n, userId: userId,
      initOptions: fill(.object(scenario.initOptions), userId: userId, n: n).objectValue ?? [:],
      deviceClockOffsetMs: scenario.deviceClockOffsetMs, items: items)
  }

  /// `{{userId}}`, `{{n}}` and `{{chars:N}}` in every string.
  static func fill(_ value: JSONValue, userId: String, n: Int) -> JSONValue {
    switch value {
    case .string(let text): return .string(fillString(text, userId: userId, n: n))
    case .array(let items): return .array(items.map { fill($0, userId: userId, n: n) })
    case .object(let object): return .object(object.mapValues { fill($0, userId: userId, n: n) })
    default: return value
    }
  }

  static func fillString(_ text: String, userId: String, n: Int) -> String {
    guard text.contains("{{") else { return text }
    var out = ""
    var rest = Substring(text)
    while let open = rest.range(of: "{{") {
      out += rest[..<open.lowerBound]
      let after = rest[open.upperBound...]
      guard let close = after.range(of: "}}") else {
        out += rest[open.lowerBound...]
        return out
      }
      let name = after[..<close.lowerBound]
      if name == "userId" {
        out += userId
      } else if name == "n" {
        out += String(n)
      } else if name.hasPrefix("chars:"), let count = Int(name.dropFirst(6)) {
        out += String(repeating: "x", count: count)
      } else {
        out += "{{\(name)}}"
      }
      rest = after[close.upperBound...]
    }
    return out + rest
  }
}

public struct Step: Sendable {
  public var json: JSONValue
  public var origin: String
}

public struct Scenario: Sendable {
  public var name: String
  public var initOptions: [String: JSONValue]
  public var deviceClockOffsetMs: Int64
  public var steps: [Step]
}

public struct PlanItem: Sendable {
  public var timeMs: Int64
  public var actor: String
  public var device: String?
  public var call: JSONValue
  /// The step's position, so equal times keep the scenario's order (`Array.sort`
  /// in JavaScript is stable; Swift's is not guaranteed to be).
  public var order: Int
}

public struct Plan: Sendable {
  public var scenario: String
  public var n: Int
  public var userId: String
  public var initOptions: [String: JSONValue]
  public var deviceClockOffsetMs: Int64
  public var items: [PlanItem]

  /// In time order, stably.
  public var ordered: [PlanItem] {
    items.sorted { $0.timeMs != $1.timeMs ? $0.timeMs < $1.timeMs : $0.order < $1.order }
  }
}

public struct ScenarioError: Error, CustomStringConvertible {
  public let description: String
  init(_ description: String) { self.description = description }
}
