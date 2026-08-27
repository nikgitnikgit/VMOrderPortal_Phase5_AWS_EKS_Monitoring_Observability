"""app/common/metrics.py — Prometheus instrumentation shared by backend and worker.

One copy of this file is baked into both images (see docker/*/Dockerfile), so
the two services cannot drift into reporting the same idea under two different
metric names. A dashboard panel that has to say
`http_requests_total or backend_http_requests_total` is a panel nobody trusts.

THE PART THAT IS EASY TO GET WRONG: gunicorn forks.

Both services run gunicorn with 2 workers and 4 threads. Each worker is a
separate OS process with its own memory, so a plain prometheus_client registry
gives each worker its OWN counters. Prometheus scrapes one endpoint, the OS
hands the connection to whichever worker accepts it first, and the answer is
whatever that worker happens to have seen. Counters appear to jump backwards
between scrapes, rates go negative, and `increase()` silently invents traffic
that never happened.

prometheus_client solves this with multiprocess mode: every process writes its
samples into mmap'd files in a shared directory, and the scrape merges them.
Three things have to be true for it to work, and all three live here or in
gunicorn.conf.py:

  1. PROMETHEUS_MULTIPROC_DIR is set BEFORE any metric object is created.
     Import order matters: a Counter created before the variable is read
     registers itself in the ordinary in-process registry and is then invisible
     to the merged scrape, with no error anywhere.
  2. The directory is wiped at pod start (reset_multiproc_dir). An emptyDir
     survives a container restart inside the same pod, so a crashed worker's
     files would otherwise keep being merged in forever -- the pod restarts,
     the traffic stops, and the counters stay high.
  3. A dying worker is marked dead (mark_worker_dead) so its gauge samples stop
     being counted as live.

And one thing that simply does not work in multiprocess mode: Info metrics.
`app_build_info` is therefore a Gauge fixed at 1 with the labels on it, which
is the conventional `_info` pattern anyway and is what the dashboards join
against.

THE OTHER PART THAT IS EASY TO GET WRONG: label cardinality.

Every label value creates a time series that lives for the whole retention
window. `request.path` as a label means one new series per URL ever requested,
so a single scan for /wp-login.php, /.env, /admin lands thousands of dead
series in the index. We label with `request.url_rule.rule` -- the ROUTE
PATTERN, of which there are about six -- and anything that matched no route is
labelled "unmatched". No ticket ID, no email address, no idempotency key, no
raw path is ever a label value.
"""
import os
import shutil
import time

# Must happen before prometheus_client is imported anywhere else in the
# process. Import this module first from app.py / worker.py and the ordering
# takes care of itself.
MULTIPROC_DIR = os.environ.get("PROMETHEUS_MULTIPROC_DIR", "/tmp/prom")
os.environ.setdefault("PROMETHEUS_MULTIPROC_DIR", MULTIPROC_DIR)

from prometheus_client import (          # noqa: E402  (see the note above)
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    multiprocess,
    start_http_server,
)

def _env_port(name: str, default: int) -> int:
    """Parse a port from the environment without ever raising at import time.

    AUDIT FIX. `int(os.environ.get("METRICS_PORT", "9090"))` looks safe and is
    not: a Helm value that renders to an empty string sets the variable to ""
    rather than leaving it unset, so the `default` never applies and the module
    dies with ValueError during `import metrics` -- before app.py has run a
    single line. The pod then CrashLoopBackOffs with a traceback that points at
    the metrics module, which reads as "the application is broken" rather than
    "a value rendered empty".

    Failing to start because of a metrics detail is the same mistake
    reset_multiproc_dir() already refuses to make below.
    """
    raw = (os.environ.get(name) or "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        print(f"metrics: {name}={raw!r} is not a port number, using {default}")
        return default


METRICS_PORT = _env_port("METRICS_PORT", 9090)

# ---------------------------------------------------------------------------
# Metric definitions
# ---------------------------------------------------------------------------

# Buckets chosen for THIS application, not copied from a tutorial. The SLO is
# "95% of requests under 500 ms", so there are bucket edges either side of
# 0.5 -- 0.25, 0.5, 1.0 -- which is what lets histogram_quantile interpolate
# a p95 near the threshold instead of guessing across a wide bucket. The long
# tail (5, 10) exists because /submit-order calls RDS, then S3, then the
# worker, and a 5-second timeout on any of them is a real outcome worth seeing.
LATENCY_BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0)

http_requests_total = Counter(
    "http_requests_total",
    "HTTP requests, by method, matched route pattern and status class.",
    ["service", "method", "route", "status"],
)

