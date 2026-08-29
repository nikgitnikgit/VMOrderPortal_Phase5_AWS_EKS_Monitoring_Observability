#!/usr/bin/env python3
"""tests/check_node_count.py — documented node counts must match Terraform.

The shipped NodeNotReadyOrPressure alert description told whoever is on call
that the cluster has "four nodes and three of them single-purpose". It has
five, two of them single-purpose. Those were Phase 4's numbers -- 3 app + 1
jenkins -- left behind when Phase 5 added the monitoring node group, and
repeated in the runbook and in the Prometheus sizing table.

An alert description is read during an incident, which is exactly when nobody
has the time to go and count nodes. So the number is derived from Terraform
here, and prose that disagrees fails.

Written as a file rather than inline in run_all.sh on purpose: the first
version was inline, and by the time the regexes had passed through bash -c and
a nested python3 -c their backslashes had been eaten. It computed three nodes
instead of five and still reported success, because the word "five" was missing
from its own word list -- a check that was wrong twice and green anyway.
"""
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

WORD_TO_INT = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
}

# Files whose prose states a node count.
PROSE = [
    "helm/observability/templates/prometheusrule-platform.yaml",
    "docs/runbooks/NodeNotReadyOrPressure.md",
    "docs/PHASE5_PLAN.md",
    "docs/architecture-observability.mmd",
    "README.md",
]


def terraform_node_count():
    eks = (REPO / "terraform/modules/eks/main.tf").read_text()
    tfvars = (REPO / "terraform/variables.tf").read_text()

    m = re.search(r'variable\s+"node_count".*?default\s*=\s*(\d+)', tfvars, re.S)
    if not m:
        sys.exit("could not find the node_count default in terraform/variables.tf")
    app = int(m.group(1))

    groups = re.findall(r'resource\s+"aws_eks_node_group"\s+"(\w+)"', eks)
    # Every group's desired_size, in file order, so a hardcoded 1 is counted and
    # the var-driven one is not double counted.
    sizes = re.findall(r"desired_size\s*=\s*(\S+)", eks)
    if len(groups) != len(sizes):
        sys.exit(f"found {len(groups)} node groups but {len(sizes)} desired_size "
                 "settings; the parsing assumption no longer holds")

    total, single_purpose = 0, 0
    for name, size in zip(groups, sizes):
        if size.isdigit():
            n = int(size)
            single_purpose += 1        # a fixed-size group is a dedicated one
        else:
            n = app                    # var.node_count, the app pool
        total += n
    return total, single_purpose, len(groups)


def main():
    total, single_purpose, group_count = terraform_node_count()
    if group_count != 3:
        print(f"expected 3 node groups, Terraform declares {group_count} — "
              "update PROSE and this check together")
        return 1

    bad = []
    for rel in PROSE:
        f = REPO / rel
        if not f.exists():
            continue
        text = f.read_text()
        for m in re.finditer(r"\b(\w+)\s+nodes\b", text):
            token = m.group(1).lower()
            if token.isdigit():
                stated = int(token)
            elif token in WORD_TO_INT:
                stated = WORD_TO_INT[token]
            else:
                continue               # "all nodes", "the nodes", "tainted nodes"
            if stated != total:
                bad.append(f'{rel}: says "{m.group(0)}", Terraform creates {total}')

    if bad:
        print("documented node counts disagree with Terraform:")
        for b in sorted(set(bad)):
            print("  " + b)
        print("")
        print("The alert description is shipped to whoever is on call, and is read")
        print("during an incident — the moment when checking it is hardest.")
        return 1

    print(f"Terraform creates {total} nodes across {group_count} groups "
          f"({single_purpose} single-purpose); every documented count agrees")
    return 0


if __name__ == "__main__":
    sys.exit(main())
