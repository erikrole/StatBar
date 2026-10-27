# Changelog

## Unreleased — 1.0.0

- Keep one menu-bar instance when copies launch together, with an asynchronous
  grace period for an older copy to finish quitting.
- Isolate report, snapshot and idle-measurement runs from automatic updates,
  notification prompts and Login Items setup. Report invalid diagnostic arguments
  and failed snapshot writes as errors.
- Show the installed version and build in Settings.

## 0.1.3 - 2026-10-27

- Only one StatBar icon: a second copy waits briefly for the first to exit, then quits and brings the first forward.

## 0.1.2 - 2026-10-26

- Install stable updates automatically at launch (Settings > Update automatically, on by default). A failed update stops retrying after two tries.

## 0.1.1 - 2026-10-23

- Add signed ZIP self-updates through AppUpdater, preserving save and busy safeguards.
- Publish a notarized Apple Silicon release requiring macOS 27 or later.

## 0.1.0 — 2026-10-12

Initial signed and notarized release for Apple Silicon on macOS 27 or later.

- Monitor CPU, GPU, memory, battery, network, disks, thermal state and top apps
  from one menu-bar item, with attention summaries and optional notifications.
- Scan a compact CPU/GPU overview, expand technical details, and retain detail
  preferences and app sorting between popover openings.
- Open Activity Monitor or use Alerts, Launch at login and Quit from the footer.
- Keep blocked detail reads from accumulating, reset sampling baselines after
  pause/resume, and clear stale network details without false VPN events.
- Include repeatable tests, optimized reader benchmarks and idle measurements.

[Release and downloads](https://github.com/erikrole/StatBar/releases/tag/v0.1.0).
