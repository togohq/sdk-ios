import Foundation
import TogoCore

#if canImport(Darwin)
  import Darwin
#endif

/// What the platform says about the app and the device, read once at
/// `setup()`. Nothing here needs the main thread: the OS version comes from
/// `ProcessInfo`, the model from `uname`, and the device class from the model,
/// so `setup()` can run on any thread without touching UIKit.
enum Platform {
  /// The app's version and build: the options when given, the bundle otherwise.
  static func app(version: String?, build: String?, bundle: Bundle = .main) -> AppInfo? {
    let info = bundle.infoDictionary ?? [:]
    let app = AppInfo(
      version: version ?? info["CFBundleShortVersionString"] as? String,
      build: build ?? info["CFBundleVersion"] as? String)
    return app.version == nil && app.build == nil ? nil : app
  }

  /// `device` is a native SDK's word only. Off iOS — the
  /// macOS host the tests run on — there is no device to describe.
  static func device() -> DeviceInfo? {
    #if os(iOS)
      #if targetEnvironment(macCatalyst)
        let os = "macOS"
      #else
        let os = "iOS"
      #endif
      let model = hardwareModel()
      return DeviceInfo(
        os: os, osVersion: osVersion(ProcessInfo.processInfo.operatingSystemVersion),
        model: model, deviceType: model.flatMap(deviceType))
    #else
      return nil
    #endif
  }

  /// `18.1`, or `18.1.2` when there is a patch — the form `UIDevice.systemVersion` gives.
  static func osVersion(_ version: OperatingSystemVersion) -> String {
    let base = "\(version.majorVersion).\(version.minorVersion)"
    return version.patchVersion == 0 ? base : "\(base).\(version.patchVersion)"
  }

  /// The `utsname` machine id (`iPhone16,1`). On the simulator that is the
  /// host's `arm64`, so the simulated model's id is read instead.
  static func hardwareModel() -> String? {
    if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
      return simulated
    }
    #if canImport(Darwin)
      var system = utsname()
      uname(&system)
      let model = withUnsafeBytes(of: &system.machine) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
      }
      return model.isEmpty ? nil : model
    #else
      return nil
    #endif
  }

  /// `mobile` or `tablet`, the vocabulary `ctx_device_type` already holds
  /// for the web — never `phone`, which would split one breakdown into two
  /// words for one class. Read from the model id rather than from
  /// `UIDevice.userInterfaceIdiom`, which is main-actor isolated; an iPhone app
  /// running on an iPad is still on an iPad.
  static func deviceType(_ model: String) -> String? {
    if model.hasPrefix("iPad") { return "tablet" }
    if model.hasPrefix("iPhone") || model.hasPrefix("iPod") { return "mobile" }
    return nil
  }

  static func timezone() -> String? {
    let zone = TimeZone.current.identifier
    return zone.isEmpty || zone.utf16.count > Wire.maxTimezoneLength ? nil : zone
  }

  /// A server: no device, many people. `nil` on a device.
  static func serverRuntime() -> String? {
    #if os(Linux)
      return "Linux"
    #elseif os(Windows)
      return "Windows"
    #else
      return nil
    #endif
  }

  /// The SDK's two files live here, in Application Support:
  /// in the app's container, so deleting the app deletes them.
  static func directory() -> URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("ai.togohq.sdk", isDirectory: true)
  }

  static func queueURL() -> URL { directory().appendingPathComponent("queue.jsonl") }
  static func identityURL() -> URL { directory().appendingPathComponent("identity.json") }
  static func experimentsURL() -> URL { directory().appendingPathComponent("experiments.json") }
}
