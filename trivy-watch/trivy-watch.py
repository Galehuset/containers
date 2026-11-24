#!/usr/bin/env python3
"""trivy-watch: scan the images of running Docker containers with Trivy.

  - at start-up, and then every RESCAN_SECONDS: every running container
  - on every container start (docker events): that container, right away
  - on container destroy: drop its metrics

Scans go to the cluster's Trivy server (client/server mode, so no local
vulnerability DB). Each container gets a node_exporter textfile with
per-severity counts (split by whether a fix exists), and every HIGH and
CRITICAL finding is logged as one logfmt line, so Loki/Perses can list the
CVEs themselves. Full Trivy JSON reports are kept under STATE_DIR/reports.

Configured through the environment (see common/trivy-watch.nix):
  TRIVY_SERVER, TRIVY_TOKEN, TEXTFILE_DIR, STATE_DIR, RESCAN_SECONDS
"""
import collections
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time

SERVER = os.environ["TRIVY_SERVER"]
TEXTFILE_DIR = os.environ["TEXTFILE_DIR"]
STATE_DIR = os.environ["STATE_DIR"]
RESCAN_SECONDS = int(os.environ.get("RESCAN_SECONDS", "86400"))
SEVERITIES = ("CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN")
LOGGED = ("CRITICAL", "HIGH")
# A container started again within this window reuses the last result for
# its image (restart loops shouldn't hammer the server).
CACHE_SECONDS = 900

jobs = queue.Queue()
cache = {}  # image id -> (time, report)


def log(msg):
    print(msg, flush=True)


def esc(v):
    """Escape a value for a Prometheus label or a quoted logfmt value."""
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def safe_name(name):
    return re.sub(r"[^A-Za-z0-9_.-]", "_", name)


def docker(*args):
    return subprocess.run(["docker", *args], capture_output=True, text=True, check=True).stdout


def running():
    """{container name: image id} for every running container."""
    out = {}
    for line in docker("ps", "--format", "{{.Names}}").split():
        try:
            out[line] = docker("inspect", "-f", "{{.Image}}", line).strip()
        except subprocess.CalledProcessError:
            pass  # gone in the meantime
    return out


def trivy(image_id):
    hit = cache.get(image_id)
    if hit and time.time() - hit[0] < CACHE_SECONDS:
        return hit[1]
    p = subprocess.run(
        # The token reaches trivy as $TRIVY_TOKEN (environment), not argv,
        # so it doesn't show in the process list.
        ["trivy", "image", "--quiet", "--image-src", "docker", "--server", SERVER,
         "--scanners", "vuln", "--format", "json", "--cache-dir", os.path.join(STATE_DIR, "cache"),
         "--timeout", "15m", image_id],
        capture_output=True, text=True, timeout=1800)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip().splitlines()[-1] if p.stderr.strip() else f"exit {p.returncode}")
    report = json.loads(p.stdout)
    cache[image_id] = (time.time(), report)
    return report


