#!/bin/sh
# A ceiling on what this SDK adds to a customer's app, and a check that it never
# links the advertising frameworks.
#
# WHAT IS MEASURED: how much a Release, arm64 build of the example app grows
# when it adds the package. Examples/TogoExample is built twice — the
# `TogoExample` target, which links the package, and `TogoExampleBaseline`, the
# same app without it — and the SDK is charged the difference in the Mach-O's
# __TEXT, __DATA_CONST and __DATA segments: their sections' sizes, from
# `size -m`. That is the code, the constants and the Swift metadata the SDK
# puts in the app. __DATA_CONST counts because arm64 Swift puts its metadata
# there. __LINKEDIT does not: it is symbol tables, which the App Store build
# strips. Section sizes rather than segment sizes, because a segment is rounded
# up to a 16 KB page, which would move the number in 16 KB steps. Uncompressed,
# because the App Store's download size depends on compression and app
# thinning. The resource bundle (the privacy manifest, ~2 KB) is not counted.
#
# THE CEILING: 340 KB. It started at 400 KB, an estimate; the first real
# measurement, on 2026-11-19 with Xcode 26.4, was 275,723 bytes (269 KB), and
# the gate is set about 25% above it. Raise it deliberately, in the same commit
# as the reason — never quietly. The Swift runtime ships with iOS, so this is
# the SDK's own code only, and one dependency would trip it on its own.
#
# THE LINKED FRAMEWORKS: the example app's binary must link neither AdSupport
# nor AppTrackingTransparency (`otool -L`). The SDK never reads the advertising
# identifier or the tracking status, and its privacy manifest says so without
# conditions; a later change that links either would make that false.
#
# REFUSES rather than skips without Xcode: this is the command that exists to
# run the gate, and a skip would read as a pass to anything checking the exit
# code. Inside the package, so the gate goes wherever the package goes.
#
# It also checks itself, without a second build: the comparison it just passed
# must fail at a ceiling one byte below the measurement, and the framework check
# must fail on a binary list that names AdSupport. A gate whose failing branch
# is broken passes everything.
set -eu
cd "$(dirname "$0")/.."

CEILING_BYTES=$((340 * 1024))
FORBIDDEN="AdSupport AppTrackingTransparency"

if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo "check-size: refusing — xcodebuild is not available. The size gate builds an iOS app, which needs Xcode (macOS only)." >&2
  exit 1
fi

OUT=.build/size
rm -rf "$OUT"
for target in TogoExample TogoExampleBaseline; do
  xcodebuild build -quiet \
    -project Examples/TogoExample/TogoExample.xcodeproj \
    -target "$target" -configuration Release -sdk iphoneos -arch arm64 \
    CODE_SIGNING_ALLOWED=NO SYMROOT="$PWD/$OUT/sym" OBJROOT="$PWD/$OUT/obj" \
    2>&1 | grep -v "All interface orientations must be supported" || true
done
APP="$OUT/sym/Release-iphoneos/TogoExample.app/TogoExample"
BASE="$OUT/sym/Release-iphoneos/TogoExampleBaseline.app/TogoExampleBaseline"
for binary in "$APP" "$BASE"; do
  if [ ! -f "$binary" ]; then
    echo "check-size: $binary was not built — see xcodebuild's output above" >&2
    exit 1
  fi
done

# The sections of __TEXT, __DATA_CONST and __DATA, summed.
segments() {
  size -m "$1" | awk '
    /^Segment/ { seg = $2; sub(":", "", seg) }
    /^\tSection/ { if (seg == "__TEXT" || seg == "__DATA_CONST" || seg == "__DATA") sum += $NF }
    END { print sum + 0 }'
}

# within <bytes> <ceiling>: 0 when the SDK fits.
within() { [ "$1" -le "$2" ]; }

# clean <otool -L output>: 0 when no forbidden framework is linked.
clean() {
  for framework in $FORBIDDEN; do
    if printf '%s\n' "$1" | grep -q "/$framework.framework/"; then
      echo "check-size: the example app links $framework.framework — the SDK must not" >&2
      return 1
    fi
  done
}

WITH=$(segments "$APP")
WITHOUT=$(segments "$BASE")
ADDED=$((WITH - WITHOUT))
LINKED=$(otool -L "$APP")

# The self-check, before the verdict: both failing branches must fail.
if within "$ADDED" $((ADDED - 1)); then
  echo "check-size: self-check failed — a ceiling below the measurement passed" >&2
  exit 1
fi
if clean "/System/Library/Frameworks/AdSupport.framework/AdSupport (compatibility version 1.0.0)" 2>/dev/null; then
  echo "check-size: self-check failed — a binary linking AdSupport passed" >&2
  exit 1
fi

echo "check-size: the SDK adds $ADDED bytes ($((ADDED / 1024)) KB) to a Release arm64 app; ceiling $CEILING_BYTES ($((CEILING_BYTES / 1024)) KB)"
if ! within "$ADDED" "$CEILING_BYTES"; then
  echo "check-size: over the ceiling by $((ADDED - CEILING_BYTES)) bytes. Shrink it, or raise the ceiling in this script deliberately, with the reason, in the same commit." >&2
  exit 1
fi
clean "$LINKED"
echo "check-size: links neither AdSupport nor AppTrackingTransparency"
