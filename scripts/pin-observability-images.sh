#!/usr/bin/env bash
#
# scripts/pin-observability-images.sh
#
# THE PROBLEM
#   helm/observability/CHART_VERSION pins the kube-prometheus-stack CHART, and
#   that is already deterministic: `--version 86.1.0` fetches byte-identical
#   chart content every time, including the image tags in its own values.yaml.
#   Nothing installs "latest".
#
#   But those tags live inside a chart nobody reads. Two consequences:
#
#     1. You cannot answer "which Grafana are we running?" from this
#        repository. You have to go and look at someone else's chart.
#     2. Bumping CHART_VERSION by one line silently changes Prometheus,
#        Grafana, Alertmanager, kube-state-metrics and node-exporter all at
#        once, and the diff shows a single digit changing.
#
#   jenkins/values.yaml does not accept that: it pins the chart in
#   jenkins/CHART_VERSION AND the controller image explicitly, so a version
#   change is a visible line in a review. The observability stack should meet
#   the same bar.
#
# WHAT THIS DOES
#   Resolves the image tags the PINNED chart actually uses, and writes them as
#   explicit overrides into helm/observability/kube-prometheus-stack.values.yaml.
#   After running it, every component version is a line in this repository that
#   a reviewer can see change.
#
#   It needs the chart repository, so it runs on your machine and commits the
#   result — the same reasoning as scripts/pin-base-images.sh, which resolves
#   base image digests rather than inventing them.
#
# USAGE
#   ./scripts/pin-observability-images.sh            # resolve and write
#   ./scripts/pin-observability-images.sh --check    # report, change nothing
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VALUES="helm/observability/kube-prometheus-stack.values.yaml"
CHART_VERSION=$(tr -d '[:space:]' < helm/observability/CHART_VERSION)

# The one marker string, used by the writer, the cleanup pass and --check.
# Three copies of it is how --check ended up looking for a string nothing
# ever wrote.
PIN_MARKER="# pinned by scripts/pin-observability-images.sh"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

command -v helm >/dev/null || { echo "ERROR: helm is required." >&2; exit 1; }

echo "Resolving image tags used by kube-prometheus-stack ${CHART_VERSION}..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update >/dev/null 2>&1 || true

DEFAULTS=$(mktemp); trap 'rm -f "$DEFAULTS"' EXIT
if ! helm show values prometheus-community/kube-prometheus-stack \
        --version "$CHART_VERSION" > "$DEFAULTS" 2>/dev/null; then
    echo "ERROR: could not fetch chart ${CHART_VERSION} from the repository." >&2
    echo "       Check network access and that the version still exists:" >&2
    echo "       helm search repo prometheus-community/kube-prometheus-stack --versions" >&2
    exit 1
fi

# Each component's tag lives at a different path in the chart's values. Read
# them structurally rather than with grep: a grep for 'tag:' matches a dozen
# unrelated things, including the sidecars.
read -r -d '' PYCODE <<'PY' || true
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))

def dig(*path):
    cur = d
    for p in path:
        if not isinstance(cur, dict) or p not in cur:
            return None
        cur = cur[p]
    return cur

components = {
    "prometheus":         dig("prometheus", "prometheusSpec", "image", "tag"),
    "alertmanager":       dig("alertmanager", "alertmanagerSpec", "image", "tag"),
    "grafana":            dig("grafana", "image", "tag"),
    "prometheusOperator": dig("prometheusOperator", "image", "tag"),
    "kubeStateMetrics":   dig("kube-state-metrics", "image", "tag"),
    "nodeExporter":       dig("prometheus-node-exporter", "image", "tag"),
}
# A chart that stops declaring a tag would otherwise be recorded as an empty
# pin, which reads as "pinned" and behaves as "whatever the chart decides".
missing = [k for k, v in components.items() if not v]
if missing:
    sys.exit("could not resolve a tag for: " + ", ".join(missing))
