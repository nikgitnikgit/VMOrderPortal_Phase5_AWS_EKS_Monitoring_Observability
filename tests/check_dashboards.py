"""Every dashboard must be loadable, wired to the right datasource, and queryable.

A broken Grafana dashboard does not error. It renders an empty panel, which is
visually identical to a healthy service with no traffic. That is the failure
this file exists to catch, and every check below corresponds to a way it
happens:

  * malformed JSON            -> the sidecar skips the ConfigMap silently
  * missing uid               -> the dashboard gets a random one on each
                                 install, so links and annotations break
  * wrong datasource uid      -> "Datasource not found" on every panel, which
                                 reads as a broken Prometheus
  * unparseable PromQL        -> empty panel, forever, no error
  * generated file is stale   -> the JSON in Git no longer matches the
                                 generator, so the next regeneration silently
                                 reverts someone's edit
"""
import glob
import json
import os
import subprocess
import sys

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

DASH_DIR = "helm/observability/dashboards"
EXPECTED_DS_UID = "prometheus"
REQUIRED = {"vm-app-overview", "vm-k8s-cluster", "vm-jenkins-delivery"}

problems = []
files = sorted(glob.glob(f"{DASH_DIR}/*.json"))

if not files:
    print(f"no dashboards found in {DASH_DIR}/")
    sys.exit(1)

have_promtool = subprocess.run(
    ["which", "promtool"], capture_output=True).returncode == 0

uids = set()
checked_queries = 0

for path in files:
    name = os.path.basename(path)
    try:
        d = json.load(open(path))
    except json.JSONDecodeError as exc:
        problems.append(f"{name}: not valid JSON — {exc}")
        continue

    for key in ("uid", "title", "panels"):
        if not d.get(key):
            problems.append(f"{name}: no {key}")
    uid = d.get("uid")
    if uid:
        if uid in uids:
            problems.append(f"{name}: duplicate uid {uid!r} — the second one silently overwrites the first")
        uids.add(uid)

    # editable:false matches allowUiUpdates:false in the Grafana values. If a
    # dashboard were editable, someone would edit it, it would work until the
    # pod restarted, and the change would vanish with no explanation.
    if d.get("editable") is not False:
        problems.append(f"{name}: editable is not false — a UI edit would appear to work and then vanish")

    panels = [p for p in d.get("panels", []) if p.get("type") != "row"]
    if not panels:
        problems.append(f"{name}: no panels other than rows")

    for p in panels:
        title = p.get("title", "<untitled>")
        ds = p.get("datasource") or {}
        if ds.get("uid") != EXPECTED_DS_UID:
            problems.append(
                f"{name}: panel {title!r} points at datasource {ds.get('uid')!r}, "
                f"expected {EXPECTED_DS_UID!r}")
        targets = p.get("targets") or []
        if not targets:
            problems.append(f"{name}: panel {title!r} has no query")
        for t in targets:
            expr = t.get("expr")
            if not expr:
                problems.append(f"{name}: panel {title!r} has a target with no expr")
                continue
            if not have_promtool:
                continue
            # Template variables are Grafana's, not PromQL's. Substitute
            # something syntactically valid before parsing, or every templated
            # panel reports a false error.
            q = (expr.replace("$service", ".*")
                     .replace("$pod", ".*")
                     .replace("$__rate_interval", "5m")
                     .replace("$__interval", "5m"))
            r = subprocess.run(
                ["promtool", "promql", "format", "--experimental", q],
                capture_output=True, text=True)
            checked_queries += 1
            if r.returncode != 0:
                problems.append(
                    f"{name}: panel {title!r} query does not parse — "
                    f"{r.stderr.strip().splitlines()[0] if r.stderr.strip() else 'unknown'}")

    # The release annotation is what ties a graph to a deploy. Without it the
    # Application dashboard cannot answer "did this release cause it?", which
    # is one of the questions the assignment names explicitly.
    if uid == "vm-app-overview":
        anns = d.get("annotations", {}).get("list", [])
        if not any("app_build_info" in (a.get("expr") or "") for a in anns):
            problems.append(f"{name}: no release annotation driven by app_build_info")

missing = REQUIRED - uids
if missing:
    problems.append("required dashboard(s) missing: " + ", ".join(sorted(missing)))

# The committed JSON must match what the generator produces. Otherwise the two
# drift and the next regeneration silently reverts a hand edit.
gen = "helm/observability/build-dashboards.py"
if os.path.exists(gen):
    before = {f: open(f).read() for f in files}
    r = subprocess.run([sys.executable, gen], capture_output=True, text=True)
    if r.returncode != 0:
        problems.append(f"{gen} failed to run: {r.stderr.strip()[:200]}")
    else:
        for f, old in before.items():
            if open(f).read() != old:
                problems.append(
                    f"{os.path.basename(f)} differs from what {gen} produces — "
                    "re-run the generator and commit the result")

if problems:
    print("dashboard problems:")
    for p in problems:
        print("  " + p)
    sys.exit(1)

print(f"{len(files)} dashboards valid, {checked_queries} PromQL expressions parsed"
      + ("" if have_promtool else " (promtool absent: queries NOT parsed)"))
if not have_promtool:
    # Say it out loud and fail: a check that could not run has not passed.
    print("promtool is required for this check")
    sys.exit(1)
