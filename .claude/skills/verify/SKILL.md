---
name: verify
description: Use before committing or opening a PR that touches StatBar/, StatBarTests/, project.yml or scripts, to prove a Monitor (StatBar) change works by running the tests, building the app, reading live stats and driving the real menu bar popover.
---

# Verify a Monitor change

Goal: evidence, not a green unit test. Run the cheap checks first, then the real app.
All output goes under `build/verify/` (ignored by `build/`). Judge every step by its
exit code, not by `tail`. Run from the repo root. Shell variables don't survive between tool calls, so each
block below sets the ones it uses.

The debug build shares the installed app's bundle ID (`com.erole.StatBar`) and prefs.
A normal launch of it loses the one-icon election to a running installed copy and quits;
if it wins (no installed copy, or after `build_and_run.sh` pkills it) it runs the Login
Items path from the build folder, because `launchAtLoginEnabled` is usually 1.
So this skill never does a normal launch: it uses the diagnostic modes
`--report`, `--snapshot` and `--measure-idle`, which skip the election, Login Items and
update checks and suppress notifications. They can run next to the installed app.

## 0. Setup (always)

```bash
mkdir -p build/verify
defaults export com.erole.StatBar - > build/verify/prefs-before.plist   # XML, so step 4 can diff it; popover toggles write real prefs
sfltool dumpbtm 2>/dev/null | grep -i -A11 'Name: StatBar' > build/verify/btm-before.txt   # Login Items state
pgrep -lf StatBar   # note every copy and its path; only ever kill PIDs you started
```

## 1. Cheap checks (always, ~35 s)

```bash
./scripts/check-macos.sh test > build/verify/test.log 2>&1; echo "exit $?"
L="$(ls -td build/checks/test-*/ | head -1)xcodebuild.log"
grep -E 'Executed .* tests|\*\* TEST (SUCCEEDED|FAILED) \*\*|: error:' "$L" | tail -4
```

XCTest only (no Swift Testing). The last `Executed N tests, with 0 failures` line is the
total (57 at the time of writing). A non-zero exit, `** TEST FAILED **` or any `: error:`
is a failure. Don't grep plain `failed`. Run tests before any launch: the test host is a
StatBar process too.

Add the heavier modes only when the diff touches their area:

| Diff touches | Also run |
|---|---|
| readers, sampling, `StatMonitor`, anything perf-sensitive | `./scripts/check-macos.sh benchmark` (optimized reader benchmarks; not run in the dry run) |
| build settings, optimization, Release-only code (`#if !DEBUG`, AppUpdate) | `./scripts/check-macos.sh release-test` (not run in the dry run) |
| idle cost, timers, status item redraws | `python3 scripts/measure-idle.py build/run/Build/Products/Debug/StatBar.app/Contents/MacOS/StatBar --seconds 10` (~16 s; temp copy with its own bundle ID). For real numbers build with `STATBAR_CONFIGURATION=Release` and compare on the same Mac |

## 2. Build and read the real app (always, ~20 s)

