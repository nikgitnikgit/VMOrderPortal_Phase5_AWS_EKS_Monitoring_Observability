"""Put the shared metrics module on the path for the unit tests.

In the container, docker/*/Dockerfile COPIES app/common/metrics.py next to
app.py, so a bare `import metrics` resolves. Running the tests from the
repository there is no such copy, and both service modules fail to import.

A conftest.py is the right place for this rather than a PYTHONPATH in every
invocation: pytest imports it automatically, so `pytest app/` works the same
way from a developer's shell, from the CI pipeline and from the GitHub Actions
workflow, with nothing to remember.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "common"))

# Metrics must never be created before this is set, or they register in the
# ordinary registry instead of the multiprocess one. Under test the directory
# is a throwaway.
os.environ.setdefault("PROMETHEUS_MULTIPROC_DIR", "/tmp/pytest-prom")
os.makedirs(os.environ["PROMETHEUS_MULTIPROC_DIR"], exist_ok=True)
