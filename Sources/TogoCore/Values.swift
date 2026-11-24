/// One property value: a string, a number, a boolean or null — the four the
/// envelope admits. No nesting and no arrays: the property-value type is one of
/// the places that keeps free text and personal data out of event properties.
///
/// Literal-expressible, so a call reads like the other SDKs':
/// `Togo.track("plan_selected", properties: ["plan_id": "pro", "seats": 5])`.
public enum TogoValue: Sendable, Equatable, Hashable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case null

  var json: JSONValue {
    switch self {
    case .string(let value): return .string(value)
    case .int(let value): return .int(Int64(value))
    case .double(let value): return .double(value)
    case .bool(let value): return .bool(value)
    case .null: return .null
    }
  }

  /// A JSON value back into a property value; `nil` for an array or object,
  /// which the envelope never carries.
  init?(json: JSONValue) {
    switch json {
    case .string(let value): self = .string(value)
    case .int(let value): self = .int(Int(value))
    case .double(let value): self = .double(value)
    case .bool(let value): self = .bool(value)
    case .null: self = .null
    case .array, .object: return nil
    }
  }
}

extension TogoValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .int(value) }
  public init(floatLiteral value: Double) { self = .double(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(nilLiteral: ()) { self = .null }
}

/// An event's properties, or a person-property map.
public typealias TogoProperties = [String: TogoValue]

extension Dictionary where Key == String, Value == TogoValue {
  var json: JSONValue { .object(mapValues(\.json)) }

  init?(json: JSONValue?) {
    guard let object = json?.objectValue else { return nil }
    var result: [String: TogoValue] = [:]
    for (key, value) in object {
      guard let converted = TogoValue(json: value) else { return nil }
      result[key] = converted
    }
    self = result
  }
}
