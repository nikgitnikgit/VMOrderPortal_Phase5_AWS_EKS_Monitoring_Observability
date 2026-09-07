# Evidence — failure exercises and observability proof

Captured on 2026-09-07 against the live cluster `vm-order-prod-eks`, on the
commit history ending `e130321`. Every screenshot here is from a real incident
performed on the running system, not a mock-up.

Required by §3 (תרגילי כשל והוכחות) and §4 (הגשה והגנת הפרויקט) of
*DevOps on AWS — פרויקט הגמר: הרחבת Observability*.

---

## Exercise 1 — return 5xx in a controlled way

*Spec: metric rises, dashboard changes, alert fires, matching runbook.*

**Method.** The backend's `NetworkPolicy` egress rule for PostgreSQL (port 5432)
was removed, cutting the database from pods that were **already running**.
`/api/check-name` and `/api/submit-order` then return 500 from
`app/backend/app.py:458` and increment `dependency_failures_total{dependency="rds"}`.

The pods stayed `Running` and `Ready` throughout — the failure is invisible to
`kubectl get pods` and to liveness probes, which is exactly the case monitoring
exists to catch.

| File | Shows |
|---|---|
| `ex1-error-ratio-dashboard.png` | Application Overview: error ratio **20.1%** against a 2% SLO, p95 **8.76s** against 500ms, availability 94.7%, and the "Error ratio vs SLO" panel crossing the threshold line |
| `ex1-higherrorrate-email.png` | `[FIRING] HighErrorRate` — severity critical, summary *"5xx ratio is 20.87%, above the 0.02 threshold"*, description, and `runbook_url` |
| `ex1-runbook.png` | `docs/runbooks/HighLatencyP95.md` opened from the alert link, with the full runbooks folder visible in the repository |

p95 rose to 8.76s because `get_db_connection()` sets `connect_timeout=5` — the
latency SLI and the error SLI both degraded from one injected fault.

---

## Exercise 2 — pod deleted / readiness fails

*Spec: Kubernetes metrics, recovery/rollout, service availability.*

**Method.** The three application nodes were cordoned and the frontend pods
deleted, so no replica could be scheduled while the Deployment still wanted 2.

An earlier attempt — patching the Deployment with an impossible `nodeSelector` —
did **not** produce a mismatch, because Kubernetes keeps the old ReplicaSet
serving until new pods are ready. That is Kubernetes protecting availability
during a stalled rollout, and it is visible as the first dip in
`ex2-replicas-grafana.png`.

| File | Shows |
|---|---|
| `ex2-replicas-diverging.png` | `kubectl`: cordon applied, pods deleted, deployment at `0/2` with `AVAILABLE 0`, both pods `Pending` |
| `ex2-replicas-grafana.png` | Kubernetes / Cluster: `frontend available` falling to 0 while `backend` and `worker` hold at 2 |
| `ex2-replicasmismatch-email.png` | `[FIRING] ReplicasMismatch` — `deployment=frontend`, `namespace=devops-app`, severity warning, runbook link |
| `ex2-podrestarting-email.png` | `[FIRING] PodRestartingRepeatedly` — fired independently earlier the same day from a genuine CrashLoopBackOff |
| `ex2-ex3-recovery.png` | Uncordon, `deployment "frontend" successfully rolled out`, all pods `Running` |

---

## Exercise 3 — Jenkins agent cannot start

*Spec: queue/agent metrics and an alert with no false positives.*

**Method.** The Jenkins node group is a single tainted node. Cordoning it means
agent pods — created fresh per build — cannot be scheduled, while the Jenkins
controller keeps running. A build was then started and sat in the queue.

| File | Shows |
|---|---|
| `ex3-agent-pending.png` | Cordon, node `Ready,SchedulingDisabled`, agent pod `Pending 0/4`, build **#8 Pending** in Jenkins, and the scheduler's own reason: `FailedScheduling — 0/5 nodes are available: 1 node(s) had untolerated taint(s), 1 node(s) were unschedulable, 3 node(s) didn't match Pod's node affinity/selector` |
| `ex3-queue-climbing.png` | Jenkins & Delivery: **Queue length 2**, **Busy executors 0**, **Dynamic agent pods — pending 1, running 0** |
| `ex3-jenkinsqueuestuck-firing-and-resolved.png` | `[FIRING] JenkinsQueueStuck` with its design rationale, and the same thread showing **Resolved** 10 minutes later |
| `ex2-ex3-recovery.png` | After uncordon, the agent pod reaches `4/4 Running` and the queued build executes |

