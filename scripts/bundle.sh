#!/bin/zsh
# Builds a release binary and wraps it into build/MayloveE.app (ad-hoc signed).
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release
bin_dir=$(swift build -c release --show-bin-path)

app=build/MayloveE.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/MayloveE" "$app/Contents/MacOS/MayloveE"
# SwiftPM resource bundles (e.g. tree-sitter queries) are looked up in Contents/Resources.
cp -R "$bin_dir"/*.bundle "$app/Contents/Resources/"
cp Support/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"

echo "Built $app"
