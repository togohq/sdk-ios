import Foundation

/// The durable event queue — the one place a failure is not an error. Offline is normal
/// operation on a phone, so a failed send re-queues rather than throwing, and
/// the queue survives the app being killed, for days. It is a different thing from the consent buffer, which is memory only.
///
/// **The file is JSON Lines, one entry per line.** One more event APPENDS its
/// line; the whole file is rewritten, atomically, only when the queue changes
/// otherwise — an answer, an eviction past a bound, an expiry — once per batch
/// rather than once per event. A line cut off by a kill mid-append is skipped
/// at the next read, and every whole line before it is kept.
///
/// **Each queued event carries the `app` and `device` current when it was
/// tracked**, and `take()` never puts two different ones in one batch.
/// Both are batch-level on the wire, so an event recorded on 1.2 and flushed
/// after an update to 1.3 would otherwise be stamped 1.3 — a plausible wrong
/// answer on a row nothing rewrites.
final class EventQueue {
  struct Entry: Equatable {
    let event: RawEvent
    let app: AppInfo?
    let device: DeviceInfo?
    /// Where the event's `deviceId` came from, recorded with it: an upload made
    /// before this launch has read its identity record must still say how long
    /// the id lasts, and a batch never mixes two modes.
    let deviceIdMode: String?
    /// This entry as one line of the queue file, and the event's size on the
    /// wire — encoded ONCE, here. A rewrite joins the cached lines: re-encoding
    /// a 5,000-event backlog for each change stalled the serial queue the
    /// getters wait on.
    let line: String
    let eventBytes: Int

    init(event: RawEvent, app: AppInfo?, device: DeviceInfo?, deviceIdMode: String? = nil) {
      self.event = event
      self.app = app
      self.device = device
      self.deviceIdMode = deviceIdMode
      let eventJSON = event.json
      var object: [String: JSONValue] = ["event": eventJSON]
      if let app { object["app"] = app.json }
      if let device { object["device"] = device.json }
      if let deviceIdMode { object["deviceIdMode"] = .string(deviceIdMode) }
      line = JSONValue.object(object).serialized()
      eventBytes = eventJSON.serialized().utf8.count + 1
    }
  }

  /// Bounds, both of them, as in the browser SDK's `queue.ts`: a count bound
  /// alone lets a few fat events grow the file without limit, a byte bound
  /// alone lets a flood of tiny ones make every rewrite slow. Larger than the
  /// browser's 1,000 events and 256 KB, because an app's queue lasts days of
  /// offline use where a page's lasts seconds; still bounded, because every
  /// answer rewrites the file.
  static let maxEvents = 5_000
  /// 8 MiB: about a week of an active user's events, the 7-day age past which
  /// the edge refuses one. The queue has two copies — the file survives a kill,
  /// and this list, the WHOLE queue, is what the SDK works from — so the bound
  /// is app memory as well as disk, and stays well inside an app extension's.
  static let maxBytes = 8 * 1024 * 1024
  /// One upload's byte budget: a device SDK's 1 MiB batch, less room for the
  /// batch's own fields — cellular uploads fail and are retried whole, so it is
  /// set on its own rather than from the edge's much larger request limit.
  static let maxBatchBytes = 1_048_576 - 16 * 1024

  private(set) var entries: [Entry] = []
  /// Taken for an upload that has not been answered. **Still in the file**:
  /// iOS can kill a suspended app mid-upload with no callback — the flush on
  /// the move to the background is exactly that upload — and an event removed
  /// from the file when it was taken would be lost with the process. Kept, it
  /// is sent again at the next launch under the same `eventId`, which the edge
  /// dedupes if the first upload did land. Only an answer removes it.
  private(set) var inFlight: [Entry] = []
  /// The bytes `entries` take in the file, kept as they change so an append
  /// never sums the backlog.
  private var bytes = 0
  private var hydrated = false
  private let store: QueueStore
  private let onDrop: ([RawEvent], TogoErrorCode) -> Void

  init(store: QueueStore, onDrop: @escaping ([RawEvent], TogoErrorCode) -> Void) {
    self.store = store
    self.onDrop = onDrop
  }

  var count: Int { entries.count }

  /// Load from the file once, one entry per line. A line that does not parse
  /// — the last one, cut off by a kill mid-append — is skipped and the rest
  /// are kept. A file with no entry in it is dropped: worth less than an
  /// exception, and re-parsing the same garbage on every launch.
  func hydrate() {
    if hydrated { return }
    hydrated = true
    guard let data = store.read() else { return }
    let lines = data.split(separator: UInt8(ascii: "\n")).filter {
      !$0.allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") }
    }
    let loaded = lines.compactMap { line -> Entry? in
      guard let item = try? JSONValue.parse(Data(line)), let eventJSON = item["event"],
        let event = RawEvent(json: eventJSON)
      else { return nil }
      return Entry(
        event: event, app: AppInfo(json: item["app"]), device: DeviceInfo(json: item["device"]),
        deviceIdMode: item["deviceIdMode"]?.stringValue)
    }
    if loaded.isEmpty {
      store.remove()
      return
    }
    entries = loaded + entries
    bytes = EventQueue.size(entries)
    // Rewritten once, so a torn line does not stay in the file under the
    // appends that follow it — nor a whole last line that lost its newline,
    // which the next append would join into one line that reads as neither.
    if loaded.count != lines.count || data.last != UInt8(ascii: "\n") { persist() }
  }

