# Changelog

## 0.1.2 - 2026-10-26

- Install stable updates automatically at launch (Settings > Update automatically, on by default). A failed update stops retrying after two tries.

## 0.1.1 - 2026-10-23

- Add signed ZIP self-updates through AppUpdater, preserving save and busy safeguards.
- Publish a notarized Apple Silicon release requiring macOS 27 or later.

## Unreleased

- Restore blue CPU charts, purple GPU charts, teal disk bars, blue/orange network graphs,
  and green healthy status indicators while retaining the compact layout.
- Remove redundant menu-bar padding while keeping the CPU indicator's width stable
  across percentages and warning states.

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
