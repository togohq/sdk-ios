import Foundation

/// The package's privacy manifest, `PrivacyInfo.xcprivacy`, shipped as a
/// resource of this target so Xcode folds it into the app's privacy report.
///
/// What it declares, and why each line is true:
///
/// - **No tracking, no tracking domains.** The SDK never reads the advertising
///   identifier or the App Tracking Transparency status, and links neither
///   `AdSupport` nor `AppTrackingTransparency` (`scripts/check-size.sh` checks
///   the example app's binary on every run).
/// - **Device ID, User ID and Product Interaction**, each linked to the user,
///   none used for tracking, all for Analytics: the identifier for vendor (or
///   an id generated once per install), the id `identify()` is given, and the
///   events the app tracks.
/// - **One required-reason API: system boot time, reason `35F9.1`.**
///   `ProcessInfo.systemUptime` is the monotonic clock that measures elapsed
///   time inside one process (idle time, the upload offset); it is never sent
///   off the device. The SDK uses no `UserDefaults`, no file timestamp and no
///   disk-space API: its two files are written and read, never stat'ed.
///   A new use of any required-reason API is declared here in the same change.
enum PrivacyManifest {
  static var url: URL? { Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") }
}
