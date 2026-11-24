import Foundation

/// A JSON value, with its own parser and serializer.
///
/// **Hand-written rather than `Codable` or `JSONSerialization`, on purpose.** The
/// envelope must come out byte-for-byte the same on Apple platforms and on Linux,
/// and both Foundation paths blur the one distinction a property value depends on:
/// `JSONSerialization` hands back an `NSNumber` that cannot say whether it was
/// `true` or `1` on every platform, and `JSONDecoder`'s leniency about bool and
/// number has differed between Foundation releases. A property sent as `5999`
/// that came back as `5999.0`, or a `true` that became `1`, is a different value
/// on a row nothing rewrites. The whole thing is a few hundred lines with no
/// dependency, which is the price of taking none.
public enum JSONValue: Sendable, Equatable, Hashable {
  case null
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public subscript(key: String) -> JSONValue? {
    if case .object(let object) = self { return object[key] }
    return nil
  }

  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  public var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var int64Value: Int64? {
    switch self {
    case .int(let value): return value
    case .double(let value) where value.rounded() == value && abs(value) < 9e15:
      return Int64(value)
    default: return nil
    }
  }
}

// MARK: - Serialising

extension JSONValue {
  /// Compact JSON. Object keys are sorted, so one value always serialises to the
  /// same bytes — what a golden file and a queue file diff need.
  public func serialized() -> String {
    var out = ""
    write(into: &out)
    return out
  }

  /// Indented, for files a person reads (a re-recorded golden).
  public func pretty(indent: Int = 2) -> String {
    var out = ""
    writePretty(into: &out, depth: 0, indent: indent)
    return out
  }

  private func write(into out: inout String) {
    switch self {
    case .null: out += "null"
    case .bool(let value): out += value ? "true" : "false"
    case .int(let value): out += String(value)
    case .double(let value): out += JSONValue.format(value)
    case .string(let value): JSONValue.quote(value, into: &out)
    case .array(let values):
      out += "["
      for (index, value) in values.enumerated() {
        if index > 0 { out += "," }
        value.write(into: &out)
      }
      out += "]"
    case .object(let object):
      out += "{"
      for (index, key) in object.keys.sorted().enumerated() {
        if index > 0 { out += "," }
        JSONValue.quote(key, into: &out)
        out += ":"
        object[key]!.write(into: &out)
      }
      out += "}"
    }
  }

  private func writePretty(into out: inout String, depth: Int, indent: Int) {
    let pad = String(repeating: " ", count: (depth + 1) * indent)
    let close = String(repeating: " ", count: depth * indent)
    switch self {
    case .array(let values) where !values.isEmpty:
      out += "[\n"
      for (index, value) in values.enumerated() {
        out += pad
        value.writePretty(into: &out, depth: depth + 1, indent: indent)
        out += index < values.count - 1 ? ",\n" : "\n"
      }
      out += close + "]"
    case .object(let object) where !object.isEmpty:
      out += "{\n"
      let keys = object.keys.sorted()
      for (index, key) in keys.enumerated() {
        out += pad
        JSONValue.quote(key, into: &out)
        out += ": "
        object[key]!.writePretty(into: &out, depth: depth + 1, indent: indent)
        out += index < keys.count - 1 ? ",\n" : "\n"
      }
      out += close + "}"
    default:
      write(into: &out)
    }
  }

  /// A finite double in its shortest round-tripping form. JSON has no NaN or
  /// infinity, so those become `null` rather than an unparseable body that
  /// would `400` the whole batch.
  static func format(_ value: Double) -> String {
    guard value.isFinite else { return "null" }
    if value.rounded() == value && abs(value) < 1e15 { return String(Int64(value)) }
    return "\(value)"
  }

