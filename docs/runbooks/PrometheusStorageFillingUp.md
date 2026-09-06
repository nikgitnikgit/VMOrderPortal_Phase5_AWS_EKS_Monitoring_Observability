# PrometheusStorageFillingUp

**Severity:** warning · **Fires when:** the Prometheus PVC is above 80% used
for 15 minutes

Prometheus does not degrade gracefully when its disk fills. The TSDB wedges,
compaction fails, and recovery means deleting block files by hand from a volume
that is only mounted inside a pod that is itself unhealthy. This alert is a
warning rather than a critical because it is meant to reach you while there is
still room to act — by the time it would be critical, the cheap fixes are gone.

If it fires, `retentionSize` is not doing its job. That setting exists to make
this alert impossible, so treat it as the question to answer, not the number to
raise.

## First three commands

```bash
kubectl get pvc -n observability -l app.kubernetes.io/name=prometheus
kubectl exec -n observability prometheus-kube-prometheus-stack-prometheus-0 \
  -c prometheus -- df -h /prometheus
./scripts/port-forward-monitoring.sh   # then http://localhost:9090/tsdb-status
```

`/tsdb-status` is the page that matters: it names the label with the highest
cardinality, which is almost always the cause.

## Work through it in this order

1. **Is `retentionSize` still below the volume size?**

   ```bash
   kubectl get prometheus -n observability -o jsonpath='{.items[0].spec.retentionSize}{"\n"}'
   kubectl get pvc -n observability -l app.kubernetes.io/name=prometheus \
     -o jsonpath='{.items[0].spec.resources.requests.storage}{"\n"}'
   ```

   Shipped values are **7GB** retention on a **10Gi** volume, and
   `verify-observability.sh` asserts that relationship. If someone raised
   retention without growing the volume, that is the bug — put it back.

2. **Has series count jumped?** Compare against a week ago:

   ```promql
   prometheus_tsdb_head_series
   ```

   A step change means something started producing new label combinations, not
   that the cluster grew. Steady growth on a flat workload is cardinality.

3. **Find what is producing them.**

   ```promql
   topk(10, count by (__name__)({__name__=~".+"}))
   ```

   This project has already had one of these: the `method` label on
   `http_requests_total` was taking its value straight from the request verb,
   which is client-controlled. Sixty-one series from a handful of bogus verbs,
   and nothing bounded it. `app/common/metrics.py` now folds anything outside a
   known-verb allowlist to `other`, and `tests/check_metrics_runtime.py`
   attacks the instrumentation with hostile input to keep it that way.

   If a *new* unbounded label has appeared, fix it at the source. Dropping it
   with `metric_relabel_configs` stops the growth but keeps the series already
   in the head block until they age out.

4. **Only then consider more disk.** Growing the PVC is correct when the
   cluster genuinely got bigger. It is the wrong answer to a cardinality bug,
   because the same bug will fill any volume you give it — just later, and next
   time probably at night.

   ```bash
   kubectl patch pvc <name> -n observability \
     -p '{"spec":{"resources":{"requests":{"storage":"20Gi"}}}}'
   ```

   gp3 supports online expansion. Raise `retentionSize` in
   `helm/observability/kube-prometheus-stack.values.yaml` to match — leaving it
   at 7GB on a 20Gi volume wastes the space you just paid for, and
   `verify-observability.sh` checks the two agree.

## In an emergency

If the disk is already full and Prometheus will not start, delete the oldest
blocks directly:

```bash
kubectl exec -n observability prometheus-kube-prometheus-stack-prometheus-0 \
  -c prometheus -- sh -c 'ls -1t /prometheus | tail -5'
```

Delete the oldest of those, one at a time, then let the pod restart. **This
destroys history permanently.** Do it only when the alternative is no
monitoring at all, and note in the incident record which window was lost —
otherwise a future investigation will read the gap as a quiet period.

## What this alert deliberately does not do

It does not page. Storage filling is a slope, not a cliff, and 80% with
15 minutes of persistence leaves hours. If you find yourself reacting to it at
speed, the alert fired too late — lower the threshold rather than treating it
as an incident.

## Related

- [PrometheusTargetDown](PrometheusTargetDown.md) — the failure mode after this
  one is ignored: Prometheus stops, and every alert goes quiet at once.
