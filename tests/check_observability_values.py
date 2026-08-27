"""The values that decide whether the monitoring plane works at all.

Every check here guards a setting whose WRONG value produces no error message.
That is the selection criterion: if getting it wrong would break loudly, it
does not need a test. These all fail silently.
"""
import os
import re
import sys

import yaml

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

VALUES = "helm/observability/kube-prometheus-stack.values.yaml"
v = yaml.safe_load(open(VALUES))
problems = []


def get(path, default=None):
    cur = v
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return default
        cur = cur[part]
    return cur


# 1. node-exporter must tolerate EVERY taint.
#    Wrong value: it runs happily on the untainted nodes and silently has no
#    data for the jenkins and monitoring nodes. No error, no warning.
tol = get("prometheus-node-exporter.tolerations") or []
if not any(t.get("operator") == "Exists" and "key" not in t for t in tol):
    problems.append(
        "prometheus-node-exporter.tolerations must include {operator: Exists} with no key — "
        "otherwise it silently skips the tainted nodes and reports no error")

# 2. The selectors that make Prometheus look outside its own release.
#    Wrong value: every ServiceMonitor is created, valid, and never read.
for key in ("serviceMonitorSelectorNilUsesHelmValues",
            "podMonitorSelectorNilUsesHelmValues",
            "ruleSelectorNilUsesHelmValues"):
    if get(f"prometheus.prometheusSpec.{key}") is not False:
        problems.append(
            f"prometheus.prometheusSpec.{key} must be false — "
            "true means Prometheus ignores every monitor not tagged with its own release")

# 3. The EKS control-plane targets that do not exist.
#    Wrong value: four targets DOWN forever, PrometheusTargetDown becomes
#    noise, and "all targets up" stops being provable.
for comp in ("kubeControllerManager", "kubeScheduler", "kubeEtcd", "kubeProxy"):
    if get(f"{comp}.enabled") is not False:
        problems.append(
            f"{comp}.enabled must be false — it is not reachable on EKS and would sit DOWN forever")

# 4. retentionSize strictly below the volume size.
#    Wrong value: Prometheus fills the disk and wedges.
rs = str(get("prometheus.prometheusSpec.retentionSize", ""))
vol = str(get("prometheus.prometheusSpec.storageSpec.volumeClaimTemplate."
              "spec.resources.requests.storage", ""))
rs_n = int("".join(c for c in rs if c.isdigit()) or 0)
vol_n = int("".join(c for c in vol if c.isdigit()) or 0)
if not (0 < rs_n < vol_n):
    problems.append(f"retentionSize ({rs}) must be strictly below the volume size ({vol})")

# 5. Neither Prometheus nor Alertmanager may grow an Ingress.
#    This is the exposure decision; a values edit must not undo it quietly.
for comp in ("prometheus", "alertmanager"):
    if get(f"{comp}.ingress.enabled") is not False:
        problems.append(
            f"{comp}.ingress.enabled must be false — it has NO authentication of any kind")

# 6. Admin API off. It deletes series with no auth in front of it.
if get("prometheus.prometheusSpec.enableAdminAPI") is not False:
    problems.append("prometheus.prometheusSpec.enableAdminAPI must be false")

# 7. Grafana must have a login and must not persist.
if get("grafana.persistence.enabled") is not False:
    problems.append(
        "grafana.persistence.enabled must be false — a UI edit must not survive a restart, "
        "which is what makes 'dashboards come from Git' true rather than aspirational")
if get("grafana.grafana\\.ini") is None and "grafana.ini" in (v.get("grafana") or {}):
    ini = v["grafana"]["grafana.ini"]
    if (ini.get("auth.anonymous") or {}).get("enabled") is not False:
        problems.append("grafana.ini auth.anonymous.enabled must be false")
    if (ini.get("users") or {}).get("allow_sign_up") is not False:
        problems.append("grafana.ini users.allow_sign_up must be false")

# 8. Grafana's Ingress must restrict inbound CIDRs.
ann = get("grafana.ingress.annotations") or {}
if not any("inbound-cidrs" in k for k in ann):
    problems.append("grafana.ingress must set alb.ingress.kubernetes.io/inbound-cidrs")
if ann.get("alb.ingress.kubernetes.io/pathType") is None and get("grafana.ingress.pathType") != "Prefix":
    problems.append(
        "grafana.ingress.pathType must be Prefix — ImplementationSpecific makes the ALB treat "
        "'/' as an EXACT match and every asset returns 404 before reaching Grafana")

# 9. Helm must not own the CRDs.
if get("crds.enabled") is not False:
    problems.append(
        "crds.enabled must be false — Helm installs CRDs once and never upgrades them, "
        "and these are too large for a client-side apply")

# 10. Every placeholder must still be a placeholder in the committed file.
#     If a real ARN or IP is here, a secret or an address has been committed.
raw = open(VALUES).read()
for m in re.finditer(r'arn:aws:[a-z0-9:-]+', raw):
    problems.append(f"a real ARN is committed in {VALUES}: {m.group(0)}")
if re.search(r'inbound-cidrs:\s*["\']?\d+\.\d+\.\d+\.\d+', raw):
    problems.append(f"a real IP address is committed in {VALUES}")

# 11. Exactly ONE default Grafana datasource may exist.
#
#     Added after an audit found two. kube-prometheus-stack generates its own
#     "Prometheus" datasource whenever grafana.sidecar.datasources.enabled is
#     true, and this file provisions one as well. Grafana validates provisioning
#     at startup and refuses to run with two defaults -- a CrashLoopBackOff whose
#     message blames "datasource.yaml" and never mentions the chart.
if get("grafana.sidecar.datasources.enabled") is not False:
    problems.append(
        "grafana.sidecar.datasources.enabled must be false — the chart then generates a SECOND "
        "datasource named Prometheus with isDefault: true, and Grafana refuses to start with "
        "two defaults ('Only one datasource per organization can be marked as default')")

ds = (get("grafana.datasources") or {}).get("datasources.yaml", {}).get("datasources") or []
defaults = [d for d in ds if d.get("isDefault")]
if len(defaults) != 1:
    problems.append(
        f"exactly one provisioned datasource must be isDefault, found {len(defaults)}")
if defaults and defaults[0].get("uid") != "prometheus":
    problems.append(
        "the default datasource uid must be 'prometheus' — every panel in dashboards/*.json "
        "references it by that uid and would render 'Datasource not found'")

# 12. The Alertmanager config must contain no Go template delimiters.
#
#     This file is a Helm VALUES file and the chart may render
#     alertmanager.config through `tpl`. Alertmanager's own templates use the
#     same {{ }} delimiters, so Helm evaluates them, finds no template of that
#     name, and aborts the install. Alertmanager's defaults are identical to
#     what those lines were setting, so the rule is simply: none here.
am_raw = yaml.safe_dump(get("alertmanager.config") or {})
if "{{" in am_raw:
    problems.append(
        "alertmanager.config contains '{{' — Helm's tpl and Alertmanager's templates share the "
        "same delimiters, so this either breaks the install or is silently rewritten. "
        "Omit the key and take Alertmanager's default instead")

if problems:
    print("observability values problems:")
    for p in problems:
        print("  " + p)
    sys.exit(1)
print(f"{VALUES}: all critical settings correct")