http_request_duration_seconds = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds, by matched route pattern.",
    ["service", "method", "route"],
    buckets=LATENCY_BUCKETS,
)

# livesum: each process reports its own value and the scrape SUMS the values of
# processes that are still alive. 'all' (the default) would keep counting a
# dead worker's in-flight requests forever.
http_requests_in_flight = Gauge(
    "http_requests_in_flight",
    "Requests currently being served.",
    ["service"],
    multiprocess_mode="livesum",
)

# The question this answers is "which hop broke?", which is the first thing
# anyone asks when the error rate rises. `dependency` is a closed set -- five
# values, enumerated in DEPENDENCIES -- so it can never grow unbounded.
dependency_failures_total = Counter(
    "dependency_failures_total",
    "Failed calls to a downstream dependency, by dependency name.",
    ["service", "dependency"],
)

DEPENDENCIES = ("rds", "s3", "worker", "sns", "ses")

# The metric that carries the commit into the time series database. CD sets
# GIT_SHA and APP_VERSION from the tag and commit it is already deploying, so a
# dashboard can annotate a latency step change with the release that caused it,
# and the CD monitoring gate can assert that the pods now serving traffic are
# reporting the commit this build promoted.
#
# A Gauge, not an Info: Info is unsupported in multiprocess mode. 'max' rather
# than 'livesum' because every process reports the same 1 and summing them
# would report the worker count instead.
app_build_info = Gauge(
    "app_build_info",
    "Build identity of the running process. Always 1; the labels carry the information.",
    ["service", "version", "git_sha", "release"],
    multiprocess_mode="max",
)


def _unknown(name):
    """Env value or a literal 'unknown' -- never an empty label.

    An empty string is a legal label value and joins to nothing, so a panel
    filtering on git_sha!="" would quietly show no data rather than showing
    that the deployment forgot to pass it.
    """
    v = (os.environ.get(name) or "").strip()
    return v or "unknown"


def set_build_info(service: str) -> None:
    app_build_info.labels(
        service=service,
        version=_unknown("APP_VERSION"),
        git_sha=_unknown("GIT_SHA"),
        release=_unknown("RELEASE"),
    ).set(1)


# ---------------------------------------------------------------------------
# Multiprocess plumbing -- called from gunicorn.conf.py hooks
# ---------------------------------------------------------------------------

def reset_multiproc_dir() -> None:
    """Empty the shared directory. Called from gunicorn's on_starting hook.

    An emptyDir volume belongs to the POD, not the container, so it survives a
    container restart. Without this wipe, a worker that was OOM-killed leaves
    its .db files behind and every later scrape keeps merging them: the pod
    restarts, traffic stops, and the counters stay exactly where they were.
    """
    try:
        shutil.rmtree(MULTIPROC_DIR, ignore_errors=True)
        os.makedirs(MULTIPROC_DIR, exist_ok=True)
    except OSError as exc:
        # Never take the application down because metrics could not start.
        # Monitoring that can kill the thing it monitors is worse than none.
        print(f"metrics: could not reset {MULTIPROC_DIR}: {exc}")


def mark_worker_dead(pid: int) -> None:
    """Called from gunicorn's child_exit hook."""
    try:
        multiprocess.mark_process_dead(pid)
    except Exception as exc:                      # noqa: BLE001 - never fatal
        print(f"metrics: could not mark worker {pid} dead: {exc}")


def start_metrics_server(service: str, port: int = None) -> None:
    """Serve the merged registry on its own port. Master process only.

    Called from gunicorn's when_ready hook, which runs ONCE in the arbiter
    after the socket is bound and before workers fork. Starting it per-worker
    would mean two processes racing for the same port and one dying with
    EADDRINUSE.

    Deliberately a SEPARATE port from the application. The task sheet requires
    the metrics endpoint to be separate from readiness and liveness, and there
    is a practical reason beyond compliance: /metrics on the app port would sit
    behind the same NetworkPolicy, rate limits and (in the frontend's case)
    nginx routing as user traffic, so tightening one would silently break the
    other.

    AUDIT FIX -- and the reason is stated three functions below this one:
    "Never take the application down because metrics could not start.
    Monitoring that can kill the thing it monitors is worse than none."
    reset_multiproc_dir() and mark_worker_dead() both honour that. This one did
    not. It is called from gunicorn's `when_ready`, and an exception raised in
    a gunicorn hook kills the ARBITER, not just the hook -- so a port already
    bound (a sidecar, a leftover process, a hostNetwork clash) turned a metrics
    problem into a pod that will not serve traffic at all.

    Verified rather than assumed: binding :9490 and then calling this function
    on the same port exits the process with OSError [Errno 98].
    """
    port = port or METRICS_PORT
    try:
        registry = CollectorRegistry()
        multiprocess.MultiProcessCollector(registry)
        start_http_server(port, registry=registry)
    except Exception as exc:                      # noqa: BLE001 - never fatal
        # Loud in the log, and the absence of the target is itself alerted on:
        # PrometheusTargetDown fires when this endpoint does not answer, so
        # degrading here is visible rather than silent.
        print(f"metrics: could not serve {service} on :{port}: {exc}")
        return
    print(f"metrics: serving {service} on :{port}/metrics (multiprocess)")


