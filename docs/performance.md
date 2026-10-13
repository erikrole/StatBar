# Validation and performance — October 12, 2026

Measured on Apple M5 Max, 128 GiB RAM, macOS 27.0.1, Xcode 27.0 (27A266a).
Baseline source: `bcd6b0613f6d9bc19375313a8951b79913eb3c93`.
The comparison copy received only the same notification-argument parsing correction
so both profiling copies could suppress notifications without changing preferences.
These measurements were captured before committing the fixes and compact UI.
No signed release or notarization was performed for this validation pass.

## Focused fixes

- Only one asynchronous detail read can occupy a worker slot. A blocked OS call
  retains its slot until it returns; the fast loop, fan reads and network detail
  reads remain independent.
- Pause cancels sampling and reachability, invalidates old detail results, and
  cooperatively cancels remaining reader work. Wake/restart clears pre-sleep CPU,
  disk, network and process baselines and refreshes detail promptly.
- Disconnect clears old interface, IP, router, link-speed, VPN and throughput
  state. Missing counters reset their baseline and append zero to the history.
- Route changes refresh details immediately. VPN status remains unknown until a
  fresh read, avoiding false disconnect/reconnect events on an interface switch.
- Interface identity uses one SystemConfiguration enumeration for both transport
  and display name instead of two.
- Launch-only notification overrides are interpreted correctly without changing
  the saved preference, so profiling can suppress notifications reliably.

## Reader benchmarks

Release optimization with `ENABLE_TESTABILITY=YES`; three warmup calls, followed
by 20 measured calls per reader (10 for the full process reader; 100 for the
200-app insight fixture). Values below are milliseconds, median / p95. Baseline
and fixed builds ran sequentially on the same Mac. Other local workloads were
not frozen, so small differences should be treated as noise.

| Operation | Baseline median / p95 | Fixed median / p95 |
| --- | ---: | ---: |
| CPU, GPU, memory, route and network counters together | 0.286 / 0.331 | 0.303 / 0.351 |
| Battery | 0.066 / 0.086 | 0.050 / 0.056 |
| Quick volumes | 0.005 / 0.006 | 0.005 / 0.005 |
| Full volumes | 15.284 / 16.323 | 15.668 / 17.145 |
| Disk I/O counters | 0.029 / 0.031 | 0.026 / 0.028 |
| Quick processes | 3.804 / 4.135 | 4.088 / 4.470 |
| Full processes | 34.773 / 38.395 | 35.791 / 39.904 |
| Interface identity | 2.632 / 2.770 | 1.353 / 1.467 |
| Network details | 1.544 / 1.604 | 1.537 / 1.610 |
| Insights for 200 apps | 0.053 / 0.055 | 0.054 / 0.057 |

The interface lookup's median fell about 49%, consistent with eliminating one
enumeration. The other readers were not optimized in this change. These are
reader timings, not UI frame time or complete sampling-loop latency.

## Process measurement

Each Release app ran separately with the popover closed. After five seconds of
warmup, `scripts/measure-idle.py` measured 35 seconds, crossing a background
detail refresh. CPU is the change in process CPU time divided by elapsed wall
time; 100% means one logical core. RSS is sampled once per second.

| Metric | Baseline | Fixed |
| --- | ---: | ---: |
| CPU time during interval | 0.09 s | 0.07 s |
| Mean CPU, one-core scale | 0.257% | 0.200% |
| RSS at start | 87.547 MiB | 85.156 MiB |
| RSS at end | 88.656 MiB | 86.188 MiB |
| Peak sampled RSS | 88.656 MiB | 86.188 MiB |

The CPU difference is only 0.02 seconds, two increments at the reporting resolution
of `ps`; this does not establish an overall CPU reduction. The short memory sample does not
establish leak freedom or long-term stability. No battery-energy, popover frame
rate, physical sleep/wake, real VPN transition or stalled-drive test was run.
Those lifecycle cases are covered with controlled readers and signals instead.

## Reproduce

Verification: the original suite passed 27 tests; the expanded suite passed all
43 tests in Debug and all 43 in Release. This includes a 21-second blocked-reader
regression that crosses the old 20-second abandonment threshold while asserting
that fast sampling continues. Independent review of the concurrency and network
fixes found no remaining actionable issues. Shell syntax and `git diff --check`
also passed. Xcode emitted its nonblocking App Intents metadata warning because
this app has no AppIntents dependency.

