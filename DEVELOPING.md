# Development

Fan Curve has five small parts:

- `FanCurveCore` holds curve math, hardware rules, safety checks, smoothing, history, and wake state.
- `FanCurveApp` reads temperatures, writes the user state file, and starts the app.
- `FanCurveUI` shows the menu-bar window and keeps macOS effects replaceable for action checks.
- `FanCurveHelper` runs as root, checks the state and heartbeat, writes fan settings, and restores Apple control.
- `FanCurveProbe` reads hardware state and prints the support report.

Keep hardware rules and safety checks in `FanCurveCore` so the app, helper, probe, and checks use the same rules.

## Safety rules

- Treat missing, partial, non-finite, or out-of-range SMC data as unsupported.
- Do not write until the state is enabled, fresh, owned by the current user, and safe under thermal pressure.
- Keep targets within each fan's reported minimum and maximum.
- Restore Apple automatic control after disable, quit, a stale heartbeat, sleep, or an error.
- Do not add a model to the verified list without the attended checks in [Device support](SUPPORT.md).

## Local checks

Run:

```sh
swift run FanCurveCheck
swift run FanCurveAppCheck
./scripts/build.sh
codesign --verify --deep --strict build/FanCurve.app
swift build -c release --triple x86_64-apple-macosx13.0
arch -x86_64 .build/out/Products/Release/FanCurveCheck
git diff --check
```

`FanCurveAppCheck` drives every menu action through the real AppKit controls:
curve drag, arrow keys, exact value edits, add, delete, reset, copy, paste,
enable, helper install, launch at login, launch resume, support report, menu
open/close, and quit. It swaps in test effects, so it cannot change fans,
login settings, the clipboard, or the running app.

`FanCurveCheck` covers the matching curve, hardware, helper, safety, wake, and
launch rules. Real SMC writes and automatic recovery still need the attended
device checks in [Device support](SUPPORT.md).

The cross-build needs Apple's Intel support tools. Pull requests and releases run the portable core checks on AWS runners for both ARM and Intel. Run the full app build and signing checks on a Mac before merging.

## Release flow

The release job runs after both Mac test jobs pass. A push to `main` then creates a source release and updates the Homebrew tap. Do not push `main` only to test the release flow.

After users update the app, they must run the helper installer again. Changes to CPU sensor keys or fan mode rules need a read-only probe report and the physical checks in [Device support](SUPPORT.md).
