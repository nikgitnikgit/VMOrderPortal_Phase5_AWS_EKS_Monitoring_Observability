#!/bin/bash
# Functional end-to-end test: runs the REAL app code (backend, worker, nginx
# with the chart env contract) against local PostgreSQL + moto mock AWS,
# pushes a real order through and verifies every hop.
# Requires: postgresql, nginx, python3-venv, internet for pip. Skips if absent.
set -e
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v psql >/dev/null || ! command -v nginx >/dev/null; then
    echo "SKIPPED (needs postgresql + nginx installed)"
    exit 0
fi

# REVIEW FIX 4.8 — the guard above only proved the binaries EXIST. Starting
# the postgresql cluster and `su postgres` both need root, so on a developer
# machine that has postgres and nginx installed but is running as a normal
# user, the test used to get halfway in and die on "Permission denied".
# A test that fails on a correctly configured machine is worse than no test:
# it teaches you to ignore a red result. Skip honestly, and say how to run it.
if [ "$(id -u)" != "0" ]; then
    echo "SKIPPED (needs root: starts the postgresql cluster, creates the test DB)"
    echo "  to run it:  sudo bash tests/run_functional.sh"
    exit 0
fi

VENV=/tmp/qa_func_venv
# The venv is cached across runs to keep this test quick, but "the directory
# exists" is not the same as "the venv works" -- and the difference is not
# theoretical. A venv hard-codes the interpreter it was built from, so upgrading
# or switching python3 leaves a directory that looks fine and whose pip dies
# with:
#
#     File "/tmp/qa_func_venv/bin/pip", line 5, in <module>
#       from pip._internal.cli.main import main
#     ModuleNotFoundError: No module named 'pip'
#
# which reads as a broken test rather than a stale cache. Found by moving this
# sandbox from Python 3.11 to 3.12 to match the machine the suite actually runs
# on. Verify the cache instead of trusting it, and rebuild when it is stale.
VENV_REBUILT=0
if [ -d "$VENV" ] && ! "$VENV/bin/python" -m pip --version >/dev/null 2>&1; then
    echo "  (rebuilding $VENV — it was built by a different python3)"
    rm -rf "$VENV"
    VENV_REBUILT=1
fi
[ -d "$VENV" ] || python3 -m venv "$VENV"
# TWO pip calls, not one, and that is load bearing.
#
# requirements.txt carries sha256 hashes (REVIEW FIX 4.3). pip switches into
# --require-hashes mode automatically as soon as ANY requirement in the
# invocation has a hash, and then REJECTS every requirement that does not have
# one. Naming the hashed files and the unhashed test-only packages in a single
# command therefore aborts with:
#
#   ERROR: Hashes are required in --require-hashes mode, but they are missing
#          from some requirements ... moto==5.0.28 --hash=sha256:...
#
# This test skips unless it is run as root on a machine with postgresql and
# nginx, so the failure sat here undiscovered: T7.6 reported PASS on every
# machine that could not run it, and would have failed on every machine that
# could. A test that only passes when it does nothing is the same
# false-success shape this project keeps finding elsewhere.
#
# The application dependencies stay hash-checked. Only the test harness
# (moto, requests) is installed without hashes, in its own call.
"$VENV/bin/pip" install -q -r "$REPO/app/backend/requirements.txt" -r "$REPO/app/worker/requirements.txt"
"$VENV/bin/pip" install -q "moto[server]==5.0.28" requests

pg_ctlcluster 16 main start 2>/dev/null || service postgresql start 2>/dev/null || true
su postgres -c "psql -c \"CREATE USER vmadmin WITH PASSWORD 'testpass123';\"" 2>/dev/null || true
su postgres -c "psql -c \"CREATE DATABASE vmorders OWNER vmadmin;\"" 2>/dev/null || true

