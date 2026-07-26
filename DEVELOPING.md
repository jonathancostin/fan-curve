# Development

Fan Curve has four small parts:

- `FanCurveCore` holds curve math, hardware rules, safety checks, smoothing, history, and wake state.
- `FanCurveApp` reads temperatures, writes the user state file, and shows the menu-bar window.
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
./scripts/build.sh
codesign --verify --deep --strict build/FanCurve.app
swift build -c release --triple x86_64-apple-macosx13.0
arch -x86_64 .build/out/Products/Release/FanCurveCheck
git diff --check
```

The cross-build needs Apple's Intel support tools. Pull requests and releases run the portable core checks on AWS runners for both ARM and Intel. Run the full app build and signing checks on a Mac before merging.

## Release flow

The release job runs after both Mac test jobs pass. A push to `main` then creates a source release and updates the Homebrew tap. Do not push `main` only to test the release flow.

After users update the app, they must run the helper installer again. Changes to CPU sensor keys or fan mode rules need a read-only probe report and the physical checks in [Device support](SUPPORT.md).