for k, v in components.items():
    print(f"{k}={v}")
PY

RESOLVED=$(python3 -c "$PYCODE" "$DEFAULTS") || {
    echo "ERROR: $RESOLVED" >&2
    echo "       The chart's values layout may have changed between versions." >&2
    exit 1
}

echo ""
echo "  chart ${CHART_VERSION} resolves to:"
echo "$RESOLVED" | while read -r line; do echo "    $line"; done
echo ""

# The resolved values are handed to the writer on STDIN rather than eval'd into
# shell variables. eval on text fetched from a remote chart is a code-execution
# path for no benefit, and it also hides the assignment from static analysis --
# which is how a typo'd variable name becomes an empty pin that reads as
# "pinned" and behaves as "whatever the chart decides".

if [ "$CHECK_ONLY" -eq 1 ]; then
    # AUDIT FIX -- this grepped for "PINNED_BY_SCRIPT", a string that appears
    # nowhere except in that grep. The writer inserts the marker
    # "# pinned by scripts/pin-observability-images.sh" instead, so --check
    # reported "NO explicit image pins" unconditionally: immediately after a
    # successful pin run, and forever after. It always exited 0, so nothing
    # noticed. The sentinel is now the string the writer actually emits, and
    # both live in one variable so they cannot drift apart again.
    if grep -q "$PIN_MARKER" "$VALUES"; then
        echo "  ${VALUES} carries explicit pins."
        echo "  Compare the values above with the ones committed there."
    else
        echo "  ${VALUES} has NO explicit image pins."
        echo "  The chart version alone decides these. Run without --check to pin them."
    fi
    exit 0
fi

# The resolved pairs go to a temp FILE and the writer reads it by path.
#
# The obvious `printf ... | python3 - "$VALUES" <<'PY'` does not work: the
# heredoc supplying the program overrides the pipe, so the script would read
# its own source as input and find no pairs. That is a silent nothing-happens,
# not an error -- shellcheck flags it as SC2259.
RESOLVED_FILE=$(mktemp)
trap 'rm -f "$DEFAULTS" "$RESOLVED_FILE"' EXIT
printf '%s\n' "$RESOLVED" > "$RESOLVED_FILE"

read -r -d '' WRITER <<'PY' || true
"""Insert image tags INTO the existing blocks. Never append new ones.

THE BUG THIS AVOIDS, WHICH THE FIRST VERSION HAD

Appending

    prometheus:
      prometheusSpec:
        image:
          tag: "v3.1.0"

to the end of the file produces a SECOND top-level `prometheus:` key. YAML
resolves duplicate keys by taking the last one, so that block does not merge
with the first -- it REPLACES it. retention, retentionSize, the
serviceMonitorSelector settings, `ingress.enabled: false` and every resource
limit vanish, and the file still parses perfectly. Helm accepts it. Prometheus
comes up with default retention and an Ingress it must never have.

The file was written by a script, the mistake is invisible in a `yaml.safe_load`
smoke test that only checks the tag it just wrote, and nothing fails until
someone notices Prometheus is exposed.

So: find the parent key in the existing text and insert under it, in place.
That keeps one copy of every key and preserves the comments, which in this
repository are the point.
"""
import sys

path, resolved_path, marker = sys.argv[1], sys.argv[2], sys.argv[3]
resolved = dict(
    line.split("=", 1) for line in open(resolved_path).read().split() if "=" in line
)
required = ["prometheus", "alertmanager", "grafana",
            "prometheusOperator", "kubeStateMetrics", "nodeExporter"]
missing = [k for k in required if not resolved.get(k)]
if missing:
    sys.exit("resolver did not supply: " + ", ".join(missing))

