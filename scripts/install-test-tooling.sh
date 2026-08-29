#!/usr/bin/env bash
#
# scripts/install-test-tooling.sh
#
# Installs everything tests/run_all.sh needs in order to actually RUN every
# check, rather than skip some of them.
#
# WHY THIS EXISTS
#
#   A skipped check is not a passing check. The suite says so in its summary and
#   lists them by name, but knowing WHICH tool is missing and how to get it used
#   to live in somebody's head. On a fresh Ubuntu machine the suite reports
#   roughly:
#
#       210 passed, 1 failed, 4 skipped
#
#   and every one of those five is a missing package, not a defect. This script
#   is the answer, kept in the repository so it cannot go stale in a chat log.
#
#   GitHub Actions runs this SAME script (.github/workflows/ci.yml), so the
#   tooling CI uses and the tooling you use are one definition, pinned in one
#   place. T18.43 asserts the workflow still calls it.
#
# USAGE
#   ./scripts/install-test-tooling.sh              # everything
#   ./scripts/install-test-tooling.sh --no-sudo    # skip anything needing root
#
# Needs sudo for: promtool, kubeconform, shellcheck, postgresql, nginx.
set -euo pipefail

# Pinned, for the same reason every other version in this project is pinned: a
# floating "latest" makes a green run unreproducible, and a tool that silently
# changes behaviour between runs is worse than one that is simply old.
#
# MUST MATCH jenkins/agent-tools/Dockerfile. They did not: this script pinned
# kubeconform 0.6.7 while the image built 0.7.0, so CI, a developer machine and
# the build agent could each validate manifests with a different schema
# validator and disagree about whether the same file was valid. T18.44 now
# fails if they drift.
#
# These are also a SECURITY surface, which is easy to forget for a validation
# tool. promtool 3.1.0 and kubeconform 0.7.0 were about nineteen months old and
# had aged into a vulnerable Go crypto/tls (CVE-2025-68121) and gRPC
# (CVE-2026-33186). The Trivy CRITICAL gate in install-jenkins.sh caught it and
# stopped the deploy before the image was pushed -- which is the gate working,
# not a gate to argue with. Old validation tooling is still shipped tooling.
PROM_VERSION=3.14.0
KUBECONFORM_VERSION=0.8.0

NO_SUDO=0
[ "${1:-}" = "--no-sudo" ] && NO_SUDO=1

SUDO=""
if [ "$(id -u)" != "0" ]; then
    if [ "$NO_SUDO" -eq 1 ]; then
        SUDO="SKIP"
    elif command -v sudo >/dev/null; then
        SUDO="sudo"
    else
        echo "Not root and no sudo available; re-run as root or with --no-sudo." >&2
        exit 1
    fi
fi

have() { command -v "$1" >/dev/null 2>&1; }
note() { echo "  $1"; }

echo "=================================================="
echo "  Test tooling for tests/run_all.sh"
echo "=================================================="

# --- Python packages -------------------------------------------------------
#
# ONE PACKAGE AT A TIME, AND VERIFIED BY IMPORT.
#
# The first version of this script installed them in two batched pip calls and
# then printed "installed" unconditionally. That is wrong twice over:
#
#   1. pip resolves a whole invocation before installing any of it, so ONE
#      unavailable package means NONE of the others are installed either. A
#      batch is all-or-nothing, and the failure takes down packages that were
#      perfectly installable.
#   2. Printing "installed" after the command, with --quiet hiding the output,
#      is a claim rather than a check. The script reported success on a machine
#      where seven checks then failed for want of exactly these packages.
#
# So: each package separately, and the ONLY evidence that counts is that the
# module imports afterwards. `pip said ok` is not evidence; `import worked` is.
echo ""
echo "[1/4] Python packages"

PIP_FLAGS=""
# --break-system-packages is needed on Ubuntu 23.04+ (PEP 668), and does not
# exist on older pip. Ask pip itself rather than guessing from the OS version:
# passing an unsupported flag fails every install with "no such option".
if python3 -m pip install --help 2>/dev/null | grep -q -- "--break-system-packages"; then
    PIP_FLAGS="--break-system-packages"
fi

# package:import_name -- they differ often enough that assuming is a bug.
PYPKGS="
pyyaml:yaml
python-hcl2:hcl2
crossplane:crossplane
dockerfile:dockerfile
kubernetes-validate:kubernetes_validate
requests:requests
flake8:flake8
pytest:pytest
pytest-cov:pytest_cov
flask:flask
prometheus-client:prometheus_client
boto3:boto3
psycopg2-binary:psycopg2
"

