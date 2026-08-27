#!/usr/bin/env python3
"""tests/check_metrics_runtime.py — run the instrumentation and attack it.

Every other check in this directory reads files. This one imports the real
app/common/metrics.py, drives a real Flask app through it, and looks at the
bytes a Prometheus scrape would actually receive. Three of the four properties
below were BROKEN when this file was written, and none of them were visible to
a static check: the code read correctly in every case.

  1. The `method` label is bounded. It is a string the CLIENT chooses, and
     Werkzeug happily parses `HUNTER2 / HTTP/1.1`. Unbounded, an unauthenticated
     loop over random verbs mints series that live for the whole retention
     window -- which is precisely the failure metrics.py's own docstring
     promises to avoid for `route`, one label to the left.

  2. The `route` label is the matched RULE, and an unrouted path collapses to
     "unmatched" rather than minting a series per URL scanned for.

  3. start_metrics_server() never raises. It is called from gunicorn's
     `when_ready`, and an exception in a gunicorn hook kills the arbiter -- so
     a port clash turned "no metrics" into "no application".

  4. The module imports with a hostile environment. METRICS_PORT="" is what a
     Helm value that renders empty produces, and it is not the same as unset:
     the default never applies.
"""
import os
import socket
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMMON = os.path.join(REPO, "app", "common")

problems = []


def check(ok, message):
    if not ok:
        problems.append(message)


# --- 1 & 2: label bounds, driven through a real Flask app ------------------
os.environ["PROMETHEUS_MULTIPROC_DIR"] = tempfile.mkdtemp(prefix="metrics-runtime-")
sys.path.insert(0, COMMON)

try:
    from flask import Flask
    from prometheus_client import CollectorRegistry, generate_latest, multiprocess

    import metrics
except ImportError as exc:                        # pragma: no cover
    print(f"SKIPPED (flask/prometheus_client not installed: {exc})")
    sys.exit(0)

app = Flask(__name__)


@app.route("/check-name")
def _check_name():
    return "ok"


metrics.instrument_flask(app, "backend")
client = app.test_client()

client.get("/check-name")
client.post("/check-name")

# The attack: bogus verbs, and bogus paths of the shape a vulnerability scanner
# produces. A bounded implementation adds nothing new for any of them.
HOSTILE_METHODS = ["HUNTER2", "FOO", "BAR", "GETX", "ÉTÉ"]
HOSTILE_PATHS = ["/wp-login.php", "/.env", "/admin/config", "/?id=1"]
for m in HOSTILE_METHODS:
    for p in HOSTILE_PATHS:
        client.open(p, method=m)

registry = CollectorRegistry()
multiprocess.MultiProcessCollector(registry)
body = generate_latest(registry).decode()


def label_values(name):
    token = f'{name}="'
    return {line.split(token)[1].split('"')[0]
            for line in body.splitlines() if token in line}


methods = label_values("method")
routes = label_values("route")

leaked = methods - {"GET", "POST", "PUT", "PATCH", "DELETE",
                    "HEAD", "OPTIONS", "TRACE", "CONNECT", "other"}
check(not leaked,
      f"the `method` label is unbounded: a client minted the series {sorted(leaked)} "
      "just by sending that word as an HTTP verb")
check("other" in methods,
      "no request was recorded as method=\"other\" — the hostile verbs above should "
      "have collapsed into it, so either the collapse is missing or this test is "
      "no longer reaching the instrumentation")

leaked_routes = routes - {"/check-name", "unmatched"}
check(not leaked_routes,
      f"the `route` label is unbounded: {sorted(leaked_routes)} came from the request path")


# --- 3: the metrics server must never take the process down ----------------
holder = socket.socket()
holder.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
holder.bind(("127.0.0.1", 0))
busy_port = holder.getsockname()[1]
holder.listen(1)
try:
    metrics.start_metrics_server("backend", busy_port)
except Exception as exc:                          # noqa: BLE001 - that is the bug
    problems.append(
        f"start_metrics_server raised {type(exc).__name__} on a port already in use. "
        "It runs in gunicorn's when_ready hook, where an exception kills the arbiter: "
        "a metrics problem becomes a pod that serves no traffic at all")
finally:
    holder.close()


# --- 4: import must survive a hostile environment --------------------------
# A subprocess, because the module is already imported in this one.
for label, env_extra in (
    ('METRICS_PORT=""  (a Helm value that rendered empty)', {"METRICS_PORT": ""}),
    ('METRICS_PORT="http"  (a port NAME instead of a number)', {"METRICS_PORT": "http"}),
    ("a PROMETHEUS_MULTIPROC_DIR that does not exist yet",
     {"PROMETHEUS_MULTIPROC_DIR": os.path.join(tempfile.mkdtemp(), "not-created")}),
):
    env = dict(os.environ, PYTHONPATH=COMMON, **env_extra)
    env.setdefault("PROMETHEUS_MULTIPROC_DIR", os.environ["PROMETHEUS_MULTIPROC_DIR"])
    result = subprocess.run([sys.executable, "-c", "import metrics"],
                            env=env, capture_output=True, text=True)
    check(result.returncode == 0,
          f"`import metrics` fails with {label}: {result.stderr.strip().splitlines()[-1:]}. "
          "The pod CrashLoopBackOffs with a traceback pointing at the metrics module, "
          "which reads as a broken application rather than an empty value")

if problems:
    print("metrics runtime problems:")
    for p in problems:
        print("  " + p)
    sys.exit(1)

print(f"metrics runtime: method label bounded to {sorted(methods)}, "
      f"route label bounded to {sorted(routes)}, "
      "server degrades without raising, import survives a hostile environment")
