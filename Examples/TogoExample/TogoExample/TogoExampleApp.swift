import SwiftUI
import Togo

/// The smallest app that uses the SDK: set up at launch, one event on a tap.
/// The lifecycle events — `$app_installed`, `$app_updated`, `$app_opened` — need
/// no code. `scripts/check-size.sh` builds this app with and without the package.
@main
struct TogoExampleApp: App {
  init() {
    // Paste a project's TEST key (`togo_pkt_…`) to see these events in
    // verify_tracking. This placeholder is not a key: the SDK logs one line
    // saying so and sends nothing. TOGO_WRITE_KEY and TOGO_ENDPOINT in the
    // launch environment override both, for a local stack.
    let environment = ProcessInfo.processInfo.environment
    var config = TogoConfig(writeKey: environment["TOGO_WRITE_KEY"] ?? "PASTE_YOUR_TEST_KEY")
    if let endpoint = environment["TOGO_ENDPOINT"].flatMap(URL.init(string:)) {
      config.endpoint = endpoint
    }
    Togo.setup(config)
  }

  var body: some Scene {
    WindowGroup {
      Button("Track an event") {
        Togo.track("example_button_tapped")
      }
    }
  }
}