The local Release build launched through `script/build_and_run.sh --verify`.
The `--report` smoke check returned CPU, GPU, memory, power, network, disk, I/O,
heat and top-process readings. Native UI inspection timed out, so visual
popover verification is not claimed.

Retained evidence for this run:

- `build/checks/test-20261013T020737Z-30420/Results.xcresult` — 43 Debug tests.
- `build/validation/final-43-release-tests.xcresult` — 43 Release tests.
- `build/validation/paired-baseline-rebuilt.log` — baseline comparison benchmarks.
- `build/validation/paired-fixed-rebuilt.log` — fixed comparison benchmarks in the table above.
- `build/validation/baseline-idle-notifications-off.json` and `build/validation/final-idle-notifications-off.json` — process measurements.
- `build/validation/final-launch.log` — final local Release build and process verification.

```sh
./scripts/check-macos.sh test
./scripts/check-macos.sh benchmark
STATBAR_CONFIGURATION=Release ./script/build_and_run.sh --verify
python3 scripts/measure-idle.py build/run/Build/Products/Release/StatBar.app/Contents/MacOS/StatBar
```

The benchmark script enables testability only through the command line. Publishing
still uses the unchanged signing/notarization workflow. Test results are saved
under ignored `build/checks/`; the comparison results for this run are under
`build/validation/`. No raw process listings, local network addresses or screenshots
belong in source control.

## Compact UI follow-up

The working tree now pairs CPU/GPU, collapses core, memory, power and network
breakdowns by default, remembers disclosure and process-sort choices, and keeps
Activity Monitor plus a settings menu in the footer. Alerts remain at the top.
The lightweight Canvas graphs and destruction of the hidden hosting controller
are retained. A graph sizing mismatch was also corrected: network graphs now
actually draw at their intended 28-point height.

Final verification after these UI changes:

- `./scripts/check-macos.sh test`: all 43 Debug tests passed.
- `./scripts/check-macos.sh benchmark`: all six Release benchmark tests completed.
- Compact and expanded card renders were inspected in light and dark appearance.
  CPU/GPU, memory, power and network fit within the first view with no active
  alerts. The compact rendered card stack is about 822 points tall versus about
  1126 in the preceding live render; exact height depends on live content.
- A focused independent source review found no actionable UI regressions.
- The exact-path native UI automation call timed out. Menu clicks, keyboard
  operation and reopening persistence have source review but no interactive
  verification. The card renderer excludes the native footer and segmented picker.
  An attempted hosted-window bitmap capture produced invalid colors and was
  removed; its images are not accepted verification evidence.

Final Release reader timings, milliseconds, median / p95:

| Operation | After compact UI |
| --- | ---: |
| CPU, GPU, memory, route and network counters together | 0.280 / 0.330 |
| Battery | 0.061 / 0.072 |
| Quick volumes | 0.005 / 0.006 |
| Full volumes | 15.910 / 16.526 |
| Disk I/O counters | 0.029 / 0.033 |
| Quick processes | 5.970 / 6.266 |
| Full processes | 42.228 / 45.174 |
| Interface identity | 1.386 / 1.473 |
| Network details | 1.736 / 1.883 |
| Insights for 200 apps | 0.055 / 0.057 |

These live-reader measurements are sensitive to other work and process counts.
Quick/full process medians are higher than the earlier fixed run (4.088/35.791 ms);
the process readers did not change in the UI pass. This is not a controlled UI
performance comparison, and no frame-time or energy improvement is claimed.

Evidence for the UI follow-up:

- `build/checks/test-20261013T022829Z-56783/Results.xcresult`
- `build/checks/benchmark-20261013T022919Z-58259/Results.xcresult`
- `build/validation/ui/compact-cards-dark.png` and `compact-cards-light.png`
- `build/validation/ui/expanded-dark.png` and `expanded-light.png`
- `build/validation/ui/idle-final.json` — final 35-second closed-popover profile:
  0.04 seconds CPU (0.114% of one core), 85.719 MiB starting RSS, 85.844 MiB
  ending/peak sampled RSS. The same short-run/resolution limits described above
  apply; this does not establish an energy or CPU improvement.
- `build/validation/ui/final-launch.log` — final unsigned local Release launch.

The final app was rebuilt and launched locally from changes based on
`bcd6b0613f6d9bc19375313a8951b79913eb3c93`. Source-control publication is separate
from deployment: no deployment, signed release or notarization was run for this
UI follow-up. `git diff --check` passed.
