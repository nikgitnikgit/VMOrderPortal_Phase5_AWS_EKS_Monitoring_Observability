# The CD monitoring gate failed

Not an alert — this is what to read when `application-cd` fails at the
**Monitoring gate** stage and rolls the release back.

The gate asks Prometheus four questions about the release that was just
deployed. Any "no", and any "I don't know", fails the build.

## What each failure means

### 1. `fewer than N targets are up`

The pods deployed but Prometheus is not scraping them.

```bash
kubectl get pods -n devops-app
kubectl get servicemonitor -n devops-app
kubectl get endpoints -n devops-app
```

Most often the Service has no `metrics` port, or the NetworkPolicy is not
admitting the observability namespace. See `PrometheusTargetDown.md`.

### 2. `no pod reports app_build_info{git_sha="..."}`

**This is the interesting one.** The rollout succeeded and an older image is
still serving, or the build identity never reached the container.

```bash
kubectl get pods -n devops-app -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
kubectl exec -n devops-app deploy/backend -- env | grep GIT_SHA
kubectl exec -n devops-app deploy/backend -- curl -s localhost:9090/metrics | grep app_build_info
```

If `GIT_SHA` is empty, CD did not pass `--set build.gitSha`. If it is set but
the metric is absent, the metrics server did not start — check the pod log for
the `metrics: serving ...` line written by gunicorn's `when_ready` hook.

### 3. `5xx ratio exceeds ...`

The release is serving errors. Follow `HighErrorRate.md`. The rollback has
already run, so the previous version should be recovering — confirm it is.

### 4. `p95 exceeds ...` or `no latency data`

Slow, or not reporting. *No latency data* right after a smoke test means the
metrics path is broken rather than that nothing happened — treat it as case 1.

## Why it rolled back automatically

`scripts/monitoring-gate.sh` exits non-zero, which fails the stage, which
triggers `post { failure }` in `Jenkinsfile-cd`: diagnostics are collected
first (they disappear with the failed ReplicaSet otherwise), then
`helm rollback`, then an SNS notification.

## Re-running

Fix the cause and push. Do not re-run CD with the same tag hoping for a
different answer — if the gate was right, it will be right again.

To deploy while genuinely unable to satisfy the gate (an emergency), the
honest route is to say so out loud in the build and use a manual `helm upgrade`
from an operator machine, not to weaken the gate.
