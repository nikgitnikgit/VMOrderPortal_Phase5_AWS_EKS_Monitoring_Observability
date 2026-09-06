# JenkinsDown

**Severity:** critical · **Fires when:** `up{namespace="jenkins"} == 0` for
5 minutes

The Jenkins controller is not being scraped. Either it is down, or the scrape
path is broken — and the two need telling apart before anything else, because
they look identical from here and the fixes have nothing in common.

While this is firing, no release can be made and no build metric is being
recorded. The second half matters more than it sounds: the Grafana panels for
build duration and queue depth will show a flat line, which reads like a quiet
period rather than an outage.

## First three commands

```bash
kubectl get pods -n jenkins -o wide
kubectl get svc,servicemonitor -n jenkins
kubectl logs -n jenkins sts/jenkins -c jenkins --tail=100
```

## Work through it in this order

1. **Is the controller pod running?**

   ```bash
   kubectl get pods -n jenkins
   kubectl describe pod -n jenkins -l app.kubernetes.io/component=jenkins-controller
   ```

   `Pending` is almost always the node group: the controller runs on a tainted,
   single-node group and does not fit anywhere else.

   ```bash
   kubectl get nodes -L eks.amazonaws.com/nodegroup
   ```

2. **If the pod is fine, this is a scrape problem, not a Jenkins problem.**
   Jenkins is serving builds and only the metrics path is broken. Check the
   endpoint answers from inside the cluster:

   ```bash
   kubectl exec -n jenkins sts/jenkins -c jenkins -- \
     curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/prometheus
   ```

   `200` here with the alert still firing means the path between Prometheus and
   Jenkins is blocked, not the endpoint. Go to step 3.

   Anything else means the `prometheus` plugin is not installed or not
   configured — it is declared in `jenkins/values.yaml` under `installPlugins`,
   and a plugin that failed to install does not stop Jenkins from starting.

3. **NetworkPolicy.** Prometheus egress to the jenkins namespace is enumerated
   by port, and Jenkins is reached on **8080**:

   ```bash
   kubectl get netpol -n observability prometheus -o yaml | grep -A6 "jenkins"
   kubectl get netpol -n jenkins
   ```

   This exact class of failure has bitten this project once already, on CoreDNS:
   a missing port in the egress list produced `context deadline exceeded` on
   every scrape. A NetworkPolicy **drops** rather than refuses, so a blocked
   scrape times out and looks like a slow endpoint rather than a blocked one.
   If the target's last error is a timeout, suspect policy before suspecting
   load.

4. **ServiceMonitor still selecting the right port name.**

   ```bash
   kubectl get servicemonitor -n observability jenkins -o yaml | grep -A4 endpoints
   kubectl get svc -n jenkins jenkins -o jsonpath='{.spec.ports[*].name}{"\n"}'
   ```

   The ServiceMonitor selects the port **by name**. A renamed port does not
   error anywhere — it simply scrapes nothing.

## Confirming the fix

```bash
./scripts/port-forward-monitoring.sh    # then http://localhost:9090/targets
./scripts/verify-jenkins.sh
```

The target should return to `UP` within one scrape interval. `verify-jenkins.sh`
also asserts the controller is Ready, runs zero executors, and that
`application-ci` has discovered at least one branch — worth running in full
rather than only re-checking the target, since a controller that restarted may
have come back with jobs missing.

## Related

- [JenkinsQueueStuck](JenkinsQueueStuck.md) — Jenkins is up and scraping, but
  builds are not starting. Different problem, different fix.
- [PrometheusTargetDown](PrometheusTargetDown.md) — the general form of step 2
  onwards, for any namespace.
