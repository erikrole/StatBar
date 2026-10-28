# Monitor roadmap

- October 28 interface pass: **1.0.0 (6)** is installed locally with the shared family UI. A shared identity header with explicit quiet/attention status, consistent section spacing and Settings footer, and Reduced Motion-aware attention transitions. The existing metric palette, native disclosures and compact overview remain. [Verification](docs/verification-2026-10-28-family-ui.md). No public binary release was published.

- October 28: adopted **Monitor** as the display name, with the shared [Mac utility design language](docs/brand/FAMILY.md). Existing technical identities and update feeds remain compatible. The signed renamed build is now installed locally. Source validation, installation checks and distribution boundaries: [rename verification](docs/verification-2026-10-28-naming.md).

Current focus: feedback on the local **1.0.0 (build 6)** family-interface build,
plus remaining hardware acceptance. Public release remains **1.0.0 (build 5)**.
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
