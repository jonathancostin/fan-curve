# Device support

This document tells users how to collect a safe support report and tells maintainers when a Mac can move into the verified support list.

The report reads hardware state only. It does not install the helper, enable a curve, or write fan settings. It excludes serial numbers, account names, and hardware IDs.

## Support levels

- **Known keys**: Fan Curve recognizes the CPU sensors and compiles for the Mac's processor type. No one has yet proved fan writes and recovery on that model.
- **Verified**: A maintainer reviewed the support report and the model passed the enable, disable, quit, and sleep checks below.
- **Unsupported**: The Mac has no fans, reports unsafe fan data, or uses a fan control path that Fan Curve does not support.

| Mac | Fans | Level |
| --- | ---: | --- |
| MacBook Pro `Mac17,9`, Apple M5 Pro | 2 | Verified |
| Apple M1–M5 Macs with fans | Varies | Known keys |
| Intel Macs with one or two fans | 1–2 | Known keys |
| Intel Macs with more than two fans | 3+ | Unsupported |
| MacBook Air and other fanless Macs | 0 | Unsupported |

## Collect a report

From a source checkout:

```sh
swift run FanCurveProbe > fan-curve-report.json
```

From an installed app:

```sh
"/Applications/Fan Curve.app/Contents/Resources/FanCurveProbe" > fan-curve-report.json
```

Review the file before sharing it. A useful report has a model and chip, an app version, at least one CPU sensor, valid fan ranges, and `fanControlSupported` set to `true`. `helperMatchesBundle` must be `true` before a device test; reinstall the helper if it is `false`.

## Verify a new Mac

Fan writes need clear approval from the Mac's owner. Run this check with the Mac attended and no other fan-control app active.

1. Build the app and collect a report while Apple automatic control is active.
2. Install the bundled helper once.
3. Open Fan Curve, keep the default curve, and enable it.
4. Collect a second report. Every fan must show `forced`, and each target RPM must stay within its reported minimum and maximum.
5. Disable the curve. Within five seconds, collect a third report. Every fan must show `automatic` or `system`, not `forced`.
6. Enable the curve again, quit Fan Curve, wait seven seconds, and confirm another report shows `automatic` or `system`.
7. Reopen and enable Fan Curve, put the Mac to sleep, then wake it. The app must wait for a fresh temperature before it resumes the curve.
8. Disable the curve before removing the helper.

Do not mark the model verified if a sensor is missing, a target falls outside its range, one fan does not change mode, or automatic control does not return after disable or quit.

Record the Mac model, chip, fan count, macOS version, Fan Curve commit, and the reports from automatic, forced, and restored states. Do not attach reports that contain data added by other tools.
