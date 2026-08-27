#!/usr/bin/env python3
"""helm/observability/build-dashboards.py — generate the dashboard JSON.

WHY A GENERATOR AND NOT THREE HAND-WRITTEN JSON FILES

A Grafana dashboard is 600+ lines of JSON in which about 30 lines are the part
a human cares about: the title, the query, the unit and the threshold.
Hand-maintaining the other 570 is how dashboards end up with a null datasource
on one panel, a percentunit on one gauge and a percent on the next, and grid
positions that overlap after someone adds a row.

Everything shared — the datasource uid, the release annotation, the template
variables, the panel scaffolding — is written once here. The dashboards
themselves are declared as short lists of (title, query, unit, threshold).

The generated files ARE committed: CI validates them, the ConfigMaps are built
from them, and nothing at deploy time needs Python. Re-run this after editing:

    python3 helm/observability/build-dashboards.py

tests/check_dashboards.py fails if the committed files do not match what this
script produces, so the two cannot drift.
"""
import json
import os

DS = {"type": "prometheus", "uid": "prometheus"}
# Inside the chart, and that is not a style choice: Helm's .Files.Glob cannot
# read anything outside the chart directory, so a top-level grafana/ directory
# renders zero ConfigMaps and gives no error while doing it.
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dashboards")

APP_NS = "devops-app"
JENKINS_NS = "jenkins"
OBS_NS = "observability"
SLO_LATENCY = 0.5
SLO_AVAILABILITY = 0.99

_id = [0]


def nid():
    _id[0] += 1
    return _id[0]


def target(expr, legend="", instant=False):
    return {
        "datasource": DS,
        "expr": expr,
        "legendFormat": legend,
        "refId": chr(65 + (nid() % 26)),
        "instant": instant,
        "range": not instant,
    }


def thresholds(steps):
    return {"mode": "absolute", "steps": [{"color": c, "value": v} for c, v in steps]}


def timeseries(title, targets, unit="short", desc="", w=12, h=8, x=0, y=0,
               thr=None, legend_calcs=("mean", "max", "lastNotNull")):
    return {
        "id": nid(), "type": "timeseries", "title": title, "description": desc,
        "datasource": DS, "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": targets,
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "custom": {
                    "drawStyle": "line", "lineWidth": 2, "fillOpacity": 8,
                    "showPoints": "never", "spanNulls": False,
                    "axisLabel": "", "gradientMode": "opacity",
                },
                "thresholds": thr or thresholds([("green", None)]),
                "color": {"mode": "palette-classic"},
            },
            "overrides": [],
        },
        "options": {
            "legend": {"displayMode": "table", "placement": "bottom",
                       "showLegend": True, "calcs": list(legend_calcs)},
            "tooltip": {"mode": "multi", "sort": "desc"},
        },
    }


def stat(title, targets, unit="short", desc="", w=6, h=5, x=0, y=0, thr=None,
         text_size=42, graph=True):
    return {
        "id": nid(), "type": "stat", "title": title, "description": desc,
        "datasource": DS, "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": targets,
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "thresholds": thr or thresholds([("green", None)]),
                "color": {"mode": "thresholds"},
                "mappings": [],
            },
            "overrides": [],
        },
        "options": {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "graphMode": "area" if graph else "none",
            "colorMode": "value", "justifyMode": "auto",
            "textMode": "auto", "text": {"valueSize": text_size},
        },
    }


def table(title, targets, desc="", w=12, h=8, x=0, y=0, overrides=None):
    return {
        "id": nid(), "type": "table", "title": title, "description": desc,
        "datasource": DS, "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": targets,
        "transformations": [
            {"id": "labelsToFields", "options": {"mode": "columns"}},
            {"id": "organize", "options": {"excludeByName": {"Time": True}}},
        ],
        "fieldConfig": {"defaults": {"custom": {"align": "auto"}},
                        "overrides": overrides or []},
        "options": {"showHeader": True, "footer": {"show": False}},
    }


