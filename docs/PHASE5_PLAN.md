# Phase 5 — Monitoring & Observability: what has to be built, and how

> **STATUS: plan.** Nothing in this document is implemented yet. It is the
> analysis written before the work begins, in the same spirit as the gap
> analysis that preceded Phase 4. Every section states what the task sheet
> requires, what Phase 4 already gives us, the decision taken, and how we will
> know it actually works.

**Starting point:** `nikgitnikgit/VMOrderPortal_Phase4_AWS_EKS_With_Jenkins-CI-CD`
at `b6d1fd6`, working tree clean, `bash tests/run_all.sh` → 173 passed, 0 failed.

**Diagrams:**

- `docs/architecture-observability.png` — where the monitoring plane runs and
  how a number gets from a pod to a dashboard and from a rule to an inbox.
- `docs/architecture-monitoring-flow.png` — the proof chain the defence asks
  for: commit → CI build → image digest → Pod → dashboard/alert.

---

## 0. The one-sentence summary

Phase 4 built a system that can *deploy itself correctly*. Phase 5 makes it a
system that can *tell you whether the thing it deployed is actually working* —
and then wires that answer back into the pipeline, so a release that cannot
prove it is healthy does not stay deployed.

---

## 1. What the task sheet requires

Translated from `DevOps_on_AWS_Final_Project_Task_5.pdf`, section by section.

| § | Requirement | Non-negotiable detail |
|---|---|---|
| 1 | Deploy Prometheus + Grafana **inside the cluster**, from **Helm values kept in Git** | Configuration and provisioning must be reproducible from scratch — **no manual UI settings in Grafana** |
| 1 | Prometheus Operator + Prometheus instance | PVC, retention, requests/limits, an explicit selector strategy |
| 1 | Grafana with **automatic datasource + dashboard provisioning** | Dashboards come from Git, not from the UI import dialog |
| 1 | Alertmanager with a **real receiver** | Secrets stay outside the repository |
| 1 | kube-state-metrics + node-exporter, and kubelet/cAdvisor metrics | The Kubernetes layer, not just the app |
| 1 | ServiceMonitor **or** PodMonitor for every application service **and for Jenkins** | |
| 1 | Jenkins metrics via the Prometheus plugin or an exporter | A Service with a dedicated scrape target |
| 1 | Security: Grafana and Prometheus **not open to the internet**; authentication and HTTPS; RBAC + dedicated ServiceAccounts, **no cluster-admin**; NetworkPolicies restricting scrape; **no secrets or PII in metric labels**; retention documented; recovery from Pod/PVC loss | |
| 2 | Application metrics: request rate, 5xx rate, latency histogram + p95, availability, dependency failures, `app_build_info{version,git_sha,release}` | |
| 2 | Kubernetes metrics: node readiness, CPU/memory/disk, pod restarts, OOMKilled, throttling, pending pods, desired vs available replicas, PVC usage | |
| 2 | Jenkins metrics: controller/JVM, queue length + wait time, executors, dynamic agents, build status/rate/duration, CI/CD failures | |
| 2 | **Three dashboards**: Application Overview, Kubernetes/Cluster, Jenkins & Delivery | Each panel must answer an *operational question*, and dashboards must be tied to release |
| 2 | Instrumentation rules: `/metrics` **separate from readiness/liveness**, reachable only from an authorised scrape path; correct counter/gauge/histogram choice; **no unbounded-cardinality labels** (user ID, request ID, raw URL); **one business metric** for a meaningful action | |
| 2 | Minimal SLI/SLO: availability (e.g. 99% of a user journey in a window) and latency (e.g. 95% under a threshold), each with a PromQL expression, a panel and an alert | |
| 3 | **Six alerts**, minimum: HighErrorRate, HighLatencyP95, ReplicasMismatch, NodeNotReady/Pressure, JenkinsQueueStuck, PrometheusTargetDown | Every alert carries **severity, summary, description and a runbook reference** |
| 3 | **CI**: validate ServiceMonitor, PrometheusRule and Grafana dashboards. **CI must not deploy them.** | |
| 3 | **CD**: after rollout and smoke test, verify targets are UP and that error rate / latency are within bounds. A failing **post-deploy monitoring gate** means the release is not considered healthy → runbook / rollback | |
| 3 | Four failure drills with evidence: deliberate 5xx, pod readiness failure, stuck Jenkins agent, failed release rollout | |
| 3 | **Observability as Code** — anything created only by clicking in a UI does not count | |
| 4 | Repository additions: Helm values, ServiceMonitors/PodMonitors, PrometheusRules, three dashboard JSONs + provisioning, instrumentation code, SLI/SLO PromQL, runbooks, an evidence pack, updated diagrams and README | |
| 4 | Defence: show commit → CI build → image digest → Pod → dashboard/alert; trigger a failure and recover or roll back; explain ServiceMonitor, discovery, labels/cardinality, retention and the limits of what was built | |

**Entry condition stated in the doc:** Prometheus and Grafana must actually be
running in the cluster and the three dashboards must be live. Manually
configured dashboards, or secrets committed to Git, are not accepted.

---

## 2. What Phase 4 already gives us (and what that saves)

