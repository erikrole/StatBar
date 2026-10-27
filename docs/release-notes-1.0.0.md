# StatBar 1.0

Version 1.0.0 (build 5), for Apple Silicon and macOS 27 or later.

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

The download is Developer ID-signed, notarized by Apple and stapled. Signature,
ticket, checksum and Gatekeeper checks passed after extracting the final ZIP.
The source passed 57 tests in both Debug and Release, plus live launch and reader
checks. See the [readiness record](https://github.com/erikrole/StatBar/blob/main/docs/1.0-readiness.md)
for remaining hardware and interaction acceptance boundaries.

Download the ZIP and its `.sha256` file to the same folder, then verify with:

```sh
shasum -a 256 -c StatBar-1.0.0-arm64.zip.sha256
```

Built from [987aba0](https://github.com/erikrole/StatBar/commit/987aba0f0821f4e11adea5e8bbe30503eac42ad1).
The attached `release-manifest.json` records the source, version, signing team,
notarization submission and final ZIP digest.