def row(title, y):
    return {"id": nid(), "type": "row", "title": title, "collapsed": False,
            "gridPos": {"h": 1, "w": 24, "x": 0, "y": y}, "panels": []}


def dashboard(uid, title, description, panels, templating=None, annotations=None,
              tags=None, refresh="30s"):
    return {
        "uid": uid,
        "title": title,
        "description": description,
        "tags": tags or ["vm-order-portal"],
        "timezone": "browser",
        "schemaVersion": 39,
        "version": 1,
        "refresh": refresh,
        "editable": False,          # matches allowUiUpdates: false — the UI is
                                    # a viewer, Git is the source
        "time": {"from": "now-6h", "to": "now"},
        "templating": {"list": templating or []},
        "annotations": {"list": annotations or []},
        "panels": panels,
    }


# The annotation that ties every graph to a release. app_build_info changes
# value the moment a new git_sha starts reporting, so `changes()` marks the
# exact instant a deploy took effect — which is what makes "did this release
# cause it?" answerable by looking rather than by correlating timestamps.
RELEASE_ANNOTATION = {
    "name": "Releases",
    "enable": True,
    "iconColor": "rgba(255, 96, 96, 1)",
    "datasource": DS,
    "expr": f'changes(app_build_info{{namespace="{APP_NS}"}}[1m]) > 0',
    "titleFormat": "release {{git_sha}}",
    "textFormat": "version {{version}} · service {{service}}",
    "step": "60s",
}

SERVICE_VAR = {
    "name": "service", "label": "Service", "type": "query", "datasource": DS,
    "query": {"query": f'label_values(http_requests_total{{namespace="{APP_NS}"}}, service)',
              "refId": "service"},
    "refresh": 2, "includeAll": True, "multi": True, "current": {"text": "All", "value": "$__all"},
    "sort": 1,
}

POD_VAR = {
    "name": "pod", "label": "Pod", "type": "query", "datasource": DS,
    "query": {"query": f'label_values(http_requests_total{{namespace="{APP_NS}",service=~"$service"}}, pod)',
              "refId": "pod"},
    "refresh": 2, "includeAll": True, "multi": True, "current": {"text": "All", "value": "$__all"},
    "sort": 1,
}