# ---------------------------------------------------------------------------
# Flask integration
# ---------------------------------------------------------------------------

def _route_label(request) -> str:
    """The matched route PATTERN, never the raw path.

    '/check-name' and '/submit-order' are two series. '/check-name?name=<x>'
    for every x a user types would be thousands. url_rule is None when nothing
    matched -- a 404 -- and every one of those collapses into 'unmatched'.
    """
    rule = getattr(request, "url_rule", None)
    return rule.rule if rule is not None else "unmatched"


# The methods this application can ever legitimately see. Everything else is
# recorded as "other".
#
# AUDIT FIX -- this file's own docstring says "No ticket ID, no email address,
# no idempotency key, no raw path is ever a label value", and then used
# `request.method` raw, which is a string the CLIENT chooses. Werkzeug does not
# restrict it to the known verbs: a request line of `HUNTER2 / HTTP/1.1` is
# parsed, routed to a 405, and its method reaches after_request unchanged.
#
# Measured, not assumed: 3 bogus methods against 2 paths minted 61 http_*
# series where a bounded set produces a constant handful. A loop over random
# verbs is a cardinality bomb that needs no authentication, no valid path and
# no rate above a trickle, and every series it mints survives the whole
# retention window -- so `route` was carefully bounded while the label next to
# it was left open.
_KNOWN_METHODS = frozenset((
    "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "TRACE", "CONNECT",
))


def _method_label(method: str) -> str:
    """The request method if it is a real one, else 'other'."""
    return method if method in _KNOWN_METHODS else "other"


def _status_label(status_code: int) -> str:
    """Status CLASS, not the exact code: 2xx, 4xx, 5xx.

    The alerts and the SLO both ask "what fraction of requests failed", which
    is a question about classes. Keeping the exact code would multiply every
    route's series count for no gain a dashboard actually uses.
    """
    return f"{status_code // 100}xx"


def instrument_flask(app, service: str) -> None:
    """Attach request metrics to a Flask app.

    Uses before_request/after_request rather than WSGI middleware so that the
    matched url_rule is available -- middleware runs before routing, where the
    route pattern does not exist yet and only the raw path does, which is
    precisely the label we must not use.
    """
    from flask import g, request

    @app.before_request
    def _metrics_start():                        # noqa: ANN202 - flask hook
        g._metrics_start = time.perf_counter()
        http_requests_in_flight.labels(service=service).inc()

    @app.after_request
    def _metrics_end(response):                  # noqa: ANN001 - flask hook
        # The metrics endpoint is served by a separate HTTP server on its own
        # port, so nothing here can observe itself.
        route = _route_label(request)
        method = _method_label(request.method)
        http_requests_total.labels(
            service=service,
            method=method,
            route=route,
            status=_status_label(response.status_code),
        ).inc()
        started = getattr(g, "_metrics_start", None)
        if started is not None:
            http_request_duration_seconds.labels(
                service=service, method=method, route=route,
            ).observe(time.perf_counter() - started)
        return response

    @app.teardown_request
    def _metrics_teardown(exc):                  # noqa: ANN001 - flask hook
        # teardown, not after_request: after_request is SKIPPED when the view
        # raises, and an unhandled exception is exactly when you do not want
        # the in-flight gauge to leak upwards forever.
        http_requests_in_flight.labels(service=service).dec()


def record_dependency_failure(service: str, dependency: str) -> None:
    """Count a failed downstream call.

    Guarded against a typo silently creating a sixth dependency: a name outside
    DEPENDENCIES is recorded as 'other' rather than minting a new series, and
    says so in the log where someone will see it.
    """
    if dependency not in DEPENDENCIES:
        print(f"metrics: unknown dependency {dependency!r}, recording as 'other'")
        dependency = "other"
    dependency_failures_total.labels(service=service, dependency=dependency).inc()
