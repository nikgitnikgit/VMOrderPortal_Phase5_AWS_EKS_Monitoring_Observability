# ReplicasMismatch

**Severity:** warning · **Fires when:** available < desired for 10 minutes

A deployment has been short of replicas for longer than any healthy rollout
takes. Capacity is reduced and a single further failure may take the service
down.

## First three commands

```bash
kubectl get deploy,rs,pods -n devops-app
kubectl describe deployment <name> -n devops-app
kubectl describe pod -n devops-app <pending-or-crashing-pod>
```

## Read the pod state

| State | Meaning | Where to look |
|---|---|---|
| `Pending` | cannot be scheduled | Events — usually no node has room, or a taint |
| `ImagePullBackOff` | image cannot be pulled | the tag exists in ECR? node role has ECR read? |
| `CrashLoopBackOff` | starting and dying | `kubectl logs --previous` |
| `Running` but not Ready | readiness probe failing | the probe path and the app's dependencies |

On this cluster the app nodes are 3 × t3.small with an 11-pod ceiling each, so
"no room" is a realistic answer rather than a theoretical one.

## Recover

```bash
# after fixing the cause
kubectl rollout restart deployment/<name> -n devops-app
kubectl rollout status  deployment/<name> -n devops-app
```

If a bad image is the cause, roll back rather than waiting:

```bash
HELM_DRIVER=configmap helm history <name> -n devops-app
HELM_DRIVER=configmap helm rollback <name> <REVISION> -n devops-app
```

## Confirm recovery

The *Desired vs available replicas* panel on the Kubernetes dashboard — the two
lines should meet.