PY_FAILED=""
for entry in $PYPKGS; do
    pkg="${entry%%:*}"; mod="${entry##*:}"
    if python3 -c "import ${mod}" >/dev/null 2>&1; then
        note "already importable: ${pkg}"
        continue
    fi
    # Not --quiet: if this fails, the reason is the useful part. Captured so a
    # success stays tidy and a failure prints everything.
    if ! out=$(python3 -m pip install $PIP_FLAGS "$pkg" 2>&1); then
        # ONE retry, for one specific and very common Debian/Ubuntu failure.
        #
        # Some pure-Python modules ship as .deb packages with no RECORD file,
        # so pip refuses to replace them:
        #
        #   ERROR: Cannot uninstall blinker 1.7.0, RECORD file not found.
        #          Hint: The package was installed by debian.
        #
        # On Ubuntu 24.04 that single message blocks flask entirely, because
        # blinker is one of its dependencies. --ignore-installed leaves the
        # apt-owned copy alone and installs alongside it, which is what is
        # wanted: the suite needs the module importable, not the packaging
        # tidy. Narrow on purpose -- only retried for THIS error, so a genuine
        # failure (no such package, no network) is still reported as one.
        #
        # Found by matching the reader's interpreter rather than reasoning
        # about it: invisible on Python 3.11, immediate on 3.12.
        if printf '%s' "$out" | grep -q "RECORD file not found"; then
            note "retrying ${pkg} with --ignore-installed (apt-owned dependency)"
            out=$(python3 -m pip install $PIP_FLAGS --ignore-installed "$pkg" 2>&1) || true
        fi
    fi
    # The ONLY thing that decides the outcome is whether the module imports.
    # Not pip's exit code, not "Successfully installed" in its output -- both of
    # those have been wrong here before.
    if python3 -c "import ${mod}" >/dev/null 2>&1; then
        note "installed: ${pkg}"
    else
        note "FAILED: ${pkg} is still not importable after installing. pip said:"
        printf '%s\n' "$out" | tail -5 | sed 's/^/           /'
        note "         this python3 is $(command -v python3)"
        PY_FAILED="$PY_FAILED $pkg"
    fi
done

# --- promtool --------------------------------------------------------------
echo ""
echo "[2/4] promtool  (T18.2 dashboards, and PromQL parsing in validate-observability.sh)"
# VERSION, not mere presence. AUDIT FIX: this used to accept any promtool at
# all, so a machine that installed 3.1.0 last week kept it forever -- including
# after the pin moved for a CRITICAL CVE. "Already present" is not the question;
# "is it the pinned version" is.
if have promtool && promtool --version 2>&1 | grep -q "${PROM_VERSION}"; then
    note "already at the pinned version: $(promtool --version 2>&1 | head -1)"
elif [ "$SUDO" = "SKIP" ]; then
    if have promtool; then
        note "SKIPPED (present but NOT ${PROM_VERSION}; needs root to replace)"
    else
        note "SKIPPED (needs root to write /usr/local/bin)"
    fi
else
    if have promtool; then note "replacing $(promtool --version 2>&1 | head -1)"; fi
    # --strip-components, so the binary lands in bin/ rather than in a
    # versioned directory that the next release renames.
    curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz" \
        | $SUDO tar -xz --strip-components=1 -C /usr/local/bin \
              "prometheus-${PROM_VERSION}.linux-amd64/promtool"
    note "installed $(promtool --version 2>&1 | head -1)"
fi

# --- kubeconform -----------------------------------------------------------
echo ""
echo "[3/4] kubeconform  (Kubernetes schema validation in validate-observability.sh)"
if have kubeconform && kubeconform -v 2>&1 | grep -q "${KUBECONFORM_VERSION}"; then
    note "already at the pinned version: $(kubeconform -v 2>&1 | head -1)"
elif [ "$SUDO" = "SKIP" ]; then
    if have kubeconform; then
        note "SKIPPED (present but NOT ${KUBECONFORM_VERSION}; needs root)"
    else
        note "SKIPPED (needs root to write /usr/local/bin)"
    fi
else
    if have kubeconform; then note "replacing $(kubeconform -v 2>&1 | head -1)"; fi
    curl -fsSL "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" \
        | $SUDO tar -xz -C /usr/local/bin kubeconform
    note "installed $(kubeconform -v 2>&1 | head -1)"
