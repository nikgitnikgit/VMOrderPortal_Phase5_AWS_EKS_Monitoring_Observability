# VM Order Portal — Phase 5 · start here

Everything is in this archive. Nothing has been deployed; this is source.

## What you need first

- AWS credentials with admin rights on a sandbox account
- `terraform >= 1.5`, `kubectl`, `helm 3.x`, `aws` CLI, `docker`
- An SES sender address you have verified
- Your current public IP: `curl -s https://checkip.amazonaws.com`

## Run it

```bash
cd VMOrderPortal_Phase5

cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars       # six values, all explained in README §3

export GITHUB_TOKEN=ghp_xxxxxxxx         # optional, for push-triggered CI

./scripts/deploy.sh                      # ~35 minutes
```

`deploy.sh` runs seven steps and prints two sets of credentials:

| Step | What |
|---|---|
| 1 | `terraform apply` — VPC, EKS (3 node groups), RDS, S3, SNS, ECR, IAM |
| 2 | `install-observability.sh` — CRDs, Prometheus, Grafana, Alertmanager. **Prints the Grafana URL and password. Save it; it is shown once.** |
| 3 | `install-jenkins.sh` — add-ons, RBAC, TLS, agent image, Jenkins |
| 4 | `create-jobs.sh` — the two pipelines, from code |
| 5 | `register-webhook.sh` — push-to-main triggers CI |
| 6 | `verify-jenkins.sh` — ~35 assertions |
| 7 | `verify-observability.sh` — ~35 more. **Prints the Jenkins URL and password.** |

Step 2 runs before step 3 deliberately: the application and Jenkins charts ship
`ServiceMonitor` objects, and a chart referencing a CRD that does not exist yet
fails outright.

## Then

```bash
# Grafana: https://<grafana-alb>   (restricted to your IP, admin / printed password)
# Jenkins: https://<jenkins-alb>   (restricted to your IP, admin / printed password)

# Prometheus and Alertmanager have NO Ingress, on purpose — neither has any
# authentication of its own:
./scripts/port-forward-monitoring.sh     # localhost:9090 and :9093
```

Open Jenkins, run `application-ci`. It builds, scans, pushes and hands off to
`application-cd`, which deploys, smoke-tests, and then **asks Prometheus
whether the release is actually healthy** before keeping it.

## Component versions

Nothing installs "latest". `helm/observability/CHART_VERSION` pins
kube-prometheus-stack, and a pinned chart resolves to the same Prometheus,
Grafana and Alertmanager images every time.

To also make those versions visible in the repo rather than buried in the
chart — worth doing once, before your first deploy:

```bash
./scripts/pin-observability-images.sh --check   # show what the pinned chart resolves to
./scripts/pin-observability-images.sh           # write them in explicitly
```

Same idea for base images: `./scripts/pin-base-images.sh`.

## Before you run anything

```bash
bash tests/run_all.sh        # 203 checks, all offline
```

It needs a few tools to run everything rather than skipping:

```bash
pip install --break-system-packages dockerfile dockerfile-parse python-hcl2 \
    crossplane pyyaml kubernetes-validate
apt-get install -y shellcheck
# plus: helm, kubeconform, hadolint, promtool  (see README §13)
```

A missing tool makes a check FAIL, never silently pass.

## Tear it down

```bash
./scripts/destroy.sh
```

Collect any evidence first — `destroy.sh` empties the S3 bucket.

## Where to read next

| | |
|---|---|
| `README.md` | the operator's manual. §14 is the whole observability chapter |
| `docs/PHASE5_PLAN.md` | why each decision was made, and what it cost |
| `docs/architecture-observability.png` | how a number gets from a pod to a dashboard |
| `docs/architecture-monitoring-flow.png` | commit → CI → digest → Pod → dashboard → alert |
| `docs/runbooks/` | one per alert: first three commands, usual cause, how to recover |

## Two things worth knowing before your first deploy

**Your IP.** Three ALBs and the EKS API are all restricted to it. When your ISP
rotates your address, `kubectl` fails with an **i/o timeout** — a drop, not a
refusal, so it looks like a hang. Re-run `curl -s https://checkip.amazonaws.com`,
update `api_public_access_cidrs` in tfvars, `terraform apply`, and re-run
`install-observability.sh` to refresh the Grafana allowlist.

**Cost.** Four EC2 nodes, three ALBs, an RDS instance and a NAT Gateway run
continuously. `destroy.sh` removes all of it; use it between sessions.

## One thing that changed after the build was finished

Everything above was written before two full adversarial audits were run over
the finished code. They found sixteen real defects, all fixed here — most of
them the kind that fail quietly:

- **Every CI build would have failed.** `prometheus_client` was added to the
  application in Phase 5 but never to the Jenkins agent image, which is what CI
  runs pytest against. Collection died before any test ran. If you built your
  own agent image from an earlier copy of this repository, rebuild it: the tag
  is now `tools-1.4`.
- **The Prometheus Operator was selected by the wrong label in a NetworkPolicy**,
  so it fell through default-deny with no API access and could never create the
  Prometheus StatefulSet. Nothing about that is visible in `kubectl get netpol`.
- **CD's failure path rolled back releases it had never touched**, including on
  a bad parameter, and reported "nothing to roll back" whenever a rollback
  actually failed.
- **`destroy.sh` could print "back to $0/hour" with everything still running**,
  because a failed AWS query counted as zero.

The full list, with the reasoning for each fix, is in the last three commit
messages (`git log`). If you are reading this to learn the codebase rather than
to deploy it, those three messages are the most useful thing in the repository:
they are a catalogue of ways a check can look stronger than it is.

`bash tests/run_all.sh` → **213 passed, 0 failed**.

## From a clean AWS account, there is nothing extra to do

`./scripts/deploy.sh` handles all of it. Two notes, only because they look like
prerequisites and are not:

**The Jenkins agent image builds itself.** The tag is now `tools-1.4`, which adds
`prometheus_client` — without it every CI build dies at test collection.
`install-jenkins.sh` checks ECR for that tag and builds it when it is absent,
which on a new account it always is. The tag only matters if you are reusing an
ECR repository that already holds `tools-1.3`: same repo, older image, and the
skip-if-present check would have kept it. Bumping the tag is what forces the
rebuild in that case.

**The empty nginx exporter digest does not block anything.**
`helm/frontend/values.yaml` ships `digest: ""` and the chart then renders
`nginx/nginx-prometheus-exporter:1.4.2` — a valid, pullable reference. Nothing in
`deploy.sh` or either pipeline calls `pin-base-images.sh --check`, so nothing
fails. Running `./scripts/pin-base-images.sh` upgrades that tag to a digest,
which is supply-chain hardening you can do whenever you like, or not at all. It
is left empty because resolving a digest needs Docker and a reachable registry,
and inventing one would be a lie.

## What has never been tested

All 213 tests are static or run against mocks. **Nothing in this repository has
ever run against a real EKS cluster.** The audits fixed several defects that
only appear in one — a NetworkPolicy selector that matched nothing, a Helm chart
that would not start — and the fixes are reasoned from the upstream chart's
behaviour, not observed. The chart repository was unreachable from where this
was built, so `kube-prometheus-stack 86.1.0` itself was never fetched.

`scripts/verify-observability.sh` is what turns that reasoning into evidence.
Run it after `install-observability.sh` and read every line; it is written to
fail loudly rather than to reassure. One known cosmetic issue it will not
catch: Grafana's `root_url` renders as `http:///` because the ALB hostname is
not known until after the Ingress exists. Grafana serves correctly at `/`; only
absolute links it generates are affected.
