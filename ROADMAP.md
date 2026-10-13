# StatBar roadmap

Current focus: validate the new app's system readers, background cost and sampling
lifecycle before a signed release. The compact overview, remembered detail
disclosures and simplified footer are implemented.

- Keep deterministic coverage for pause/resume, delayed detail results, network
  disconnects, route changes and bounded histories.
- Retain repeatable Debug tests, Release reader benchmarks and isolated process
  CPU/resident-memory measurements.
- Next hardware checks: actual display sleep/wake, Ethernet/Wi-Fi transitions with
  GlobalProtect, removable-drive stalls, and longer idle/battery sessions.
- Signed distribution and notarization remain a separate release step; see
  [releasing](docs/releasing.md).
