# StatBar 1.0

Draft release notes for 1.0.0 (build 5). Not yet published.

StatBar brings CPU, GPU, memory, power, network, disks, heat and top apps into one
compact menu-bar utility for Apple Silicon Macs.

- See live readings and recent history, then expand the details you need. StatBar
  remembers your disclosure choices and Top apps sort order.
- Get attention summaries for sustained conditions such as memory pressure,
  low battery, full disks, lost connectivity and thermal throttling. Optional
  notifications have a cooldown to avoid repeated alerts.
- Install signed stable updates automatically at launch, or turn automatic
  installation off in Settings and check manually.
- Keep one menu-bar icon when multiple copies launch together. The startup grace
  period leaves the app responsive while an older copy finishes quitting.
- Check the installed version and build in Settings.

Requires Apple Silicon and macOS 27 or later. Download the ZIP, expand it, move
`StatBar.app` to Applications, and open it.

Before publication, attach the prepared Developer ID-signed, notarized and stapled
ZIP, its SHA-256 file, and `release-manifest.json`. Use the exact source commit in
that manifest for the release tag. See [1.0 readiness](1.0-readiness.md) for checks
and remaining hardware acceptance boundaries.
