# HighErrorRate

**Severity:** critical · **Fires when:** 5xx ratio above 2% for 5 minutes

Customers are seeing failures right now. This is the one alert that means the
product is broken rather than degraded.

## First three commands

```bash
kubectl get pods -n devops-app -o wide
kubectl logs deployment/backend -n devops-app --tail=100
./scripts/port-forward-monitoring.sh   # then open the Application dashboard
```

## Find the hop before guessing

The Application Overview dashboard has a **Dependency failures by hop** panel.
It names the broken hop instead of making you infer it:

```promql
sum by (dependency, service) (rate(dependency_failures_total{namespace="devops-app"}[5m]))
```

| Hop | What it means | Usual cause |
|---|---|---|
| `rds` | the database is unreachable or rejecting | the security group, a rotated password, RDS restarting |
| `s3` | the archive upload failed | IRSA role or bucket policy — orders still succeed, state stays `received` |
| `worker` | backend cannot reach the worker | worker pods down, or the NetworkPolicy |
| `sns` / `ses` | notifications failing | IRSA on worker-sa, or an unverified SES sender |

A rising 5xx with **no** dependency failures means the error is inside the
backend itself — read the pod log.

## Recover

- Recent deploy? The release annotation on the dashboard shows the `git_sha`
  and when it landed. Roll back:
  ```bash
  HELM_DRIVER=configmap helm rollback backend -n devops-app
  ```
- Database unreachable: check RDS is available and that the backend
  NetworkPolicy still allows 5432 to the DB subnets.
- Pods not ready: `kubectl describe pod -n devops-app <pod>` and read Events.

## Confirm recovery

The alert resolves on its own once the ratio drops. Do not silence it to make
it go away — the resolved notification is the proof that the fix worked.

```promql
sli:http_error_ratio:rate5m
```
