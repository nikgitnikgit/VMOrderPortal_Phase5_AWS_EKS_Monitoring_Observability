"""Every metric a dashboard or an alert references must be one something produces.

THE BUG THIS CATCHES

A typo in a metric name is the most common way an observability change is
wrong, and it is completely silent. `http_request_total` instead of
`http_requests_total` gives a panel that is empty forever and an alert that can
never fire. Nothing errors. Prometheus has no opinion about a query for a
metric that does not exist -- it returns an empty vector, which is
indistinguishable from "this is fine".

HOW IT WORKS

Extract every metric name referenced by grafana/*.json and by every
PrometheusRule in the rendered charts, then check each one against a set built
from three sources:

  1. metrics DEFINED in our own application code (app/common/metrics.py and the
     service modules) -- parsed out of the source, so adding a metric to the
     code is enough and nothing has to be listed twice;
  2. metrics produced by exporters we deploy, listed explicitly below;
  3. recording rules we define, which are metrics too.

An unknown name fails. The explicit list in (2) is the honest part: those names
cannot be derived from anything in this repository, so they are written down,
with the exporter that produces each one.
"""
import glob
import json
import os
import re
import subprocess
import sys

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

# --- 2. metrics produced by components we deploy but do not write -----------
# Grouped by producer so an unfamiliar name can be traced back to the thing
# that emits it rather than guessed at.
EXPORTER_METRICS = {
    # kube-state-metrics
    "kube_node_status_condition", "kube_pod_status_phase",
    "kube_pod_container_status_restarts_total",
    "kube_pod_container_status_last_terminated_reason",
    "kube_deployment_spec_replicas", "kube_deployment_status_replicas_available",
    # node-exporter
    "node_cpu_seconds_total", "node_memory_MemAvailable_bytes",
    # kubelet / cAdvisor
    "container_cpu_cfs_throttled_periods_total", "container_cpu_cfs_periods_total",
    "container_memory_working_set_bytes",
    "kubelet_volume_stats_used_bytes", "kubelet_volume_stats_capacity_bytes",
    # available, not used: the kubelet publishes both, and available/capacity is
    # the pair that needs no join. PrometheusStorageFillingUp used to divide
    # prometheus_tsdb_storage_blocks_bytes by capacity `on(instance)`, which can
    # never match — the two carry different instance labels — so the alert
    # returned an empty vector forever and could not fire.
    "kubelet_volume_stats_available_bytes",
    # Prometheus itself
    "up", "ALERTS", "scrape_duration_seconds", "process_start_time_seconds",
    "prometheus_tsdb_head_series", "prometheus_tsdb_head_samples_appended_total",
    "prometheus_tsdb_storage_blocks_bytes",
    "prometheus_rule_evaluation_failures_total",
    "alertmanager_notifications_failed_total",
    # Jenkins Prometheus plugin
    "jenkins_queue_size_value", "jenkins_queue_waiting_value",
    "jenkins_executor_in_use_value", "jenkins_node_online_value",
    "jenkins_runs_total_total", "jenkins_runs_success_total",
    "jenkins_runs_failure_total", "jenkins_runs_unstable_total",
    "jenkins_builds_last_build_duration_milliseconds",
    "jvm_memory_bytes_used", "jvm_memory_bytes_max",
    # nginx-prometheus-exporter
    "nginx_connections_active", "nginx_http_requests_total", "nginx_up",
}

# PromQL functions and keywords that the extractor would otherwise mistake for
# metric names.
NOT_METRICS = {
    "sum", "rate", "irate", "increase", "avg", "min", "max", "count", "by",
    "without", "on", "ignoring", "group_left", "group_right", "histogram_quantile",
    "vector", "scalar", "clamp_min", "clamp_max", "time", "changes", "delta",
    "absent", "or", "and", "unless", "le", "topk", "bottomk", "quantile",
    "label_values", "min_over_time", "max_over_time", "avg_over_time",
    "sum_over_time", "count_over_time", "last_over_time", "abs", "ceil", "floor",
    "round", "predict_linear", "deriv", "stddev", "stdvar", "offset", "bool",
    "humanizePercentage", "humanizeDuration", "namespace", "instance", "job",
}

METRIC_RE = re.compile(r'\b([a-zA-Z_:][a-zA-Z0-9_:]*)\s*(?:\{|\[|\)|\s|$)')


