import Foundation

/// The app's lifecycle as the SDK sees it, decided HERE and platform-free: the
/// UIKit adapter only forwards notifications, so every rule below runs under
/// `swift test`, on Linux too.
///
/// - **Foreground is a COUNT of scenes, never a boolean**. One iPad
///   window going to the background while another is in front starts no idle
///   time and sends nothing; background begins when the last one leaves.
/// - **`$app_opened` is the move from no scene in front to one.** Never a
///   second scene joining one already in front, never a background launch (a
///   push, `BGAppRefreshTask`) and never a prewarm, since in none of them does
///   a scene come forward. `from_background` is false for the process's FIRST
///   foreground — however it was launched — and true for every return after it.
/// - **A human is present only while a scene is in front**, and only an event
///   with a human present can open a session. So `setup()` and the
///   launch's `$app_installed` never open one unless a scene was already
///   in front when the SDK started.
///
/// Confined to the engine's executor, like the engine.
public final class AppLifecycle: @unchecked Sendable {
  private var foreground: Set<String> = []
  private var hasBeenForeground = false
  private weak var engine: TogoEngine?

  public init() {}

  /// What the engine's `humanPresent` reads.
  public var isForeground: Bool { !foreground.isEmpty }

  /// The process started. `foregroundScenes` are those already in front when
  /// the SDK was set up late — after the first scene came forward — and empty
  /// for a launch the SDK saw from the start, a background launch or a prewarm.
  /// The launch's install/update event is decided first, so it precedes the
  /// `$app_opened` of the same launch.
  public func launched(_ engine: TogoEngine, foregroundScenes: Set<String> = []) {
    self.engine = engine
    foreground = foregroundScenes
    engine.start()
    if !foreground.isEmpty { opened() }
  }

  public func sceneForegrounded(_ scene: String) {
    let wasBackground = foreground.isEmpty
    foreground.insert(scene)
    if wasBackground { opened() }
  }

  /// A scene left the foreground (or was disconnected). `completion` runs
  /// after the background flush when this was the last scene in front, and at
  /// once otherwise — the adapter's background task ends there.
  public func sceneBackgrounded(_ scene: String, completion: (@Sendable () -> Void)? = nil) {
    guard foreground.remove(scene) != nil, foreground.isEmpty, let engine else {
      completion?()
      return
    }
    engine.appBackgrounded(completion: completion)
  }

  private func opened() {
    let fromBackground = hasBeenForeground
    hasBeenForeground = true
    engine?.appOpened(fromBackground: fromBackground)
  }
}