| Already in place | What Phase 5 gets for free |
|---|---|
| EKS 1.35, IRSA/OIDC provider, EBS CSI driver addon | Prometheus can have a real PVC; Alertmanager can publish to SNS with **no static credentials** |
| Two tainted node groups, `role=jenkins` pattern | The pattern for a third, tainted `role=monitoring` group is already proven |
| `k8s/namespace.yaml` with Pod Security Admission labels | The `observability` namespace slots in as a fourth declarative namespace |
| NetworkPolicy default-deny in `jenkins`, per-workload policies in `devops-app`, VPC CNI enforcement on | Restricting scrape traffic is an edit, not a new capability |
| Two ALBs, `create-cert.sh --purpose`, IP-restricted Jenkins ingress | A third, IP-restricted ALB for Grafana is a third `--purpose` |
| SNS topic with a working email subscription, used by both pipelines | Alertmanager reuses it — the delivery path is already proven |
| Strict CI/CD split with RBAC that enforces it | The new validation lands in CI, the new gate in CD, and the split still holds |
| Immutable ECR tags = git short SHA, digest verified in CD | `app_build_info{git_sha}` closes the loop with a value that is already authoritative |
| `tests/run_all.sh`, 173 checks, mutation-tested | The Phase 5 work has a gate on day one |

**What Phase 4 does *not* give us:** any metric of any kind. `metrics-server`
is installed, but that serves the HPA's resource API and is **not** Prometheus —
it stores nothing and cannot answer a question about last Tuesday. Nothing in
the repository currently emits, stores, displays or alerts on a metric.

---

## 3. Decisions taken

| # | Decision | Why, and what it costs |
|---|---|---|
| D1 | **A third, tainted node group `monitoring-nodes`** — 1 × `m7i-flex.large`, taint `role=monitoring:NoSchedule` | Prometheus wants 1–2 GiB; a `t3.small` app node has ~1.6 GiB allocatable and an 11-pod cap. Putting it on the Jenkins node means a BuildKit memory spike can evict the thing that would have told you about it. Cost: one more node. `m7i-flex.large` because post-2025-07-15 accounts are hard-restricted to a short list and `t3.medium` is not on it (same reasoning as the Jenkins node) |
| D2 | **New repository** `VMOrderPortal_Phase5_AWS_EKS_Observability`, seeded from `b6d1fd6` | Matches the per-phase naming; Phase 4 stays submittable exactly as reviewed |
| D3 | **Grafana behind its own IP-restricted HTTPS ALB; Prometheus and Alertmanager get no Ingress at all** | Grafana has authentication of its own, so an ALB + ACM cert + `inbound-cidrs` = operator IP mirrors the Jenkins UI decision. Prometheus and Alertmanager have **no authentication whatsoever** — see §3.1 for why exposing them is worse than it looks. They are reached with `kubectl port-forward`, authenticated by the Kubernetes API, and the operational view they would have provided is rebuilt as a **scrape-health row in Grafana** (W10) |
| D4 | **Alertmanager publishes to the existing SNS topic via `sns_configs` + sigv4 + IRSA** | The email subscription already works, the SDK picks IRSA credentials out of the default chain, and **no secret enters Git or the cluster**. Consistent with Phase 4's decision to delete SMTP rather than store a credential |
| D5 | **Grafana runs with `persistence.enabled: false`** | This is a feature, not a saving. With no database, a dashboard edited in the UI dies at the next pod restart — which *enforces* "Observability as Code" instead of merely asking for it, and gives us a one-command demo of it |
| D6 | **App `/metrics` on its own port `:9090`**, served from the gunicorn **master**, never the request port | The task sheet requires the metrics endpoint to be separate from the probes. Serving it from the master also solves the multi-worker problem (§5.1) |
| D7 | **ServiceMonitors and app PrometheusRules ship inside the app Helm charts**; platform-level monitors and rules ship in the observability chart | An alert about the backend belongs to the backend's chart and is deployed by the same CD run that deployed the backend. Platform rules are not tied to a release |
| D8 | **The observability stack is installed by a bootstrap script, not by Jenkins** | Same division of labour as Phase 4: Terraform = infrastructure, bootstrap = platform, Jenkins = application. CD *uses* Prometheus; it must not be able to reconfigure it |

**Still open — see §11.** How the Jenkins `/prometheus` endpoint is
authenticated is a real trade-off and I want a decision from you rather than a
default from me.

### 3.1 Why Prometheus gets no Ingress, specifically

"Not open to the internet" is easy to satisfy on paper and easy to get wrong in
practice. There is no login page to put behind an ALB, because Prometheus has
none. Four concrete consequences of exposing it, even IP-restricted:

- **It republishes what this repo deliberately scrubs.**
  `scripts/collect-ci-evidence.sh` strips the AWS account ID out of the evidence
  pack on purpose. An exposed Prometheus serves
  `kube_pod_container_info{image="<account-id>.dkr.ecr…"}` to anyone who asks,
  which makes the scrubber theatre.
- **Arbitrary PromQL is a one-request kill switch.** `{__name__=~".+"}[15d]`
  will OOM a 2 GB Prometheus. Whoever can reach it can turn the monitoring
  plane off from a browser.
- **`/-/reload` is reachable.** The operator has to enable the lifecycle API so
  its config-reloader sidecar can POST to it. Not destructive, but it is an
  unauthenticated state-changing endpoint.
- **A third IP allowlist.** `api_public_access_cidrs` and the Jenkins ALB
  already go stale when the operator's address rotates — the first of those
  fails as an `i/o timeout`, which is a drop and not a refusal, and is
  documented in the handoff notes precisely because it wasted an afternoon.
  A third one fails the same silent way.

Plus roughly $18/month for a load balancer that exists to serve one person.

What port-forward costs is the `/targets`, `/alerts` and `/rules` pages for
evidence. That gap is closed properly in W10 rather than by exposing the whole
server: a **scrape-health row** on the Kubernetes dashboard showing `up` by job
and namespace, scrape duration, TSDB head series, rule-evaluation failures and
firing-alert count. That is stronger evidence than a screenshot of `/targets`,
because it lives in Git, it is reviewable, and it is behind a login. Grafana's
**Explore** view covers ad-hoc PromQL, authenticated.

If it ever does need to be reachable without a terminal, the defensible route
is an `oauth2-proxy` or basic-auth sidecar in front of Prometheus and *then* an
ALB — real authentication, rather than IP allowlisting standing in for it.

