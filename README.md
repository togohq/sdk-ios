# Togo AI iOS SDK

The Swift SDK for iOS and iPadOS apps: `track`, `identify`, `setPersonProperties`, `reset`, consent,
sessions, and an offline queue that survives the app being killed.

## Install

In Xcode: **File → Add Package Dependencies…**, enter `https://github.com/togohq/sdk-ios`, choose
**Up to Next Major Version** from `1.0.0`, and add the **Togo** library to your app target. Or in a
`Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/togohq/sdk-ios", from: "1.0.0")
],
targets: [
  .target(name: "MyApp", dependencies: [.product(name: "Togo", package: "sdk-ios")])
]
```

iOS 15 or later, Swift 6. No dependencies.

## Use

```swift
import Togo

#if DEBUG
  let key = "togo_pkt_…"  // a test key: verify_tracking sees the simulator's events
#else
  let key = "togo_pkl_…"
#endif

Togo.setup(TogoConfig(writeKey: key))
Togo.track("plan_selected", properties: ["plan_id": "pro", "seats": 5])
Togo.identify("account_8412")
Togo.setPersonProperties(email: "ada@example.com", name: "Ada")
Togo.reset()  // at logout
```

Every call can be made from any thread and never waits on the network. No call throws: a refused
call logs one `[togo]` line saying why, and `TogoConfig(onError:)` receives it too.

With no code of yours, the SDK sends `$app_installed` on an install's first launch, `$app_updated`
when the app's version or build changes, and `$app_opened` each time the app comes to the
foreground, and it keeps the session across the app being suspended and killed. Every event carries
the app's version and build, read from the bundle. The device id is the identifier for vendor, read
once and stored. Identity is one file in Application Support, excluded from backup; deleting the app,
or `Togo.setConsent(.denied)`, deletes it.

In the first release of your app that adds the SDK, every existing user's first launch sends
`$app_installed`, because there is no earlier install to find. Expect a one-time spike of installs
in that release.

## Privacy

The SDK never reads the advertising identifier (IDFA) or the App Tracking Transparency status, never
shows the tracking prompt, and links neither `AdSupport` nor `AppTrackingTransparency`. Its privacy
manifest, which Xcode adds to your app's privacy report, declares:

- **No tracking**, and no tracking domains.
- **Collected data:** Device ID, User ID and Product Interaction — each linked to the user, none
  used for tracking, all for Analytics. Answer the App Store privacy questions the same way for the
  data the SDK collects.
- **One required-reason API:** system boot time (`35F9.1`), the monotonic clock that measures
  elapsed time within the app's process.

## Development

```bash
swift build && swift test         # macOS or Linux: the core, the lifecycle rules, the scenarios
swift run togo-scenarios          # the shared scenarios against their expected batches
sh scripts/test-simulator.sh      # every suite on an iOS Simulator, with the UIKit adapter's (macOS + Xcode)
sh scripts/check-size.sh          # the size gate and the linked-frameworks check (macOS + Xcode)
```

The size gate builds `Examples/TogoExample` in Release for arm64 with and without the package and
fails when the SDK adds more than 420 KB, or when the app links `AdSupport` or
`AppTrackingTransparency`. The UIKit adapter only forwards notifications; the rules it forwards into
are in `TogoCore`, so `swift test` covers them anywhere. What neither can show is a device before
its first unlock after a reboot: the identity file and the IDFV are unreadable then, and only a
physical device demonstrates it.

Apache-2.0.
