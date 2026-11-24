#if canImport(UIKit) && !os(watchOS)
  import Foundation
  import TogoCore
  import UIKit
  import XCTest

  @testable import Togo

  /// The UIKit glue, which only a simulator or a device can run:
  /// `sh scripts/test-simulator.sh`, from `pnpm test:sdks`. The rules it forwards
  /// into are `TogoCore`'s and run under `swift test` everywhere; this file
  /// checks the forwarding — the notification names, the IDFV read, the
  /// background task's pairing — and the files' protection class.
  ///
  /// The tests run in `xctest` with no host app, so `UIApplication.shared` does
  /// not exist: nothing here may reach it. That is why the adapter takes its
  /// notification centre, its scene id and its background tasks as seams.
  @MainActor
  final class UIKitAdapterTests: XCTestCase {
    final class Recorder: @unchecked Sendable {
      private let lock = NSLock()
      private var all: [String] = []
      private var completions: [@Sendable () -> Void] = []
      func record(_ line: String) {
        lock.lock()
        all.append(line)
        lock.unlock()
      }
      func hold(_ completion: @escaping @Sendable () -> Void) {
        lock.lock()
        completions.append(completion)
        lock.unlock()
      }
      func finishAll() {
        lock.lock()
        let due = completions
        completions = []
        lock.unlock()
        due.forEach { $0() }
      }
      var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return all
      }
    }

    final class Tasks: BackgroundTasks {
      var begun = 0
      var ended: [Int] = []
      var expirations: [@MainActor @Sendable () -> Void] = []
      func begin(expiration: @escaping @MainActor @Sendable () -> Void) -> Int {
        begun += 1
        expirations.append(expiration)
        return begun
      }
      func end(_ task: Int) { ended.append(task) }
    }

    final class Flag: @unchecked Sendable { var value = false }

    func adapter(
      _ recorder: Recorder, _ tasks: Tasks, center: NotificationCenter, usesScenes: Bool = true,
      protectedNow: Flag = Flag()
    ) -> (UIKitAdapter, ProtectedDataState) {
      let state = ProtectedDataState(available: false)
      let sink = LifecycleSink(
        foreground: { recorder.record("foreground \($0)") },
        background: { scene, completion in
          recorder.record("background \(scene)")
          recorder.hold(completion)
        },
        protectedDataAvailable: { recorder.record("protected data available") })
      let adapter = UIKitAdapter(
        center: center, sink: sink, tasks: tasks, protectedData: state, sceneId: { $0 as? String },
        readProtectedData: { protectedNow.value })
      adapter.start(usesScenes: usesScenes)
      return (adapter, state)
    }

    /// Lets the main queue run what was dispatched onto it.
    func drainMain() {
      let done = expectation(description: "main queue drained")
      DispatchQueue.main.async { done.fulfill() }
      wait(for: [done], timeout: 5)
    }

    /// A scene app: both "coming forward" notifications forward the scene
    /// (the core counts a set, so the pair counts once), both "going away"
    /// ones forward its leaving, inside a background task.
    func testSceneNotificationsAreForwardedByScene() {
      let recorder = Recorder()
      let tasks = Tasks()
      let center = NotificationCenter()
      let (adapter, _) = self.adapter(recorder, tasks, center: center)
      center.post(name: UIScene.willEnterForegroundNotification, object: "left")
      center.post(name: UIScene.didActivateNotification, object: "left")
      center.post(name: UIScene.didEnterBackgroundNotification, object: "left")
      center.post(name: UIScene.didDisconnectNotification, object: "right")
      XCTAssertEqual(
        recorder.lines,
        ["foreground left", "foreground left", "background left", "background right"])
      XCTAssertEqual(tasks.begun, 2)
      // The application's own notifications are not a scene app's signal.
      center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
      XCTAssertEqual(recorder.lines.count, 4)
      withExtendedLifetime(adapter) {}
    }

    /// An app with no scene manifest gets the application's notifications,
    /// as one scene.
    func testAnAppWithoutScenesIsOneScene() {
      let recorder = Recorder()
      let center = NotificationCenter()
      let (adapter, _) = self.adapter(recorder, Tasks(), center: center, usesScenes: false)
      center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
      center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
      center.post(name: UIScene.willEnterForegroundNotification, object: "ignored")
      XCTAssertEqual(recorder.lines, ["foreground application", "background application"])
      withExtendedLifetime(adapter) {}
    }

    /// The background task ends when the flush answers — once — and an
    /// expiration that comes first ends it instead, never twice.
    func testTheBackgroundTaskEndsOnceWhenTheFlushAnswersOrTimeRunsOut() {
      let recorder = Recorder()
      let tasks = Tasks()
      let center = NotificationCenter()
      let (adapter, _) = self.adapter(recorder, tasks, center: center)
      center.post(name: UIScene.didEnterBackgroundNotification, object: "a")
      XCTAssertEqual(tasks.ended, [], "not before the flush answers")
      recorder.finishAll()
      drainMain()
      XCTAssertEqual(tasks.ended, [1])
      tasks.expirations[0]()
      XCTAssertEqual(tasks.ended, [1], "ended once")

      center.post(name: UIScene.didEnterBackgroundNotification, object: "b")
      tasks.expirations[1]()
      XCTAssertEqual(tasks.ended, [1, 2], "time ran out first")
      recorder.finishAll()
      drainMain()
      XCTAssertEqual(tasks.ended, [1, 2])
      withExtendedLifetime(adapter) {}
    }

    /// D3: protected data becoming available is the unlock the core waits for.
    func testProtectedDataNotificationsSetTheStateAndReleaseWhatWasHeld() {
      let recorder = Recorder()
      let center = NotificationCenter()
      let (adapter, state) = self.adapter(recorder, Tasks(), center: center)
      center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
      XCTAssertTrue(state.value)
      XCTAssertEqual(recorder.lines, ["protected data available"])
      center.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
      XCTAssertFalse(state.value)
      withExtendedLifetime(adapter) {}
    }

    /// Found on the simulator: in `App.init` UIKit reports protected data
    /// unavailable on an unlocked device, and no notification follows, so a
    /// fresh install held its events for good. A scene coming forward asks
    /// again, and releases what was held BEFORE the open; once available, it
    /// does not ask again. The positive half: while UIKit still says no,
    /// nothing is released.
    func testASceneComingForwardReleasesWhatALateProtectedDataReadingHeld() {
      let recorder = Recorder()
      let center = NotificationCenter()
      let protectedNow = Flag()
      let (adapter, state) = self.adapter(recorder, Tasks(), center: center, protectedNow: protectedNow)
      center.post(name: UIScene.willEnterForegroundNotification, object: "a")
      XCTAssertEqual(recorder.lines, ["foreground a"])
      XCTAssertFalse(state.value)

      protectedNow.value = true
      center.post(name: UIScene.willEnterForegroundNotification, object: "b")
      center.post(name: UIScene.didActivateNotification, object: "b")
      XCTAssertEqual(
        recorder.lines, ["foreground a", "protected data available", "foreground b", "foreground b"])
      XCTAssertTrue(state.value)
      withExtendedLifetime(adapter) {}
    }

    /// The adapter asks once when it starts, too: a background launch with
    /// protected data available need not wait for a scene.
    func testTheAdapterAsksForProtectedDataWhenItStarts() {
      let recorder = Recorder()
      let protectedNow = Flag()
      protectedNow.value = true
      let (adapter, state) = self.adapter(
        recorder, Tasks(), center: NotificationCenter(), protectedNow: protectedNow)
      XCTAssertTrue(state.value)
      XCTAssertEqual(recorder.lines, ["protected data available"])
      withExtendedLifetime(adapter) {}
    }

    /// D1: the IDFV is read on the main thread when first asked, never while
    /// the asker waits; `onRead` tells the engine to ask again, and the answer
    /// is UIKit's own, with mode `idfv`.
    func testTheIdfvIsReadFromUIDeviceOnTheMainThread() {
      let provider = IdfvProvider()
      let read = expectation(description: "onRead")
      provider.onRead = { read.fulfill() }
      XCTAssertNil(provider.deviceId(), "not now: the read is scheduled")
      wait(for: [read], timeout: 5)
      let expected = UIDevice.current.identifierForVendor?.uuidString
      XCTAssertNotNil(expected)
      XCTAssertEqual(provider.deviceId()?.id, expected)
      XCTAssertEqual(provider.deviceId()?.mode, "idfv")
    }

    /// D1 step 4: a nil IDFV is not an answer and nothing is called; the next
    /// ask reads again.
    func testANilIdfvIsReadAgainAtTheNextAsk() {
      final class Values: @unchecked Sendable { var next: [String?] = [nil, "IDFV-1"] }
      let values = Values()
      let provider = IdfvProvider(read: { values.next.removeFirst() })
      let calls = Recorder()
      provider.onRead = { calls.record("read") }
      XCTAssertNil(provider.deviceId())
      drainMain()
      XCTAssertEqual(calls.lines, [])
      XCTAssertNil(provider.deviceId())
      drainMain()
      XCTAssertEqual(calls.lines, ["read"])
      XCTAssertEqual(provider.deviceId()?.id, "IDFV-1")
    }
  }
#endif
