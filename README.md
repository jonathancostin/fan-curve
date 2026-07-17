# Fan Curve

A tiny native macOS menu-bar app for this M5 Pro MacBook Pro. Drag five points on a temperature-to-fan graph; the app displays average CPU temperature and applies the interpolated fan percentage across both fans.

`0%` means the detected minimum safe RPM and `100%` means the detected maximum. Enabling control shows the normal macOS administrator prompt. Quitting, disabling control, losing the heartbeat, sleeping, or reaching serious thermal pressure restores Apple automatic fan control.

## Build

```sh
./scripts/build.sh
open build/FanCurve.app
```

The SMC implementation is reused from [Stats](https://github.com/exelban/stats) under its MIT license and pinned as a Git submodule.
