#!/usr/bin/env python3
"""tests/check_alert_routing.py — meta-alerts must never reach a human.

kube-prometheus-stack ships two alerts that are not about the system at all:

    Watchdog        always fires, so that "no alerts" and "alerting is broken"
                    can be told apart by something watching from outside
    InfoInhibitor   fires whenever an info-severity alert is active in a
                    namespace, and exists only to be the SOURCE of an
                    inhibition rule that suppresses those info alerts

Both are machinery. Upstream routes both to a null receiver. This config
null-routed Watchdog -- with a comment saying it must not reach the inbox --
and missed InfoInhibitor, which then emailed a FIRING/RESOLVED pair for the
jenkins namespace during an ordinary CD run.

That is not a cosmetic bug. Alert fatigue is the failure mode this whole phase
is built to avoid: an operator who learns that two of the emails are noise
stops reading the third. So the rule is checked rather than remembered.

It also asserts InfoInhibitor is USED. Null-routing it without the inhibit
rule leaves an alert that fires, notifies nobody and suppresses nothing -- the
quiet version of the same bug, and exactly the state this config was in.
"""
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
VALUES = REPO / "helm/observability/kube-prometheus-stack.values.yaml"

META_ALERTS = ("Watchdog", "InfoInhibitor")


def main():
    try:
        import yaml
    except ImportError:
        print("SKIPPED (pyyaml is not installed; run scripts/install-test-tooling.sh)")
        return 0

    cfg = (yaml.safe_load(VALUES.read_text()) or {})["alertmanager"]["config"]
    route = cfg["route"]
    problems = []

    # The catch-all must not be the null receiver: that would mute everything
    # and pass every check below for the worst possible reason.
    if route.get("receiver") == "null":
        problems.append("the top-level route sends EVERYTHING to the null "
                        "receiver — no alert would ever be delivered")

    null_routed = set()
    for r in route.get("routes") or []:
        matchers = r.get("matchers") or []
        if r.get("receiver") != "null":
            continue
        for m in matchers:
            if "alertname" in m and "=" in m:
                null_routed.add(m.split("=", 1)[1].strip().strip('"'))

    for name in META_ALERTS:
        if name not in null_routed:
            problems.append(
                f"{name} is not routed to the null receiver, so it reaches the "
                "SNS topic and the operator's inbox. It carries no information "
                "about the system; it is machinery.")

    # InfoInhibitor must actually inhibit something.
    inhibits = cfg.get("inhibit_rules") or []
    used = any("InfoInhibitor" in " ".join(r.get("source_matchers") or [])
               for r in inhibits)
    if not used:
        problems.append(
            "InfoInhibitor is not the source of any inhibit rule, so it fires "
            "and achieves nothing. Add a rule with source_matchers "
            "[alertname = InfoInhibitor], target_matchers [severity = info], "
            "equal [namespace] — or drop the alert entirely.")

    # A receiver named "null" has to exist, or Alertmanager rejects the config
    # and the whole notification path is down.
    if not any(r.get("name") == "null" for r in cfg.get("receivers") or []):
        problems.append('no receiver named "null" is defined, but routes '
                        "reference it — Alertmanager will reject this config")

    if problems:
        print("Alertmanager routing problems:")
        for p in problems:
            print("  - " + p)
        return 1

    print(f"both meta-alerts ({', '.join(META_ALERTS)}) are null-routed, "
          f"InfoInhibitor drives an inhibit rule, {len(inhibits)} rules total")
    return 0


if __name__ == "__main__":
    sys.exit(main())