  static func quote(_ value: String, into out: inout String) {
    out += "\""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if scalar.value < 0x20 {
          let hex = String(scalar.value, radix: 16)
          out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    out += "\""
  }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible, Sendable {
  public let description: String
}

extension JSONValue {
  public static func parse(_ text: String) throws -> JSONValue {
    var parser = Parser(Array(text.utf8))
    parser.skipWhitespace()
    let value = try parser.value()
    parser.skipWhitespace()
    guard parser.atEnd else { throw parser.error("trailing characters") }
    return value
  }

  public static func parse(_ data: Data) throws -> JSONValue {
    try parse(String(decoding: data, as: UTF8.self))
  }
}

private struct Parser {
  let bytes: [UInt8]
  var index = 0

  init(_ bytes: [UInt8]) { self.bytes = bytes }

  var atEnd: Bool { index >= bytes.count }

  func error(_ message: String) -> JSONParseError {
    JSONParseError(description: "JSON: \(message) at byte \(index)")
  }

  mutating func skipWhitespace() {
    while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
  }

  mutating func value() throws -> JSONValue {
    guard index < bytes.count else { throw error("unexpected end") }
    switch bytes[index] {
    case UInt8(ascii: "{"): return try object()
    case UInt8(ascii: "["): return try array()
    case UInt8(ascii: "\""): return .string(try string())
    case UInt8(ascii: "t"): try literal("true"); return .bool(true)
    case UInt8(ascii: "f"): try literal("false"); return .bool(false)
    case UInt8(ascii: "n"): try literal("null"); return .null
    default: return try number()
    }
  }

  mutating func literal(_ word: String) throws {
    let expected = Array(word.utf8)
    guard index + expected.count <= bytes.count,
      Array(bytes[index..<index + expected.count]) == expected
    else { throw error("expected \(word)") }
    index += expected.count
  }

  mutating func object() throws -> JSONValue {
    index += 1
    var result: [String: JSONValue] = [:]
    skipWhitespace()
    if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
      index += 1
      return .object(result)
    }
    while true {
      skipWhitespace()
      guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
        throw error("expected a key")
      }
      let key = try string()
      skipWhitespace()
      guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
        throw error("expected :")
      }
      index += 1
      skipWhitespace()
      result[key] = try value()
      skipWhitespace()
      guard index < bytes.count else { throw error("unterminated object") }
      if bytes[index] == UInt8(ascii: ",") {
        index += 1
        continue
      }
      if bytes[index] == UInt8(ascii: "}") {
        index += 1
        return .object(result)
      }
      throw error("expected , or }")
    }
  }

  mutating func array() throws -> JSONValue {
    index += 1
    var result: [JSONValue] = []
    skipWhitespace()
    if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
      index += 1
      return .array(result)
    }
    while true {
      skipWhitespace()
      result.append(try value())
      skipWhitespace()
      guard index < bytes.count else { throw error("unterminated array") }
      if bytes[index] == UInt8(ascii: ",") {
        index += 1
        continue
      }
      if bytes[index] == UInt8(ascii: "]") {
        index += 1
        return .array(result)
      }
      throw error("expected , or ]")
    }
  }

  mutating func string() throws -> String {
    index += 1
    var scalars = String.UnicodeScalarView()
    var raw: [UInt8] = []
    func flush(_ raw: inout [UInt8], into scalars: inout String.UnicodeScalarView) {
      if raw.isEmpty { return }
      scalars.append(contentsOf: String(decoding: raw, as: UTF8.self).unicodeScalars)
      raw.removeAll(keepingCapacity: true)
    }
    while index < bytes.count {
      let byte = bytes[index]
      if byte == UInt8(ascii: "\"") {
        index += 1
        flush(&raw, into: &scalars)
        return String(scalars)
      }
      if byte == UInt8(ascii: "\\") {
        flush(&raw, into: &scalars)
        index += 1
        guard index < bytes.count else { break }
        let escape = bytes[index]
        index += 1
        switch escape {
        case UInt8(ascii: "\""): scalars.append("\"")
        case UInt8(ascii: "\\"): scalars.append("\\")
        case UInt8(ascii: "/"): scalars.append("/")
        case UInt8(ascii: "b"): scalars.append("\u{08}")
        case UInt8(ascii: "f"): scalars.append("\u{0C}")
        case UInt8(ascii: "n"): scalars.append("\n")
        case UInt8(ascii: "r"): scalars.append("\r")
        case UInt8(ascii: "t"): scalars.append("\t")
        case UInt8(ascii: "u"):
          let code = try hex4()
          if (0xD800...0xDBFF).contains(code), index + 1 < bytes.count,
            bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u")
          {
            index += 2
            let low = try hex4()
            if (0xDC00...0xDFFF).contains(low) {
              scalars.append(Unicode.Scalar(0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)) ?? "\u{FFFD}")
            } else {
              // A high surrogate followed by something that is not a low one:
              // never subtract (that traps on UInt32); the lone half becomes
              // U+FFFD — a Swift string cannot hold it — and the second escape
              // stands on its own.
              scalars.append("\u{FFFD}")
              scalars.append(Unicode.Scalar(low) ?? "\u{FFFD}")
            }
          } else {
            // A lone surrogate either way round has no scalar: U+FFFD.
            scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
          }
        default: throw error("bad escape")
        }
        continue
      }
      raw.append(byte)
      index += 1
    }
    throw error("unterminated string")
  }

  mutating func hex4() throws -> UInt32 {
    guard index + 4 <= bytes.count,
      let code = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
    else { throw error("bad \\u escape") }
    index += 4
    return code
  }

  mutating func number() throws -> JSONValue {
    let start = index
    var isInteger = true
    if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
    while index < bytes.count {
      let byte = bytes[index]
      if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
        index += 1
      } else if [UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"), UInt8(ascii: "+"),
        UInt8(ascii: "-")].contains(byte)
      {
        isInteger = false
        index += 1
      } else {
        break
      }
    }
    let text = String(decoding: bytes[start..<index], as: UTF8.self)
    if isInteger, let value = Int64(text) { return .int(value) }
    guard let value = Double(text) else { throw error("bad number \(text)") }
    return .double(value)
  }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByNilLiteral, ExpressibleByArrayLiteral,
  ExpressibleByDictionaryLiteral, ExpressibleByFloatLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int64) { self = .int(value) }
  public init(floatLiteral value: Double) { self = .double(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(nilLiteral: ()) { self = .null }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}
