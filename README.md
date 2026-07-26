# Fan Curve

A native macOS menu-bar app for Macs with fans. Add, delete, or drag points on a temperature-to-fan graph; the app displays average CPU temperature and applies the interpolated fan percentage across every detected fan.

`0%` means the detected minimum safe RPM and `100%` means the detected maximum. A one-time installer adds the root background helper required for fan writes. After that, enabling the curve does not prompt again. Quitting, disabling control, losing the heartbeat, sleeping, or reaching serious thermal pressure restores Apple automatic fan control.

The popover can install or repair the helper, restore the default curve, copy a private support report, and register Fan Curve to launch at login.

## Build

```sh
./scripts/build.sh
open build/FanCurve.app
./scripts/install-helper.sh
```

Re-run the helper installer after replacing the app with a newer build. Remove it with `./scripts/install-helper.sh uninstall`.

## Homebrew

The tap builds Fan Curve locally, so no Apple Developer membership is required:

```sh
brew install --cask jonathancostin/tap/fan-curve
fan-curve-helper install
open -a "Fan Curve"
```

Update with `brew upgrade --cask fan-curve`, then run `fan-curve-helper install` again. Remove the privileged helper before uninstalling with `fan-curve-helper uninstall`.

The SMC implementation is reused from [Stats](https://github.com/exelban/stats) under its MIT license and pinned as a Git submodule.

## Mac support

Fan Curve knows the CPU temperature keys used by Intel Macs and Apple M1 through M5 chips. Hardware checks reject missing or unsafe fan data before the helper writes any fan setting. Intel control currently supports one or two fans; Macs with more need device testing and a proven writer first.

CI builds and checks both Intel and Apple-silicon versions. Real fan control has only been tested on an M5 Pro MacBook Pro so far; other Macs need device tests before they can move from known-key support to confirmed support.

Run `swift run FanCurveProbe` for a read-only hardware report. See [Device support](SUPPORT.md) for the support levels and the physical test checklist.

## Checks

```sh
swift run FanCurveCheck
./scripts/build.sh
codesign --verify --deep --strict build/FanCurve.app
```

See [Development](DEVELOPING.md) before changing hardware support, helper behavior, or the release flow.
