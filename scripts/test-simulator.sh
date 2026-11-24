#!/bin/sh
# The package's tests on an iOS Simulator: what `swift test` cannot reach,
# because it needs UIKit — the adapter's notification wiring, the IDFV read,
# the background task, the files' protection class (UIKitAdapterTests) — plus
# every other suite again, compiled for iOS.
#
# REFUSES rather than skips when Xcode or an iOS Simulator is missing: this is
# the command that exists to run those tests, and a skip would read as a pass
# to anything checking the exit code. Inside the package, so it goes
# wherever the package goes.
set -eu
cd "$(dirname "$0")/.."

if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo "test-simulator: refusing — xcodebuild is not available. The UIKit adapter's tests need Xcode and an iOS Simulator (macOS only)." >&2
  exit 1
fi

# The newest iOS runtime's last iPhone, unless SIMULATOR_ID names one.
SIMULATOR_ID="${SIMULATOR_ID:-$(xcrun simctl list devices available | awk '
  /^-- iOS / { ios = 1; next }
  /^-- /     { ios = 0 }
  ios && /iPhone/ { match($0, /\([0-9A-F-]{36}\)/); id = substr($0, RSTART + 1, 36) }
  END { print id }')}"
if [ -z "$SIMULATOR_ID" ]; then
  echo "test-simulator: refusing — no iOS Simulator is installed. Add an iOS runtime in Xcode → Settings → Components." >&2
  exit 1
fi

echo "test-simulator: on $SIMULATOR_ID"
xcodebuild test -quiet \
  -scheme Togo-Package \
  -destination "id=$SIMULATOR_ID,arch=$(uname -m)" \
  -derivedDataPath .build/xcode

echo "test-simulator: every suite passed on the simulator"
