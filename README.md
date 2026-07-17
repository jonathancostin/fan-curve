# Fan Curve

A tiny native macOS menu-bar app for this M5 Pro MacBook Pro. Drag five points on a temperature-to-fan graph; the app displays average CPU temperature and applies the interpolated fan percentage across both fans.

`0%` means the detected minimum safe RPM and `100%` means the detected maximum. A one-time installer adds the root background helper required for fan writes. After that, enabling the curve does not prompt again. Quitting, disabling control, losing the heartbeat, sleeping, or reaching serious thermal pressure restores Apple automatic fan control.

## Build

```sh
./scripts/build.sh
open build/FanCurve.app
./scripts/install-helper.sh
```

Re-run the helper installer after replacing the app with a newer build. Remove it with `./scripts/install-helper.sh uninstall`.

The SMC implementation is reused from [Stats](https://github.com/exelban/stats) under its MIT license and pinned as a Git submodule.
