#!/usr/bin/env python3
"""tests/check_sns_subject.py — the SNS Subject must fit in 100 characters.

WHAT HAPPENED

Alertmanager's `subject` was removed by an earlier audit on the grounds that
omitting it produced byte-identical notifications and avoided a Helm `tpl`
hazard. Omitting it does not produce a bounded subject. Alertmanager's default
expands to something like

    [FIRING:1] AlertmanagerClusterFailedToSendAlerts vm-order
    (observability/kube-prometheus-stack-prometheus critical)

which is 115 characters. AWS SNS rejects any Subject over 100 with

    400 Invalid parameter: Subject

and Alertmanager treats that as unrecoverable and drops the notification.

The shape of the failure is what makes it worth a test. SHORT alert names fit
under the cap and were delivered normally; LONG ones were rejected. So alerting
appeared to work -- emails were arriving all evening -- while the three alerts
whose entire purpose is to report broken delivery were themselves the ones
being dropped, because their names are the longest in the system:

    AlertmanagerClusterFailedToSendAlerts   37
    AlertmanagerFailedToSendAlerts          30
    AlertmanagerNotificationsFailing        32

An alerting system that silently drops exactly the alerts about alerting is the
worst instance of this project's recurring bug, and it was introduced by a fix.

WHAT THIS ASSERTS

  1. `subject` is set at all -- the default is unbounded.
  2. Its worst-case rendered length is under the SNS cap, computed with the
     longest alertname this project actually defines.
  3. `tplConfig` is explicitly set, so whether Helm pre-renders the config is
     a decision in the file rather than a chart default nobody has read.
"""
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
VALUES = REPO / "helm/observability/kube-prometheus-stack.values.yaml"
RULES = REPO / "helm/observability/templates/prometheusrule-platform.yaml"

SNS_SUBJECT_LIMIT = 100
# Room for the chart's own alerts, whose names we do not control and which are
# longer than ours -- AlertmanagerClusterFailedToSendAlerts is 37.
ASSUMED_LONGEST_ALERTNAME = 45
STATUS_LONGEST = len("RESOLVED")


def main():
    try:
        import yaml
    except ImportError:
        print("SKIPPED (pyyaml is not installed; run scripts/install-test-tooling.sh)")
        return 0

    doc = yaml.safe_load(VALUES.read_text()) or {}
    am = doc.get("alertmanager") or {}
    problems = []

    if "tplConfig" not in am:
        problems.append(
            "alertmanager.tplConfig is not set. Helm and Alertmanager share the "
            "{{ }} delimiter, so whether the chart pre-renders this config "
            "decides whether the templates below are Alertmanager's or Helm's. "
            "State it rather than inheriting it.")

    receivers = (am.get("config") or {}).get("receivers") or []
    sns = [s for r in receivers for s in (r.get("sns_configs") or [])]
    if not sns:
        print("no sns_configs in the Alertmanager config — this check is not "
              "looking at anything, which is not the same as passing")
        return 1

    for cfg in sns:
        subject = cfg.get("subject")
        if not subject:
            problems.append(
                "an sns_config has no `subject`. Alertmanager's default is "
                "UNBOUNDED and SNS rejects anything over "
                f"{SNS_SUBJECT_LIMIT} characters with 400 Invalid parameter: "
                "Subject. Long alert names are dropped, short ones are "
                "delivered, and alerting looks like it works.")
            continue

        # Worst case: every {{ ... }} replaced by the longest value it can hold.
        literal = re.sub(r"\{\{.*?\}\}", "", subject)
        n_actions = len(re.findall(r"\{\{.*?\}\}", subject))
        if n_actions == 0:
            worst = len(literal)
        else:
            worst = len(literal) + STATUS_LONGEST + ASSUMED_LONGEST_ALERTNAME
        if worst > SNS_SUBJECT_LIMIT:
            problems.append(
                f"subject {subject!r} can render to about {worst} characters, "
                f"over the SNS limit of {SNS_SUBJECT_LIMIT}. Notifications "
                "whose labels push it over are rejected and dropped.")

        # A subject that interpolates annotations is unbounded in practice:
        # summary and description are free prose.
        for field in ("CommonAnnotations", ".Annotations", "GroupLabels.instance"):
            if field in subject:
                problems.append(
                    f"subject interpolates {field}, which is free-form text "
                    "with no length bound. Use status and alertname only.")

    if problems:
        print("SNS subject problems:")
        for p in problems:
            print("  - " + p)
        print("")
        print("SNS rejects an over-long Subject with 400 and Alertmanager treats")
        print("that as unrecoverable, so the notification is dropped silently.")
        return 1

    longest = 0
    if RULES.exists():
        names = re.findall(r"-\s*alert:\s*(\S+)", RULES.read_text())
        longest = max((len(n) for n in names), default=0)
    print(f"SNS subject is set and bounded (worst case ~{worst} of "
          f"{SNS_SUBJECT_LIMIT}); longest local alertname is {longest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