# ===========================================================================
# 1. Application Overview
# ===========================================================================
def application_overview():
    p = []
    y = 0
    p.append(row("Service level — is the product working?", y)); y += 1

    p.append(stat(
        "Availability (30m)",
        [target("sli:http_availability:ratio30m", "availability")],
        unit="percentunit", x=0, y=y, w=6,
        desc=("Fraction of requests not returning 5xx, over 30 minutes. "
              f"SLO is {SLO_AVAILABILITY:.0%}. Red is a breach happening now, "
              "not a historical error budget."),
        thr=thresholds([("red", None), ("orange", 0.98), ("green", SLO_AVAILABILITY)])))

    p.append(stat(
        "p95 latency (5m)",
        [target("sli:http_latency_p95:rate5m", "p95")],
        unit="s", x=6, y=y, w=6,
        desc=f"SLO is {SLO_LATENCY}s. Turns amber at 80% of the threshold so there is warning before a breach.",
        thr=thresholds([("green", None), ("orange", SLO_LATENCY * 0.8), ("red", SLO_LATENCY)])))

    p.append(stat(
        "Error ratio (5m)",
        [target("sli:http_error_ratio:rate5m", "5xx ratio")],
        unit="percentunit", x=12, y=y, w=6,
        desc="Matches the HighErrorRate alert expression exactly — same recording rule, so the panel and the page cannot disagree.",
        thr=thresholds([("green", None), ("orange", 0.01), ("red", 0.02)])))

    p.append(stat(
        "Requests / sec",
        [target("sum(sli:http_requests:rate5m)", "rps")],
        unit="reqps", x=18, y=y, w=6,
        desc="The denominator. Check it before believing an error RATIO spike: a ratio also rises when traffic collapses."))
    y += 5

    p.append(row("Traffic and errors", y)); y += 1
    p.append(timeseries(
        "Request rate by service and status",
        [target(f'sum by (service, status) (rate(http_requests_total{{namespace="{APP_NS}",service=~"$service",pod=~"$pod"}}[5m]))',
                "{{service}} · {{status}}")],
        unit="reqps", x=0, y=y,
        desc="Split by status class. A rising 4xx line with flat 5xx is usually a client or a scanner, not an outage."))
    p.append(timeseries(
        "Error ratio vs SLO",
        [target("sli:http_error_ratio:rate5m", "5xx ratio"),
         target(str(0.02), "alert threshold")],
        unit="percentunit", x=12, y=y,
        desc="The flat line is where HighErrorRate fires.",
        thr=thresholds([("green", None), ("red", 0.02)])))
    y += 8

    p.append(row("Latency", y)); y += 1
    p.append(timeseries(
        "Latency percentiles",
        [target("sli:http_latency_p95:rate5m", "p95"),
         target("sli:http_latency_p99:rate5m", "p99"),
         target(f'histogram_quantile(0.50, sum by (le) (rate(http_request_duration_seconds_bucket{{namespace="{APP_NS}"}}[5m])))', "p50")],
        unit="s", x=0, y=y,
        desc=("p50 next to p95 answers 'is everything slow, or is there a slow tail?' — "
              "a p95 that moves while p50 is flat is a subset of requests, usually one route.")))
    p.append(timeseries(
        "p95 by route",
        [target(f'histogram_quantile(0.95, sum by (le, route) (rate(http_request_duration_seconds_bucket{{namespace="{APP_NS}",service=~"$service"}}[5m])))',
                "{{route}}")],
        unit="s", x=12, y=y,
        desc="Which endpoint is slow. /submit-order is expected to be the slowest — it calls RDS, then S3, then the worker."))
    y += 8

    p.append(row("Dependencies and business outcome", y)); y += 1
    p.append(timeseries(
        "Dependency failures by hop",
        [target(f'sum by (dependency, service) (rate(dependency_failures_total{{namespace="{APP_NS}"}}[5m]))',
                "{{service}} → {{dependency}}")],
        unit="short", x=0, y=y,
        desc="The first panel to look at when the error rate rises: it names the hop that broke instead of making you guess."))
    p.append(timeseries(
        "Orders by state reached",
        [target(f'sum by (state) (rate(vm_orders_total{{namespace="{APP_NS}"}}[5m]) * 60)', "{{state}}")],
        unit="short", x=12, y=y,
        desc=("The business metric. received > stored means S3 archiving is failing; "
              "stored > notified means customers are not getting their confirmation email. "
              "Neither is visible in any technical metric.")))
    y += 8

    p.append(row("Release", y)); y += 1
    p.append(table(
        "What is actually running",
        [target(f'app_build_info{{namespace="{APP_NS}"}}', "", instant=True)],
        x=0, y=y, w=24, h=6,
        desc=("Straight from the pods. This is the commit → Pod → dashboard link the defence asks for: "
              "the git_sha here is the tag CD deployed and the digest CI scanned.")))
    return dashboard(
        "vm-app-overview", "Application Overview",
        "Traffic, errors, latency, dependencies and the business outcome for the VM Order Portal.",
        p, templating=[SERVICE_VAR, POD_VAR], annotations=[RELEASE_ANNOTATION],
        tags=["vm-order-portal", "application"])