  /// One more event: an APPEND of its line, not a rewrite of the file — a
  /// 5,000-event backlog rewritten on every `track()` is megabytes of writing
  /// on the queue the getters wait on. Past a bound the file is rewritten,
  /// which is where the eviction happens.
  func add(_ entry: Entry) {
    entries.append(entry)
    bytes += entry.line.utf8.count + 1
    if entries.count > EventQueue.maxEvents || bytes > EventQueue.maxBytes {
      persist()
    } else {
      store.append(Data((entry.line + "\n").utf8))
    }
  }

  private static func size(_ entries: [Entry]) -> Int {
    entries.reduce(0) { $0 + $1.line.utf8.count + 1 }
  }

  /// The next batch: up to `limit` events, oldest first, all with the same
  /// `app`, `device` and `deviceIdMode`, within one upload's bytes. Events past
  /// `MAX_EVENT_AGE_MS` at `nowMs` are dropped first and reported — the edge
  /// would refuse them, and they would crowd out events that can still land.
  func take(limit: Int, nowMs: Int64) -> [Entry] {
    let stale = entries.filter { nowMs - $0.event.clientEventMs > Wire.maxEventAgeMs }
    if !stale.isEmpty {
      entries.removeAll { nowMs - $0.event.clientEventMs > Wire.maxEventAgeMs }
      onDrop(stale.map(\.event), .timestampTooOld)
    }
    guard let first = entries.first else {
      if !stale.isEmpty { persist() }
      return []
    }
    var taken: [Entry] = []
    var batchBytes = 0
    for entry in entries {
      guard taken.count < limit, entry.app == first.app, entry.device == first.device,
        entry.deviceIdMode == first.deviceIdMode
      else { break }
      let size = entry.eventBytes
      // Always at least one: a single event past the budget goes alone and
      // the edge's 413 answers it, rather than blocking the queue forever.
      if !taken.isEmpty, batchBytes + size > EventQueue.maxBatchBytes { break }
      batchBytes += size
      taken.append(entry)
    }
    entries.removeFirst(taken.count)
    bytes = EventQueue.size(entries)
    // Not removed from the file: in flight until answered.
    inFlight = taken
    if !stale.isEmpty { persist() }
    return taken
  }

  /// The upload was answered — delivered, or refused for good: out of the file.
  func acknowledge() {
    guard !inFlight.isEmpty else { return }
    inFlight = []
    persist()
  }

  /// The upload will be retried: back at the FRONT, in order, so the oldest —
  /// closest to the age bound — are not starved. The file already holds them
  /// there, in flight first, so nothing is written. Nothing to do when a
  /// withdrawal cleared the queue while the upload was out: putting them back
  /// would keep events from before an explicit refusal.
  func retryInFlight() {
    guard !inFlight.isEmpty else { return }
    entries = inFlight + entries
    inFlight = []
    bytes = EventQueue.size(entries)
  }

  /// Forget everything, in memory and on disk. Consent withdrawal.
  func clear() {
    entries = []
    inFlight = []
    bytes = 0
    hydrated = true
    store.remove()
  }

  private func persist() {
    var dropped: [RawEvent] = []
    if entries.count > EventQueue.maxEvents {
      let excess = entries.count - EventQueue.maxEvents
      dropped += entries.prefix(excess).map(\.event)
      entries.removeFirst(excess)
    }
    // Sizes and lines are the ones each entry cached when it was made: summing
    // integers and joining strings, never re-encoding the backlog.
    var total = entries.reduce(0) { $0 + $1.line.utf8.count + 1 }
    // The byte bound evicts the OLDEST, like the count. Largest-first dropped
    // the same kinds of event every time a queue filled — some are reliably
    // bigger than others — and so quietly under-counted exactly those;
    // oldest-first loses in time order. No event over the 256 KiB limit is ever
    // queued, so there is no monster left for largest-first to protect against.
    // Counted first and removed once: `removeFirst()` in a loop shifts the
    // array each time, quadratic on a 5,000-entry queue.
    var evict = 0
    while total > EventQueue.maxBytes, entries.count - evict > 1 {
      total -= entries[evict].line.utf8.count + 1
      dropped.append(entries[evict].event)
      evict += 1
    }
    entries.removeFirst(evict)
    bytes = total
    // In flight first: that is their place in the queue if the process dies
    // before the answer, and where `retryInFlight` puts them if it comes.
    let all = inFlight + entries
    if all.isEmpty {
      store.remove()
    } else {
      store.write(Data(all.map { $0.line + "\n" }.joined().utf8))
    }
    if !dropped.isEmpty { onDrop(dropped, .queueFull) }
  }
}