Build with the same lines as `script/build_and_run.sh`, without its `pkill -x StatBar`
(that kills the installed copy and any of Erik's own builds):

```bash
{ xcodegen generate && xcodebuild -quiet -project StatBar.xcodeproj -scheme StatBar -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/run CODE_SIGNING_ALLOWED=NO build; } > build/verify/build.log 2>&1; echo "exit $?"
git status --short   # xcodegen must not leave a project diff unless you changed project.yml
B=build/run/Build/Products/Debug/StatBar.app/Contents/MacOS/StatBar
"$B" --report 15 > build/verify/report.txt; echo "exit $?"; cat build/verify/report.txt
"$B" --report 0; echo "want exit 1: $?"
```

Want: CPU with core groups, GPU, MEM, POWER, NET, DISK, IO, HEAT and five TOP lines with
real values. Use 15 s or more: the default 4.5 s shows every TOP app at 0% because the
process list hasn't taken a second sample yet. Add `--report 75` for sustained insights
(NOW lines).

## 3. Drive the changed flow

Pick what matches the change:

- **Popover layout / copy / colors (~41 s, run both at once):**
  ```bash
  B=build/run/Build/Products/Debug/StatBar.app/Contents/MacOS/StatBar
  "$B" --snapshot build/verify/snapshot-dark.png & "$B" --snapshot build/verify/snapshot-light.png --snapshot-light \
    -showCoreDetails YES -showMemoryDetails YES -showPowerDetails YES -showNetworkDetails YES & wait
  ```
  Open both PNGs and look. These are ImageRenderer renders of the cards (no scroll view,
  no footer, native controls drawn approximately, and the whole image comes out dimmed),
  so they are layout evidence only. The `-show…Details YES` flags are process-local and
  don't change saved prefs.
- **Anything interactive, or the real look (status item, popover, disclosures, sorting):**
  launch a live copy in `--measure-idle` mode and drive it by PID with `ax.swift`
  (System Events and computer use can't target it: both copies are called StatBar and
  computer use doesn't list menu bar apps).
  ```bash
  B=build/run/Build/Products/Debug/StatBar.app/Contents/MacOS/StatBar
  "$PWD/$B" --measure-idle -notificationsEnabled NO > build/verify/live.log 2>&1 & echo $! > build/verify/live.pid; sleep 4
  P=$(cat build/verify/live.pid); A=.claude/skills/verify/ax.swift
  swift $A $P toggle                       # opens the popover (want "toggled")
  sleep 2; screencapture -x -o -l "$(swift $A $P window)" build/verify/popover.png
  swift $A $P                              # dump: every card, disclosure and button with its live text
  swift $A $P press "CPU cores"            # or "Wi-Fi", "Plugged in", sort "Memory" / "CPU"; want "pressed …"
  swift $A $P toggle; swift $A $P toggle   # close and reopen: disclosure and sort state must persist
  defaults read com.erole.StatBar processSort   # sort choice is saved here; disclosures as show…Details
  ```
  The popover is transient: any click Erik makes anywhere closes it, and then `press`
  fails and `window` prints 0. Open, press and capture in the same shell command
  (`[ "$(swift $A $P window)" = 0 ] && swift $A $P toggle` reopens it); in a later
  call, set `P=$(cat build/verify/live.pid); A=.claude/skills/verify/ax.swift` first. Never send
  keystrokes to "drive" it; they go to whatever app is in front.
  A second Monitor item shows in the menu bar while it runs; that's yours. Don't press
  the **Monitor settings** menu, Launch at login, Alerts, Update automatically or Check for
  Updates: they change the real Login Item and updater state. Never run
  `--measure-idle` without `-notificationsEnabled NO`.
- **Launch, election, Login Items or updater code:** only then run
  `./script/build_and_run.sh --verify` (it quits every StatBar, the installed one too, and
  a Debug normal launch can register the build folder as the login item; compare
  `sfltool dumpbtm` with step 0 afterwards). Not run in the dry run for that reason.
  Update checks are Release-only (`#if !DEBUG`); never trigger a real update to test.
- **Logs:** `log stream --info --style compact --predicate 'subsystem == "com.erole.StatBar"'` while reproducing (same as `build_and_run.sh --telemetry`; not run in the dry run).

Look at the output yourself. "It built" is not verification.

## 4. Clean up (always)

```bash
[ -f build/verify/live.pid ] && kill "$(cat build/verify/live.pid)" && rm build/verify/live.pid   # your copy only; never pkill -x StatBar
defaults delete com.erole.StatBar; defaults import com.erole.StatBar build/verify/prefs-before.plist
defaults export com.erole.StatBar - | diff build/verify/prefs-before.plist - && echo "prefs restored"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -dump | grep -c "$PWD/build"   # registrations before (non-zero after a build)
find "$PWD/build" -name '*.app' -type d -print0 | xargs -0 -n1 "$LSR" -u   # build/run and the test host in build/checks
"$LSR" -dump | grep -c "$PWD/build"   # want 0   ("failed to scan … -10814" for an app that wasn't registered is harmless)
sfltool dumpbtm 2>/dev/null | grep -i -A11 'Name: StatBar' | diff build/verify/btm-before.txt - && echo "login items unchanged"
pgrep -lf StatBar   # want the same list as step 0
```

Do the prefs restore before relaunching anything: the installed Release app rewrites
`AppUpdater.lastCheck` at launch. If you quit `/Applications/StatBar.app` (only the
step 3 launch-code option does), relaunch it with `open -a /Applications/StatBar.app`
only if it was running at step 0.

## 5. Report the evidence

In the commit message, add one trailer line:

```
Verified: check-macos test (N tests, 0 failures), debug build, --report 15 <key readings>, <what you drove and saw>
```

Use `Verified: none (<reason>)` if you truly couldn't verify. Never leave it out.
In the thread reply, attach or link the popover screenshot and give the test count.

## Rules when something fails

- **Three strikes.** Fix and rerun up to 3 rounds. If it still fails, stop and tell Erik
  what fails, what you tried and the exact output. Don't keep going.
- **Never game the check.** No skipping or disabling tests, no adding sleeps, no rerunning
  until it passes, no loosening an assertion to match new output, no editing this skill to
  make your change pass.
- **Flaky test?** Find the root cause. If you can't, say so to Erik with the evidence;
  don't silently delete or retry it.
- **When a bug slips past this skill**, add the check that would have caught it here
  (one line in the table or step 3), in the same PR as the fix.
