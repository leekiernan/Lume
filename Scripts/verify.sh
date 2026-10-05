#!/bin/bash
# Build/test verification with terse output.
#
#   Scripts/verify.sh quick Suite [Suite…]   macOS LumeTests for the named suites only
#   Scripts/verify.sh builds                 iOS + tvOS simulator builds, in parallel
#   Scripts/verify.sh full                   builds + all of LumeTests (once per branch, before merge)
#
# Speed: simulator builds compile arm64 only (the generic destination builds
# arm64 and x86_64) and skip the index store; private DerivedData per platform,
# shared package clone (see AGENTS.md). Logs go to /tmp/lume-verify-*.log; only
# a summary is printed.
set -u
cd "$(dirname "$0")/.."

SPM=(-clonedSourcePackagesDirPath "$HOME/Library/Developer/Lume-SharedSPM")
FAST=(ARCHS=arm64 ONLY_ACTIVE_ARCH=YES COMPILER_INDEX_STORE_ENABLE=NO)
LOG=/tmp/lume-verify

build() { # platform label
    xcodebuild build -quiet -project Lume.xcodeproj -scheme Lume "${SPM[@]}" \
        -derivedDataPath "/tmp/lume-dd-$2" -destination "generic/platform=$1 Simulator" "${FAST[@]}" \
        > "$LOG-$2.log" 2>&1
    echo "$2 build: exit $?"
}

tests() { # [Suite…]
    local only=(-only-testing:LumeTests)
    if [ $# -gt 0 ]; then
        only=()
        for suite in "$@"; do only+=("-only-testing:LumeTests/$suite"); done
    fi
    xcodebuild test -project Lume.xcodeproj -scheme Lume "${SPM[@]}" -derivedDataPath /tmp/lume-dd-mac \
        -destination 'platform=macOS' COMPILER_INDEX_STORE_ENABLE=NO "${only[@]}" > "$LOG-test.log" 2>&1
    local status=$?
    echo "tests: exit $status, passed $(grep -c "^Test case .*' passed" "$LOG-test.log"), failed $(grep -c "^Test case .*' failed" "$LOG-test.log")"
    grep "^Test case .*' failed\|error:" "$LOG-test.log" | head -5
}

builds() {
    build iOS ios & build tvOS tvos & wait
    grep -h "error:" "$LOG-ios.log" "$LOG-tvos.log" | sort -u | head -5
}

case "${1:-}" in
quick) shift; tests "$@" ;;
builds) builds ;;
full) builds; tests ;;
*) echo "usage: $0 quick Suite… | builds | full"; exit 2 ;;
esac

git diff --quiet -- Lume/Localizable.xcstrings || echo "STRINGS: Localizable.xcstrings changed"
