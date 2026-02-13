#!/usr/bin/env python3
# ------------------------------------------------------------
# EmbyConvert - Weekly report daemon (Friday 20:00)
# - runs continuously and triggers weekly_mail_report.py every week
# - no cron/apk required (robust on NAS / Docker UIs)
#
# Configuration:
# - Default: Friday 20:00 (container local time)
# - optional via ENV:
#   REPORT_WEEKDAY=5   # 1=Monday ... 7=Sunday (default: 5=Friday)
#   REPORT_HOUR=20     # default: 20
#   REPORT_MINUTE=0    # default: 0
#   RUN_ON_START=0     # 1 = run report immediately on startup
#
# Copyright Roman Glos 2026
# ------------------------------------------------------------

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from datetime import datetime, timedelta


def env_int(name: str, default: int) -> int:
    v = os.getenv(name, "").strip()
    if not v:
        return default
    try:
        return int(v)
    except ValueError:
        return default


def env_bool(name: str, default: bool = False) -> bool:
    v = os.getenv(name)
    if v is None:
        return default
    return str(v).strip().lower() in {"1", "true", "yes", "y", "on"}


def clamp(n: int, lo: int, hi: int) -> int:
    return lo if n < lo else hi if n > hi else n


def next_run_local(now: datetime, weekday_1_7: int, hour: int, minute: int) -> datetime:
    # Python: weekday() => 0=Mon ... 6=Sun
    target_py = (weekday_1_7 - 1) % 7
    candidate = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    days_ahead = (target_py - now.weekday()) % 7
    candidate = candidate + timedelta(days=days_ahead)

    # If today and time already passed (or equal) -> next week
    if candidate <= now:
        candidate = candidate + timedelta(days=7)
    return candidate


def log(msg: str) -> None:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[weekly_mail_report_daemon] {ts} | {msg}", flush=True)


def run_report(in_root: str, out_root: str, envfile: str) -> int:
    cmd = [
        sys.executable,
        "/scripts/weekly_mail_report.py",
        "--in",
        in_root,
        "--out",
        out_root,
    ]
    if envfile:
        cmd += ["--envfile", envfile]

    log(f"Starting report: {' '.join(cmd)}")
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    # Write output to container stdout so it shows up in logs
    if p.stdout:
        for line in p.stdout.splitlines():
            print(line, flush=True)
    log(f"Report finished with exit code {p.returncode}")
    return p.returncode


def main() -> int:
    ap = argparse.ArgumentParser(description="EmbyConvert weekly report daemon")
    ap.add_argument("--in", dest="in_root", default="/in", help="IN root (default: /in)")
    ap.add_argument("--out", dest="out_root", default="/out", help="OUT root (default: /out)")
    ap.add_argument("--envfile", dest="envfile", default="", help="Optional: path to env file (e.g. /config/embyconvert_mail.env)")
    ap.add_argument("--sleep-step", dest="sleep_step", default=30, type=int, help="Sleep step in seconds (default: 30)")
    args = ap.parse_args()

    weekday = clamp(env_int("REPORT_WEEKDAY", 5), 1, 7)  # 5 = Friday
    hour = clamp(env_int("REPORT_HOUR", 20), 0, 23)
    minute = clamp(env_int("REPORT_MINUTE", 0), 0, 59)
    run_on_start = env_bool("RUN_ON_START", False)
    sleep_step = clamp(int(args.sleep_step), 5, 3600)

    log(f"Daemon started. Schedule: weekday={weekday} hour={hour:02d}:{minute:02d} (container local time) | run_on_start={int(run_on_start)}")

    if run_on_start:
        try:
            run_report(args.in_root, args.out_root, args.envfile)
        except Exception as e:
            log(f"ERROR during startup run: {e}")

    while True:
        now = datetime.now()
        nr = next_run_local(now, weekday, hour, minute)
        delta = (nr - now).total_seconds()
        log(f"Next run: {nr.strftime('%Y-%m-%d %H:%M:%S')} (in {int(delta)}s)")

        # Sleep in steps so the container remains responsive to stop signals
        while True:
            now2 = datetime.now()
            remaining = (nr - now2).total_seconds()
            if remaining <= 0:
                break
            time.sleep(min(sleep_step, max(1.0, remaining)))

        try:
            run_report(args.in_root, args.out_root, args.envfile)
        except Exception as e:
            log(f"ERROR during report run: {e}")

        # Small pause to avoid double execution on edge timing cases
        time.sleep(5)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        log("Stopped (KeyboardInterrupt)")
        raise
