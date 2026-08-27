# PodRestartingRepeatedly

**Severity:** warning · **Fires when:** a container restarts more than 3 times
in 30 minutes

A pod that keeps almost working is invisible to a replica count: it comes back,
the deployment reports available, and the requests in flight at each restart
are simply lost.

## First three commands

```bash
kubectl get pods -n <ns> -o wide
kubectl logs <pod> -n <ns> --previous          # the log from BEFORE the restart
kubectl describe pod <pod> -n <ns>             # Events and Last State
```

`--previous` is the important one. The current log starts after the restart and
will not contain the reason.

## Read `Last State`

| Reason | Meaning | Fix |
|---|---|---|
| `OOMKilled` | hit the memory limit | raise `resources.limits.memory`, or find the leak |
| `Error` with an exit code | the process died | the previous log has it |
| liveness probe failures in Events | the app stopped answering `/health` | usually a lost database connection |

For the backend specifically: `init_db()` runs in gunicorn's `on_starting` hook
and retries a slow RDS five times over ~40 s. A `startupProbe` suspends
liveness for up to 60 s so that a slow database does not cause exactly this
alert. If it fires anyway, the database is not slow — it is unreachable.

## Recover

```bash
HELM_DRIVER=configmap helm rollback <release> -n devops-app   # if a deploy caused it
kubectl rollout restart deployment/<name> -n devops-app        # if it is transient
```

## Confirm recovery

```promql
increase(kube_pod_container_status_restarts_total{namespace="devops-app"}[30m])
```
