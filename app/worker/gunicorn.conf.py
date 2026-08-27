"""Gunicorn configuration for the worker service.

REVIEW FIX 3.4 — see app/backend/gunicorn.conf.py for the reasoning. There is
no on_starting hook here: the worker owns no schema, it only reads and updates
rows the backend created.
"""
import os

SERVICE_NAME = "worker"

bind = "0.0.0.0:5001"

# See app/backend/gunicorn.conf.py: readOnlyRootFilesystem plus an emptyDir at
# /tmp, and gunicorn kills workers whose heartbeat file cannot be written.
worker_tmp_dir = "/tmp"

# /notify calls SNS, then SES, then updates RDS — three blocking round trips.
# Threads keep a second notification from queueing behind the first.
worker_class = "gthread"
workers = int(os.environ.get("GUNICORN_WORKERS", "2"))
threads = int(os.environ.get("GUNICORN_THREADS", "4"))

# The backend gives up on this service after 5s (requests.post timeout=5), so a
# long gunicorn timeout only holds a connection the caller has abandoned.
# 30s leaves room for a slow SES call while still bounding the worker.
timeout = 30
graceful_timeout = 30
keepalive = 65

accesslog = "-"
errorlog = "-"
loglevel = os.environ.get("GUNICORN_LOG_LEVEL", "info")
access_log_format = '%(h)s "%(r)s" %(s)s %(b)s %(D)sus'


# ---------------------------------------------------------------------------
# Prometheus multiprocess plumbing (phase 5)
#
# These three hooks are the whole reason the metrics endpoint reports the truth
# instead of "whatever the worker that answered happened to have seen". The
# reasoning is in app/common/metrics.py; the short version:
#
#   on_starting   master, before any fork -- wipe the shared directory, or a
#                 previous crashed worker's samples are merged in forever
#   when_ready    master, after the socket is bound -- start ONE metrics
#                 server on :9090. Per-worker would race for the port.
#   child_exit    master, when a worker dies -- stop counting its live gauges
#
# Load bearing detail: sys.path must include the app directory before importing
# metrics, because gunicorn is started with a config file rather than from the
# module's own directory.
# ---------------------------------------------------------------------------
def _load_metrics():
    import sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import metrics
    return metrics


def on_starting(server):
    _load_metrics().reset_multiproc_dir()


def when_ready(server):
    _load_metrics().start_metrics_server(SERVICE_NAME)


def child_exit(server, worker):
    _load_metrics().mark_worker_dead(worker.pid)
