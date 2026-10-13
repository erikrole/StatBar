# StatBar roadmap

Current focus: hardware and interaction validation after the first local signed,
notarized 0.1.0 build. The compact overview, remembered detail disclosures and
simplified footer are implemented.

- Keep deterministic coverage for pause/resume, delayed detail results, network
  disconnects, route changes and bounded histories.
- Retain repeatable Debug tests, Release reader benchmarks and isolated process
  CPU/resident-memory measurements.
- Next hardware checks: actual display sleep/wake, Ethernet/Wi-Fi transitions with
  GlobalProtect, removable-drive stalls, and longer idle/battery sessions.
- Developer ID signing, notarization, stapling and Gatekeeper verification passed
  for the local 0.1.0 build. Public distribution remains separate; see
  [releasing](docs/releasing.md).
