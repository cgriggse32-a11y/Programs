#!/usr/bin/env python3
"""
FreshStart PCs - Windows diagnostic tool (Windows 8/8.1/10/11)
Single-file CLI that collects system + health diagnostics and writes JSON + HTML reports.

Notes:
 - Works on Python 3.8+ (tested with 3.12).
 - Optional but recommended: `pip install psutil wmi` for richer info. The script falls back to CLI tools when possible.
 - Some checks require Administrator: sfc, chkdsk analysis, certain registry reads, slmgr. The script will detect and warn.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
import time
from datetime import datetime
from typing import Any, Dict, List, Tuple, Optional

# Optional dependencies
try:
    import psutil
except Exception:
    psutil = None

try:
    import wmi
except Exception:
    wmi = None

APP = "FreshStart Diagnostic"
VERSION = "1.1"


# ---------- helpers ----------
def run_cmd(cmd: List[str] | str, timeout: int = 30, shell: bool = False) -> Tuple[int, str]:
    """
    Run a command and return (returncode, stdout).
    Accepts a list or a raw string. If shell=True you may pass a string.
    """
    try:
        completed = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   timeout=timeout, shell=shell, text=True)
        return completed.returncode, (completed.stdout or "").strip()
    except subprocess.TimeoutExpired:
        return -1, "timeout"
    except Exception as e:
        return -1, f"error: {e}"


def which(tool: str) -> Optional[str]:
    """Return path if available in PATH."""
    from shutil import which as _which
    return _which(tool)


def is_admin() -> bool:
    """Return True if running with Administrator privileges (Windows)."""
    if platform.system().lower() != "windows":
        return False
    try:
        import ctypes
        return ctypes.windll.shell32.IsUserAnAdmin() != 0
    except Exception:
        return False


# ---------- collectors ----------
def gather_basic_info() -> Dict[str, Any]:
    info: Dict[str, Any] = {
        "tool": APP,
        "version": VERSION,
        "collected_at_utc": datetime.utcnow().isoformat() + "Z",
        "platform": platform.platform(),
        "os": f"{platform.system()} {platform.release()}",
        "hostname": platform.node(),
        "python_version": platform.python_version(),
    }
    # uptime
    try:
        if psutil:
            boot_ts = psutil.boot_time()
            info["boot_time"] = datetime.fromtimestamp(boot_ts).isoformat()
            info["uptime_seconds"] = int(time.time() - boot_ts)
        else:
            info["boot_time"] = None
            info["uptime_seconds"] = None
    except Exception as e:
        info["boot_time_error"] = str(e)
    return info


def gather_cpu_memory() -> Dict[str, Any]:
    if not psutil:
        return {"notice": "psutil not installed; install with pip install psutil for better data"}
    try:
        vm = psutil.virtual_memory()
        return {
            "cpu_count_logical": psutil.cpu_count(logical=True),
            "cpu_count_physical": psutil.cpu_count(logical=False),
            "cpu_percent_1s": psutil.cpu_percent(interval=1),
            "memory_total_mb": int(vm.total / 1024 / 1024),
            "memory_available_mb": int(vm.available / 1024 / 1024),
        }
    except Exception as e:
        return {"error": str(e)}


def gather_disks() -> Dict[str, Any]:
    partitions: List[Dict[str, Any]] = []
    wmic_disks: List[Dict[str, str]] = []

    # Partitions via psutil (preferred)
    if psutil:
        try:
            for p in psutil.disk_partitions(all=False):
                try:
                    usage = psutil.disk_usage(p.mountpoint)
                    partitions.append({
                        "device": p.device,
                        "mountpoint": p.mountpoint,
                        "fstype": p.fstype,
                        "opts": p.opts,
                        "total_gb": round(usage.total / (1024 ** 3), 2),
                        "used_gb": round(usage.used / (1024 ** 3), 2),
                        "free_gb": round(usage.free / (1024 ** 3), 2),
                        "percent": usage.percent
                    })
                except Exception:
                    partitions.append({"device": p.device, "mountpoint": p.mountpoint, "error": "access failed"})
        except Exception as e:
            partitions.append({"error": str(e)})
    else:
        partitions.append({"notice": "psutil not installed; limited partition info"})

    # Physical disk / SMART via wmic (CSV) fallback
    if which("wmic"):
        rc, out = run_cmd(["wmic", "diskdrive", "get", "Model,DeviceID,Status,Size", "/format:csv"], timeout=6)
        if rc == 0 and out:
            lines = [l for l in out.splitlines() if l.strip()]
            # CSV: Node,DeviceID,Model,Size,Status
            # skip header, parse naively
            headers = []
            for i, ln in enumerate(lines):
                if i == 0:
                    headers = [h.strip() for h in ln.split(",")]
                    continue
                parts = [p.strip() for p in ln.split(",")]
                if len(parts) >= len(headers):
                    rec = dict(zip(headers, parts))
                    wmic_disks.append(rec)
        else:
            wmic_disks.append({"notice": "wmic failed or returned no output"})
    else:
        wmic_disks.append({"notice": "wmic not found in PATH"})

    return {"partitions": partitions, "wmic_disk_info": wmic_disks}


def gather_event_summary(max_events: int = 50) -> Dict[str, Any]:
    """
    Try to use PowerShell Get-WinEvent -> ConvertTo-Json for robust results.
    Fallback to wevtutil if PowerShell not available.
    """
    if platform.system().lower() != "windows":
        return {"notice": "Event collection only supported on Windows"}

    # PowerShell approach (preferred)
    ps_cmd = (
        "powershell -NoProfile -Command "
        f"'Get-WinEvent -LogName System -MaxEvents {max_events} | "
        "Select-Object TimeCreated,Id,LevelDisplayName,ProviderName,Message | ConvertTo-Json -Compress'"
    )
    rc, out = run_cmd(ps_cmd, timeout=20, shell=True)
    if rc == 0 and out:
        try:
            # PowerShell may return either a single object or an array
            data = json.loads(out)
            errors = []
            warnings = []
            if isinstance(data, dict):
                data = [data]
            for ev in data:
                lvl = ev.get("LevelDisplayName", "").lower()
                summary = {
                    "time": ev.get("TimeCreated"),
                    "id": ev.get("Id"),
                    "level": ev.get("LevelDisplayName"),
                    "provider": ev.get("ProviderName"),
                    "message_snippet": (ev.get("Message") or "")[:400]
                }
                if lvl in ("error", "critical", "error "):
                    errors.append(summary)
                else:
                    warnings.append(summary)
            return {"errors": errors, "warnings": warnings, "source": "powershell"}
        except Exception:
            # fall through to wevtutil
            pass

    # wevtutil fallback (text)
    if which("wevtutil"):
        rc2, out2 = run_cmd(["wevtutil", "qe", "System", f"/c:{max_events}", "/f:text"], timeout=15)
        if rc2 == 0 and out2:
            chunks = [c.strip() for c in out2.split("\n\n") if c.strip()]
            errs = []
            warns = []
            for c in chunks:
                if "Level: 1" in c or "Level: 2" in c:
                    errs.append(c[:500])
                else:
                    warns.append(c[:300])
            return {"errors": errs, "warnings": warns, "source": "wevtutil_text"}
        else:
            return {"notice": "wevtutil unavailable or returned no output"}
    else:
        return {"notice": "no event collection tool found (PowerShell/wevtutil)"}


def check_windows_activation() -> Dict[str, Any]:
    """
    Use cscript slmgr.vbs /dli to get a lightweight activation hint.
    This may require admin and may not always provide full info.
    """
    if platform.system().lower() != "windows":
        return {"notice": "activation check only for Windows"}
    windir = os.environ.get("windir", r"C:\Windows")
    slmgr_path = os.path.join(windir, "system32", "slmgr.vbs")
    if not os.path.exists(slmgr_path):
        return {"notice": f"slmgr.vbs not found at {slmgr_path}"}
    rc, out = run_cmd(["cscript", slmgr_path, "/dli"], timeout=8)
    if rc == 0 and out:
        return {"slmgr_dli_raw": out[:4000]}
    return {"notice": "slmgr query failed or returned no output (may require admin)"}


def find_suspicious_startups() -> Dict[str, Any]:
    """
    Inspect startup folders and HKLM/HKCU run keys via reg query.
    Non-destructive. Registry reads may require privileges.
    """
    res: Dict[str, Any] = {"startup_shortcuts": [], "autoruns": []}
    # Startup folders
    appdata = os.environ.get("APPDATA", "")
    programdata = os.environ.get("PROGRAMDATA", "")
    startup_paths = [
        os.path.join(appdata, "Microsoft", "Windows", "Start Menu", "Programs", "Startup"),
        os.path.join(programdata, "Microsoft", "Windows", "Start Menu", "Programs", "Startup"),
    ]
    for p in startup_paths:
        try:
            if os.path.isdir(p):
                for name in os.listdir(p):
                    res["startup_shortcuts"].append(name)
        except Exception:
            pass
    res["startup_shortcuts_count"] = len(res["startup_shortcuts"])

    # Registry Run keys
    if which("reg"):
        for key in (r"HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run", r"HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"):
            rc, out = run_cmd(["reg", "query", key], timeout=6)
            if rc == 0 and out:
                lines = [l.strip() for l in out.splitlines() if l.strip() and "REG_" in l]
                for l in lines:
                    res["autoruns"].append({"key": key, "entry": l})
            else:
                # don't spam if empty
                pass
    else:
        res["autoruns_notice"] = "reg.exe not found; registry autoruns not queried"

    return res


def run_sfc_scan() -> Dict[str, Any]:
    """
    Run sfc /scannow. This will attempt repairs and therefore must only be run with admin.
    We only run if admin and user requested it.
    """
    if not is_admin():
        return {"notice": "sfc requires Administrator privileges"}
    if not which("sfc"):
        return {"notice": "sfc not available in PATH"}
    rc, out = run_cmd(["sfc", "/scannow"], timeout=600)
    return {"rc": rc, "output": out[:8000]}


def run_chkdsk_analysis(drive: str = "C:") -> Dict[str, Any]:
    """
    Run chkdsk without fixes to analyze the drive. On system drives chkdsk may require scheduling.
    """
    if not which("chkdsk"):
        return {"notice": "chkdsk not found"}
    rc, out = run_cmd(["chkdsk", drive], timeout=120)
    return {"rc": rc, "output": out[:8000]}


# ---------- reporting ----------
def write_json(path: str, data: Dict[str, Any]) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def write_html(path: str, report: Dict[str, Any]) -> None:
    # Minimal template, safe-escaped-ish (we avoid heavy escaping for brevity).
    basic = report.get("basic", {})
    cpu = report.get("cpu_mem", {})
    disks = report.get("disks", {})
    events = report.get("events", {})
    startups = report.get("startup", {})

    html_parts: List[str] = []
    html_parts.append("<!doctype html><html><head><meta charset='utf-8'>")
    html_parts.append(f"<title>{APP} report</title>")
    html_parts.append("<style>body{font-family:Arial,Helvetica,sans-serif;max-width:1000px;margin:18px}h1{border-bottom:1px solid #ddd}table{width:100%;border-collapse:collapse}th,td{padding:6px;text-align:left;border:1px solid #eee}pre{white-space:pre-wrap;background:#f7f7f7;padding:8px}</style>")
    html_parts.append("</head><body>")
    html_parts.append(f"<h1>{APP} - Diagnostic Report</h1>")
    html_parts.append(f"<p><strong>Host:</strong> {basic.get('hostname','-')} &nbsp; <strong>OS:</strong> {basic.get('os','-')} &nbsp; <strong>Collected:</strong> {basic.get('collected_at_utc','-')}</p>")

    html_parts.append("<h2>Summary</h2><ul>")
    html_parts.append(f"<li>CPU load: {cpu.get('cpu_percent_1s','?')}% | RAM: {cpu.get('memory_available_mb','?')}MB free / {cpu.get('memory_total_mb','?')}MB</li>")
    if disks.get("partitions"):
        # pick a partition likely C:
        primary = next((p for p in disks["partitions"] if str(p.get("mountpoint","")).upper().startswith("C")), disks["partitions"][0])
        html_parts.append(f"<li>Primary drive: {primary.get('used_gb','?')}GB used of {primary.get('total_gb','?')}GB ({primary.get('percent','?')}%)</li>")
    html_parts.append("</ul>")

    html_parts.append("<h2>Partitions</h2>")
    html_parts.append("<table><thead><tr><th>Device</th><th>Mount</th><th>FS</th><th>Total(GB)</th><th>Used(GB)</th><th>Free(GB)</th><th>%</th></tr></thead><tbody>")
    for p in disks.get("partitions", []):
        html_parts.append("<tr>")
        html_parts.append(f"<td>{p.get('device','')}</td>")
        html_parts.append(f"<td>{p.get('mountpoint','')}</td>")
        html_parts.append(f"<td>{p.get('fstype','')}</td>")
        html_parts.append(f"<td>{p.get('total_gb','')}</td>")
        html_parts.append(f"<td>{p.get('used_gb','')}</td>")
        html_parts.append(f"<td>{p.get('free_gb','')}</td>")
        html_parts.append(f"<td>{p.get('percent','')}</td>")
        html_parts.append("</tr>")
    html_parts.append("</tbody></table>")

    html_parts.append("<h2>Recent System Events (errors/warnings)</h2>")
    if events.get("errors"):
        html_parts.append("<h3>Errors</h3>")
        for ev in events.get("errors", [])[:10]:
            html_parts.append("<pre>")
            html_parts.append(json.dumps(ev, indent=2, ensure_ascii=False))
            html_parts.append("</pre>")
    else:
        html_parts.append("<p>No recent critical system errors found or event collection unavailable.</p>")

    html_parts.append("<h2>Startup / Autoruns</h2>")
    html_parts.append(f"<p>Startup shortcuts: {startups.get('startup_shortcuts_count','?')}</p>")
    if startups.get("startup_shortcuts"):
        html_parts.append("<ul>")
        for s in startups.get("startup_shortcuts", [])[:40]:
            html_parts.append(f"<li>{s}</li>")
        html_parts.append("</ul>")
    if startups.get("autoruns"):
        html_parts.append("<h3>Registry Run entries (sample)</h3><pre>")
        html_parts.append("\n".join([str(x) for x in startups.get("autoruns", [])[:40]]))
        html_parts.append("</pre>")

    html_parts.append("<h2>Raw: WMIC Disk Info (truncated)</h2><pre>")
    for rec in disks.get("wmic_disk_info", [])[:10]:
        html_parts.append(json.dumps(rec, ensure_ascii=False))
    html_parts.append("</pre>")

    html_parts.append("<hr><p>Generated by FreshStart Diagnostic. Default run is non-destructive. Run with --run-safe-checks & Administrator for optional scans (sfc, chkdsk analysis).</p>")
    html_parts.append("</body></html>")

    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(html_parts))


# ---------- orchestrator ----------
def generate_report(out_prefix: str, run_safe_checks: bool = False, do_fix: bool = False) -> Tuple[Dict[str, Any], str, str]:
    report: Dict[str, Any] = {}
    report["basic"] = gather_basic_info()
    report["cpu_mem"] = gather_cpu_memory()
    report["disks"] = gather_disks()
    report["events"] = gather_event_summary()
    report["startup"] = find_suspicious_startups()
    report["activation"] = check_windows_activation()

    if run_safe_checks:
        # sfc
        report["sfc"] = run_sfc_scan()
        # chkdsk analysis for C:
        report["chkdsk_c"] = run_chkdsk_analysis("C:")

    if do_fix:
        report["fix_attempt"] = {"notice": "Automated fixes are intentionally limited. Use specific flags for explicit actions (not implemented by default)."}

    json_path = out_prefix + ".json"
    html_path = out_prefix + ".html"
    write_json(json_path, report)
    write_html(html_path, report)
    return report, json_path, html_path


# ---------- CLI ----------
def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="FreshStart PCs - Windows Diagnostics")
    p.add_argument("--out", "-o", default="freshdiag_report", help="Output file prefix (no extension)")
    p.add_argument("--run-safe-checks", action="store_true", help="Run safe system checks (sfc, chkdsk analysis) - requires admin")
    p.add_argument("--fix", action="store_true", help="Allow non-destructive repairs (admin only). Disabled by default")
    p.add_argument("--pretty", action="store_true", help="Print a short terminal summary")
    return p.parse_args()


def short_terminal_summary(report: Dict[str, Any]) -> str:
    basic = report.get("basic", {})
    cpu = report.get("cpu_mem", {})
    lines: List[str] = []
    lines.append(f"{APP} v{VERSION} - quick summary")
    lines.append(f"Host: {basic.get('hostname','-')} | OS: {basic.get('os','-')} | Collected: {basic.get('collected_at_utc','-')}")
    if cpu and "cpu_percent_1s" in cpu:
        lines.append(f"CPU: {cpu.get('cpu_percent_1s')}% | RAM free: {cpu.get('memory_available_mb')}MB / {cpu.get('memory_total_mb')}MB")
    parts = report.get("disks", {}).get("partitions", [])
    if parts:
        primary = next((p for p in parts if str(p.get("mountpoint","")).upper().startswith("C")), parts[0])
        lines.append(f"C: {primary.get('used_gb','?')}GB used / {primary.get('total_gb','?')}GB ({primary.get('percent','?')}%)")
    errs = report.get("events", {}).get("errors", [])
    lines.append(f"Recent system errors: {len(errs) if errs is not None else 'n/a'}")
    return "\n".join(lines)


def main() -> None:
    if platform.system().lower() != "windows":
        print("Warning: This script is intended for Windows. Some checks will be skipped on non-Windows hosts.")
    args = parse_args()

    # Admin check for operations that require it
    if args.fix or args.run_safe_checks:
        if not is_admin():
            print("Error: --run-safe-checks and --fix require Administrator privileges. Re-run elevated.")
            sys.exit(2)

    report, jp, hp = generate_report(args.out, run_safe_checks=args.run_safe_checks, do_fix=args.fix)
    if args.pretty:
        print(short_terminal_summary(report))
    print(f"Reports written: {hp} and {jp}")


if __name__ == "__main__":
    main()