def write_atomic(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def prom_path(container):
    return os.path.join(TEXTFILE_DIR, f"trivy_{safe_name(container)}.prom")


def scan(container, image_id):
    try:
        report = trivy(image_id)
        ok = 1
    except Exception as e:  # noqa: BLE001 -- any failure is reported, not fatal
        log(f'level=error msg="scan failed" container="{esc(container)}" image_id={image_id[:19]} error="{esc(e)}"')
        report, ok = None, 0

    tags = (report or {}).get("Metadata", {}).get("RepoTags") or []
    image = tags[0] if tags else image_id[:19]
    labels = f'container="{esc(container)}",image="{esc(image)}"'
    now = int(time.time())
    lines = [
        "# HELP trivy_container_vulnerabilities Vulnerabilities in a running container's image, by severity and whether a fixed version exists.",
        "# TYPE trivy_container_vulnerabilities gauge",
    ]
    if report is not None:
        counts = collections.Counter()
        for result in report.get("Results") or []:
            for v in result.get("Vulnerabilities") or []:
                sev = v.get("Severity", "UNKNOWN")
                fixable = bool(v.get("FixedVersion"))
                counts[(sev, fixable)] += 1
                if sev in LOGGED:
                    log(f'level=warn msg="vulnerability" cve={v.get("VulnerabilityID")} severity={sev} '
                        f'fixable={str(fixable).lower()} container="{esc(container)}" image="{esc(image)}" '
                        f'package="{esc(v.get("PkgName", ""))}" installed="{esc(v.get("InstalledVersion", ""))}" '
                        f'fixed="{esc(v.get("FixedVersion", ""))}" title="{esc(v.get("Title", ""))[:200]}"')
        for sev in SEVERITIES:
            for fixable in (True, False):
                lines.append(f'trivy_container_vulnerabilities{{{labels},severity="{sev}",'
                             f'fixable="{str(fixable).lower()}"}} {counts[(sev, fixable)]}')
        os.makedirs(os.path.join(STATE_DIR, "reports"), exist_ok=True)
        write_atomic(os.path.join(STATE_DIR, "reports", f"{safe_name(container)}.json"), json.dumps(report))
        log(f'level=info msg="scanned" container="{esc(container)}" image="{esc(image)}" '
            + " ".join(f"{s.lower()}={sum(n for (sv, _), n in counts.items() if sv == s)}" for s in SEVERITIES))
    lines += [
        "# HELP trivy_container_scan_success Whether the last scan of this container's image worked.",
        "# TYPE trivy_container_scan_success gauge",
        f"trivy_container_scan_success{{{labels}}} {ok}",
        "# HELP trivy_container_scan_timestamp_seconds When this container's image was last scanned.",
        "# TYPE trivy_container_scan_timestamp_seconds gauge",
        f"trivy_container_scan_timestamp_seconds{{{labels}}} {now}",
    ]
    write_atomic(prom_path(container), "\n".join(lines) + "\n")


def full_rescan():
    current = running()
    # drop files of containers that no longer run
    for f in os.listdir(TEXTFILE_DIR):
        if f.startswith("trivy_") and f.endswith(".prom"):
            if f not in {os.path.basename(prom_path(c)) for c in current}:
                os.remove(os.path.join(TEXTFILE_DIR, f))
    cache.clear()  # the daily pass is what picks up newly published CVEs
    for name, image_id in current.items():
        jobs.put(("scan", name, image_id))
    log(f'level=info msg="full rescan queued" containers={len(current)}')


def watch_events():
    """Feed container start/destroy events into the job queue, forever."""
    while True:
        p = subprocess.Popen(
            ["docker", "events", "--format", "{{json .}}", "--filter", "type=container",
             "--filter", "event=start", "--filter", "event=destroy",
             # podman's Docker-compatible API (VyOS) reports "remove"
             "--filter", "event=remove"],
            stdout=subprocess.PIPE, text=True)
        for line in p.stdout:
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            name = ev.get("Actor", {}).get("Attributes", {}).get("name")
            if not name:
                continue
            if ev.get("Action") in ("destroy", "remove"):
                jobs.put(("drop", name, None))
            else:
                jobs.put(("start", name, None))
        log('level=warn msg="docker events stream ended, reconnecting"')
        time.sleep(5)


def rescan_timer():
    while True:
        time.sleep(RESCAN_SECONDS)
        jobs.put(("rescan", None, None))


def main():
    os.makedirs(TEXTFILE_DIR, exist_ok=True)
    threading.Thread(target=watch_events, daemon=True).start()
    threading.Thread(target=rescan_timer, daemon=True).start()
    full_rescan()
    while True:
        kind, name, image_id = jobs.get()
        try:
            if kind == "rescan":
                full_rescan()
            elif kind == "drop":
                try:
                    os.remove(prom_path(name))
                except FileNotFoundError:
                    pass
            elif kind == "start":
                try:
                    image_id = docker("inspect", "-f", "{{.Image}}", name).strip()
                except subprocess.CalledProcessError:
                    continue  # already gone
                scan(name, image_id)
            else:
                scan(name, image_id)
        except Exception as e:  # noqa: BLE001 -- keep the daemon alive
            log(f'level=error msg="job failed" job={kind} container="{esc(name)}" error="{esc(e)}"')


if __name__ == "__main__":
    sys.exit(main())
