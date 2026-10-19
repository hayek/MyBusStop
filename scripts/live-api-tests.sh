#!/bin/zsh
# Runs BusBusLiveAPITests — real network calls to every shipping provider — on the Mac (no simulator).
# A failing provider means its region should not be on sale until it is fixed.
#
#   scripts/live-api-tests.sh                       # all providers
#   scripts/live-api-tests.sh -only-testing:BusBusLiveAPITests/LiveAPITests/vehicles(_:)
# Keyed providers get their key from the Keychain (scripts/api-keys.sh); xcodebuild hands every
# TEST_RUNNER_-prefixed variable to the tests without the prefix. A provider whose key is missing
# is skipped, not failed.
set -euo pipefail
cd "${0:A:h}/.."
source scripts/api-keys.sh
busbus_export_keys TEST_RUNNER_
xcodebuild test -project BusBus.xcodeproj -scheme BusBusLiveAPI \
  -destination 'platform=macOS' -derivedDataPath .build/LiveAPI "$@" 2>&1 \
  | grep -v 'nw_proxy_resolver' | grep -E '(Test |error:|\*\* TEST)' || true
exit ${pipestatus[1]}
