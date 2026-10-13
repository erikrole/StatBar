# StatBar roadmap

Current focus: hardware and interaction validation after the published signed,
notarized 0.1.0 release. The compact overview, remembered detail disclosures and
simplified footer are implemented.

- Keep deterministic coverage for pause/resume, delayed detail results, network
  disconnects, route changes and bounded histories.
- Retain repeatable Debug tests, Release reader benchmarks and isolated process
  CPU/resident-memory measurements.
- Next hardware checks: actual display sleep/wake, Ethernet/Wi-Fi transitions with
  GlobalProtect, removable-drive stalls, and longer idle/battery sessions.
- Developer ID signing, notarization, stapling and Gatekeeper verification passed
  for 0.1.0. The ZIP and checksum are published on GitHub; see
  [releasing](docs/releasing.md). Homebrew remains deferred.