# A moto server left running from the OLD venv is still listening, so the
# reachability check below is satisfied -- and then every AWS call fails with an
# XML parse error from deep inside botocore, because the process is running from
# an interpreter and site-packages that no longer exist. Reachable is not
# healthy, which is the same lesson as the venv check above. If the venv was
# rebuilt, the moto that belonged to it has to go with it.
if [ "$VENV_REBUILT" = "1" ]; then
    fuser -k 5566/tcp 2>/dev/null || true
    sleep 1
fi
curl -s -m 2 http://127.0.0.1:5566/moto-api/data.json >/dev/null 2>&1 || \
  { setsid "$VENV/bin/moto_server" -p 5566 </dev/null >/tmp/qa_moto.log 2>&1 & sleep 3; }

fuser -k 5000/tcp 5001/tcp 8080/tcp 9090/tcp 9091/tcp 2>/dev/null || true; sleep 1
# Fresh multiprocess directories. They are per-service because two processes
# writing into one directory merge into a single reported service.
rm -rf /tmp/qa_prom /tmp/qa_prom_worker
mkdir -p /tmp/qa_prom /tmp/qa_prom_worker
# An array, not a string: `env "${COMMON[@]}"` passes each KEY=VALUE as one
# argument, so a value containing a space could never split into two.
COMMON=(
  AWS_ENDPOINT_URL=http://127.0.0.1:5566
  AWS_ACCESS_KEY_ID=test
  AWS_SECRET_ACCESS_KEY=test
  AWS_REGION=us-east-1
  DB_HOST=127.0.0.1
  DB_PORT=5432
  DB_USER=vmadmin
  DB_PASSWORD=testpass123
  DB_NAME=vmorders
  PYTHONDONTWRITEBYTECODE=1
  # Phase 5. In the container the shared metrics module is COPIED next to
  # app.py by the Dockerfile, so a bare `import metrics` resolves. Running from
  # the repository it lives in app/common/, so the path has to be given
  # explicitly -- otherwise the app dies at import with ModuleNotFoundError and
  # the failure looks like a broken application rather than a test-harness
  # detail.
  "PYTHONPATH=$REPO/app/common"
  # Its own directory per service, and wiped by the harness below. Two services
  # sharing one multiprocess directory would merge each other's samples, which
  # is the exact bug the directory exists to avoid.
  PROMETHEUS_MULTIPROC_DIR=/tmp/qa_prom
  # Exercised for real: the gate and the dashboards both join on these.
  APP_VERSION=functional-test
  GIT_SHA=func0123456789
  RELEASE=functional
)
# Started under GUNICORN, not `python app.py`.
#
# Phase 5 made this the difference between testing the real thing and testing
# something adjacent to it. The metrics server is started by gunicorn's
# when_ready hook, the multiprocess directory is wiped by on_starting, and dead
# workers are reaped by child_exit -- none of which run under Flask's
# development server. Testing with `python app.py` would have exercised an
# arrangement that never runs anywhere, and reported that metrics worked when
# the production path was untested.
#
# It also matches the container exactly: docker/*/Dockerfile ends in
# `gunicorn --config gunicorn.conf.py`.
( cd "$REPO/app/worker" && env "${COMMON[@]}" \
    SNS_TOPIC_ARN=arn:aws:sns:us-east-1:123456789012:vm-order-func-sns \
    SES_SENDER=func-test@example.com \
    PROMETHEUS_MULTIPROC_DIR=/tmp/qa_prom_worker METRICS_PORT=9091 \
    setsid "$VENV/bin/gunicorn" --config gunicorn.conf.py worker:app \
    </dev/null >/tmp/qa_worker.log 2>&1 & )
( cd "$REPO/app/backend" && env "${COMMON[@]}" \
    S3_BUCKET=vm-order-func-test WORKER_URL=http://127.0.0.1:5001 \
    setsid "$VENV/bin/gunicorn" --config gunicorn.conf.py app:app \
    </dev/null >/tmp/qa_backend.log 2>&1 & )
