# StatBar roadmap

Current focus: finish hardware acceptance and publication of the prepared
**1.0.0 (build 5)** candidate, based on the published 0.1.3 feature set.
The monitoring overview, alerts, remembered disclosures, automatic signed ZIP
updates and single-instance behavior are implemented.

- Done: harden concurrent launches and keep diagnostic runs independent of the installed
  app, saved preferences, Login Items and automatic updates.
- Done: validate 57 tests in both Debug and Release, run live launch/reader checks,
  inspect light/dark card renders and measure the isolated Release process. Native
  menu/keyboard interaction remains unverified because UI automation timed out.
- Done: prepare the signed ZIP, checksum, provenance manifest and draft release
  notes. Apple notarization was explicitly approved and accepted; stapling and
  fresh-extraction Gatekeeper checks passed. Packaged source: `987aba0`.
- Complete real display sleep/wake, Ethernet/Wi-Fi transitions with GlobalProtect,
  removable-drive stalls, longer idle/battery sessions and installed updater/relaunch
  acceptance before calling those scenarios verified.
- Publish 1.0 separately after reviewing the prepared artifact and acceptance
  record. Keep Homebrew deferred.

Current evidence and remaining boundaries: [1.0 readiness](docs/1.0-readiness.md).
Release workflow: [releasing](docs/releasing.md).
