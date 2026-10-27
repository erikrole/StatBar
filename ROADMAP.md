# StatBar roadmap

Current focus: hardware and interaction acceptance after the published and
installed **1.0.0 (build 5)** release.
The monitoring overview, alerts, remembered disclosures, automatic signed ZIP
updates and single-instance behavior are implemented.

- Done: harden concurrent launches and keep diagnostic runs independent of the installed
  app, saved preferences, Login Items and automatic updates.
- Done: validate 57 tests in both Debug and Release, run live launch/reader checks,
  inspect light/dark card renders and measure the isolated Release process. Native
  menu/keyboard interaction remains unverified because UI automation timed out.
- Done: prepare the signed ZIP, checksum, provenance manifest and release
  notes. Apple notarization was explicitly approved and accepted; stapling and
  fresh-extraction Gatekeeper checks passed. Packaged source: `987aba0`.
- Done: publish [1.0](https://github.com/erikrole/StatBar/releases/tag/v1.0.0) from
  the exact packaged source, verify all three GitHub assets, and manually install
  the downloaded app over 0.1.2. Installed trust checks, live readings and one
  running instance passed; the old app is retained outside the checkout.
- Complete real display sleep/wake, Ethernet/Wi-Fi transitions with GlobalProtect,
  removable-drive stalls, longer idle/battery sessions and automatic updater/relaunch
  acceptance before calling those scenarios verified.
- Keep Homebrew deferred.

Current evidence and remaining boundaries: [1.0 readiness](docs/1.0-readiness.md).
Release workflow: [releasing](docs/releasing.md).
