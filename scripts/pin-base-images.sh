#!/usr/bin/env bash
#
# scripts/pin-base-images.sh — REVIEW FIX 4.2
#
# THE PROBLEM
#   Every Dockerfile pins a base image by TAG:
#       FROM python:3.12-slim
#   A tag is a mutable pointer. The maintainer can move it, and a rebuild six
#   months from now can produce a different image than the one that was
#   scanned, tested and approved — with no change in Git to show for it.
#   That breaks reproducibility and it means a Trivy result has a shelf life.
#
# THE FIX
#   Pin by DIGEST as well:
#       FROM python:3.12-slim@sha256:<64 hex chars>
#   The tag stays for readability; the digest is what Docker actually resolves.
#   Bytes are now fixed: the same Dockerfile builds the same base forever.
#
# WHY THIS IS A SCRIPT RATHER THAN A COMMITTED DIFF
#   A digest can only be obtained from the registry, and it must be the REAL
#   one — an invented or stale digest does not degrade gracefully, it fails
#   the build with "manifest unknown". So this resolves them on your machine,
#   where the registry is reachable, and rewrites the Dockerfiles in place.
#
# USAGE
#   ./scripts/pin-base-images.sh            # rewrite in place
#   ./scripts/pin-base-images.sh --check    # report what is not pinned
#
# --check is a REPORT, not a gate. Nothing in deploy.sh, Jenkinsfile-ci or
# Jenkinsfile-cd calls it — the "(CI)" this line used to carry implied a gate
# that has never existed, which is the sort of claim that makes a reader assume
# a pipeline is enforcing something it is not. An unpinned base image therefore
# does not fail a build; it shows up here when you ask.
#
# helm/frontend/values.yaml ships the nginx exporter with an empty digest on
# purpose, so --check reports one unpinned image on a fresh checkout. That is
# the honest answer, not a defect: the chart renders a valid tag reference and
# deploys fine. Run this script without --check, on a machine with Docker and a
# reachable registry, to turn that tag into a digest.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

DOCKERFILES=(
    docker/backend/Dockerfile
    docker/worker/Dockerfile
    docker/frontend/Dockerfile
    jenkins/agent-tools/Dockerfile
)

EXPORTER_VALUES_CHECK="helm/frontend/values.yaml"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

if [ "$CHECK_ONLY" -eq 1 ]; then
    unpinned=0
    for f in "${DOCKERFILES[@]}"; do
        # AUDIT FIX -- a missing or renamed Dockerfile used to PASS this audit.
        #
        # `grep -E '^FROM ' "$f"` on a nonexistent path writes to stderr and
        # produces no stdout, so the `while` body never ran, `unpinned` stayed
        # 0, and --check printed "All base images are digest-pinned" and exited
        # 0. Renaming a Dockerfile silently removed it from the audit, which is
        # the same false-success shape as an assertion over an empty collection.
        if [ ! -f "$f" ]; then
            echo "  MISSING   $f — listed in DOCKERFILES but not present"
            unpinned=$((unpinned + 1))
            continue
        fi
        froms=0
        while read -r line; do
            froms=$((froms + 1))
            case "$line" in
                *"@sha256:"*) ;;
                *) echo "  UNPINNED  $f: $line"; unpinned=$((unpinned + 1)) ;;
            esac
        done < <(grep -E '^FROM ' "$f")
        # Zero FROM lines is not "all pinned", it is "nothing was examined".
        if [ "$froms" -eq 0 ]; then
            echo "  NO FROM   $f — nothing was audited in this file"
            unpinned=$((unpinned + 1))
        fi
    done

    # AUDIT FIX -- --check ignored the one image the write path also pins.
    #
    # The nginx exporter sidecar is pinned by digest in helm/frontend/values.yaml
    # by the resolve path below, but --check only ever looked at FROM lines. So
    # --check reported "All base images are digest-pinned" while that digest was
    # empty, which is exactly the state the repository ships in.
    if [ -f "$EXPORTER_VALUES_CHECK" ]; then
        exp_digest=$(awk '/repository: nginx\/nginx-prometheus-exporter/{found=1; next} found && /digest:/{gsub(/[",]/,"",$2); print $2; exit}' "$EXPORTER_VALUES_CHECK")
        if [ -z "$exp_digest" ]; then
            echo "  UNPINNED  $EXPORTER_VALUES_CHECK: nginx-prometheus-exporter has no digest"
            unpinned=$((unpinned + 1))
        fi
    fi

    if [ "$unpinned" -gt 0 ]; then
        echo ""
        echo "$unpinned base image(s) pinned by tag only."
        echo "Run ./scripts/pin-base-images.sh to pin them by digest."
        exit 1
    fi
    echo "All base images are digest-pinned."
    exit 0
