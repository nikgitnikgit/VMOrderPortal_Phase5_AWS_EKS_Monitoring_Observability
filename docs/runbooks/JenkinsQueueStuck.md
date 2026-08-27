# JenkinsQueueStuck

**Severity:** warning · **Fires when:** the build queue has been continuously
non-empty for 15 minutes

Nothing is shipping. Note the expression uses `min_over_time`, not an average:
the queue must have been occupied for the *whole* window. A busy afternoon of
healthy builds does not trigger this.

## First three commands

```bash
kubectl get pods -n jenkins -o wide
kubectl describe pod -n jenkins <pending-agent-pod>
kubectl describe node -l eks.amazonaws.com/nodegroup=<cluster>-jenkins-nodes
```

## The usual cause: the agent pod cannot be scheduled

The Jenkins node is **tainted** `role=jenkins:NoSchedule` and there is exactly
one of it. An agent pod lands there only if it tolerates that taint and the
node has room.

| Symptom in `describe pod` | Cause |
|---|---|
| `untolerated taint` | the pod template lost its toleration |
| `Insufficient cpu/memory` | one node, and a previous build is still holding it |
| `ImagePullBackOff` | the `tools-1.4` agent image is not in ECR |

The *Dynamic agent pods* panel on the Jenkins dashboard shows pending agents
next to queue length. Pending agents plus a non-empty queue is this exact
failure.

## Recover

```bash
# a build that finished but left its pod behind
kubectl delete pod -n jenkins -l jenkins/agent=true --field-selector status.phase=Succeeded

# the agent image is missing — rebuild and push it
./scripts/install-jenkins.sh        # skips the build if the tag already exists

# a wedged controller
kubectl rollout restart statefulset/jenkins -n jenkins
```

If the node itself is gone, this alert will be accompanied by
`NodeNotReadyOrPressure` — fix that first.

## Confirm recovery

```promql
jenkins_queue_size_value
```

**If that returns nothing at all**, the alert is not "not firing" — it is blind,
and so is every panel on the Jenkins dashboard. The plugin prefixes its metrics
with the namespace set in `jenkins/values.yaml`
(`prometheusConfiguration.defaultNamespace: "jenkins"`), and its own metric
names already begin with `jenkins_`, so the controller most likely emits
`jenkins_jenkins_queue_size_value`. The ServiceMonitor collapses that doubled
prefix at scrape time (`metricRelabelings` in
`helm/observability/templates/servicemonitor-jenkins.yaml`). Check what the
controller actually emits before assuming the queue is empty:

```bash
kubectl exec -n jenkins deploy/jenkins -- curl -s localhost:8080/prometheus | grep queue_size
```

`scripts/verify-observability.sh` asserts this after every install, so a
mismatch should have failed there first.

Then run a build and watch it get an executor.

---

## Also covers: `JenkinsDown`

Same runbook. `up{namespace="jenkins"} == 0` means the controller is not being
scraped at all: either it is down, or the `/prometheus` endpoint is broken.

```bash
kubectl get pods -n jenkins
kubectl exec -n jenkins statefulset/jenkins -- curl -s localhost:8080/prometheus | head
kubectl get networkpolicy -n jenkins jenkins-controller -o yaml   # observability allowed on 8080?
```