def defined_in_code():
    """Metric names created by Counter/Gauge/Histogram/Summary in our code."""
    names = set()
    pat = re.compile(r'(?:Counter|Gauge|Histogram|Summary)\(\s*\n?\s*"([a-zA-Z_:][a-zA-Z0-9_:]*)"')
    for f in glob.glob("app/**/*.py", recursive=True):
        src = open(f).read()
        for m in pat.finditer(src):
            base = m.group(1)
            names.add(base)
            # A Histogram called x produces x_bucket, x_sum and x_count; a
            # Counter called x_total is also queryable as x_total. Register the
            # derived series or every histogram query looks unknown.
            names.update({f"{base}_bucket", f"{base}_sum", f"{base}_count",
                          f"{base}_created"})
    return names


def recording_rules(rendered):
    names = set()
    for doc in rendered:
        if doc.get("kind") != "PrometheusRule":
            continue
        for g in doc["spec"]["groups"]:
            for r in g["rules"]:
                if "record" in r:
                    names.add(r["record"])
    return names


# `by (a, b)` and `without (a, b)` name LABELS, not metrics. Stripping the
# whole clause is the right fix; adding the label names to NOT_METRICS would
# work today and hide a genuine typo tomorrow, because a metric that happens to
# share a name with a label we group by would stop being checked.
GROUPING_RE = re.compile(r'\b(?:by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)')


def referenced(exprs):
    out = set()
    for e in exprs:
        # Order matters: grouping clauses first, then label matchers, then
        # string literals. Each strip can otherwise expose text the next one
        # would have removed.
        # label_values(metric, label) -- the SECOND argument is a label name.
        # Grafana template variables use this form, and without special
        # handling every templated dashboard reports its own label as an
        # unknown metric.
        cleaned = re.sub(r'label_values\s*\(([^,)]*),[^)]*\)', r'\1', e)
        cleaned = GROUPING_RE.sub(' ', cleaned)
        cleaned = re.sub(r'\{[^}]*\}', ' ', cleaned)
        cleaned = re.sub(r'"[^"]*"', ' ', cleaned)
        cleaned = re.sub(r"'[^']*'", ' ', cleaned)
        for m in METRIC_RE.finditer(cleaned):
            n = m.group(1)
            if n in NOT_METRICS or n.isdigit():
                continue
            out.add(n)
    return out


def main():
    import yaml

    # Render the charts so the rules are the real, templated ones.
    rendered = []
    for chart, extra in (("helm/backend", True), ("helm/worker", True),
                         ("helm/frontend", False), ("helm/observability", False)):
        cmd = ["helm", "template", os.path.basename(chart), chart,
               "--set", "image.registry=dummy"]
        if extra:
            cmd += ["--set", "serviceAccount.roleArn=arn:aws:iam::000000000000:role/dummy"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"could not render {chart}: {r.stderr.strip()[:200]}")
            return 1
        rendered += [d for d in yaml.safe_load_all(r.stdout) if d]

    known = EXPORTER_METRICS | defined_in_code() | recording_rules(rendered)

    exprs = []
    for doc in rendered:
        if doc.get("kind") == "PrometheusRule":
            for g in doc["spec"]["groups"]:
                for rule in g["rules"]:
                    exprs.append(rule["expr"])
    for f in glob.glob("helm/observability/dashboards/*.json"):
        d = json.load(open(f))
        for p in d.get("panels", []):
            for t in p.get("targets", []) or []:
                if t.get("expr"):
                    exprs.append(t["expr"])
        for a in d.get("annotations", {}).get("list", []):
            if a.get("expr"):
                exprs.append(a["expr"])
        for v in d.get("templating", {}).get("list", []):
            q = v.get("query")
            if isinstance(q, dict):
                q = q.get("query")
            if q:
                exprs.append(q)

    used = referenced(exprs)
    unknown = sorted(used - known)

    if unknown:
        print("metric names referenced but produced by nothing:")
        for u in unknown:
            print(f"  {u}")
        print("")
        print("Either it is a typo, or it comes from an exporter that should be")
        print("added to EXPORTER_METRICS in this file with a comment saying which.")
        return 1

    print(f"{len(exprs)} expressions reference {len(used)} distinct metrics, all accounted for")
    return 0


if __name__ == "__main__":
    sys.exit(main())
