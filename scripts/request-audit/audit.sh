#!/bin/zsh
# Counts the HTTP requests each provider makes per phase of a rider's journey — setup (search + lines at
# the stop), the board's pattern for up to four lines, opening each line's card, re-opening it, a
# day-later pattern refresh, and one board poll — one JSON line per fixture. Every request is counted,
# including sessions with their own configuration (RequestCounter.swift). Run it on two checkouts to
# compare what a change costs; build with -D SHAPES for the line-card phases.
#
#   scripts/request-audit/audit.sh . busGovIL,mbta out.jsonl -D SHAPES
#
# Keyed providers get their key from the Keychain (scripts/api-keys.sh), as in scripts/live-probe.sh.
set -euo pipefail
repo=$1; fixtures=(${(s:,:)2}); out=$3; shift 3
A=${0:A:h}
tmp=$(mktemp -d)
{
  echo 'import Foundation'
  echo 'RequestCounter.install()'
  echo 'var lines: [String] = []'
  for f in $fixtures; do
    echo "do { let r = await Audit.run(LiveFixture.$f); let d = try! JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]); let s = String(decoding: d, as: UTF8.self); print(s); fflush(stdout) }"
  done
} > $tmp/main.swift
cd $repo
source scripts/api-keys.sh
sdk=$(xcrun --show-sdk-path --sdk macosx)
xcrun swiftc -O -sdk $sdk -target arm64-apple-macos27.0 -module-name AuditCLI \
  -default-isolation MainActor -D DEBUG "$@" \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature MemberImportVisibility -enable-bare-slash-regex \
  $(find BusBus/Transit BusBus/MapEngine -name '*.swift' ! -name ServiceHealth.swift) BusBus/Persistence/AppLanguage.swift \
  BusBusLiveAPITests/Support/LiveProbe.swift BusBusLiveAPITests/Fixtures/*.swift \
  $A/RequestCounter.swift $A/Audit.swift $tmp/main.swift -o $tmp/audit 2>&1 | grep -E "error" | head -20 || true
busbus_export_keys
$tmp/audit > $out
rm -rf $tmp