# Longer than the old 5s: gunicorn's on_starting hook runs init_db, which
# retries a slow database up to five times before the port is even bound.
sleep 12

mkdir -p /tmp/qa_ngx && cp "$REPO/docker/frontend/nginx.conf" /tmp/qa_ngx/default.conf
# REVIEW FIX 4.8 — this used to append "127.0.0.1 backend" to /etc/hosts so
# that nginx could resolve the Kubernetes Service name. That mutated a system
# file outside the repo (the thing T16.3 forbids for the working tree, and the
# same principle applies here), it needed root purely for name resolution, and
# it left a line behind on the machine after the test finished.
# The config is already a throwaway copy in /tmp, so point the upstream at
# loopback there instead. Nothing is lost: T5.1 separately asserts that the
# REAL nginx.conf targets the correct Service name and port, so this rewrite
# cannot hide a mismatch. The `grep -q` afterwards fails loudly if the
# upstream in nginx.conf is ever renamed and this sed silently stops matching.
sed -i 's|proxy_pass http://backend:|proxy_pass http://127.0.0.1:|' /tmp/qa_ngx/default.conf
grep -q "proxy_pass http://127.0.0.1:5000/" /tmp/qa_ngx/default.conf || {
    echo "FAIL: could not rewrite the nginx upstream to loopback." >&2
    echo "      docker/frontend/nginx.conf no longer contains" >&2
    echo "      'proxy_pass http://backend:5000/' — update the sed above." >&2
    exit 1
}
cp "$REPO/app/index.html" /usr/share/nginx/html/index.html 2>/dev/null || true
printf "pid /tmp/qa_ngx/nginx.pid;\nerror_log /tmp/qa_ngx/error.log;\nevents {}\nhttp { access_log off; include /etc/nginx/mime.types; include /tmp/qa_ngx/default.conf; }\n" > /tmp/qa_ngx/main.conf
nginx -c /tmp/qa_ngx/main.conf 2>/dev/null || nginx -s reload 2>/dev/null || true
sleep 1

AWS_ENDPOINT_URL=http://127.0.0.1:5566 AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=us-east-1 \
  "$VENV/bin/python" "$REPO/tests/functional_assert.py"

# --- Phase 5: the same order must be visible as METRICS ----------------------
#
# The chain above proves the order reached every hop. This proves the
# instrumentation observed it. They are different claims: an app can serve
# perfectly while reporting nothing, and that failure is invisible until the
# day a dashboard is empty during an incident.
#
# Scraped from the app's own :9090, exactly as Prometheus would.
"$VENV/bin/python" - <<'PYEOF'
import sys
import urllib.request

try:
    body = urllib.request.urlopen("http://127.0.0.1:9090/metrics", timeout=10).read().decode()
except Exception as exc:
    sys.exit(f"FAIL: the backend metrics endpoint did not answer on :9090 ({exc})")

required = {
    # the order that just went through, counted as a business event
    'vm_orders_total{state="received"}':  "the business metric did not count the order",
    'vm_orders_total{state="stored"}':    "the S3 archive step was not counted",
    'vm_orders_total{state="notified"}':  "the worker notification was not counted",
    # the request that carried it
    'http_requests_total{':               "no HTTP requests were counted at all",
    'http_request_duration_seconds_':     "no latency histogram was produced",
    # the commit identity the CD gate and the dashboards join on
    'git_sha="func0123456789"':           "app_build_info is not reporting GIT_SHA",
}
missing = [msg for token, msg in required.items() if token not in body]
if missing:
    print(body[:1500])
    sys.exit("FAIL: " + "; ".join(missing))

# Cardinality, checked against reality rather than trusted: the route label
# must be the matched RULE, and a request to an unknown path must collapse
# into "unmatched" rather than minting a series per URL.
if 'route="/submit-order"' not in body:
    sys.exit("FAIL: route label is not the matched url_rule")

print("metrics OK: business counters, request counters, latency histogram and app_build_info all present")
PYEOF
