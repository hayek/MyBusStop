#!/bin/zsh
# Writes Config/Secrets.xcconfig (gitignored) from the Keychain's "BusBus API key: <id>" items, so
# the app build embeds them. Keys missing from the Keychain keep whatever value the file already had.
#
# Also writes Config/Feedback.xcconfig (gitignored, Debug and Release) from the Keychain item
# "BusBus feedback token" — the fine-grained GitHub token, limited to hayek/my-bus-stop-feedback,
# that in-app feedback files issues with:
#   security add-generic-password -a busbus -s "BusBus feedback token" -w <token>
#
#   scripts/fill-secrets.sh
set -euo pipefail
cd "${0:A:h}/.."
source scripts/api-keys.sh

file=Config/Secrets.xcconfig
[[ -f $file ]] || cp Config/Secrets.example.xcconfig $file
for id in ${(f)"$(busbus_keychain_ids)"}; do
  name=$(busbus_key_name $id)
  value=$(busbus_key_value $id) || continue
  [[ -n $value ]] || continue
  if grep -q "^$name *=" $file; then
    # Keys are URL-safe tokens; "|" never occurs in one.
    sed -i '' "s|^$name *=.*|$name = $value|" $file
  else
    print -r -- "$name = $value" >> $file
  fi
  print "filled $name from Keychain \"$id\""
done
git check-ignore -q $file || { print -u2 "warning: $file is not gitignored"; exit 1; }

feedback=Config/Feedback.xcconfig
if token=$(security find-generic-password -a busbus -s "BusBus feedback token" -w 2>/dev/null) && [[ -n $token ]]; then
  git check-ignore -q $feedback || { print -u2 "warning: $feedback is not gitignored"; exit 1; }
  umask 077
  print -r -- "// Written by scripts/fill-secrets.sh from the Keychain. Gitignored: never commit." > $feedback
  print -r -- "LOVELETTER_GITHUB_TOKEN = $token" >> $feedback
  print "filled LOVELETTER_GITHUB_TOKEN from Keychain \"BusBus feedback token\""
fi