### 3.2 Storage, sized from arithmetic rather than habit

An earlier draft of this plan said 20 Gi for Prometheus and 2 Gi for
Alertmanager. Both were conventions rather than calculations, and both were
wrong.

**Prometheus.** The formula is `retention × samples/sec × bytes/sample`.
Counting the series this cluster will actually produce:

| Source | Active series |
|---|---:|
| node-exporter, 5 nodes | ~4,000 |
| kubelet + cAdvisor, ~45 containers | ~4,500 |
| kube-state-metrics | ~6,000 |
| our three services, 6 pods | ~1,700 |
| Jenkins Prometheus plugin | ~2,000 |
| the monitoring stack scraping itself | ~4,000 |
| **total** | **~22,200** |

> Corrected after the first live deploy. The node-exporter row and the total
> were Phase 4's figures (one node fewer, ~800 series fewer): Phase 5 adds the monitoring
> node group, so the cluster is 3 app + 1 jenkins + 1 monitoring = **five**
> nodes. The arithmetic below moves by about 4% and the conclusion does not
> change, but a sizing table that quietly describes a different cluster is one
> nobody can check.

22,200 series ÷ 30 s = 740 samples/sec. Over 15 days that is 959 million
samples, and Prometheus compresses to roughly 1.5–2 bytes each — **1.4–1.9 GB
of chunk data**. Add index overhead from churn (every ephemeral CI agent pod
and every rolling deploy mints pod-name series that live in the index for the
whole window) and transient space for compaction, which writes the merged block
before deleting its sources. Realistic total: **3–5 GB**.

**10 Gi with `retentionSize: 7GB`** is therefore 2–3× headroom over the
computed size, and `retentionSize` trims from the old end rather than letting
the volume fill — which matters, because a full Prometheus disk is a genuinely
unpleasant recovery.

**The storage class is the more interesting correction.** gp2 delivers 3 IOPS
per GiB with a floor of 100, so a 10 Gi *and* a 20 Gi gp2 volume both get
exactly 100 baseline IOPS; size buys nothing until 34 GiB. gp3 delivers 3000
IOPS and 125 MB/s baseline at any size, and costs $0.08/GiB-month against gp2's
$0.10. Compaction is IO-heavy, so this is a real difference and a cheaper one.

**Alertmanager** stores exactly two things: the notification log (what it has
already told you about, so a restart does not re-page you) and silences. Both
are kilobytes; even a busy instance stays under 10 MB. The PVC is not there for
capacity — it is there so a silence set for a maintenance window survives a pod
restart. **1 Gi**, which is the EBS minimum and therefore the smallest thing
that can be asked for.

The gp3 StorageClass does not exist on an EKS cluster by default — `gp2` is
what EKS creates. Adding one is about ten lines of manifest and the EBS CSI
driver is already installed by Phase 4's addon, so nothing else changes. It is
applied by `install-observability.sh` (W4).

---

## 4. Target architecture

```
namespace: observability          (new, PSA privileged + audit/warn baseline — see §10.7)
  ├── prometheus-operator          reconciles ServiceMonitor / PodMonitor / PrometheusRule
  ├── prometheus                   PVC 10Gi gp3 · retention 15d / 7GB · scrape 30s
  ├── alertmanager                 PVC 1Gi gp3 · SA annotated for IRSA → sns:Publish
  ├── grafana                      NO PVC · datasource + 3 dashboards from ConfigMaps
  ├── kube-state-metrics           replicas, restarts, rollouts, PVC usage
  └── node-exporter (DaemonSet)    on EVERY node, tolerating EVERY taint

namespace: devops-app             (existing)
  ├── backend  :5000 app  + :9090 /metrics   + ServiceMonitor + PrometheusRule
  ├── worker   :5001 app  + :9090 /metrics   + ServiceMonitor + PrometheusRule
  └── frontend :8080 nginx + :9113 exporter  + ServiceMonitor + PrometheusRule

namespace: jenkins                (existing)
  └── jenkins-0 :8080/prometheus              + ServiceMonitor + PrometheusRule
```

**Scrape direction is always Prometheus → target.** Nothing pushes. Every
NetworkPolicy change below is therefore an *ingress* rule on the target and an
*egress* rule on Prometheus — never the reverse.

---

## 5. The work plan

Fifteen work items. Each is independently reviewable and each ends green on
`bash tests/run_all.sh`.

### W1 — Terraform: monitoring node group, Alertmanager IRSA role, outputs

**Files:** `terraform/modules/eks/{main,variables,outputs}.tf`,
`terraform/modules/irsa/{main,outputs}.tf`, `terraform/{main,outputs}.tf`,
`terraform/terraform.tfvars.example`

- Third managed node group `${cluster}-monitoring-nodes`, `m7i-flex.large`,
  desired/min 1, max 2, taint `role=monitoring:NO_SCHEDULE`, private subnets.
- New IRSA role `alertmanager` trusting
  `system:serviceaccount:observability:alertmanager` with a policy allowing
  exactly `sns:Publish` on the existing topic ARN — nothing else.
- Outputs: `alertmanager_role_arn`, `monitoring_node_group`, `observability_namespace`.

**Acceptance:** `terraform validate` and the T3 group pass; `tests/check_terraform.py`
and `check_tf_references.py` see the new wiring with no dangling references.

### W2 — The `observability` namespace, declaratively

**Files:** `k8s/namespace.yaml`

Add a third namespace with `kubernetes.io/metadata.name` (NetworkPolicies select
on it) and Pod Security Admission set the same way the `jenkins` namespace is —
`enforce: privileged`, `audit/warn: baseline` — with a comment that says exactly
why (§10.7: node-exporter needs hostPath and host namespaces; PSA has no
per-pod exemption).

