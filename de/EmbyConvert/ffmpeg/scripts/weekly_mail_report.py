#!/usr/bin/env python3
# ------------------------------------------------------------
# EmbyConvert - Wochenreport per E-Mail (Freitag 20:00)
# - Listet nur konvertierte Dateien: OUT/*.mkv mit passender Quelle in IN
# - Berechnet Delta (Output - Input) und damit Platzersparnis als negative Zahl
# - Schreibt immer HTML nach /out/_ffmpeg_logs/
# - SMTP Settings via ENV oder ENV-File (empfohlen: embyconvert_mail.env)
#
# Copyright Roman Glos 2026
# ------------------------------------------------------------

from __future__ import annotations

import argparse
import os
import re
import smtplib
import socket
import sys
import json
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from pathlib import Path
from typing import Dict, List, Optional, Tuple

try:
    from zoneinfo import ZoneInfo  # Python 3.9+
except Exception:
    ZoneInfo = None  # type: ignore


VIDEO_EXTS = [".mp4", ".mkv", ".m4v", ".mov", ".avi", ".ts", ".m2ts", ".wmv", ".webm"]
EXCLUDE_DIR_NAMES = {"_state", "_ffmpeg_logs", "@eaDir", "#recycle"}


def _strip(v: Optional[str]) -> str:
    return "" if v is None else str(v).strip()


def env_str(name: str, default: str = "") -> str:
    v = os.getenv(name)
    return default if v is None or str(v).strip() == "" else str(v).strip()


def env_int(name: str, default: int) -> int:
    v = os.getenv(name)
    if v is None or str(v).strip() == "":
        return default
    try:
        return int(str(v).strip())
    except ValueError:
        return default


def env_bool(name: str, default: bool = False) -> bool:
    v = os.getenv(name)
    if v is None:
        return default
    return str(v).strip().lower() in {"1", "true", "yes", "y", "on"}


def split_recipients(s: str) -> List[str]:
    raw = s.replace(";", ",")
    return [x.strip() for x in raw.split(",") if x.strip()]


def human_bytes(num: int) -> str:
    step = 1024.0
    n = float(num)
    for unit in ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]:
        if n < step:
            if unit == "B":
                return f"{int(n)} {unit}"
            return f"{n:.2f} {unit}"
        n /= step
    return f"{n:.2f} EiB"


def human_bytes_signed(num: int, always_sign: bool = False) -> str:
    """Format bytes with sign for delta values."""
    if num < 0:
        return f"-{human_bytes(abs(num))}"
    if always_sign:
        return f"+{human_bytes(num)}"
    return human_bytes(num)


def pct(saved: int, original: int) -> str:
    if original <= 0:
        return "0%"
    return f"{(saved / original) * 100.0:.1f}%"


def now_tz(tz_name: str) -> datetime:
    if ZoneInfo is None:
        return datetime.now()
    try:
        return datetime.now(ZoneInfo(tz_name))
    except Exception:
        return datetime.now()


def fmt_dt(dt: datetime) -> str:
    # 2026-01-21 20:00 Europe/Berlin
    try:
        return dt.strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return str(dt)


def parse_env_file(envfile: Path) -> Dict[str, str]:
    """
    Lädt KEY=VALUE Zeilen aus einer .env Datei (Kommentare/Leerzeilen werden ignoriert).
    Setzt NICHT automatisch os.environ (das macht load_env_file()).
    """
    out: Dict[str, str] = {}
    if not envfile.exists():
        return out
    for line in envfile.read_text(encoding="utf-8", errors="ignore").splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if "=" not in s:
            continue
        k, v = s.split("=", 1)
        k = k.strip()
        v = v.strip()
        # Entferne einfache/doppelte Quotes
        if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
            v = v[1:-1]
        if k:
            out[k] = v
    return out


def load_env_file(envfile: Optional[Path]) -> None:
    """
    Lädt eine env-Datei in os.environ.

    Wichtig: In manchen Docker-Setups existieren ENV-Keys bereits, sind aber leer.
    In diesem Fall soll die env-Datei die leeren Werte überschreiben.
    """
    if envfile is None:
        return
    data = parse_env_file(envfile)
    for k, v in data.items():
        cur = os.environ.get(k)
        if cur is None or str(cur).strip() == "":
            os.environ[k] = v


