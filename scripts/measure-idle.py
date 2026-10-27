#!/usr/bin/env python3
"""Measure a fresh app process with its popover closed; terminate only that process."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import uuid


def reading(pid):
    output = subprocess.check_output(
        ["/bin/ps", "-p", str(pid), "-o", "time=", "-o", "rss="],
        text=True, env={**os.environ, "LC_ALL": "C"},
    ).split()
    clock, rss_kib = output
    days = 0
    if "-" in clock:
        days, clock = clock.split("-", 1)
    seconds = float(days) * 86400
    for index, component in enumerate(reversed(clock.split(":"))):
        seconds += float(component) * 60 ** index
    return seconds, int(rss_kib) / 1024


def measure(executable, seconds):
    process = subprocess.Popen(
        [str(executable), "--measure-idle", "-notificationsEnabled", "NO"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(5)  # exclude launch and initial detail read
        if process.poll() is not None:
            raise RuntimeError(f"App exited during warmup: {process.returncode}")
        initial_cpu, initial_rss = reading(process.pid)
        resident = [initial_rss]
        start = time.monotonic()
        while time.monotonic() - start < seconds:
            time.sleep(max(0, min(1, seconds - (time.monotonic() - start))))
            if process.poll() is not None:
                raise RuntimeError(f"App exited during measurement: {process.returncode}")
            final_cpu, rss = reading(process.pid)
            resident.append(rss)
        elapsed = time.monotonic() - start
        print(json.dumps({
            "mode": "popover-closed", "warmup_seconds": 5,
            "measured_seconds": round(elapsed, 3),
            "cpu_seconds": round(final_cpu - initial_cpu, 4),
            "cpu_percent_of_one_core": round((final_cpu - initial_cpu) / elapsed * 100, 3),
            "rss_start_mib": round(initial_rss, 3),
            "rss_end_mib": round(resident[-1], 3),
            "rss_peak_sampled_mib": round(max(resident), 3),
        }, indent=2))
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path, help="StatBar.app/Contents/MacOS/StatBar")
    parser.add_argument("--seconds", type=float, default=35)
    args = parser.parse_args()
    executable = args.executable.resolve()
    bundle = executable.parent.parent.parent
    if (not executable.is_file() or not (bundle / "Contents/Info.plist").is_file()
            or not 5 <= args.seconds <= 300):
        parser.error("provide an existing app executable and a duration from 5 to 300 seconds")

    # A unique bundle identity keeps profiling out of the real app's instance
    # election and preferences. Only the temporary copy is modified and ad-hoc signed.
    with tempfile.TemporaryDirectory(prefix="StatBar-measure-") as directory:
        copy = Path(directory) / "StatBar.app"
        shutil.copytree(bundle, copy, symlinks=True)
        info_path = copy / "Contents/Info.plist"
        with info_path.open("rb") as file:
            info = plistlib.load(file)
        info["CFBundleIdentifier"] = f"com.erole.StatBar.measurement.{uuid.uuid4().hex}"
        with info_path.open("wb") as file:
            plistlib.dump(info, file)
        subprocess.run(
            ["/usr/bin/codesign", "--force", "--sign", "-", str(copy)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        measure(copy / executable.relative_to(bundle), args.seconds)


if __name__ == "__main__":
    main()