### W3 — `helm/observability/` — the stack, as values in Git

**Files:** `helm/observability/{Chart.yaml,Chart.lock,values.yaml}`,
`helm/observability/templates/*`, `grafana/dashboards/*.json`

An umbrella chart with `kube-prometheus-stack` **86.1.0** (app v0.91.0) as a
pinned dependency, plus our own templates. `values.yaml` carries:

- `nodeSelector` + `tolerations` for `role=monitoring` on **operator,
  prometheus, alertmanager, grafana, kube-state-metrics** — and
  `tolerations: [{operator: Exists}]` on **node-exporter only**, so the
  DaemonSet lands on the app, Jenkins *and* monitoring nodes (§10.3).
- `prometheus.prometheusSpec`: `retention: 15d`, `retentionSize: 7GB`,
  `scrapeInterval: 30s`, `storageSpec` → 10Gi `gp3` (§3.2), explicit
  requests/limits, `enableAdminAPI: false`, and
  `serviceMonitorSelectorNilUsesHelmValues: false` (plus the pod-monitor,
  rule and probe equivalents) so objects in `devops-app` and `jenkins` are
  discovered at all.
- `kubeControllerManager/kubeScheduler/kubeEtcd/kubeProxy: enabled: false` and
  the matching `defaultRules` groups off — on EKS those control-plane
  components are not reachable and would sit DOWN forever, which would make
  both `PrometheusTargetDown` and our "all targets up" evidence dishonest (§10.2).
- `grafana`: `persistence.enabled: false`, `admin.existingSecret`, sidecar
  dashboard discovery on label `grafana_dashboard: "1"`, the Prometheus
  datasource provisioned by value, ALB Ingress with the Grafana ACM cert and
  `inbound-cidrs`.
- `alertmanager`: PVC 1Gi (§3.2), SA name pinned and annotated with the IRSA role,
  `config` with an `sns_configs` receiver (`sigv4.region`, `topic_arn`),
  grouping by `alertname`+`namespace`, an inhibition rule so a `critical`
  suppresses the matching `warning`.

Our own templates: three dashboard ConfigMaps built with `.Files.Get` from
`grafana/dashboards/*.json`, the platform PrometheusRules, and the
observability NetworkPolicies (W8).

**RBAC posture, because the sheet asks for it explicitly.** Every component
gets its own ServiceAccount from the chart, and **nothing is bound to
`cluster-admin`**. The operator and Prometheus do hold *cluster-scoped* roles —
Prometheus cannot discover endpoints across namespaces otherwise — but they are
read-only discovery roles (`get/list/watch` on nodes, services, endpoints,
pods, and `nonResourceURLs: /metrics`). Grafana, Alertmanager and
kube-state-metrics are namespace-scoped. A T18 test asserts no
ClusterRoleBinding created by this chart names `cluster-admin`, and that
Prometheus holds no `create`, `update`, `patch` or `delete` verb anywhere.

### W4 — `scripts/install-observability.sh` + `deploy.sh` step

**Files:** `scripts/install-observability.sh`,
`scripts/port-forward-monitoring.sh`, `k8s/storageclass-gp3.yaml`,
`scripts/deploy.sh`, `scripts/destroy.sh`, `scripts/uninstall-jenkins.sh`

Reads everything from `terraform output` exactly like `install-jenkins.sh`.
Order: apply CRDs **server-side** for the pinned chart version → apply the
namespace and the gp3 StorageClass → create the Grafana admin Secret from a
generated password (printed once, never committed) → `helm dependency build`
→ `helm upgrade --install` → wait for rollout → print the Grafana URL. Slots
into `deploy.sh` as a new step **before** Jenkins, because the ServiceMonitor
CRD must exist before any chart that ships one is installed.

`port-forward-monitoring.sh` opens Prometheus on 9090 and Alertmanager on 9093
in one command, so the "no Ingress" decision costs one line rather than two
remembered incantations.

> CRDs are the trap here. Helm does not upgrade CRDs it installed, and the
> kube-prometheus-stack CRDs are too large for a client-side apply (the
> `last-applied-configuration` annotation exceeds 262144 bytes). Both facts
> mean `kubectl apply --server-side --force-conflicts` on the pinned CRD
> bundle, as an explicit step, every time (§10.1).

### W5 — Application instrumentation

**Files:** `app/common/metrics.py` (new, copied into both images),
`app/backend/{app.py,gunicorn.conf.py,requirements.in,requirements.txt}`,
`app/worker/{worker.py,gunicorn.conf.py,requirements.in,requirements.txt}`,
`docker/{backend,worker}/Dockerfile`, `app/*/test_*.py`

`prometheus_client` in **multiprocess mode**: gunicorn runs 2 workers × 4
threads, so a naive in-process registry would give a different answer on every
scrape depending on which worker answered. Concretely:

- `PROMETHEUS_MULTIPROC_DIR=/tmp/prom` — the `/tmp` emptyDir already exists
  because the root filesystem is read-only.
- `on_starting` **wipes** that directory before anything registers (an emptyDir
  survives a container restart inside the same pod, so stale files from the
  crashed process would otherwise be merged in forever).
- `child_exit` calls `multiprocess.mark_process_dead(worker.pid)`.
- `when_ready` (master only) starts the metrics HTTP server on `:9090` over a
  registry with a `MultiProcessCollector`. One listener per pod, on its own
  port, never the port the probes use.

Metrics — deliberately small, and every label bounded:

