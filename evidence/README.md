# Evidence

Outputs and screenshots proving each required step. Collect them during a live
cycle, **before** running `destroy.sh` — it empties the S3 bucket.

**This directory is currently empty apart from this file, and that is
correct.** Phase 4's evidence pack was removed when this repository became the
Phase 5 start point: every file in it photographed a cluster that has since
been destroyed — build numbers that no longer exist, ALB hostnames that no
longer resolve, an SBOM of images that were rebuilt afterwards. Keeping them
here would have left an `evidence/` directory that looks like it proves the
current system and does not, which is the one thing this project's rules do not
allow. Phase 4's pack is intact in the Phase 4 repository at commit `b6d1fd6`,
which is where a reviewer of Phase 4 will look for it.

What follows is the index to fill in for Phase 5.

## How to collect

### Platform — the cluster and Jenkins (unchanged from Phase 4)

```bash
kubectl get namespaces                                   > evidence/01-namespaces.txt
kubectl get pods -n jenkins -o wide                      > evidence/02-jenkins-pods.txt
kubectl get service,ingress,pvc -n jenkins               > evidence/03-jenkins-exposure.txt
kubectl get serviceaccount,role,rolebinding -n jenkins   > evidence/04-jenkins-rbac.txt
kubectl get role,rolebinding -n devops-app               > evidence/05-app-rbac.txt
kubectl get networkpolicy -A                             > evidence/07-networkpolicies.txt

# The permission split — still the core security claim
./scripts/verify-jenkins.sh                              > evidence/08-verify.txt
```

### Observability — what Phase 5 adds

```bash
kubectl get all -n observability                         > evidence/33-observability-objects.txt
kubectl get pvc -n observability                         > evidence/34-observability-storage.txt
kubectl get servicemonitor,podmonitor,prometheusrule -A  > evidence/35-monitors-and-rules.txt
kubectl get networkpolicy -n observability               > evidence/36-observability-netpol.txt
kubectl get clusterrolebinding -o yaml | grep -c cluster-admin  # expect: no binding from this stack
kubectl get pods -n observability -o wide                > evidence/37-monitoring-node-placement.txt
kubectl get ds -n observability -o wide                  > evidence/38-node-exporter-every-node.txt
```

Prometheus and Alertmanager have no Ingress by design, so anything that needs
their API goes through a port-forward first.

### Build and delivery artifacts

```bash
./scripts/collect-ci-evidence.sh          # pulls console log, scan reports and SBOMs from a build
```

## What goes here

Every file is prefixed with a number. The ranges are blocks, so a gap at the end
of a block is deliberate rather than a missing file.

| Range | Block |
|---|---|
| `00` | the deploy run itself |
| `01`–`08` | platform: cluster, Jenkins, RBAC, NetworkPolicy |
| `09`–`19` | CI pipeline, including the new validation of rules and dashboards |
| `20`–`29` | CD pipeline, including the post-deploy monitoring gate |
| `30`–`32` | rollback |
| `33`–`39` | the observability stack itself |
| `40`–`49` | dashboards and the scrape-health view |
| `50`–`59` | alerts firing and resolving, and the notifications they produced |
| `60`–`69` | the failure drills |
| unnumbered | build artifacts pulled by `scripts/collect-ci-evidence.sh`, kept under their own names |

## The chain the defence asks for

The point of the pack is that these can be laid end to end for one commit:

1. the commit — `git log`
2. the CI build that scanned it, and the image digest it recorded
3. CD verifying that digest against the registry before deploying
4. the Pod running that tag
5. `app_build_info` reporting that commit's SHA
6. the dashboard panel and the release annotation moving to it
7. a rule firing, the alert reaching the inbox, and the runbook that closed it

## Rules for anything committed here

- No AWS account ID, no credentials, no customer data. `scripts/collect-ci-evidence.sh`
  scrubs the account ID and refuses to write a file containing a
  credential-shaped string — do not work around it.
- Nothing here may be gitignored. A `.gitignore` rule once silently swallowed
  the Trivy reports this index requires; `T15.20` exists to stop that
  recurring.
- Evidence must be **current**. If the cluster it came from has been destroyed
  and rebuilt, collect it again rather than leaving the old screenshots in
  place.
