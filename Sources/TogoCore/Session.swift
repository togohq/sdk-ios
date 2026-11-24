/// The session, decided HERE. The server stores what it is given and has no
/// sessionization of its own. Port of the browser SDK's `session.ts`
/// with iOS's clocks.
final class Sessions {
  /// 30 minutes, the same on every platform.
  static let defaultTimeoutSeconds: Double = 1800
  /// 24 hours, and NOT configurable on any platform: the idle timeout alone
  /// never fires for an app held in the foreground.
  static let hardCapMs: Int64 = 86_400_000

  /// `sdk` or `disabled`, sent per batch as `sessionIdMode`.
  let mode: String
  private let timeoutMs: Int64
  /// The session this process last touched, with the MONOTONIC time of that
  /// touch. Idle within one process is measured on it, so a wall clock moved
  /// mid-session neither extends nor cuts the session; a record restored from
  /// the identity store after a relaunch has no baseline and falls back to its
  /// persisted wall clock, since nothing monotonic survives a reboot.
  private var baseline: (id: String, monotonicMs: Int64)?

  /// `timeoutSeconds <= 0` DISABLES sessions: no `sessionId` at all. It must
  /// never be read as instant expiry, which would mint one session per event.
  /// NaN, a mis-read setting, gets the default rather than a cut
  /// that never fires.
  init(timeoutSeconds: Double?, log: TogoLogger) {
    var seconds = timeoutSeconds ?? Sessions.defaultTimeoutSeconds
    if seconds.isNaN { seconds = Sessions.defaultTimeoutSeconds }
    if seconds > Double(Sessions.hardCapMs / 1000) {
      // Past the cap the value changes nothing, so it is probably milliseconds.
      log("sessionTimeout is seconds, max 86400")
    }
    if seconds <= 0 {
      // `-infinity` included: any value at or below zero disables.
      timeoutMs = 0
    } else {
      // Clamped BEFORE the conversion: past the cap the value changes nothing,
      // and `Int64(1e16 * 1000)` — or `.infinity` — would trap inside setup().
      // A positive value under a millisecond is still a timeout, never "off".
      let capped = min(seconds, Double(Sessions.hardCapMs / 1000))
      timeoutMs = max(1, Int64(capped * 1000))
    }
    mode = timeoutMs <= 0 ? "disabled" : "sdk"
  }

  var disabled: Bool { mode == "disabled" }

  /// Called on EVERY event. Returns the id to stamp — `nil` for none — and
  /// whether this call created the session. `canStart` is false when no human
  /// is present (a background launch, a prewarm — `AppLifecycle`): such an event joins an open
  /// session and never opens one. The record is updated in place.
  func touch(
    _ record: inout SessionRecord?, wallMs: Int64, monotonicMs: Int64, canStart: Bool,
    mintId: () -> String
  ) -> (id: String?, started: Bool) {
    if disabled { return (nil, false) }
    if let existing = record, !isOver(existing, wallMs: wallMs, monotonicMs: monotonicMs) {
      // `lastActivityAt` advances on every event with a human behind it.
      if canStart {
        record!.lastActivityAtMs = wallMs
        baseline = (existing.id, monotonicMs)
      }
      return (existing.id, false)
    }
    guard canStart else { return (nil, false) }
    // Opaque and random. Never `deviceId:startTime`.
    let fresh = SessionRecord(id: mintId(), startedAtMs: wallMs, lastActivityAtMs: wallMs)
    record = fresh
    baseline = (fresh.id, monotonicMs)
    return (fresh.id, true)
  }

  /// The app went to the background with this session open: background time
  /// is idle time, so the idle clock starts now — on the persisted wall clock,
  /// for a relaunch, and on the monotonic one, for a return to this process.
  /// Returns whether the record changed; a session already over
  /// is left to end.
  func markActivity(_ record: inout SessionRecord, wallMs: Int64, monotonicMs: Int64) -> Bool {
    guard !disabled, !isOver(record, wallMs: wallMs, monotonicMs: monotonicMs) else { return false }
    record.lastActivityAtMs = wallMs
    baseline = (record.id, monotonicMs)
    return true
  }

  /// Read-only: never mints, never extends, and never reports a session that
  /// has already ended.
  func current(_ record: SessionRecord?, wallMs: Int64, monotonicMs: Int64) -> String? {
    guard !disabled, let record, !isOver(record, wallMs: wallMs, monotonicMs: monotonicMs) else {
      return nil
    }
    return record.id
  }

  /// `reset()`: the next event opens a new session.
  func forget() { baseline = nil }

  /// Three cuts. A NEGATIVE interval cuts too: a clock that moved backwards
  /// must not be trusted to extend a session.
  private func isOver(_ record: SessionRecord, wallMs: Int64, monotonicMs: Int64) -> Bool {
    let age = wallMs - record.startedAtMs
    if age < 0 || age > Sessions.hardCapMs { return true }
    let idle: Int64
    if let baseline, baseline.id == record.id {
      idle = monotonicMs - baseline.monotonicMs
    } else {
      idle = wallMs - record.lastActivityAtMs
    }
    return idle < 0 || idle > timeoutMs
  }
}

// MARK: - Consent

/// Four states, and `setup()` is never delayed.
/// The default is `notRequired`, NOT `pending`: a pending default would buffer
/// forever and send nothing for every customer who never calls `setConsent`.
public enum TogoConsent: String, Sendable, CaseIterable {
  case notRequired = "not_required"
  case pending
  case granted
  case denied

  /// May the SDK store on this device and send from it?
  var permitted: Bool { self == .notRequired || self == .granted }
}

/// One event held while consent is `pending`: in MEMORY, with no device
/// identifier, and discarded on termination — not storage. The
/// `userId` is the caller's assertion at the call, kept so a release cannot
/// write one user's profile to the next.
struct HeldEvent {
  var eventName: String
  var properties: TogoProperties
  var clientEventMs: Int64
  var eventId: String
  var userId: String?
  var personProperties: PersonPropertyOps?
  var timezone: String?
  var app: AppInfo?
  var device: DeviceInfo?
  /// Held before the identity record was read, with no `identify()` or
  /// `reset()` before it in this process: whoever the record says is signed
  /// in — the user from the last launch — is the user of this event. Read at
  /// the release, once the record is.
  var inheritsStoredUser = false
}
