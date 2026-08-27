# HighLatencyP95

**Severity:** warning · **Fires when:** p95 above 500 ms for 10 minutes

Requests are completing, slowly. The SLO says 95% of requests finish under
500 ms; this says they are not.

## First three commands

```bash
kubectl top pods -n devops-app
kubectl get hpa -n devops-app
./scripts/port-forward-monitoring.sh
```

## Narrow it down

**Is everything slow, or is there a slow tail?** The dashboard shows p50 next
to p95. p95 moving while p50 is flat means a subset of requests — usually one
route.

**Which route?** The *p95 by route* panel. `/submit-order` is expected to be
the slowest: it writes RDS, uploads to S3 and calls the worker in sequence.

**Is it throttling rather than load?** The Kubernetes dashboard's *Container
CPU throttling* panel. Throttling looks exactly like slowness with no CPU
spike, because the limit is doing what it was asked to.

## Recover

| Cause | Action |
|---|---|
| CPU throttling | raise `resources.limits.cpu` in the chart |
| Not enough replicas | check the HPA has room: `maxReplicas` is 5 for the backend |
| Slow RDS | check RDS CPU and connections in the AWS console |
| One slow route | look at what changed in that handler; check the release annotation |

## Confirm recovery

```promql
sli:http_latency_p95:rate5m
```

Give it the full 10-minute window before deciding it is fixed — the alert has
`for: 10m` precisely because latency is noisy.