# ===========================================================================
# 2. Kubernetes / Cluster
# ===========================================================================
def kubernetes_cluster():
    p = []
    y = 0
    p.append(row("Nodes", y)); y += 1
    p.append(stat("Nodes Ready",
                  [target('sum(kube_node_status_condition{condition="Ready",status="true"})', "ready")],
                  x=0, y=y, w=4,
                  desc="Four expected: 3 app, 1 jenkins, 1 monitoring — minus any that is being replaced.",
                  thr=thresholds([("red", None), ("orange", 3), ("green", 4)])))
    p.append(stat("Pods Pending",
                  [target(f'sum(kube_pod_status_phase{{phase="Pending",namespace=~"{APP_NS}|{JENKINS_NS}|{OBS_NS}"}}) or vector(0)', "pending")],
                  x=4, y=y, w=4,
                  desc="A pod that cannot be scheduled. On a cluster this small the usual cause is a taint or no room left on the one node that tolerates it.",
                  thr=thresholds([("green", None), ("orange", 1), ("red", 3)])))
    p.append(stat("Restarts (1h)",
                  [target(f'sum(increase(kube_pod_container_status_restarts_total{{namespace=~"{APP_NS}|{JENKINS_NS}|{OBS_NS}"}}[1h])) or vector(0)', "restarts")],
                  x=8, y=y, w=4,
                  desc="A container that keeps almost working never shows up as a replica shortfall.",
                  thr=thresholds([("green", None), ("orange", 3), ("red", 10)])))
    p.append(stat("OOMKilled (1h)",
                  [target(f'sum(increase(kube_pod_container_status_last_terminated_reason{{reason="OOMKilled",namespace=~"{APP_NS}|{JENKINS_NS}|{OBS_NS}"}}[1h])) or vector(0)', "oom")],
                  x=12, y=y, w=4,
                  desc="Its own panel rather than a restart cause, because the fix is different: a memory limit, not a bug.",
                  thr=thresholds([("green", None), ("red", 1)])))
    p.append(stat("Firing alerts",
                  [target('sum(ALERTS{alertstate="firing",alertname!="Watchdog"}) or vector(0)', "firing")],
                  x=16, y=y, w=4,
                  desc="Watchdog excluded: it fires permanently by design, to prove the pipeline works.",
                  thr=thresholds([("green", None), ("orange", 1), ("red", 3)])))
    p.append(stat("Prometheus disk used",
                  [target(f'max(prometheus_tsdb_storage_blocks_bytes{{namespace="{OBS_NS}"}}) / (10 * 1024 * 1024 * 1024)', "used")],
                  x=20, y=y, w=4, unit="percentunit",
                  desc="Against the 10Gi volume. retentionSize should keep this under 70%.",
                  thr=thresholds([("green", None), ("orange", 0.7), ("red", 0.85)])))
    y += 5

    p.append(row("Capacity and pressure", y)); y += 1
    p.append(timeseries("CPU usage by node",
                        [target('100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)', "{{instance}}")],
                        unit="percent", x=0, y=y,
                        desc="From node-exporter, which runs on every node including the tainted ones — see the tolerations in kube-prometheus-stack.values.yaml."))
    p.append(timeseries("Memory available by node",
                        [target("node_memory_MemAvailable_bytes", "{{instance}}")],
                        unit="bytes", x=12, y=y,
                        desc="Available, not free: free excludes reclaimable cache and makes every node look nearly full."))
    y += 8

    p.append(timeseries("Container CPU throttling",
                        [target(f'sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{{namespace="{APP_NS}"}}[5m])) '
                                f'/ clamp_min(sum by (pod) (rate(container_cpu_cfs_periods_total{{namespace="{APP_NS}"}}[5m])), 1)',
                                "{{pod}}")],
                        unit="percentunit", x=0, y=y,
                        desc=("Throttling looks like slowness with no CPU spike, because the limit is doing exactly what it was asked to. "
                              "clamp_min avoids a divide-by-zero on an idle pod.")))
    p.append(timeseries("Memory usage vs limit",
                        [target(f'sum by (pod) (container_memory_working_set_bytes{{namespace="{APP_NS}",container!=""}})', "{{pod}}")],
                        unit="bytes", x=12, y=y,
                        desc="working_set, not RSS: it is what the OOM killer actually looks at."))
    y += 8

    p.append(row("Workloads", y)); y += 1
    p.append(timeseries("Desired vs available replicas",
                        [target(f'kube_deployment_spec_replicas{{namespace="{APP_NS}"}}', "{{deployment}} desired"),
                         target(f'kube_deployment_status_replicas_available{{namespace="{APP_NS}"}}', "{{deployment}} available")],
                        x=0, y=y,
                        desc="The gap between the two lines is what ReplicasMismatch alerts on after ten minutes."))
    p.append(timeseries("PVC usage",
                        [target('kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes', "{{namespace}}/{{persistentvolumeclaim}}")],
                        unit="percentunit", x=12, y=y,
                        desc="Includes Prometheus's own volume. A monitoring system that fills its disk stops being a monitoring system.",
                        thr=thresholds([("green", None), ("orange", 0.8), ("red", 0.9)])))
    y += 8

    # ---- the row that replaces the Prometheus UI ----
    p.append(row("Scrape health — the authenticated view of /targets", y)); y += 1
    p.append(table(
        "Targets",
        [target(f'up{{namespace=~"{APP_NS}|{JENKINS_NS}|{OBS_NS}"}}', "", instant=True)],
        x=0, y=y, w=12, h=9,
        desc=("Prometheus has no Ingress and no authentication, so its /targets page is not exposed. "
              "This is the replacement, and it is better evidence: it lives in Git, it is reviewable, "
              "and it is behind a login. 1 = up, 0 = down."),
        overrides=[{"matcher": {"id": "byName", "options": "Value"},
                    "properties": [{"id": "custom.cellOptions",
                                    "value": {"type": "color-background"}},
                                   {"id": "thresholds",
                                    "value": thresholds([("red", None), ("green", 1)])}]}]))
    p.append(timeseries("Scrape duration",
                        [target(f'scrape_duration_seconds{{namespace=~"{APP_NS}|{JENKINS_NS}|{OBS_NS}"}}', "{{job}} · {{pod}}")],
                        unit="s", x=12, y=y, h=9,
                        desc="A scrape creeping towards the 10s timeout is the warning before a target starts flapping.",
                        thr=thresholds([("green", None), ("orange", 5), ("red", 9)])))
    y += 9
    p.append(timeseries("TSDB head series",
                        [target("prometheus_tsdb_head_series", "active series")],
                        x=0, y=y, w=8,
                        desc=("Active series is what storage sizing was calculated from (~21k). "
                              "A sharp climb means a new unbounded label got introduced — the failure this whole labelling discipline exists to prevent.")))
    p.append(timeseries("Samples ingested / sec",
                        [target("rate(prometheus_tsdb_head_samples_appended_total[5m])", "samples/s")],
                        x=8, y=y, w=8, desc="Roughly active series divided by the scrape interval. A step change means targets appeared or vanished."))
    p.append(timeseries("Rule evaluation failures",
                        [target("rate(prometheus_rule_evaluation_failures_total[5m])", "{{rule_group}}")],
                        x=16, y=y, w=8,
                        desc=("A rule that cannot evaluate produces no alert and no error anyone sees. "
                              "This is the panel that catches an alert which silently stopped working."),
                        thr=thresholds([("green", None), ("red", 0.001)])))
    return dashboard(
        "vm-k8s-cluster", "Kubernetes / Cluster",
        "Nodes, capacity, workload health, storage, and the health of the scrape pipeline itself.",
        p, tags=["vm-order-portal", "kubernetes"])


