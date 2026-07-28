#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
built_app="$project_dir/build/FanCurve.app"
target_app="/Applications/Fan Curve.app"
stage=

cleanup() {
    [[ -z $stage || ! -d $stage ]] || /bin/rm -rf "$stage"
}
trap cleanup EXIT

"$project_dir/scripts/build.sh" >/dev/null
/usr/bin/codesign --verify --deep --strict "$built_app"

if /usr/bin/pgrep -x FanCurveApp >/dev/null; then
    /usr/bin/osascript -e 'tell application id "com.jonathan.FanCurve" to quit' >/dev/null
    for _ in {1..40}; do
        /usr/bin/pgrep -x FanCurveApp >/dev/null || break
        /bin/sleep 0.25
    done
    /usr/bin/pgrep -x FanCurveApp >/dev/null && {
        echo "Fan Curve did not quit; local update stopped" >&2
        exit 1
    }
fi

for _ in {1..40}; do
    [[ ! -e /var/run/fancurve.active ]] && break
    /bin/sleep 0.25
done
[[ ! -e /var/run/fancurve.active ]] || {
    echo "Apple fan control was not confirmed; local update stopped" >&2
    exit 1
}

stage=$(/usr/bin/mktemp -d "/Applications/.fancurve-local.XXXXXX")
/usr/bin/ditto "$built_app" "$stage/Fan Curve.app"
/usr/bin/codesign --verify --deep --strict "$stage/Fan Curve.app"

if [[ -e $target_app ]]; then
    /bin/mv "$target_app" "$stage/previous.app"
fi
if ! /bin/mv "$stage/Fan Curve.app" "$target_app"; then
    [[ ! -e $stage/previous.app ]] || /bin/mv "$stage/previous.app" "$target_app"
    exit 1
fi

bundled_helper="$target_app/Contents/Resources/FanCurveHelper"
installed_helper="/Library/PrivilegedHelperTools/com.jonathan.FanCurveHelper"
bundled_plist="$target_app/Contents/Resources/com.jonathan.FanCurveHelper.plist"
installed_plist="/Library/LaunchDaemons/com.jonathan.FanCurveHelper.plist"
bundled_hash=$(/usr/bin/shasum -a 256 "$bundled_helper" | /usr/bin/awk '{print $1}')
installed_hash=
if [[ -f $installed_helper ]]; then
    installed_hash=$(/usr/bin/shasum -a 256 "$installed_helper" | /usr/bin/awk '{print $1}')
fi
/usr/bin/sed "s/__OWNER_UID__/$(id -u)/g" "$bundled_plist" > "$stage/expected-helper.plist"
if [[ $bundled_hash != $installed_hash ]] || ! /usr/bin/cmp -s "$stage/expected-helper.plist" "$installed_plist"; then
    "$target_app/Contents/Resources/install-helper.sh" || {
        /usr/bin/open "$target_app"
        echo "Helper update failed; Fan Curve reopened in safe mode" >&2
        exit 1
    }
fi

"$target_app/Contents/MacOS/FanCurveApp" --enable-after-restart || {
    /usr/bin/open "$target_app"
    exit 1
}
/usr/bin/open "$target_app"
echo "Installed local Fan Curve; launch and resume after login are enabled"
