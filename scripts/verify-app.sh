#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
app_path="${1:-$project_root/dist/Melo.app}"
helper_path="$app_path/Contents/Library/LaunchServices/MeloHardwareHelper"
daemon_plist="$app_path/Contents/Library/LaunchDaemons/dev.melo.companion.hardware.plist"
resource_bin="$app_path/Contents/Resources/bin"

[[ -d "$app_path" ]] || { print -u2 "Missing app: $app_path"; exit 1; }
[[ -x "$helper_path" ]] || { print -u2 "Missing helper: $helper_path"; exit 1; }
[[ ! -e "$resource_bin/bin" ]] || {
    print -u2 "Unexpected nested resource directory: $resource_bin/bin"
    exit 1
}

codesign --verify --deep --strict --verbose=2 "$app_path"
plutil -lint "$app_path/Contents/Info.plist" "$daemon_plist"

app_details="$(codesign -dvvv "$app_path" 2>&1)"
helper_details="$(codesign -dvvv "$helper_path" 2>&1)"
app_identifier="$(print -r -- "$app_details" | sed -n 's/^Identifier=//p' | head -1)"
helper_identifier="$(print -r -- "$helper_details" | sed -n 's/^Identifier=//p' | head -1)"
app_team="$(print -r -- "$app_details" | sed -n 's/^TeamIdentifier=//p' | head -1)"
helper_team="$(print -r -- "$helper_details" | sed -n 's/^TeamIdentifier=//p' | head -1)"
bundle_program="$(plutil -extract BundleProgram raw -o - "$daemon_plist")"

[[ "$app_identifier" == "dev.melo.companion" ]] || {
    print -u2 "Unexpected app identifier: $app_identifier"
    exit 1
}
[[ "$helper_identifier" == "dev.melo.companion.hardware" ]] || {
    print -u2 "Unexpected helper identifier: $helper_identifier"
    exit 1
}
[[ "$app_team" == "$helper_team" ]] || {
    print -u2 "Team mismatch: app=$app_team helper=$helper_team"
    exit 1
}
[[ "$bundle_program" == "Contents/Library/LaunchServices/MeloHardwareHelper" ]] || {
    print -u2 "Unexpected BundleProgram: $bundle_program"
    exit 1
}

if [[ -n "$app_team" && "$app_team" != "not set" ]]; then
    print -r -- "$app_details" | rg -q 'flags=.*runtime' || {
        print -u2 "Signed app is missing Hardened Runtime"
        exit 1
    }
    print -r -- "$helper_details" | rg -q 'flags=.*runtime' || {
        print -u2 "Signed helper is missing Hardened Runtime"
        exit 1
    }
fi

print "Verified Melo.app: app/helper identifiers, Team ID, Hardened Runtime, plist, and nested signature are consistent."
