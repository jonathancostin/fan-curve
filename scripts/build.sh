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
cp scripts/install-helper.sh "$app/Contents/Resources/install-helper.sh"
cp Resources/com.jonathan.FanCurveHelper.plist "$app/Contents/Resources/com.jonathan.FanCurveHelper.plist"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Vendor/Stats/LICENSE "$app/Contents/Resources/Stats-LICENSE.txt"
chmod 755 "$app/Contents/MacOS/FanCurveApp" "$app/Contents/Resources/FanCurveHelper" "$app/Contents/Resources/install-helper.sh"
codesign --force --deep --sign - "$app"

echo "$app"
