# NodeNotReadyOrPressure

**Severity:** critical · **Fires when:** a node is not Ready, or under memory
or disk pressure, for 5 minutes

This cluster has four nodes and three of them are single-purpose. Losing one is
not something to ride out.

| Node group | Loses |
|---|---|
| `app-nodes` (3 × t3.small) | a third of application capacity |
| `jenkins-nodes` (1 × m7i-flex.large, tainted) | **all** CI/CD |
| `monitoring-nodes` (1 × m7i-flex.large, tainted) | **all monitoring — including the alerting that would tell you** |

If the monitoring node is the one affected, this alert may be the last thing
you hear. Treat it as urgent.

## First three commands

```bash
kubectl get nodes -o wide
kubectl describe node <node>
kubectl get pods -A -o wide --field-selector spec.nodeName=<node>
```

## Common causes

- **MemoryPressure** — something without a limit grew. The Kubernetes
  dashboard's *Memory usage vs limit* panel shows which pod.
- **DiskPressure** — image layers or logs. Jenkins agents pull large images.
- **NotReady** — kubelet lost contact. Often an EC2-level problem.

## Recover

```bash
kubectl cordon <node>                 # stop new pods landing there
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
# then let the managed node group replace it
aws eks update-nodegroup-version --cluster-name <cluster> --nodegroup-name <ng>
```

A managed node group replaces an unhealthy node on its own; draining makes it
happen now rather than eventually.

## Confirm recovery

```promql
kube_node_status_condition{condition="Ready",status="true"}
```

Then check node-exporter is back on all nodes — it is the check that catches a
node with no metrics:

```bash
./scripts/verify-observability.sh
```
