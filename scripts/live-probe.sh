#!/bin/zsh
# Live-checks one or more providers without Xcode or a simulator: compiles the Transit layer plus the
# given fixture/provider files into a throwaway macOS binary and runs LiveProbe.report on each fixture.
#
#   scripts/live-probe.sh <fixtureName>[,<fixtureName>…] [extra .swift files…]
#   scripts/live-probe.sh busGovIL BusBusLiveAPITests/Fixtures/IsraelFixtures.swift
#
# Only BusBus/Transit and BusBus/MapEngine are compiled (minus ServiceHealth, which reports to
# Firebase), so a half-written provider elsewhere in the tree never breaks someone else's probe.
# Keyed providers get their key from the Keychain (scripts/api-keys.sh) as BUSBUS_<NAME>; the probe is
# built with DEBUG because only Debug builds read local keys (Release waits for Remote Config).
set -euo pipefail
cd "${0:A:h}/.."
source scripts/api-keys.sh

fixtures=(${(s:,:)1}); shift
out=$(mktemp -d)
{
  echo 'import Foundation'
  echo 'var ok = true'
  for f in $fixtures; do echo "if !(await LiveProbe.report(LiveFixture.$f)) { ok = false }"; done
  echo 'exit(ok ? 0 : 1)'
} > $out/main.swift

sdk=$(xcrun --show-sdk-path --sdk macosx)
xcrun swiftc -O -sdk $sdk -target arm64-apple-macos27.0 -module-name LiveProbeCLI \
  -default-isolation MainActor -D DEBUG \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature MemberImportVisibility -enable-bare-slash-regex \
  $(find BusBus/Transit BusBus/MapEngine -name '*.swift' ! -name ServiceHealth.swift) BusBus/Persistence/AppLanguage.swift \
  BusBusLiveAPITests/Support/LiveProbe.swift "$@" $out/main.swift -o $out/probe
busbus_export_keys
$out/probe
