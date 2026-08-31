#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
app_dir="$project_root/dist/Melo.app"
contents_dir="$app_dir/Contents"
sign_identity="${MELO_SIGN_IDENTITY:--}"

[[ "$app_dir" == "$project_root/dist/Melo.app" ]] || {
    print -u2 "Refusing to clean unexpected app path: $app_dir"
    exit 1
}

cd "$project_root"
swift build -c release --product Melo
swift build -c release --product MeloHardwareHelper

/bin/rm -rf "$app_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources" \
    "$contents_dir/Library/LaunchServices" "$contents_dir/Library/LaunchDaemons"
cp "$project_root/.build/release/Melo" "$contents_dir/MacOS/Melo"
cp "$project_root/.build/release/MeloHardwareHelper" "$contents_dir/Library/LaunchServices/MeloHardwareHelper"
cp "$project_root/Resources/dev.melo.companion.hardware.plist" \
    "$contents_dir/Library/LaunchDaemons/dev.melo.companion.hardware.plist"
cp "$project_root/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$project_root/Resources/MeloIcon.icns" "$contents_dir/Resources/MeloIcon.icns"
if [[ -d "$project_root/Resources/bin" ]]; then
    cp -R "$project_root/Resources/bin" "$contents_dir/Resources/bin"
fi
chmod +x "$contents_dir/MacOS/Melo"
chmod +x "$contents_dir/Library/LaunchServices/MeloHardwareHelper"

sign_options=(--force --sign "$sign_identity")
if [[ "$sign_identity" != "-" ]]; then
    sign_options+=(--timestamp --options runtime)
fi
codesign "${sign_options[@]}" --identifier dev.melo.companion.hardware \
    "$contents_dir/Library/LaunchServices/MeloHardwareHelper"
codesign "${sign_options[@]}" "$app_dir"
echo "$app_dir"
