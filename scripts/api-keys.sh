#!/bin/zsh
# Sourced by the other scripts. API keys for keyed transit feeds live in the login Keychain as
# generic passwords, account "busbus", service "BusBus API key: <id>":
#
#   security add-generic-password -a busbus -s "BusBus API key: mta-bustime-nyc" -w <key>
#
# Each id maps to a build-setting name (MTA_BUSTIME_KEY): the one in the table below, or else the id
# upper-cased with "-" turned into "_" and "_KEY" appended. A Debug build reads it from its Info.plist
# (via Config/Secrets.xcconfig) or from the environment as BUSBUS_<NAME>; Release builds hold no
# keys at all.

typeset -gA BUSBUS_KEY_NAMES=(
  mta-bustime-nyc MTA_BUSTIME_KEY
)

# Every "BusBus API key: <id>" item in the Keychain, one id per line. Reads attributes only.
busbus_keychain_ids() {
  security dump-keychain 2>/dev/null \
    | sed -n 's/.*"svce"<blob>="BusBus API key: \(.*\)"$/\1/p' | sort -u
}

busbus_key_name() {
  print -r -- "${BUSBUS_KEY_NAMES[$1]:-${${1:u}//-/_}_KEY}"
}

busbus_key_value() {
  security find-generic-password -a busbus -s "BusBus API key: $1" -w 2>/dev/null
}

# Exports <prefix>BUSBUS_<NAME>=<key> for every key in the Keychain, and lists the names on stderr.
# Values never reach stdout. Usage: busbus_export_keys [TEST_RUNNER_]
busbus_export_keys() {
  local prefix=${1:-} id name value
  for id in ${(f)"$(busbus_keychain_ids)"}; do
    name=$(busbus_key_name $id)
    value=$(busbus_key_value $id) || continue
    [[ -n $value ]] || continue
    export "${prefix}BUSBUS_${name}=${value}"
    print -u2 "api key: ${prefix}BUSBUS_${name} (from Keychain \"$id\")"
  done
}
