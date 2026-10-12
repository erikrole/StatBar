# StatBar

StatBar is a native macOS menu bar utility for the system stats that matter on a
personal M5 Max MacBook Pro used for video and motion work. It is a lean,
from-scratch take on the idea behind iStat Menus, and it absorbs the battery and
network views that used to live in PowerBar and NetBar, so one menu bar item
covers the whole machine.

- **Menu bar:** CPU percentage beside a gauge that turns yellow or red with memory pressure.
- **Now:** a short list of what needs attention, most serious first, and a log of what
  just happened. Conditions have to hold for a while before they show, so one busy
  second never flickers in:
  - an app using more than 1.5 cores for a minute (informational; renders do this);
  - memory pressure, naming the biggest app, and swap growing fast;
  - the Mac running warm or throttling, naming the busiest app;
  - battery under 20% or 10% on battery, or a charger that can't keep up while plugged in;
  - any drive under 10% free, or under 50 GB on drives of 500 GB or more (so camera
    cards and USB sticks don't trip it);
  - being offline for more than a few seconds;
  - the GPU pinned for two minutes, or an app keeping the Mac awake for half an hour;
  - events as they happen: a drive mounting or ejecting, going offline and back,
    switching Wi-Fi and Ethernet, GlobalProtect connecting or dropping.

  Warnings and above tint the menu bar gauge. Serious ones (offline, low battery, a
  struggling charger, a nearly full disk, critical memory, throttling) can also send
  a notification, at most once per condition every 30 minutes; the Alerts checkbox
  turns that off.
- **CPU:** total load with a two-minute history, and each core group (Super and
  Performance on M5) with per-core bars.
- **GPU:** device utilization with history.
- **Memory:** pressure first, then used, compressed, cached files and swap, using
  Activity Monitor's definition of Memory Used.
- **Power:** battery level, charging state and time remaining, live battery flow in
  watts, charger wattage, battery health and cycles, and which apps are keeping the
  Mac or its display awake.
- **Network:** online status, live download and upload graphs, the interface actually
  in use (with Ethernet link speed), IP address, router, and whether GlobalProtect is
  connected. Wi-Fi network names are left out because they need Location Services.
- **Disks:** free space on the startup disk and any local media drives (network
  shares are skipped so a slow NAS can't stall the menu), plus live read and write.
- **Heat:** macOS thermal state (whether the Mac is throttling) and fan speeds.
- **Top apps:** by CPU or memory, with helper processes counted as their app.

Everything is read through public, unprivileged interfaces (Mach host statistics,
sysctl, the IORegistry, IOKit power assertions, SystemConfiguration, read-only SMC
fan keys and `ps`). The network reader is adapted from NetBar's. There is no privileged
helper. CPU, GPU, memory, battery and network throughput sample every two seconds; disks, fans and the app list
are read only while the popover is open.

![Popover](docs/popover.png)

## Build and run

Requirements: macOS 14 or later, Xcode, and XcodeGen.

```sh
xcodegen generate
xcodebuild -project StatBar.xcodeproj -scheme StatBar -configuration Debug CODE_SIGNING_ALLOWED=NO build
open ~/Library/Developer/Xcode/DerivedData/StatBar-*/Build/Products/Debug/StatBar.app
```

`StatBar --report [seconds]` samples (4.5 s by default) and prints every reading and
active insight;
`StatBar --snapshot file.png` renders the popover's cards to an image.

## Test

```sh
xcodebuild -project StatBar.xcodeproj -scheme StatBar -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

## License

StatBar is released under the MIT License.
