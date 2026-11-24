import Foundation

/// The two clocks the SDK reads.
///
/// - `wallMs` — the device's wall clock, epoch milliseconds. Every
///   `clientEventTs` and `clientSentTs`, the 24-hour cap, and idle time across
///   a process restart. The edge corrects it with four timestamps.
/// - `monotonicMs` — milliseconds since boot, immune to the wall clock being
///   moved. Idle time within one process, so an NTP correction or a manual
///   change mid-session neither extends nor cuts it.
///
/// A protocol so the scenario runner and the tests can drive both.
public protocol TogoClock: Sendable {
  func wallMs() -> Int64
  func monotonicMs() -> Int64
}

public struct SystemClock: TogoClock {
  public init() {}

  public func wallMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

  /// `ProcessInfo.systemUptime` is CLOCK_MONOTONIC-based on every platform
  /// Foundation runs on.
  public func monotonicMs() -> Int64 {
    Int64((ProcessInfo.processInfo.systemUptime * 1000).rounded(.down))
  }
}

/// ISO-8601 UTC with milliseconds and a `Z` (`2026-10-21T12:00:00.000Z`) — the
/// one format stored times take. Arithmetic rather than a formatter,
/// so the output cannot vary with a locale, a calendar setting or a Foundation
/// release, and is identical on Linux.
public enum ISOTime {
  public static func format(_ epochMs: Int64) -> String {
    let millis = Int(((epochMs % 1000) + 1000) % 1000)
    let seconds = (epochMs - Int64(millis)) / 1000
    var days = Int(seconds / 86_400)
    var rest = Int(seconds % 86_400)
    if rest < 0 {
      rest += 86_400
      days -= 1
    }
    let (year, month, day) = civil(fromDays: days)
    return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(rest / 3600, 2)):"
      + "\(pad((rest % 3600) / 60, 2)):\(pad(rest % 60, 2)).\(pad(millis, 3))Z"
  }

  static func pad(_ value: Int, _ width: Int) -> String {
    let digits = String(value)
    return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
  }

  /// `YYYY-MM-DDTHH:MM:SS(.fff)Z` back to epoch milliseconds; `nil` for any
  /// other shape (only this SDK's own output is ever parsed).
  public static func parse(_ text: String) -> Int64? {
    let chars = Array(text.utf8)
    guard chars.count >= 20, chars.last == UInt8(ascii: "Z") else { return nil }
    func number(_ from: Int, _ count: Int) -> Int? {
      guard from + count <= chars.count else { return nil }
      return Int(String(decoding: chars[from..<from + count], as: UTF8.self))
    }
    guard let year = number(0, 4), let month = number(5, 2), let day = number(8, 2),
      let hour = number(11, 2), let minute = number(14, 2), let second = number(17, 2)
    else { return nil }
    var millis = 0
    if chars.count > 20, chars[19] == UInt8(ascii: ".") {
      let digits = chars.count - 21
      guard digits >= 1, let fraction = number(20, digits) else { return nil }
      guard digits <= 9 else { return nil }
      var scaled = fraction
      for _ in 0..<max(0, digits - 3) { scaled /= 10 }
      for _ in 0..<max(0, 3 - digits) { scaled *= 10 }
      millis = scaled
    }
    let days = Int64(daysFromCivil(year: year, month: month, day: day))
    return ((days * 86_400) + Int64(hour * 3600 + minute * 60 + second)) * 1000 + Int64(millis)
  }

  // Howard Hinnant's civil-calendar algorithms: proleptic Gregorian, UTC.
  static func civil(fromDays z0: Int) -> (Int, Int, Int) {
    let z = z0 + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let day = doy - (153 * mp + 2) / 5 + 1
    let month = mp < 10 ? mp + 3 : mp - 9
    let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
    return (year, month, day)
  }

  static func daysFromCivil(year y0: Int, month: Int, day: Int) -> Int {
    let y = month <= 2 ? y0 - 1 : y0
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = month > 2 ? month - 3 : month + 9
    let doy = (153 * mp + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
  }
}

/// A random, opaque id: a v4 UUID. Event ids, the anonymous id, session ids
/// and, where there is no IDFV, the install id. Never derived from a timestamp —
/// an id with a readable start time in it gets charted as one.
public func randomId() -> String { UUID().uuidString.lowercased() }