fi

# --- apt packages ----------------------------------------------------------
echo ""
echo "[4/4] shellcheck, postgresql, nginx  (T7.6 functional end-to-end)"
MISSING=""
have shellcheck || MISSING="$MISSING shellcheck"
have psql       || MISSING="$MISSING postgresql"
have nginx      || MISSING="$MISSING nginx"

if [ -z "$MISSING" ]; then
    note "all present"
elif [ "$SUDO" = "SKIP" ]; then
    note "SKIPPED (needs root): $MISSING"
elif have apt-get; then
    # shellcheck disable=SC2086  # deliberate word splitting: a package list
    $SUDO apt-get update -qq
    # shellcheck disable=SC2086
    $SUDO apt-get install -y -qq $MISSING
    note "installed:$MISSING"
else
    note "not apt-based — install by hand:$MISSING"
fi

# --- what is still missing -------------------------------------------------
#
# VERIFIED, not assumed, and covering the PYTHON PACKAGES as well as the
# binaries. The first version of this block listed only executables, so it could
# print "Everything the suite needs is present" on a machine where every
# Python-based check was about to fail -- which is exactly what happened. A
# summary that cannot see two thirds of what it is summarising is worse than no
# summary, because it stops you looking.
echo ""
echo "=================================================="
STILL=""
for tool in helm shellcheck psql nginx; do
    have "$tool" || STILL="$STILL $tool"
done
# promtool and kubeconform are checked by VERSION here too, not just presence:
# a stale one is not a missing one, but it is not the pinned one either, and
# reporting "present" for a binary the CRITICAL gate will reject is the same
# false comfort this script was rewritten to stop giving.
WRONGVER=""
if ! have promtool; then STILL="$STILL promtool"
elif ! promtool --version 2>&1 | grep -q "${PROM_VERSION}"; then
    WRONGVER="$WRONGVER promtool(want ${PROM_VERSION}, have $(promtool --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1))"
fi
if ! have kubeconform; then STILL="$STILL kubeconform"
elif ! kubeconform -v 2>&1 | grep -q "${KUBECONFORM_VERSION}"; then
    WRONGVER="$WRONGVER kubeconform(want ${KUBECONFORM_VERSION}, have $(kubeconform -v 2>&1 | head -1))"
fi

PY_STILL=""
for entry in $PYPKGS; do
    pkg="${entry%%:*}"; mod="${entry##*:}"
    python3 -c "import ${mod}" >/dev/null 2>&1 || PY_STILL="$PY_STILL $pkg"
done

if [ -n "$STILL" ] || [ -n "$PY_STILL" ] || [ -n "$WRONGVER" ]; then
    [ -n "$STILL" ]    && echo "  MISSING BINARIES:$STILL"
    [ -n "$WRONGVER" ] && echo "  WRONG VERSION:$WRONGVER"
    [ -n "$PY_STILL" ] && echo "  MISSING PYTHON PACKAGES:$PY_STILL"
    echo ""
    case "$STILL" in
        *helm*) echo "  helm is not installed by this script because it is also a"
                echo "  DEPLOYMENT tool, and installing one silently is not this"
                echo "  script's business. See README section 2:"
                echo "    https://helm.sh/docs/intro/install/"
                echo "" ;;
    esac
    if [ -n "$PY_STILL" ]; then
        echo "  Install those into the SAME python the suite uses:"
        echo "    $(command -v python3) -m pip install ${PIP_FLAGS} <package>"
        echo ""
        echo "  If pip says it succeeded and the import still fails, there are two"
        echo "  pythons on this machine and pip belongs to the other one."
    fi
    echo ""
    echo "  The suite will FAIL or SKIP the checks that need them, and name each"
    echo "  one. Neither is a pass."
    EXIT_CODE=1
else
    echo "  Verified: every tool and every Python package the suite needs"
    echo "  imports or runs on this machine."
    EXIT_CODE=0
fi
echo ""
echo "  Run the suite:"
echo "    bash tests/run_all.sh"
echo ""
echo "  T7.6 additionally needs ROOT -- it starts the postgresql cluster and"
echo "  creates a test database. Without sudo it skips honestly rather than"
echo "  dying halfway through:"
echo "    sudo bash tests/run_all.sh"
echo "=================================================="
# Non-zero when something is missing, so CI cannot proceed on a half-installed
# machine and quietly report skips as though they were a clean run.
exit $EXIT_CODE