**On false positives.** The rule is
`min_over_time(jenkins_queue_size_value[15m]) > 0` with `for: 15m`, not an
average. The queue must be *continuously* occupied for the whole window; an
average would fire on a busy afternoon of perfectly healthy builds. Queue
length 2 with **zero** busy executors is the signature of a stuck queue rather
than a loaded one.

---

## Exercise 4 — failed release, automatic rollback

*Spec: CD fails, dashboards, rollback executed automatically.*

**Method.** CD was run while Exercise 1's fault was active, so the post-deploy
monitoring gate measured a real unhealthy release.

| File | Shows |
|---|---|
| `ex4-stage-view.png` | Build #6: every stage green through Smoke test, **Monitoring gate failed** |
| `ex4-gate-failed.png` | The gate's four checks: targets `[OK]`, running build `[OK]`, error ratio `[FAIL] 0.0951 exceeds 0.02`, p95 `[FAIL] 7.337s exceeds 0.5s`, `GATE FAILED (2 check(s))`, and `Runbook: docs/runbooks/MonitoringGateFailed.md` |
| `ex4-rollback.png` | Build #7 post-actions: `REVS=3`, `helm rollback` for each release, `Rollback was a success!`, `rolled back frontend / worker / backend` |
| `ex4-helm-history.png` | `helm history frontend` — revision 4, **"Rollback to 2"** — independent proof from outside Jenkins |

**Check 2/4 is what stops the gate being decoration.** It asserts that the pods
being measured report `git_sha` equal to the commit just deployed, so the gate
cannot pass by measuring the previous release.

**A defect was found by performing this exercise.** Build #6 failed the gate
correctly and then reported *"no previous revision (first install) — nothing to
roll back"* for all three releases, while `helm history` showed three revisions.
The cause was `helm history -o json | grep -c '"revision"'`: helm prints the
whole array on one line and `grep -c` counts lines, so the count was always 1
and `helm rollback` was never reached — on any release, ever. The block was
itself an earlier audit fix whose comment argued it was correct, so review
could not find it; only running it against real data could. Fixed in `e130321`
and guarded by test **T18.55**, which runs the counting expression from
`Jenkinsfile-cd` against a three-revision fixture.

---

## Standing evidence (§4)

| File | Shows |
|---|---|
| `targets-all-up.png` | Prometheus `/targets` — every scrape pool green, application, Jenkins and platform |
| `alerts-firing.png` | `/alerts?state=firing` — `JenkinsQueueStuck` and `ReplicasMismatch` firing, both from `observability-platform-slo-and-alerts-*.yaml`, this project's own PrometheusRule |
| `alerts-resolved.png` | The same `JenkinsQueueStuck` thread: FIRING 12:49 → **Resolved 12:59** after the cause was removed |
| `inbox-alert-stream.png` | The full notification stream across the day |
| `ci-pipeline-stages.png` | CI stages end to end, and archived artifacts: `image-manifest.json`, three CycloneDX SBOMs, three Trivy reports |
| `sns-fix-long-subject-delivered.png` | `[FIRING] PrometheusTargetDown` — see below |

### Why that last file has an unusual name

AWS SNS rejects any `Subject` of 100 characters or more with
`400 Invalid parameter: Subject`. Alertmanager's **default** subject template is
unbounded — it joins every common label value — so alerts with short names were
delivered and alerts with long names were silently dropped.

The three alerts being dropped were `AlertmanagerFailedToSendAlerts`,
`AlertmanagerClusterFailedToSendAlerts` and `AlertmanagerNotificationsFailing`:
the ones whose entire purpose is to report that delivery is broken.

`PrometheusTargetDown` renders to 102 characters and could not be delivered
before the fix. This screenshot is it arriving, and is therefore proof the fix
works. The subject is now `[{{ .Status | toUpper }}] {{ .CommonLabels.alertname }}` —
worst case ~56 characters — and test **T18.54** fails the suite if it is removed
or becomes unbounded again.

Found by `AlertmanagerNotificationsFailing` firing. The monitoring located its
own blind spot.

---

## Coverage against the specification

| Requirement | Evidence |
|---|---|
| 5xx controlled, metric + dashboard + alert + runbook | `ex1-*` |
| Pod/readiness failure, k8s metrics, recovery, availability | `ex2-*`, `ex2-ex3-recovery` |
| Jenkins agent stopped, queue/agent metrics, no false positives | `ex3-*` |
| Failed release, CD fails, rollback executed | `ex4-*` |
| Targets UP | `targets-all-up` |
| Alerts firing and resolved | `alerts-firing`, `alerts-resolved` |
| Runbooks with evidence | `ex1-runbook`, and every alert email carries a working `runbook_url` |
| SBOM and vulnerability scanning | `ci-pipeline-stages` |
