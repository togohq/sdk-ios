import Foundation
import TogoCore

/// Whether the device's protected data can be read — false before the first
/// unlock after a reboot. Read by the identity file when its file is not there
/// (excluded from backup), from the SDK's queue; written from the main thread,
/// where UIKit reports it. Starts `false` on a device until UIKit has said
/// otherwise, because "not known yet" must not read as "available".
final class ProtectedDataState: @unchecked Sendable {
  private let lock = NSLock()
  private var available: Bool

  init(available: Bool) { self.available = available }

  var value: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return available
    }
    set {
      lock.lock()
      available = newValue
      lock.unlock()
    }
  }
}

/// Where the adapter's signals go: the SDK's queue, through `SharedClient`.
/// Platform-free, so a test drives the client's lifecycle the way UIKit does.
struct LifecycleSink: Sendable {
  var foreground: @Sendable (String) -> Void
  var background: @Sendable (String, _ completion: @escaping @Sendable () -> Void) -> Void
  var protectedDataAvailable: @Sendable () -> Void
}

#if canImport(UIKit) && !os(watchOS)
  import UIKit

  /// The UIKit half of the lifecycle: it only FORWARDS. Which notification means what — counting scenes, what is an
  /// open, when background time starts, what a locked device holds — is decided
  /// in `TogoCore`, where `swift test` covers it on any platform. What is left
  /// here is what only a simulator or a device can run: the notifications'
  /// names, the IDFV, `beginBackgroundTask` and protected data.

  /// The IDFV, read once per install (D1): only when the engine asks — it asks
  /// only while no device id is stored — and on the main thread, where UIKit
  /// gives it. `deviceId()` runs on the SDK's queue, so it never waits for the
  /// main thread (which may itself be waiting on a getter): it answers `nil`,
  /// "not now", schedules the read, and `onRead` tells the engine to try again.
  /// A nil IDFV — before the first unlock — is waited for, never replaced
  /// (D1 step 4): the next ask, after `protectedDataDidBecomeAvailable`, reads again.
  final class IdfvProvider: DeviceIdProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var cached: String?
    private var reading = false
    private let read: @MainActor @Sendable () -> String?
    var onRead: (@Sendable () -> Void)?

    init(read: @escaping @MainActor @Sendable () -> String? = { UIDevice.current.identifierForVendor?.uuidString }) {
      self.read = read
    }

    func deviceId() -> (id: String, mode: String)? {
      lock.lock()
      if let cached {
        lock.unlock()
        return (cached, "idfv")
      }
      let start = !reading
      reading = true
      lock.unlock()
      if start {
        DispatchQueue.main.async { [self] in
          let value = MainActor.assumeIsolated { read() }
          lock.lock()
          cached = value
          reading = false
          let notify = value != nil ? onRead : nil
          lock.unlock()
          notify?()
        }
      }
      return nil
    }
  }

  /// `beginBackgroundTask`, behind a seam so a test can see the pairing.
  @MainActor protocol BackgroundTasks {
    func begin(expiration: @escaping @MainActor @Sendable () -> Void) -> Int
    func end(_ task: Int)
  }

  @MainActor struct ApplicationBackgroundTasks: BackgroundTasks {
    func begin(expiration: @escaping @MainActor @Sendable () -> Void) -> Int {
      UIApplication.shared.beginBackgroundTask(withName: "ai.togohq.sdk.flush") {
        MainActor.assumeIsolated { expiration() }
      }.rawValue
    }

    func end(_ task: Int) {
      // `.invalid` is what `begin` returns when iOS declines; there is nothing to end.
      guard task != UIBackgroundTaskIdentifier.invalid.rawValue else { return }
      UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: task))
    }
  }

  @MainActor final class UIKitAdapter {
    /// One app-wide "scene" for an app with no scene manifest, which gets the
    /// `UIApplication` notifications only.
    static let applicationScene = "application"

    private let center: NotificationCenter
    private let sink: LifecycleSink
    private let tasks: BackgroundTasks
    private let protectedData: ProtectedDataState
    private let sceneId: @MainActor (Any?) -> String?
    private let readProtectedData: @MainActor () -> Bool
    private var observers: [NSObjectProtocol] = []

    init(
      center: NotificationCenter = .default, sink: LifecycleSink,
      tasks: BackgroundTasks = ApplicationBackgroundTasks(), protectedData: ProtectedDataState,
      sceneId: @escaping @MainActor (Any?) -> String? = UIKitAdapter.sceneId,
      readProtectedData: @escaping @MainActor () -> Bool = {
        UIApplication.shared.isProtectedDataAvailable
      }
    ) {
      self.center = center
      self.sink = sink
      self.tasks = tasks
      self.protectedData = protectedData
      self.sceneId = sceneId
      self.readProtectedData = readProtectedData
    }

    /// The scene's persistent identifier: stable for the scene's session, and
    /// the same object across its foreground and background notifications.
    static func sceneId(_ object: Any?) -> String? {
      (object as? UIScene)?.session.persistentIdentifier
    }

    /// iOS prewarms an app's process with nobody looking. A prewarmed
    /// launch reports no scene in front, and is never seeded as one.
    nonisolated static var isPrewarmed: Bool {
      ProcessInfo.processInfo.environment["ActivePrewarm"] == "1"
    }

    /// The scenes in front right now, for a `setup()` that runs after the
    /// first one came forward. Empty for a prewarm and a background launch.
    static func foregroundScenes(usesScenes: Bool) -> Set<String> {
      if isPrewarmed { return [] }
      if usesScenes {
        return Set(
          UIApplication.shared.connectedScenes
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
            .map(\.session.persistentIdentifier))
      }
      return UIApplication.shared.applicationState == .background ? [] : [applicationScene]
    }

    /// An app with a scene manifest — every SwiftUI app — gets the scene
    /// notifications; one without gets the application's.
    static var usesScenes: Bool {
      Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") != nil
    }

    func start(usesScenes: Bool) {
      // Scenes are a SET in the core, so the two notifications for one move
      // (will-enter-foreground, then activate) count once, and a late setup
      // that seeded a scene and then hears it activate counts it once too.
      if usesScenes {
        observe(UIScene.willEnterForegroundNotification) { [unowned self] in foreground($0) }
        observe(UIScene.didActivateNotification) { [unowned self] in foreground($0) }
        observe(UIScene.didEnterBackgroundNotification) { [unowned self] in background($0) }
        observe(UIScene.didDisconnectNotification) { [unowned self] in background($0) }
      } else {
        let app: @MainActor (Any?) -> String? = { _ in UIKitAdapter.applicationScene }
        observe(UIApplication.willEnterForegroundNotification) { [unowned self] _ in foreground(nil, app) }
        observe(UIApplication.didBecomeActiveNotification) { [unowned self] _ in foreground(nil, app) }
        observe(UIApplication.didEnterBackgroundNotification) { [unowned self] _ in background(nil, app) }
      }
      observe(UIApplication.protectedDataDidBecomeAvailableNotification) { [unowned self] _ in
        protectedData.value = true
        sink.protectedDataAvailable()
      }
      observe(UIApplication.protectedDataWillBecomeUnavailableNotification) { [unowned self] _ in
        protectedData.value = false
      }
      refreshProtectedData()
    }

    /// Ask UIKit again whether protected data is available, and if it now is,
    /// release what was held. **There is no reading at `setup()` to trust:**
    /// in `App.init` `isProtectedDataAvailable` answers `false` on an unlocked
    /// device, and `protectedDataDidBecomeAvailable` never follows, since
    /// nothing changed — so a first launch that believed it would hold its
    /// events for good. Asked when the adapter starts and before every scene
    /// coming forward, which is the moment it matters most.
    private func refreshProtectedData() {
      guard !protectedData.value, readProtectedData() else { return }
      protectedData.value = true
      sink.protectedDataAvailable()
    }

    private func observe(_ name: Notification.Name, _ handle: @escaping @MainActor (Any?) -> Void) {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { note in
          // Delivered on the main queue (`queue: .main`), where the object —
          // a UIScene — lives; it never leaves it.
          nonisolated(unsafe) let object = note.object
          MainActor.assumeIsolated { handle(object) }
        })
    }

    private func foreground(_ object: Any?, _ id: (@MainActor (Any?) -> String?)? = nil) {
      guard let scene = (id ?? sceneId)(object) else { return }
      // First, so the identity loads before the open is decided.
      refreshProtectedData()
      sink.foreground(scene)
    }

    /// The flush that follows the last scene leaving runs inside a background
    /// task, so iOS lets it finish; the task ends when the flush answers or when
    /// iOS says time is up, whichever comes first, and only once. Overrunning
    /// the expiration gets the app terminated.
    private func background(_ object: Any?, _ id: (@MainActor (Any?) -> String?)? = nil) {
      guard let scene = (id ?? sceneId)(object) else { return }
      let task = OnceTask(tasks)
      task.begin()
      sink.background(scene) {
        DispatchQueue.main.async { MainActor.assumeIsolated { task.end() } }
      }
    }
  }

  /// One background task, ended exactly once.
  @MainActor final class OnceTask {
    private let tasks: BackgroundTasks
    private var id: Int?

    init(_ tasks: BackgroundTasks) { self.tasks = tasks }

    func begin() {
      id = tasks.begin { [weak self] in self?.end() }
    }

    func end() {
      guard let id else { return }
      self.id = nil
      tasks.end(id)
    }
  }
#endif