@dataclass
class Item:
    rel_path: str
    group: str
    in_size: int
    out_size: int
    delta: int  # in - out (kann negativ sein)
    delta_pct: str


def safe_mkdir(p: Path) -> None:
    p.mkdir(parents=True, exist_ok=True)


def load_state(state_path: Path) -> Dict:
    try:
        return json.loads(state_path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_state(state_path: Path, state: Dict) -> None:
    safe_mkdir(state_path.parent)
    state_path.write_text(json.dumps(state, indent=2, ensure_ascii=False), encoding="utf-8")


def find_matching_input(in_root: Path, rel_out: Path) -> Optional[Path]:
    """
    OUT:  Movies/FilmXYZ.mkv
    IN:   Movies/FilmXYZ.(mp4|mkv|m4v|...)
    - Wir nehmen die größte gefundene Quelle (falls mehrere existieren).
    """
    rel_dir = rel_out.parent
    base = rel_out.stem

    candidate_dir = in_root / rel_dir
    if not candidate_dir.exists():
        return None

    best: Optional[Tuple[int, Path]] = None
    for ext in VIDEO_EXTS:
        cand = candidate_dir / f"{base}{ext}"
        if not cand.exists():
            continue
        try:
            size = cand.stat().st_size
        except Exception:
            continue
        if best is None or size > best[0]:
            best = (size, cand)
    return best[1] if best else None


def collect_items(in_root: Path, out_root: Path, start_ts: float, max_items: int) -> Tuple[List[Item], int, bool]:
    items: List[Item] = []
    missing = 0
    truncated = False

    for out_file in out_root.rglob("*.mkv"):
        # Exclude system/state dirs
        if any(part in EXCLUDE_DIR_NAMES for part in out_file.parts):
            continue
        try:
            st = out_file.stat()
        except Exception:
            continue
        if st.st_mtime < start_ts:
            continue

        rel = out_file.relative_to(out_root)
        in_file = find_matching_input(in_root, rel)
        if in_file is None:
            # Nur "tatsächlich konvertierte": ohne Input => nicht listen
            missing += 1
            continue

        try:
            in_size = in_file.stat().st_size
            out_size = st.st_size
        except Exception:
            missing += 1
            continue

        delta = out_size - in_size
        group = rel.parts[0] if len(rel.parts) else "(root)"

        items.append(
            Item(
                rel_path=str(rel).replace("\\", "/"),
                group=group,
                in_size=in_size,
                out_size=out_size,
                delta=delta,
                delta_pct=pct(delta, in_size),
            )
        )

        if max_items > 0 and len(items) >= max_items:
            truncated = True
            break

    items.sort(key=lambda x: (x.group.lower(), x.rel_path.lower()))
    return items, missing, truncated


def build_text(host: str, created: datetime, start: datetime, end: datetime, items: List[Item], missing: int, truncated: bool) -> str:
    total_in = sum(i.in_size for i in items)
    total_out = sum(i.out_size for i in items)
    total_delta = sum(i.delta for i in items)

    lines = []
    lines.append(f"EmbyConvert Wochenreport | Host: {host}")
    lines.append(f"Erstellt: {fmt_dt(created)}")
    lines.append(f"Zeitraum: {fmt_dt(start)} bis {fmt_dt(end)}")
    lines.append("")
    lines.append(f"Konvertiert: {len(items)} Datei(en)")
    lines.append(f"Input:  {human_bytes(total_in)}")
    lines.append(f"Output: {human_bytes(total_out)}")
    lines.append(f"Ersparnis (Δ): {human_bytes_signed(total_delta)} ({pct(total_delta, total_in)})")
    if missing:
        lines.append(f"⚠ Ignoriert (Quelle in IN nicht gefunden): {missing}")
    if truncated:
        lines.append("⚠ Hinweis: Ausgabe wurde wegen REPORT_MAX_ITEMS begrenzt.")
    lines.append("")
    for it in items:
        d = it.delta
        d_str = (f"+{human_bytes(d)}" if d >= 0 else f"-{human_bytes(abs(d))}")
        lines.append(f"- {it.rel_path} | IN {human_bytes(it.in_size)} -> OUT {human_bytes(it.out_size)} | Δ {d_str} ({it.delta_pct})")
    lines.append("")
    return "\n".join(lines)


def stats_table(cells: List[Tuple[str, str, str]]) -> str:
    """Render a simple 2-row table for Outlook-friendly emails.
    cells: list of (label, value, value_color_hex)
    """
    ths = []
    tds = []
    for label, value, color in cells:
        ths.append(
            f"<th style=\"text-align:left;padding:6px 10px;border:1px solid #ddd;background:#f7f7f7;color:#333;font-size:12px;\">{label}</th>"
        )
        tds.append(
            f"<td style=\"text-align:left;padding:8px 10px;border:1px solid #ddd;color:{color};font-size:14px;font-weight:600;\">{value}</td>"
        )
    return f"""<table style=\"width:100%;border-collapse:collapse;margin-top:10px;\">
  <tr>{''.join(ths)}</tr>
  <tr>{''.join(tds)}</tr>
</table>"""


def build_html(host: str, created: datetime, start: datetime, end: datetime, items: List[Item], missing: int, truncated: bool) -> str:
    total_in = sum(i.in_size for i in items)
    total_out = sum(i.out_size for i in items)
    total_delta = sum(i.delta for i in items)

    warn = ""
    if missing > 0:
        warn = f"<div style='margin-top:10px;color:#b36b00;font-size:13px;'>⚠ {missing} Datei(en) ignoriert (Quelle in IN nicht gefunden)</div>"

    trunc = ""
    if truncated:
        trunc = "<div style='margin-top:6px;color:#b36b00;font-size:13px;'>Hinweis: Ausgabe wurde wegen REPORT_MAX_ITEMS begrenzt.</div>"

    # Gruppierung (Top-Level Ordner unter OUT)
    groups: Dict[str, List[Item]] = {}
    for it in items:
        groups.setdefault(it.group, []).append(it)

    # Gesamtsumme (Excel-Style: Δ = Output - Input, daher bei Ersparnis negativ)
    total_delta_color = "#0a7d00" if total_delta <= 0 else "#b36b00"
    overall_stats = stats_table([
        ("Konvertiert", f"{len(items)} Datei(en)", "#111"),
        ("Input", human_bytes(total_in), "#111"),
        ("Output", human_bytes(total_out), "#111"),
        ("Ersparnis (Δ)", f"{human_bytes_signed(total_delta)} ({pct(total_delta, total_in)})", total_delta_color),
    ])

    group_blocks: List[str] = []
    for gname in sorted(groups.keys(), key=lambda x: x.lower()):
        gitems = sorted(groups[gname], key=lambda x: x.rel_path.lower())
        g_in = sum(i.in_size for i in gitems)
        g_out = sum(i.out_size for i in gitems)
        g_delta = sum(i.delta for i in gitems)
        g_color = "#0a7d00" if g_delta <= 0 else "#b36b00"

        g_stats = stats_table([
            ("Input", human_bytes(g_in), "#111"),
            ("Output", human_bytes(g_out), "#111"),
            ("Ersparnis (Δ)", f"{human_bytes_signed(g_delta)} ({pct(g_delta, g_in)})", g_color),
        ])

        # Detail-Tabelle pro Gruppe
        rows: List[str] = []
        for it in gitems:
            d_color = "#0a7d00" if it.delta <= 0 else "#b36b00"
            rows.append(
                f"""<tr>
  <td style=\"padding:6px 8px;border:1px solid #e2e2e2;\">{it.rel_path}</td>
  <td style=\"padding:6px 8px;border:1px solid #e2e2e2;text-align:right;\">{human_bytes(it.in_size)}</td>
  <td style=\"padding:6px 8px;border:1px solid #e2e2e2;text-align:right;\">{human_bytes(it.out_size)}</td>
  <td style=\"padding:6px 8px;border:1px solid #e2e2e2;text-align:right;color:{d_color};font-weight:700;\">{human_bytes_signed(it.delta)}</td>
  <td style=\"padding:6px 8px;border:1px solid #e2e2e2;text-align:right;color:{d_color};\">{it.delta_pct}</td>
</tr>"""
            )

        table = f"""<table style=\"width:100%;border-collapse:collapse;margin-top:10px;font-size:13px;\">
  <tr style=\"background:#f7f7f7;\">
    <th style=\"text-align:left;padding:6px 8px;border:1px solid #ddd;\">Pfad</th>
    <th style=\"text-align:right;padding:6px 8px;border:1px solid #ddd;\">Input</th>
    <th style=\"text-align:right;padding:6px 8px;border:1px solid #ddd;\">Output</th>
    <th style=\"text-align:right;padding:6px 8px;border:1px solid #ddd;\">Ersparnis (Δ)</th>
    <th style=\"text-align:right;padding:6px 8px;border:1px solid #ddd;\">%</th>
  </tr>
  {''.join(rows) if rows else '<tr><td colspan="5" style="padding:8px;border:1px solid #ddd;color:#666;">Keine konvertierten Dateien im Zeitraum gefunden.</td></tr>'}
</table>"""

        group_blocks.append(
            f"""<div style=\"margin-top:18px;padding:12px;border:1px solid #ddd;border-radius:10px;\">
  <div style=\"font-size:16px;font-weight:800;\">{gname} — {len(gitems)} Datei(en)</div>
  {g_stats}
  {table}
</div>"""
        )

    return f"""<!doctype html>
<html><head><meta charset=\"utf-8\"></head>
<body style=\"margin:0;background:#ffffff;color:#111;font-family:Segoe UI,Arial;\">
  <div style=\"padding:18px;\">
    <div style=\"font-size:20px;font-weight:800;\">EmbyConvert Wochenreport | Host: {host}</div>
    <div style=\"margin-top:4px;color:#555;font-size:12px;\">Erstellt: {fmt_dt(created)}</div>
    <div style=\"color:#555;font-size:12px;\">Zeitraum: {fmt_dt(start)} bis {fmt_dt(end)}</div>
    {warn}
    {trunc}
    {overall_stats}
    {''.join(group_blocks)}
    <div style=\"margin-top:18px;color:#777;font-size:12px;\">Copyright Roman Glos 2026</div>
  </div>
</body>
</html>
"""
def smtp_send(subject: str, text_body: str, html_body: str) -> None:
    host = env_str("SMTP_HOST")
    port = env_int("SMTP_PORT", 587)
    use_tls = env_bool("SMTP_TLS", True)
    use_ssl = env_bool("SMTP_SSL", False)
    debug = env_bool("SMTP_DEBUG", False)

    user = env_str("SMTP_USER")
    pwd = env_str("SMTP_PASS")

    mail_from = env_str("SMTP_FROM", user)
    rcpt = split_recipients(env_str("SMTP_TO"))

    if not host:
        raise RuntimeError("SMTP_HOST ist leer (prüfe embyconvert_mail.env).")
    if not rcpt:
        raise RuntimeError("SMTP_TO ist leer (prüfe embyconvert_mail.env).")
    if use_ssl and use_tls:
        raise RuntimeError("SMTP_SSL=1 und SMTP_TLS=1 gleichzeitig ist ungültig. Nutze entweder SSL (465) ODER STARTTLS (587).")

    # Mail aufbauen
    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = mail_from
    msg["To"] = ", ".join(rcpt)

    msg.attach(MIMEText(text_body, "plain", "utf-8"))
    msg.attach(MIMEText(html_body, "html", "utf-8"))

    timeout = env_int("SMTP_TIMEOUT", 30)

    if use_ssl:
        server = smtplib.SMTP_SSL(host=host, port=port, timeout=timeout)
    else:
        server = smtplib.SMTP(host=host, port=port, timeout=timeout)

    if debug:
        server.set_debuglevel(1)

    try:
        server.ehlo()
        if (not use_ssl) and use_tls:
            server.starttls()
            server.ehlo()
        if user and pwd:
            server.login(user, pwd)
        server.sendmail(mail_from, rcpt, msg.as_string())
    finally:
        try:
            server.quit()
        except Exception:
            pass



def main() -> int:
    ap = argparse.ArgumentParser(description="EmbyConvert Wochenreport per SMTP")
    ap.add_argument("--in", dest="in_root", default="/in", help="IN Root (default: /in)")
    ap.add_argument("--out", dest="out_root", default="/out", help="OUT Root (default: /out)")
    ap.add_argument("--envfile", dest="envfile", default="", help="Optional: Pfad zur env-Datei (z.B. /config/embyconvert_mail.env)")
    ap.add_argument("--no-send", dest="no_send", action="store_true", help="Keine Mail senden (nur HTML schreiben)")
    ap.add_argument("--force-send", dest="force_send_arg", action="store_true", help="Mail trotz State/Rate-Limit senden (für Tests)")
    args = ap.parse_args()

    envfile = Path(args.envfile) if args.envfile else None
    load_env_file(envfile)

    tz_name = env_str("REPORT_TZ", "Europe/Berlin")
    host = env_str("REPORT_HOSTNAME", socket.gethostname())
    days = env_int("REPORT_DAYS", 7)
    max_items = env_int("REPORT_MAX_ITEMS", 200)
    dry_run = env_bool("REPORT_DRY_RUN", False) or args.no_send
    force_send = env_bool("REPORT_FORCE_SEND", False) or bool(args.force_send_arg)

    # Debug/Status in Logs (Docker erfasst STDOUT/STDERR)
    smtp_host = env_str("SMTP_HOST", "")
    smtp_port = env_int("SMTP_PORT", 587)
    smtp_tls = env_bool("SMTP_TLS", True)
    smtp_ssl = env_bool("SMTP_SSL", False)
    smtp_from = env_str("SMTP_FROM", env_str("SMTP_USER", ""))
    smtp_to = split_recipients(env_str("SMTP_TO", ""))
    print(f"[weekly_mail_report] envfile={envfile if envfile else '(none)'}", file=sys.stderr)
    print(f"[weekly_mail_report] report tz={tz_name} host={host} days={days} max_items={max_items} dry_run={dry_run}", file=sys.stderr)
    print(f"[weekly_mail_report] smtp host={smtp_host} port={smtp_port} tls={int(smtp_tls)} ssl={int(smtp_ssl)} from={smtp_from} to={len(smtp_to)} recipient(s)", file=sys.stderr)

    created = now_tz(tz_name)
    end = created
    start = end - timedelta(days=days)

    out_root = Path(args.out_root)
    in_root = Path(args.in_root)

    logs_dir = out_root / "_ffmpeg_logs"
    safe_mkdir(logs_dir)

    # State: verhindert Doppel-Mails bei Neustarts
    state_path = logs_dir / "_weekly_mail_report_state.json"
    state = load_state(state_path)
    last_sent_iso = _strip(state.get("last_sent_iso")) if isinstance(state, dict) else ""
    if last_sent_iso and not force_send:
        try:
            last_dt = datetime.fromisoformat(last_sent_iso)
            # Wenn schon in den letzten 20 Stunden gesendet, überspringen
            if (created - last_dt).total_seconds() < 20 * 3600:
                print(f"[weekly_mail_report] Hinweis: Report wurde in den letzten 20h bereits gesendet ({last_sent_iso}). Setze REPORT_FORCE_SEND=1 oder --force-send zum Erzwingen.", file=sys.stderr)
            dry_run = True
        except Exception:
            pass

    start_ts = start.timestamp()
    items, missing, truncated = collect_items(in_root=in_root, out_root=out_root, start_ts=start_ts, max_items=max_items)

    html = build_html(host=host, created=created, start=start, end=end, items=items, missing=missing, truncated=truncated)
    text = build_text(host=host, created=created, start=start, end=end, items=items, missing=missing, truncated=truncated)

    stamp = created.strftime("%Y-%m-%d")
    html_path = logs_dir / f"weekly_report_{stamp}.html"
    txt_path = logs_dir / f"weekly_report_{stamp}.txt"

    html_path.write_text(html, encoding="utf-8")
    txt_path.write_text(text, encoding="utf-8")
    print(f"[weekly_mail_report] wrote: {html_path} and {txt_path}", file=sys.stderr)

    prefix = env_str("REPORT_SUBJECT_PREFIX", "[EmbyConvert]").strip()
    subject = f"{prefix} Wochenreport {start.strftime('%Y-%m-%d')} bis {end.strftime('%Y-%m-%d')} | Host: {host}"

    if dry_run:
        print("[weekly_mail_report] REPORT_DRY_RUN=1 oder --no-send: Mailversand deaktiviert.", file=sys.stderr)
        return 0

    print("[weekly_mail_report] sending mail...", file=sys.stderr)
    smtp_send(subject=subject, text_body=text, html_body=html)
    print("[weekly_mail_report] mail sent.", file=sys.stderr)

    # State aktualisieren
    state = {"last_sent_iso": created.isoformat(), "last_subject": subject, "items": len(items)}
    save_state(state_path, state)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as e:
        # Fehler immer in STDERR, damit Cron-Redirect es erfasst
        print(f"[weekly_mail_report] ERROR: {e}", file=sys.stderr)
        raise