fi

command -v docker >/dev/null || {
    echo "ERROR: docker is required to resolve digests." >&2; exit 1; }

echo "Resolving base image digests (this pulls each base once)..."
for f in "${DOCKERFILES[@]}"; do
    echo ""
    echo "  $f"
    # Only the image reference, ignoring any existing digest and any AS alias.
    while read -r ref; do
        base="${ref%%@*}"
        docker pull --quiet "$base" >/dev/null
        digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$base" | cut -d'@' -f2)
        [ -n "$digest" ] || { echo "    could not resolve $base" >&2; exit 1; }
        echo "    $base -> $digest"
        # Rewrite: keep the tag for readability, append/replace the digest.
        escaped_base=$(printf '%s' "$base" | sed 's/[][\.*^$/]/\\&/g')
        sed -i -E "s|^(FROM )${escaped_base}(@sha256:[a-f0-9]+)?( .*)?$|\1${base}@${digest}\3|" "$f"
    done < <(grep -E '^FROM ' "$f" | awk '{print $2}')
done

# --- Phase 5: the nginx exporter sidecar -------------------------------------
# Not a FROM line - it is an image reference in a Helm values file - but it has
# exactly the same problem and deserves exactly the same fix. Kept here rather
# than in a second script so there is ONE place that answers "which images are
# pinned, and how do I re-pin them".
EXPORTER_VALUES="helm/frontend/values.yaml"
if [ -f "$EXPORTER_VALUES" ]; then
    echo ""
    echo "  $EXPORTER_VALUES (nginx exporter sidecar)"
    exp_repo=$(awk '/repository: nginx\/nginx-prometheus-exporter/{print $2}' "$EXPORTER_VALUES")
    exp_tag=$(awk '/repository: nginx\/nginx-prometheus-exporter/{found=1; next} found && /tag:/{gsub(/"/,"",$2); print $2; exit}' "$EXPORTER_VALUES")
    if [ -n "$exp_repo" ] && [ -n "$exp_tag" ]; then
        docker pull --quiet "${exp_repo}:${exp_tag}" >/dev/null
        exp_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "${exp_repo}:${exp_tag}" | cut -d'@' -f2)
        if [ -n "$exp_digest" ]; then
            echo "    ${exp_repo}:${exp_tag} -> ${exp_digest}"
            # Replace the FIRST digest: "" that follows the exporter tag.
            python3 - "$EXPORTER_VALUES" "$exp_digest" <<'PY_INNER'
import re, sys
path, digest = sys.argv[1], sys.argv[2]
text = open(path).read()
# Anchored on the exporter block so no other digest field can be hit.
pattern = re.compile(r'(repository: nginx/nginx-prometheus-exporter.*?digest: )"[^"]*"', re.S)
new_text, n = pattern.subn(lambda m: m.group(1) + '"' + digest + '"', text, count=1)
if n != 1:
    sys.exit("could not locate the exporter digest field")
open(path, "w").write(new_text)
PY_INNER
        else
            echo "    could not resolve ${exp_repo}:${exp_tag}" >&2; exit 1
        fi
    fi
fi

echo ""
echo "Done. Review the diff, then rebuild and re-scan:"
echo "  git diff -- docker jenkins/agent-tools helm/frontend/values.yaml"
echo ""
echo "To update a base image later, edit the tag and re-run this script."
