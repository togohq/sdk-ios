// swift-tools-version:6.0
//
// `Togo` — the Togo AI iOS SDK, from github.com/togohq/sdk-ios.
//
// ZERO DEPENDENCIES, and nothing outside this package but the shared test
// scenarios (`scenarios/`, or `../scenarios` where the SDKs live together): the
// litmus test is `swift build && swift test` from this directory, on macOS and
// on Linux, and the dependency list below stays empty.
//
// Two modules, so the core can be tested on Linux and a second adapter (AppKit
// macOS) can be added later without touching it:
//
// - `TogoCore` — Foundation only. The envelope, the durable queue, batching,
//   consent, sessions, identity rules and the URLSession transport.
// - `Togo` — the public entry point (`Togo.setup(_:)`) and the UIKit adapter,
//   which forwards the lifecycle's notifications and reads the IDFV.
//
// `TogoScenarios` and `togo-scenarios` replay the shared scenarios (`scenarios/`) through the
// core. They are test tooling and are not products, so an app that adds this
// package links neither.
import PackageDescription

let strict: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
  name: "Togo",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [
    .library(name: "Togo", targets: ["Togo"])
  ],
  dependencies: [],
  targets: [
    .target(name: "TogoCore", swiftSettings: strict),
    .target(
      name: "Togo", dependencies: ["TogoCore"],
      resources: [.copy("PrivacyInfo.xcprivacy")], swiftSettings: strict),
    .target(name: "TogoScenarios", dependencies: ["TogoCore"], swiftSettings: strict),
    .executableTarget(
      name: "togo-scenarios", dependencies: ["TogoScenarios"], swiftSettings: strict),
    .testTarget(
      name: "TogoCoreTests", dependencies: ["TogoCore"], exclude: ["Fixtures"],
      swiftSettings: strict),
    .testTarget(name: "TogoTests", dependencies: ["Togo", "TogoCore"], swiftSettings: strict),
    .testTarget(
      name: "TogoScenariosTests", dependencies: ["TogoScenarios", "TogoCore"],
      swiftSettings: strict),
  ]
)