| Metric | Type | Labels | Answers |
|---|---|---|---|
| `http_requests_total` | Counter | `method`, `route`, `status` | request rate, 5xx rate, availability |
| `http_request_duration_seconds` | Histogram | `method`, `route` | p50/p95/p99, latency SLO |
| `http_requests_in_flight` | Gauge (`livesum`) | — | saturation |
| `dependency_failures_total` | Counter | `dependency` ∈ {rds, s3, worker, sns, ses} | which hop broke |
| `app_build_info` | Gauge = 1 | `version`, `git_sha`, `release` | which commit is serving |
| `vm_orders_total` | Counter | `state` ∈ {received, stored, notified} | **the business metric** |
| `notifications_total` (worker) | Counter | `channel`, `result` | did the customer get the mail |

`route` is `request.url_rule.rule`, never `request.path`, and an unmatched
request is labelled `"unmatched"` — otherwise every 404 scan mints a new time
series. No ticket ID, no email, no idempotency key ever becomes a label.

> `prometheus_client.Info` **does not work in multiprocess mode**. `app_build_info`
> is therefore a Gauge fixed at 1 with the labels on it, which is the
> conventional `_info` pattern anyway and is what the dashboards join against.

`GIT_SHA`, `APP_VERSION` and `RELEASE` arrive as environment variables from the
chart, which CD sets from the tag and commit it is already deploying — that is
the link that makes the proof chain in `architecture-monitoring-flow.png` real
rather than asserted.

### W6 — Frontend edge metrics

**Files:** `docker/frontend/nginx.conf`, `helm/frontend/templates/deployment.yaml`,
`helm/frontend/{values.yaml,templates/service.yaml}`

`stub_status` on `127.0.0.1:8081` (loopback only) plus an
`nginx-prometheus-exporter` sidecar on `:9113`, pinned by digest like every
other image. This is what gives an availability number measured at the edge —
where the user actually is — rather than only inside the backend.

### W7 — ServiceMonitors, PodMonitors and the Jenkins scrape target

**Files:** `helm/{backend,worker,frontend}/templates/servicemonitor.yaml` and
`values.yaml`, `helm/observability/templates/servicemonitor-jenkins.yaml`,
`jenkins/values.yaml`

- A named `metrics` port on each Service, and a ServiceMonitor selecting it.
  All gated behind `monitoring.enabled` with a comment explaining that a
  cluster without the operator installs the chart perfectly well with it off —
  a chart that hard-fails on a missing CRD is a chart that cannot be tested.
- Jenkins: add the `prometheus` plugin. Its four required dependencies
  (`metrics`, `junit`, `pipeline-rest-api`, `commons-lang3-api`) are **already
  in the pinned set**, so this is close to a one-line change — but
  `installLatestPlugins: false` means the pin must still be regenerated from a
  running controller and validated by a restart before committing (README §10.9).
