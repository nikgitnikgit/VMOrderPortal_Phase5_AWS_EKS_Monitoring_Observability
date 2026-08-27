# PrometheusTargetDown

**Severity:** critical · **Fires when:** any target in `devops-app`, `jenkins`
or `observability` has `up == 0` for 5 minutes

A target that is not being scraped is not "fine". Every alert that depends on
its metrics is now **silent**, and silence looks exactly like health. That is
why this one is critical even though nothing is user-visible yet.

## First three commands

```bash
./scripts/port-forward-monitoring.sh      # then http://localhost:9090/targets
kubectl get pods -n <namespace> -o wide
kubectl get servicemonitor -A
```

You can also read this without a port-forward: the **Scrape health** row on the
Kubernetes dashboard shows every target and its state, behind Grafana's login.

## Work through it in this order

1. **Is the pod running?** If not, this alert is a symptom — fix the pod.
2. **Is the Service exposing a `metrics` port?**
   ```bash
   kubectl get svc <name> -n <ns> -o jsonpath='{.spec.ports[*].name}'
   ```
   The ServiceMonitor selects the port **by name**. A renamed port does not
   error; it scrapes nothing.
3. **Does the endpoint answer?**
   ```bash
   kubectl exec -n <ns> deploy/<name> -- curl -s localhost:9090/metrics | head
   ```
4. **Is the NetworkPolicy allowing it?** The app namespaces admit port 9090
   only from `observability`:
   ```bash
   kubectl get networkpolicy backend -n devops-app -o yaml
   ```
5. **Is Prometheus even looking?** If `serviceMonitorSelectorNilUsesHelmValues`
   were true, every ServiceMonitor would be valid and ignored:
   ```bash
   kubectl get prometheus -n observability -o yaml | grep -A2 serviceMonitorSelector
   ```

## Confirm recovery

```promql
up{namespace=~"devops-app|jenkins|observability"}
```

---

## Also covers: `PrometheusStorageFillingUp`

`retentionSize` (7GB) should trim blocks long before the 10Gi volume fills. If
it is not:

```bash
kubectl get prometheus -n observability -o jsonpath='{.items[0].spec.retentionSize}'
kubectl exec -n observability prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- df -h /prometheus
```

Either `retentionSize` was raised above the volume size, or series churn is
higher than the sizing assumed — check *TSDB head series* on the dashboard for
a step change, which means a new unbounded label was introduced.

## Also covers: `AlertmanagerNotificationsFailing`

Alerts are firing and nobody is being told.

```bash
kubectl logs -n observability alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager --tail=50
kubectl get sa alertmanager -n observability -o yaml | grep role-arn
```

Usually one of: the IRSA annotation missing, the SNS topic ARN wrong, or egress
on 443 blocked from the observability namespace.
