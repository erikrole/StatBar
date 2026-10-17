# StatBar

StatBar is a native macOS menu bar utility for the system stats that matter on a
personal M5 Max MacBook Pro used for video and motion work. It is a lean,
from-scratch take on the idea behind iStat Menus, and it absorbs the battery and
network views that used to live in PowerBar and NetBar, so one menu bar item
covers the whole machine.

- **Menu bar:** CPU percentage beside a gauge. The item measures its widest contents
  once, leaving outer padding to macOS, and keeps that compact width fixed. It is redrawn
  only when that percentage or the attention state changes. A warning replaces the
  gauge with a yellow triangle; a critical condition uses a red one.
- **Now:** a short list of what needs attention, most serious first, and a log of what
  just happened. Conditions have to hold for a while before they show, so one busy
  second never flickers in:
  - an app using at least 1.5 cores for a minute (informational; renders do this);
  - memory pressure, naming the biggest app, and swap growing fast;
  - the Mac running warm or throttling, naming the busiest app;
  - battery under 20% or 10% on battery, or a charger that can't keep up while plugged in;
  - any drive under 10% free, or under 50 GB on drives of 500 GB or more (so camera
    cards and USB sticks don't trip it);
  - being offline for more than a few seconds;
  - the GPU at 90% or higher for two minutes, or an app keeping the Mac awake for half an hour;
  - events as they happen: a drive mounting or ejecting, going offline and back,
    switching Wi-Fi and Ethernet, GlobalProtect connecting or dropping.

  Warnings and above replace the menu bar gauge with a triangle. Serious ones
  (offline, low battery, a struggling charger, a nearly full disk, critical memory,
  throttling) can also send
  a notification, at most once per condition every 30 minutes; Alerts in the
  footer settings menu turns that off.
- **CPU and GPU:** side-by-side load summaries with about two minutes of history. Expand
  CPU cores for each core group (Super and Performance on M5) and per-core bars.
- **Memory:** pressure and used memory at a glance; expand for compressed memory,
  cached files and swap. Uses Activity Monitor's definition of Memory Used.
- **Power:** battery level, charging state and time remaining; expand for battery
  flow, charger wattage, health and cycles, and apps keeping the Mac awake.
- **Network:** online status, live download/upload graphs and the active interface;
  expand for Ethernet link speed, IP address, router and GlobalProtect status.
  Wi-Fi network names are left out because they need Location Services.
- **Disks:** free space on the startup disk and any local media drives (network
  shares are skipped so a slow NAS can't stall the menu), plus live read and write.
- **Heat:** macOS thermal state (whether the Mac is throttling) and fan speeds.
- **Top apps:** by CPU or memory, with helper processes counted as their app.

Charts use blue for CPU, cores and downloads, purple for GPU, teal for disks,
and orange for uploads. Healthy memory, battery and network indicators are green;
warning and critical readings retain their yellow, orange and red cues.

Detail sections start collapsed and remember their state, along with the Top apps
sort order, when the popover reopens. The fixed footer keeps Activity Monitor one
click away; its settings menu contains Alerts, Launch at login and Quit StatBar.

Everything is read through public, unprivileged interfaces (Mach host statistics,
sysctl, the IORegistry, IOKit power assertions, SystemConfiguration, read-only SMC
fan keys and `ps`). The network reader is adapted from NetBar's. There is no privileged
helper. CPU, GPU, memory and network throughput share one timer, sampling every two
seconds. With the popover closed that timer allows a one-second leeway so the system
can coalesce the wake; with the popover open the leeway is a quarter of a second.
Battery samples every ten seconds in the background and every two seconds with the
popover open. Detail readings refresh at startup, after wake, and every thirty
seconds in the background; opening the popover refreshes detail every two seconds,
with the full app list normally refreshing every ten seconds. Sampling pauses when
the displays sleep, and the network path monitor is cancelled with it. A stalled
disk or process read retains one worker slot until it returns; fast readings, fans
and network details continue independently. The popover's view exists only while it
is open.

The compact overview fits CPU, GPU, memory, power and network in the first
360 × 600-point view when there are no active alerts. Additional details, disks,
heat and the app list remain available by expanding or scrolling.

## Install

Download [StatBar 0.1.0](https://github.com/erikrole/StatBar/releases/tag/v0.1.0),
expand the ZIP, move `StatBar.app` into Applications, and open it. The app appears
in the menu bar. Requires Apple Silicon and macOS 27 or later.

The release is Developer ID-signed and notarized, with its ticket stapled. A
SHA-256 checksum file is attached to the release alongside the ZIP.

## Build and run

Requirements: macOS 27 or later, Xcode, and XcodeGen.

```sh
./script/build_and_run.sh --verify
```

The Codex Run action uses the same script. It builds an unsigned local app under
`build/run`, then replaces the running copy after the build succeeds. Use
`STATBAR_CONFIGURATION=Release` for an optimized build. Optional modes are
`--debug`, `--logs` and `--telemetry`.

`StatBar --report [seconds]` samples (4.5 s by default) and prints every reading and
active insight;
`StatBar --snapshot file.png` renders the popover's cards to an image after 40 seconds.
Add `--snapshot-light` for light appearance. Launch-only defaults
such as `-showCoreDetails YES`, `-showMemoryDetails YES`, `-showPowerDetails YES`
and `-showNetworkDetails YES` expand details for diagnostics without changing
the saved disclosure preferences.

## Test

```sh
./scripts/check-macos.sh test
```

The suite includes `MetricFormatTests`, which covers parsing and formatting for CPU,
GPU, memory, power, network, disk and heat without reading the live machine.

For optimized reader benchmarks (median and p95, with no machine-specific pass/fail
thresholds):

```sh
./scripts/check-macos.sh benchmark
```

Both commands regenerate the Xcode project and save the full log and `.xcresult`
under the ignored `build/checks` directory. Benchmarks enable testability for the
Release test host. To measure a built app's CPU and sampled resident memory with
the popover closed:

```sh
python3 scripts/measure-idle.py build/run/Build/Products/Release/StatBar.app/Contents/MacOS/StatBar
```

The profiler runs a separate copy, suppresses its notifications using launch-only
defaults, and terminates only that copy. See [performance validation](docs/performance.md)
for measured results and their limits. Logs and snapshots can contain local system
details; keep them in ignored build directories.

## License

StatBar is released under the MIT License.
