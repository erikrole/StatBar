#!/usr/bin/env python3
"""Measure a fresh app process with its popover closed; terminate only that process."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path, help="StatBar.app/Contents/MacOS/StatBar")
    parser.add_argument("--seconds", type=float, default=35)
    args = parser.parse_args()
    if not args.executable.is_file() or not 5 <= args.seconds <= 300:
        parser.error("provide an existing executable and a duration from 5 to 300 seconds")

    # Argument-domain defaults suppress notifications only in this profiling process.
    # Never change the user's saved preference or stop their existing app.
    process = subprocess.Popen(
        [str(args.executable.resolve()), "-notificationsEnabled", "NO"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(5)  # exclude launch and initial detail read
        if process.poll() is not None:
            raise RuntimeError(f"App exited during warmup: {process.returncode}")
        initial_cpu, initial_rss = reading(process.pid)
        resident = [initial_rss]
        start = time.monotonic()
        while time.monotonic() - start < args.seconds:
            time.sleep(max(0, min(1, args.seconds - (time.monotonic() - start))))
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


if __name__ == "__main__":
    main()