# component -> (line to insert under, indent of the inserted `image:` key)
TARGETS = {
    "prometheus":         ("  prometheusSpec:",         "    "),
    "alertmanager":       ("  alertmanagerSpec:",       "    "),
    "grafana":            ("grafana:",                  "  "),
    "prometheusOperator": ("prometheusOperator:",       "  "),
    "kubeStateMetrics":   ("kube-state-metrics:",       "  "),
    "nodeExporter":       ("prometheus-node-exporter:", "  "),
}

lines = open(path).read().split("\n")

# Strip anything a previous run inserted -- ONCE, before the loop.
#
# Doing this inside the loop was a bug worth recording: each component's
# cleanup pass removed the blocks the PREVIOUS components had just inserted,
# so only the last one in the list survived. The file still parsed, the last
# tag was correct, and five of six pins were silently absent. It was caught by
# the self-check below asserting every tag landed, not by anything failing.
_out, _i = [], 0
while _i < len(lines):
    if lines[_i].strip() == marker:
        _i += 3             # the comment, `image:` and `tag:`
        continue
    _out.append(lines[_i]); _i += 1
lines = _out

for comp in required:
    anchor, indent = TARGETS[comp]
    tag = resolved[comp]

    try:
        idx = next(i for i, line in enumerate(lines) if line.rstrip() == anchor)
    except StopIteration:
        sys.exit(f"could not find '{anchor}' in {path} -- the values layout changed; "
                 "fix TARGETS in this script rather than appending a duplicate key")

    lines[idx + 1:idx + 1] = [
        f"{indent}{marker}",
        f"{indent}image:",
        f'{indent}  tag: "{tag}"',
    ]

open(path, "w").write("\n".join(lines))
print(f"  inserted {len(required)} image tags into {path}")
PY

python3 -c "$WRITER" "$VALUES" "$RESOLVED_FILE" "$PIN_MARKER"

# --- verify our own output -------------------------------------------------
#
# A writer that can silently destroy settings must prove it did not. This
# re-parses the file and asserts both that the tags landed AND that the
# load-bearing settings around them survived -- the duplicate-key failure
# above would pass a check that only looked at the tags.
python3 - "$VALUES" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))

def dig(*path):
    cur = d
    for p in path:
        if not isinstance(cur, dict) or p not in cur:
            return None
        cur = cur[p]
    return cur

problems = []
for label, got in (
    ("prometheus tag",   dig("prometheus", "prometheusSpec", "image", "tag")),
    ("alertmanager tag", dig("alertmanager", "alertmanagerSpec", "image", "tag")),
    ("grafana tag",      dig("grafana", "image", "tag")),
    ("operator tag",     dig("prometheusOperator", "image", "tag")),
    ("ksm tag",          dig("kube-state-metrics", "image", "tag")),
    ("node-exporter tag", dig("prometheus-node-exporter", "image", "tag")),
):
    if not got:
        problems.append(f"{label} was not written")

# The settings a duplicate top-level key would have destroyed.
for label, got in (
    ("prometheus retention",        dig("prometheus", "prometheusSpec", "retention")),
    ("prometheus retentionSize",    dig("prometheus", "prometheusSpec", "retentionSize")),
    ("node-exporter tolerations",   dig("prometheus-node-exporter", "tolerations")),
):
    if not got:
        problems.append(f"{label} was LOST -- a duplicate top-level key replaced its block")
for label, got in (
    ("prometheus ingress disabled",   dig("prometheus", "ingress", "enabled")),
    ("alertmanager ingress disabled", dig("alertmanager", "ingress", "enabled")),
    ("grafana persistence disabled",  dig("grafana", "persistence", "enabled")),
):
    if got is not False:
        problems.append(f"{label} was LOST -- it is now {got!r}, not False")

if problems:
    print("  SELF-CHECK FAILED:")
    for p in problems:
        print("    " + p)
    sys.exit(1)
print("  self-check: tags written and every load-bearing setting survived")
PY


echo ""
echo "Done. Review the diff, then re-run the values check:"
echo "  git diff -- $VALUES"
echo "  python3 tests/check_observability_values.py"