- JCasC `unclassified.prometheusConfiguration` for path, namespace and
  collection period. **Do not set `collectNodeStatus`** — JCasC cannot handle
  that attribute (jenkinsci/prometheus-plugin#525) and the controller will
  refuse to start.

### W8 — NetworkPolicies for scrape

**Files:** `helm/{backend,worker,frontend}/templates/networkpolicy.yaml`,
`jenkins/networkpolicy.yaml`, `helm/observability/templates/networkpolicy.yaml`

- App workloads: ingress on the metrics port only, only from
  `namespaceSelector: kubernetes.io/metadata.name=observability`. The existing
  app-port rules are untouched — the backend still accepts 5000 only from the
  frontend.
- `jenkins`: controller ingress on 8080 from the observability namespace;
  **agents egress to the observability namespace on 9090**, which is what makes
  the CD monitoring gate able to ask a question at all.
- `observability`: default-deny, then egress to DNS, to the scrape targets, and
  to 443 for SNS; ingress to Grafana on 3000 from the VPC (the ALB).

> The ALB has **two** security groups and rules live on the managed one;
> `inbound-cidrs` is IPv4-only and mixing it with IPv6 makes the controller
> reject the whole Ingress. Both are Phase 4 scars and both apply again here.

### W9 — Recording rules, SLI/SLO, and the six alerts

**Files:** `helm/*/templates/prometheusrule.yaml`,
`helm/observability/templates/prometheusrule-platform.yaml`,
`docs/SLO.md`

**SLI/SLO (minimal, as the doc asks):**

| SLI | SLO | PromQL |
|---|---|---|
| Availability | 99% of `/api/*` requests succeed over 30 min | `1 - (sum(rate(http_requests_total{status=~"5.."}[30m])) / sum(rate(http_requests_total[30m])))` |
| Latency | 95% of requests under 500 ms | `histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))` |

Both get a recording rule (so the dashboard, the alert and the CD gate all
evaluate the *same* expression rather than three drifting copies), a Grafana
panel, and an alert.

**The six alerts**, each with `severity`, `summary`, `description` and
`runbook_url`:

| Alert | Fires when | Severity |
|---|---|---|
| `HighErrorRate` | 5xx ratio > 2% for 5 min | critical |
| `HighLatencyP95` | p95 > 500 ms for 10 min | warning |
| `ReplicasMismatch` | `kube_deployment_status_replicas_available < ...spec_replicas` for 10 min | warning |
| `NodeNotReadyOrPressure` | node not Ready, or memory/disk pressure, for 5 min | critical |
| `JenkinsQueueStuck` | queue length > 0 with no executor progress for 15 min | warning |
| `PrometheusTargetDown` | any target in our namespaces `up == 0` for 5 min | critical |

`runbook_url` points at `docs/runbooks/<alert>.md`, and a test asserts that the
file each alert names actually exists — a dead runbook link is worse than none.

### W10 — Three dashboards, as JSON in Git

**Files:** `grafana/dashboards/{application-overview,kubernetes-cluster,jenkins-delivery}.json`,
`docs/DASHBOARDS.md`

Every panel exists to answer a stated operational question; the doc is explicit
that a pile of panels with no tie to release or recovery is not sufficient.

- **Application Overview** — traffic, error ratio, p50/p95/p99, availability vs
  SLO, dependency failures by hop, `vm_orders_total` by state, and a **release
  annotation driven by `app_build_info`** so a latency step change lines up
  visibly with the commit that caused it. Templated by service, pod and release.
- **Kubernetes / Cluster** — node readiness and capacity, pod restarts and
  OOMKilled, CPU throttling, pending pods, desired vs available replicas,
  PVC usage (including Prometheus's own), plus a **scrape-health row**:
  `up` by job and namespace as a table, scrape duration, TSDB head series,
  rule-evaluation failures, and the count of firing alerts by severity.
  This row is what replaces the `/targets`, `/rules` and `/alerts` pages that
  D3 deliberately does not expose — and it is better evidence than a screenshot
  of them, because it is in Git, reviewable, and behind a login.
- **Jenkins & Delivery** — queue length and wait time, executors, dynamic agent
  count, build result rate and duration, CI/CD failure trend, and time since the
  last successful release.

Datasource UID is fixed in the provisioning values and referenced by that UID in
every panel, so a dashboard never lands with a null datasource.

### W11 — CI: validate the observability objects (and never deploy them)

**Files:** `Jenkinsfile-ci`, `jenkins/agent-tools/Dockerfile`,
`scripts/install-jenkins.sh`, `tests/check_dashboards.py`

New checks in the existing `Validate` stage:

1. `promtool check rules` on the `spec` of every rendered PrometheusRule.
2. `kubeconform` against **vendored** CRD schemas in `tests/crd-schemas/` so
   validation is hermetic and works offline.
3. Dashboard JSON: parses, has a `uid` and `title`, every panel names the
   provisioned datasource UID, and **every `targets[].expr` parses as PromQL**
   (`promtool promql format`, with `$__rate_interval` and template variables
   substituted first).
4. A metric-contract check: every metric name referenced by a dashboard or a
   rule is either defined in the application code or produced by a known
   exporter. This is the check that catches the panel which is silently empty
   forever because of a typo.

`promtool` and `kubeconform` go into the agent image — which means
**bumping `LABEL tools.version` and the tag everywhere it is named**.

> **Amended after the build.** Two changes to what this paragraph planned.
> `yq` was dropped: there are two unrelated programs by that name with
> incompatible syntax, so `validate-observability.sh` uses `python3` instead
> rather than betting on which one a machine has. And the tag is now
> **`tools-1.4`**, not 1.3 — the audit found that `prometheus_client` was never
> added to this image even though Phase 5 made the application import it, so
> every CI build would have died at test collection. The tag appears in four
> places, not the two this paragraph assumed; `T18.20` now fails on any stale
> one anywhere in the tree. Editing that Dockerfile without bumping
the tag is a silent no-op; `T17.11` exists because it already happened once.

CI still gets no deploy permission, and a negative RBAC assertion is added:
`jenkins-agent-ci` must not be able to create a ServiceMonitor.

### W12 — CD: the post-deploy monitoring gate

**Files:** `Jenkinsfile-cd`, `jenkins/rbac.yaml`

A new stage after `Smoke test`, before `Record deployment`. It queries
Prometheus over the cluster Service and asserts four things over a 3-minute
window:

1. Every application target is `up == 1` and the count matches what we deployed.
2. `app_build_info{git_sha="<the commit CD was given>"} == 1` — **the deployed
   pods are reporting the commit this build promoted**. This is the proof chain,
   enforced.
3. The 5xx ratio is under the SLO burn threshold.
4. p95 latency is under the SLO.

Failure calls `error()`, which hands over to the existing `post { failure }`
block: diagnostics, then `helm rollback`, then the SNS notification.

> Three ways this gate could quietly become decorative, all of which this
> project has been bitten by before, and all of which get an explicit branch:
> a query that returns **no data** must **fail** (no data is not proof of
> health); Prometheus answers HTTP 200 with `"status":"error"` in the body, so
> the check parses `.status` rather than trusting `curl -f`; and a retry loop
> that exhausts its budget must exit non-zero rather than simply ending.
> Each of these gets a mutation test.

RBAC: `jenkins-deployer` gains `monitoring.coreos.com` → `servicemonitors` in
`devops-app` only. Nothing in the `observability` namespace — CD may *read*
Prometheus and may not *reconfigure* it.

> **Amended after the build.** As first written this granted `podmonitors` and
> `prometheusrules` too, and the audit found that contradicts the sentence
> immediately after it. Prometheus discovers rules across namespaces, so write
> access to `prometheusrules` in `devops-app` is write access to the alerts that
> gate the deploy — which is exactly the "CD may not reconfigure it" this
> paragraph promises. Neither resource is rendered by any application chart, so
> nothing needed them. `T18.37` now derives the grant from what the charts
> actually render, so the justification cannot drift away from the permission
> again.

### W13 — Runbooks and the four failure drills

**Files:** `docs/runbooks/*.md`, `evidence/*`

One runbook per alert: what it means, the first three commands to run, the
usual cause, how to recover, and how to confirm recovery.

The drills use **real** failures — no fault-injection endpoint is ever shipped
in the application:

| Drill | How | What it proves |
|---|---|---|
| Deliberate 5xx | `kubectl set env deployment/backend DB_HOST=broken.invalid` and drive traffic | error-rate panel rises, `HighErrorRate` fires, SNS mail arrives, runbook restores it |
| Pod readiness failure | break the worker's readiness probe target | `ReplicasMismatch` fires; recovery time is visible on the Kubernetes dashboard |
| Stuck Jenkins agent | temporarily taint the Jenkins node so agent pods cannot schedule | queue length and wait time climb, `JenkinsQueueStuck` fires |
| Failed release rollout | promote a commit that cannot pass the gate | CD monitoring gate fails → automatic `helm rollback` → dashboards show the dip and the recovery |

A fifth drill covers the storage-recovery requirement in §1 of the sheet, and
it is the one that proves D5 was worth it:

| Drill | How | What it proves |
|---|---|---|
| Pod and PVC loss | `kubectl delete pod` on Prometheus, then on Grafana; then delete and recreate the Grafana pod after editing a dashboard in the UI | Prometheus history survives a pod restart because it is on a PVC; Grafana's dashboards come back **from Git** because it has no PVC — and the UI edit is gone, which is exactly what "Observability as Code" is supposed to mean. Deleting the Prometheus **PVC** loses history: documented, measured, and stated as a limit rather than hidden |

### W14 — Test suite: group T18

**Files:** `tests/run_all.sh`, `tests/check_dashboards.py`,
`tests/check_alert_rules.py`, `tests/check_metrics_contract.py`,
`tests/check_observability_values.py`, `tests/mocks/{promtool,kubeconform,yq}`,
`tests/run_mock_deploy.sh`

Roughly 40 new assertions, continuing the existing conventions: unique IDs,
heavier logic in `check_*.py`, and **every new test mutation-tested** — write
it, break the thing it guards, watch it fail, then fix the thing.

The ones worth naming, because they guard something that would otherwise fail
silently:

- node-exporter tolerates every taint (otherwise it silently skips the Jenkins
  and monitoring nodes and nobody notices).
- `serviceMonitorSelectorNilUsesHelmValues: false` is set (otherwise nothing
  outside the observability namespace is ever scraped).
- The EKS control-plane scrape targets are disabled (otherwise permanently DOWN
  targets make the alert and the evidence dishonest).
- Every alert has severity, summary, description and a `runbook_url` **whose
  file exists**.
- No metric label in the code is derived from a ticket ID, email, or raw path.
- The metrics port is not the probe port, in every chart.
- The CD gate fails on empty query results (mutation: return an empty vector).
- `tools.version` was bumped when the agent Dockerfile changed.
- `retentionSize` is strictly below the PVC size, and the PVC's storageClass is
  one the chart actually creates (a typo'd class leaves the PVC Pending forever
  and Prometheus never starts).
- Neither Prometheus nor Alertmanager declares an Ingress anywhere in the
  rendered chart, and `enableAdminAPI` is false. This is the test that keeps D3
  from being quietly undone by a future values edit.
- The scrape-health row's panels reference metrics that exist — otherwise the
  view that replaces `/targets` is itself empty and nobody notices.

### W15 — Documentation and diagrams

**Files:** `README.md`, `docs/architecture-deployment.mmd` (+ renders),
`docs/architecture-observability.*`, `docs/architecture-monitoring-flow.*`,
`evidence/README.md`

README gains an observability section — architecture, how to reach Grafana,
what each dashboard answers, the alert catalogue, retention and recovery, and
troubleshooting. §10.9 (recurring maintenance) gains the chart version, the
dashboard JSONs and the Jenkins plugin pin. The deployment diagram gets the
monitoring node group and the stale `app-secrets` box corrected.

**Re-render every diagram after every edit and look at the PNG.** A Mermaid
source can read perfectly while the render has swallowed half the nodes into a
subgraph; that has happened in this repo before.

---

## 6. Order of work

| Stage | Items | Why this order |
|---|---|---|
| 1 | W1, W2 | Infrastructure and namespace first — nothing else can land without the node group |
| 2 | W3, W4 | Get a real Prometheus and Grafana running before writing anything that depends on them |
| 3 | W5, W6, W7 | Emit metrics, then discover them. Confirm targets are UP in the Prometheus UI before moving on |
| 4 | W8 | Tighten the network **after** scraping demonstrably works, so a broken policy is unambiguous |
| 5 | W9, W10 | Rules and dashboards, on data that already exists |
| 6 | W11, W12 | Wire it into the pipelines |
| 7 | W13 | Drills and evidence — this is the part that cannot be rushed on the last day |
| 8 | W14, W15 | Tests and docs alongside throughout, closed out here |

Rough effort at the pace of Phase 4: 16–22 hours, against the sheet's 12–16.
The overrun is W13 — four real failure drills with real evidence take longer
than they look, and every drill is a live cluster in an unhealthy state.

---

## 7. How we work (unchanged from Phase 4)

I clone, work in my sandbox, and hand over a **patch** verified against a
pristine clone of current `HEAD` with the test suite green. You `git apply`,
run the tests, commit and push. I re-fetch and confirm the hash. I never push.

Destructive recovery commands always go in their own block, never adjacent to
something you might paste together with them.

---

## 8. Cost

One extra `m7i-flex.large` running continuously, a 10 GiB and a 1 GiB gp3
volume (about $0.90/month between them), and one more ALB — for Grafana only,
since Prometheus deliberately gets none, which is roughly $18/month saved.
Everything else is software. The
cluster remains destroyable with `scripts/destroy.sh`, and `install-observability.sh`
is idempotent, so tearing down between work sessions stays cheap.

---

## 9. Known limits, stated up front

The defence asks what the system does **not** do, so here it is:

- **No tracing and no log aggregation.** Metrics tell you *that* p95 rose;
  they cannot tell you *which* request was slow. That is a Loki/Tempo
  conversation, and pretending otherwise would be the same "weaker check
  dressed as a stronger one" mistake this project has a rule against.
- **Prometheus is a single replica with local storage.** Losing the node loses
  in-flight scrapes; losing the PVC loses history. Sized and documented, not
  solved. Thanos/AMP is out of scope.
- **15 days of retention.** Enough for "did this release regress?", not enough
  for quarterly capacity planning.
- **The alerts are threshold alerts, not full multi-window burn-rate alerts.**
  Deliberate: the task asks for a minimal SLI/SLO, and a burn-rate ladder with
  no traffic behind it is decoration.
- **Grafana has one local admin.** No SSO, no per-team folders.
- **The monitoring plane monitors itself only weakly.** If Prometheus dies,
  `PrometheusTargetDown` cannot fire, because the thing that evaluates it is
  the thing that died. The honest mitigations are the SNS heartbeat
  (`Watchdog`) and the fact that Grafana going blank is loud.

---

## 10. Landmines found while researching this phase

Each of these costs a rebuild, a broken pipeline, or a false green if it is
discovered the hard way. Same table format as `PHASE5_HANDOFF_NOTES.md` §4–5,
because these belong there next.

| # | Trap | What happens |
|---|---|---|
| 10.1 | **Helm does not upgrade CRDs** | kube-prometheus-stack CRDs are installed on first install and never touched again. Worse, they are too large for a client-side `kubectl apply` (the annotation exceeds 262144 bytes). Chart upgrades then fail with schema errors that look like values errors. Always `kubectl apply --server-side --force-conflicts` on the pinned CRD bundle as its own step |
| 10.2 | **EKS control-plane scrape targets do not exist** | `kubeControllerManager`, `kubeScheduler`, `kubeEtcd` are AWS-managed and unreachable; `kubeProxy` binds its metrics to 127.0.0.1. Left enabled, four targets sit DOWN forever, `PrometheusTargetDown` becomes background noise, and "all targets up" stops being provable |
| 10.3 | **node-exporter and custom taints** | The DaemonSet's default tolerations do not include `role=jenkins` or `role=monitoring`. It comes up healthy, reports no error, and simply has no data for two of the five nodes. Set `tolerations: [{operator: Exists}]` and assert pod count == node count |
| 10.4 | **`prometheus_client` under gunicorn** | Two workers means two registries. Without `PROMETHEUS_MULTIPROC_DIR` every scrape returns whichever worker answered, so counters appear to go backwards. And `Info` metrics are not supported in that mode at all — `app_build_info` must be a Gauge |
| 10.5 | **A stale multiprocess directory** | The `/tmp` emptyDir survives a container restart within the same pod, so dead workers' `.db` files keep being merged. Wipe the directory in `on_starting` and `mark_process_dead` in `child_exit` |
| 10.6 | **Jenkins plugin pinning** | `installLatestPlugins: false` means adding `prometheus` without regenerating the resolved set can leave a dependency unsatisfied and the controller will not start. Its four required deps happen to be pinned already — verify, do not assume |
| 10.7 | **Pod Security Admission vs node-exporter** | node-exporter needs hostPath and host namespaces. A `restricted` (or even `baseline`) `observability` namespace rejects it at admission with a 403 and no metrics from any node. PSA is namespace-wide with no per-pod exemption — same shape as the BuildKit/`jenkins` decision, and it gets the same honest comment |
| 10.8 | **JCasC and `collectNodeStatus`** | The Configuration as Code plugin cannot set that attribute of the Prometheus plugin (upstream issue #525). Setting it means the controller refuses to start with a configurator exception |
| 10.9 | **Prometheus returns 200 on a failed query** | `{"status":"error"}` inside an HTTP 200 body. `curl -f` sees success. Parse `.status`, then parse `.data.result`, and treat an empty result as a failure |
| 10.10 | **`metrics-server` is not Prometheus** | It is still needed — the HPA reads its API and nothing else provides it. Removing it because "we have Prometheus now" breaks autoscaling silently |
| 10.11 | **Grafana dashboards in ConfigMaps** | A ConfigMap caps at ~1 MiB; a generated dashboard JSON gets there faster than expected. If one grows too large it must be split or trimmed, not compressed into unreadability |
| 10.12 | **`retentionSize` vs PVC size** | Set retentionSize below the volume size (7GB on 10Gi). Equal or above and Prometheus fills the disk and wedges, which is a genuinely unpleasant recovery |
| 10.13 | **gp2's IOPS floor makes a bigger volume pointless** | gp2 is 3 IOPS/GiB with a 100 IOPS minimum, so every volume under 34 GiB gets exactly 100 baseline IOPS. Over-provisioning a gp2 volume to "make Prometheus faster" buys nothing at all. gp3 gives 3000 IOPS at any size, for less money — but the StorageClass does not exist on EKS by default and has to be created |
| 10.14 | **An exposed Prometheus undoes the evidence scrubber** | `collect-ci-evidence.sh` strips the AWS account ID by design; `kube_pod_container_info` carries it in the ECR image label. Any decision to expose Prometheus has to account for that, not just for "is there a login" |

---

## 11. Open decision — the Jenkins metrics endpoint

The Prometheus plugin's endpoint can be **unauthenticated** (the default,
registered as an unprotected root action) or **authenticated** with a Jenkins
API token supplied by the scraper.

- **Unauthenticated** is simple and the endpoint is already unreachable from
  outside the cluster except through the Jenkins ALB, which is restricted to
  your IP, and from inside the cluster except from the observability namespace
  once W8 lands. But `https://<jenkins-alb>/prometheus/` would be readable from
  your IP with no login, and it exposes job names and build outcomes.
- **Authenticated** is stronger and matches the task sheet's "reachable only
  from an authorised scrape path" language. It costs: a dedicated Jenkins user
  and API token created by JCasC, that token stored as a Kubernetes Secret by
  `configure-jenkins.sh`, and the ServiceMonitor referencing it via
  `authorization.credentials`. More moving parts, and one more secret to keep
  out of Git and out of chat.

**My recommendation: authenticated**, because the endpoint is the one piece of
this stack that is reachable from the internet at all, and because "a weaker
check must never be allowed to look like a stronger one" is this project's own
rule. But it is your call and it is genuinely a trade-off, so I have not
assumed it.
