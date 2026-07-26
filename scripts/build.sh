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
cp .build/release/FanCurveProbe "$app/Contents/Resources/FanCurveProbe"
cp scripts/install-helper.sh "$app/Contents/Resources/install-helper.sh"
cp Resources/com.jonathan.FanCurveHelper.plist "$app/Contents/Resources/com.jonathan.FanCurveHelper.plist"
cp Resources/Info.plist "$app/Contents/Info.plist"
source_revision=$(git rev-parse --verify HEAD 2>/dev/null || true)
if [[ -n $source_revision && -n $(git status --porcelain --untracked-files=normal) ]]; then
    source_revision="$source_revision-dirty"
fi
[[ -z $source_revision ]] || plutil -replace FanCurveSourceRevision -string "$source_revision" "$app/Contents/Info.plist"
cp Vendor/Stats/LICENSE "$app/Contents/Resources/Stats-LICENSE.txt"
chmod 755 "$app/Contents/MacOS/FanCurveApp" "$app/Contents/Resources/FanCurveHelper" "$app/Contents/Resources/FanCurveProbe" "$app/Contents/Resources/install-helper.sh"
codesign --force --deep --sign - "$app"

echo "$app"
