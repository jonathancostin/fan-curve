#!/bin/zsh
set -euo pipefail

action=${1:-install}
[[ $action == install || $action == uninstall ]] || { echo "usage: $0 [install|uninstall]" >&2; exit 2; }
[[ $EUID != 0 ]] || { echo "run this as your normal macOS user" >&2; exit 2; }

script_dir=${0:A:h}
project_dir=${script_dir:h}
resource_dir="/Applications/FanCurve.app/Contents/Resources"
[[ -x $resource_dir/FanCurveHelper && -f $resource_dir/com.jonathan.FanCurveHelper.plist ]] \
    || resource_dir="$project_dir/build/FanCurve.app/Contents/Resources"
[[ -x $resource_dir/FanCurveHelper && -f $resource_dir/com.jonathan.FanCurveHelper.plist ]] \
    || resource_dir="$script_dir"
helper_source="$resource_dir/FanCurveHelper"
template_source="$resource_dir/com.jonathan.FanCurveHelper.plist"

if [[ $action == install ]]; then
    [[ -x $helper_source && -f $template_source ]] || { echo "build and install FanCurve.app first" >&2; exit 1; }
    helper_hash=$(/usr/bin/shasum -a 256 "$helper_source" | /usr/bin/awk '{print $1}')
    template_hash=$(/usr/bin/shasum -a 256 "$template_source" | /usr/bin/awk '{print $1}')
else
    helper_hash=-
    template_hash=-
fi

# ponytail: ad-hoc local builds cannot use notarization-required SMAppService;
# this pins pre-authorization hashes and runs no user-writable script as root.
/usr/bin/osascript -l JavaScript - "$action" "$(id -u)" "$helper_source" "$template_source" "$helper_hash" "$template_hash" <<'JXA'
function run(argv) {
    const quote = value => "'" + String(value).replace(/'/g, "'\"'\"'") + "'";
    const rootScript = String.raw`set -euo pipefail

action=$1
owner_uid=$2
helper_source=$3
template_source=$4
expected_helper_hash=$5
expected_template_hash=$6
label=com.jonathan.FanCurveHelper
helper_destination=/Library/PrivilegedHelperTools/$label
plist_destination=/Library/LaunchDaemons/$label.plist

if [[ $action == uninstall ]]; then
    set +e
    /bin/launchctl bootout system/$label >/dev/null 2>&1
    set -e
    for attempt in {1..20}; do
        [[ ! -e /var/run/fancurve.active ]] && break
        /bin/sleep 0.25
    done
    if [[ -e /var/run/fancurve.active ]]; then
        /bin/launchctl bootstrap system $plist_destination
        /bin/launchctl kickstart -k system/$label
        echo "automatic fan restoration was not confirmed; helper restarted, disable the curve and retry" >&2
        exit 1
    fi
    /bin/rm -f $helper_destination $plist_destination
    echo "Fan Curve background helper removed"
    exit
fi

[[ $action == install && $owner_uid == <-> && $owner_uid != 0 ]] || { echo "invalid install request" >&2; exit 2; }
stage=$(/usr/bin/mktemp -d /var/tmp/fancurve-install.XXXXXX)
trap '/bin/rm -rf "$stage"' EXIT
/bin/cp $helper_source $stage/helper
/bin/cp $template_source $stage/template.plist
actual_helper_hash=$(/usr/bin/shasum -a 256 $stage/helper | /usr/bin/awk '{print $1}')
actual_template_hash=$(/usr/bin/shasum -a 256 $stage/template.plist | /usr/bin/awk '{print $1}')
[[ $actual_helper_hash == $expected_helper_hash && $actual_template_hash == $expected_template_hash ]] || { echo "install files changed during authorization" >&2; exit 1; }
/usr/bin/codesign --verify --strict $stage/helper
/usr/bin/sed "s/__OWNER_UID__/$owner_uid/g" $stage/template.plist > $stage/$label.plist
/usr/bin/plutil -lint $stage/$label.plist >/dev/null

old_helper=0
old_plist=0
old_loaded=0
[[ -f $helper_destination ]] && { /bin/cp $helper_destination $stage/old-helper; old_helper=1; }
[[ -f $plist_destination ]] && { /bin/cp $plist_destination $stage/old.plist; old_plist=1; }
/bin/launchctl print system/$label >/dev/null 2>&1 && old_loaded=1
set +e
/bin/launchctl bootout system/$label >/dev/null 2>&1
set -e

if /usr/bin/install -d -o root -g wheel -m 0755 /Library/PrivilegedHelperTools \
    && /usr/bin/install -o root -g wheel -m 0755 $stage/helper $helper_destination \
    && /usr/bin/install -o root -g wheel -m 0644 $stage/$label.plist $plist_destination \
    && /bin/launchctl bootstrap system $plist_destination \
    && /bin/launchctl enable system/$label \
    && /bin/launchctl kickstart -k system/$label; then
    echo "Fan Curve background helper installed for UID $owner_uid"
    exit
else
    failure=$?
    (( failure == 0 )) && failure=1
    rollback_failed=0
    set +e
    /bin/launchctl bootout system/$label >/dev/null 2>&1
    if (( old_helper )); then /usr/bin/install -o root -g wheel -m 0755 $stage/old-helper $helper_destination || rollback_failed=1; else /bin/rm -f $helper_destination || rollback_failed=1; fi
    if (( old_plist )); then /usr/bin/install -o root -g wheel -m 0644 $stage/old.plist $plist_destination || rollback_failed=1; else /bin/rm -f $plist_destination || rollback_failed=1; fi
    if (( old_loaded && old_plist )); then /bin/launchctl bootstrap system $plist_destination || rollback_failed=1; fi
    set -e
    if (( rollback_failed )); then
        echo "helper installation and rollback both failed" >&2
    else
        echo "helper installation failed; previous service restored" >&2
    fi
    exit $failure
fi`;

    const app = Application.currentApplication();
    app.includeStandardAdditions = true;
    const command = "/bin/zsh -c " + quote(rootScript) + " -- " + argv.map(quote).join(" ");
    return app.doShellScript(command, { administratorPrivileges: true });
}
JXA
