# Fan Curve

Fan Curve is a small macOS menu-bar app that adjusts fan speed from CPU temperature. It gives you a clear fan curve, live fan readings, and safe automatic recovery without a full hardware dashboard.

## What you can do

- Set a fan curve by dragging points or entering exact values.
- Keep three saved curves and switch between them.
- See CPU temperature, current fan speed, target speed, and fan mode.
- Check recent temperature and fan output on the same chart.
- Copy a curve as JSON and paste it back later.
- Start the app at login.
- Choose whether to resume your curve after the app starts.
- Copy a private support report when a Mac needs testing.

`0%` uses each fan's safe minimum speed. `100%` uses its reported maximum speed.

## Safety

Fan Curve uses a small background helper for fan changes. You install it once with an administrator password; normal use does not ask again.

The app returns control to macOS when you:

- turn the curve off;
- quit the app;
- put the Mac to sleep;
- lose contact with the helper; or
- reach serious system heat pressure.

Fan targets always stay within the minimum and maximum speeds reported by the Mac. If temperature, fan, or helper data looks wrong, Fan Curve does not start control.

## Install with Homebrew

```sh
brew install --cask jonathancostin/tap/fan-curve
fan-curve-helper install
open -a "Fan Curve"
```

The helper command asks for an administrator password. After that, Fan Curve appears in the menu bar.

When Homebrew installs an update, update the helper too:

```sh
brew upgrade --cask fan-curve
fan-curve-helper install
```

## First use

1. Open Fan Curve from the Applications folder or with `open -a "Fan Curve"`.
2. Check the support label and detected fan count.
3. Leave the default curve in place for the first test.
4. Turn on **Use fan curve**.
5. Check that the menu says **Active** and that each fan shows a live speed.
6. Turn the curve off and make sure the menu returns to **Automatic**.

On a Mac that has known sensor keys but has not passed device tests, the app asks for a one-time confirmation before it enables control.

## Reading the menu

- **Active** — the helper has confirmed the curve and the fans are in forced mode.
- **Automatic** — macOS controls the fans.
- **Problem** — Fan Curve cannot confirm safe control or is still waiting for automatic control to return.

If you see **Problem**, turn the curve off. Use **Copy Support Report** if the problem remains.

## Mac support

Fan Curve knows the CPU temperature keys used by Intel Macs and Apple M1 through M5 chips. It only works on Macs with physical fans.

Real fan changes and recovery have been fully tested on the two-fan Apple M5 Pro MacBook Pro (`Mac17,9`). Other Macs may show **Known keys** until someone completes the device test list. Intel Macs with more than two fans are not supported.

See [Device support](SUPPORT.md) for the current list and the safe test steps.

## Remove Fan Curve

Remove the helper before uninstalling the app:

```sh
fan-curve-helper uninstall
brew uninstall --cask fan-curve
```

## Build from source

```sh
./scripts/build.sh
open build/FanCurve.app
./scripts/install-helper.sh
```

Run `./scripts/install-helper.sh uninstall` before deleting a source build. Developers should read [Development](DEVELOPING.md) before changing hardware support, helper behavior, or the release flow.

## Privacy and source

Fan Curve does not send fan or temperature data anywhere. Its support report leaves out serial numbers, account names, and hardware IDs.

The SMC reader and writer come from [Stats](https://github.com/exelban/stats) under the MIT license and stay pinned as a Git submodule.
