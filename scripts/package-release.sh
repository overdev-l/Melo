#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
app_path="${1:-$project_root/dist/Melo.app}"
release_dir="$project_root/dist/release"

[[ "$app_path" == "$project_root/dist/Melo.app" ]] || {
    print -u2 "Refusing to package an unexpected app path: $app_path"
    exit 1
}
[[ -d "$app_path" ]] || {
    print -u2 "Missing app. Run ./scripts/build-app.sh first."
    exit 1
}

"$project_root/scripts/verify-app.sh" "$app_path"

version="$(plutil -extract CFBundleShortVersionString raw -o - "$app_path/Contents/Info.plist")"
print -r -- "$version" | rg -q '^[0-9]+([.][0-9]+){1,3}([+-][0-9A-Za-z.-]+)?$' || {
    print -u2 "Unsafe bundle version: $version"
    exit 1
}

signature_details="$(codesign -dvvv "$app_path" 2>&1)"
if print -r -- "$signature_details" | rg -q '^Authority=Developer ID Application:'; then
    package_kind="notarization-pending"
elif print -r -- "$signature_details" | rg -q '^Authority=Apple Development:'; then
    package_kind="development-preview"
else
    package_kind="unsigned-preview"
fi

artifact_base="Melo-$version-macOS-$package_kind"
zip_path="$release_dir/$artifact_base.zip"
dmg_path="$release_dir/$artifact_base.dmg"
checksums_path="$release_dir/SHA256SUMS.txt"
staging_root="$(mktemp -d "${TMPDIR:-/tmp}/melo-package.XXXXXX")"
trap '/bin/rm -rf "$staging_root"' EXIT

mkdir -p "$release_dir" "$staging_root/image"
/usr/bin/ditto "$app_path" "$staging_root/image/Melo.app"
/bin/ln -s /Applications "$staging_root/image/Applications"
/bin/rm -f "$zip_path" "$dmg_path" "$checksums_path"
/usr/bin/ditto -c -k --keepParent "$app_path" "$zip_path"
/usr/sbin/diskutil image create from \
    --format UDZO \
    --volumeName "Melo $version" \
    "$staging_root/image" \
    "$dmg_path" >/dev/null

(
    cd "$release_dir"
    /usr/bin/shasum -a 256 "${zip_path:t}" "${dmg_path:t}" > "${checksums_path:t}"
)

print "Created $zip_path"
print "Created $dmg_path"
print "Created $checksums_path"
if [[ "$package_kind" != "notarization-pending" ]]; then
    print -u2 "Warning: $package_kind is not a notarized public distribution build."
fi
