import SwiftUI

/// TogoExample without the SDK: the same app, the same button, no `import Togo`.
/// `scripts/check-size.sh` builds both and charges the SDK the difference, so
/// keep the two apps identical except for the SDK's calls.
@main
struct BaselineApp: App {
  init() {
    // Where TogoExample reads its key and sets up the SDK.
    _ = ProcessInfo.processInfo.environment["TOGO_WRITE_KEY"]
  }

  var body: some Scene {
    WindowGroup {
      Button("Track an event") {}
    }
  }
}