# ===========================================================================
# 3. Jenkins & Delivery
# ===========================================================================
def jenkins_delivery():
    p = []
    y = 0
    p.append(row("Delivery health", y)); y += 1
    p.append(stat("Queue length",
                  [target("jenkins_queue_size_value", "queued")],
                  x=0, y=y, w=6,
                  desc="Non-empty for 15 continuous minutes is what JenkinsQueueStuck alerts on.",
                  thr=thresholds([("green", None), ("orange", 1), ("red", 5)])))
    p.append(stat("Busy executors",
                  [target("jenkins_executor_in_use_value or vector(0)", "in use")],
                  x=6, y=y, w=6,
                  desc="The controller runs numExecutors=0 on purpose, so anything here is a dynamic agent pod doing real work."))
    p.append(stat("Builds (1h)",
                  [target("sum(increase(jenkins_runs_total_total[1h])) or vector(0)", "builds")],
                  x=12, y=y, w=6, desc="Total across both pipelines."))
    p.append(stat("Failures (1h)",
                  [target("sum(increase(jenkins_runs_failure_total[1h])) or vector(0)", "failed")],
                  x=18, y=y, w=6,
                  desc="A CI failure is the system working — nothing was promoted. A CD failure means a rollback ran.",
                  thr=thresholds([("green", None), ("orange", 1), ("red", 3)])))
    y += 5

    p.append(row("Queue and agents", y)); y += 1
    p.append(timeseries("Queue length and wait time",
                        [target("jenkins_queue_size_value", "queue length"),
                         target("jenkins_queue_waiting_value or vector(0)", "waiting")],
                        x=0, y=y,
                        desc=("Length alone does not distinguish 'busy' from 'stuck'. A queue that is long and moving is fine; "
                              "one that is short and motionless is not.")))
    p.append(timeseries("Dynamic agent pods",
                        [target(f'sum(kube_pod_status_phase{{namespace="{JENKINS_NS}",phase="Running"}}) - 1', "running agents"),
                         target(f'sum(kube_pod_status_phase{{namespace="{JENKINS_NS}",phase="Pending"}}) or vector(0)', "pending agents")],
                        x=12, y=y,
                        desc=("Minus one for the controller itself. Pending agents with a non-empty queue is the exact "
                              "signature of the stuck-agent drill: the pod cannot be scheduled.")))
    y += 8

    p.append(row("Build outcomes", y)); y += 1
    p.append(timeseries("Build result rate",
                        [target("sum(rate(jenkins_runs_success_total[15m]) * 900)", "success"),
                         target("sum(rate(jenkins_runs_failure_total[15m]) * 900)", "failure"),
                         target("sum(rate(jenkins_runs_unstable_total[15m]) * 900) or vector(0)", "unstable")],
                        x=0, y=y, desc="Builds per 15 minutes by outcome."))
    p.append(timeseries("Build duration",
                        [target("jenkins_builds_last_build_duration_milliseconds", "{{jenkins_job}}")],
                        unit="ms", x=12, y=y,
                        desc="A CI build creeping upwards is usually the Trivy database download or an image layer cache that stopped hitting."))
    y += 8

    p.append(row("Controller", y)); y += 1
    p.append(timeseries("JVM heap",
                        [target("jvm_memory_bytes_used{area='heap'}", "used"),
                         target("jvm_memory_bytes_max{area='heap'}", "max")],
                        unit="bytes", x=0, y=y, w=8,
                        desc="The controller has a 2Gi limit. Heap approaching max means a restart is coming, mid-build."))
    p.append(timeseries("Controller uptime",
                        [target("jenkins_node_online_value or vector(0)", "online")],
                        x=8, y=y, w=8, desc="Drops to zero on a restart, which explains a queue that suddenly emptied."))
    p.append(stat("Time since last successful build",
                  [target("time() - max(jenkins_runs_success_total > 0) * 0 - max(process_start_time_seconds{namespace=\"" + JENKINS_NS + "\"})", "since")],
                  unit="s", x=16, y=y, w=8, h=8, graph=False,
                  desc=("How long since delivery last worked end to end. A number that keeps climbing is the "
                        "quietest possible outage: nothing is broken, nothing is shipping."),
                  thr=thresholds([("green", None), ("orange", 86400), ("red", 259200)])))
    return dashboard(
        "vm-jenkins-delivery", "Jenkins & Delivery",
        "Queue, executors, agents, build outcomes and controller health for the CI/CD system.",
        p, tags=["vm-order-portal", "jenkins"])


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, fn in (("application-overview", application_overview),
                     ("kubernetes-cluster", kubernetes_cluster),
                     ("jenkins-delivery", jenkins_delivery)):
        _id[0] = 0
        path = os.path.join(OUT, f"{name}.json")
        with open(path, "w") as fh:
            json.dump(fn(), fh, indent=2, sort_keys=True)
            fh.write("\n")
        print(f"  wrote {path}")


if __name__ == "__main__":
    main()
