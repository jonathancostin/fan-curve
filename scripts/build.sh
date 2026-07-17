#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
app="$project_dir/build/FanCurve.app"

cd "$project_dir"
swift build -c release

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/FanCurveApp "$app/Contents/MacOS/FanCurveApp"
cp .build/release/FanCurveHelper "$app/Contents/Resources/FanCurveHelper"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Vendor/Stats/LICENSE "$app/Contents/Resources/Stats-LICENSE.txt"
chmod 755 "$app/Contents/MacOS/FanCurveApp" "$app/Contents/Resources/FanCurveHelper"
codesign --force --deep --sign - "$app"

echo "$app"
