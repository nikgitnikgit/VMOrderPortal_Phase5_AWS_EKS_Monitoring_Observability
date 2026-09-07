#!/usr/bin/env python3
"""tests/check_rollback_count.py — the rollback must be able to count revisions.

WHAT HAPPENED

CD build 6 failed its monitoring gate correctly and then reported:

    frontend: no previous revision (first install) — nothing to roll back
    worker:   no previous revision (first install) — nothing to roll back
    backend:  no previous revision (first install) — nothing to roll back

`helm history frontend -n devops-app` at that moment listed THREE revisions.
The bad release kept serving, and the pipeline said the environment was fine.

The cause was one character of shell:

    helm history "$r" -o json | grep -c '"revision"'

`helm history -o json` prints the whole array on ONE LINE. `grep -c` counts
matching LINES, not matches. So the count was 1 for any number of revisions,
`[ "$REVS" -lt 2 ]` was always true, and `helm rollback` was never reached --
on any release, ever.

WHY THIS GETS A TEST OF ITS OWN

The block it lives in is itself an audit fix, with a comment reading: "'No
previous revision' is now established by asking, not by inferring it from a
failure." The reasoning was right and the implementation was wrong, so a
reviewer reading the comment would agree with it and move on. Only running it
against realistic input catches this.

So this test RUNS the counting expression, extracted from Jenkinsfile-cd, with
the helm call replaced by a fixture containing three revisions in helm's actual
one-line JSON format. It asserts the answer is 3.
"""
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
CD = REPO / "Jenkinsfile-cd"

# helm history -o json, exactly as helm emits it: one line, no whitespace.
THREE_REVISIONS = (
    '[{"revision":1,"updated":"2026-09-06T17:14:36Z","status":"superseded",'
    '"chart":"frontend-0.1.0","app_version":"1.0.0","description":"Install complete"},'
    '{"revision":2,"updated":"2026-09-06T18:57:49Z","status":"superseded",'
    '"chart":"frontend-0.1.0","app_version":"1.0.0","description":"Upgrade complete"},'
    '{"revision":3,"updated":"2026-09-07T07:10:53Z","status":"deployed",'
    '"chart":"frontend-0.1.0","app_version":"1.0.0","description":"Upgrade complete"}]'
)


def counting_expression():
    """The REVS=... assignment from Jenkinsfile-cd, joined into one command."""
    text = CD.read_text()
    m = re.search(r"REVS=\$\((.*?)\)\n", text, re.S)
    if not m:
        return None
    expr = m.group(1)
    # Join the shell line continuations the Jenkinsfile uses for readability.
    expr = re.sub(r"\\\s*\n\s*", " ", expr)
    return " ".join(expr.split())


def main():
    if not CD.exists():
        print("Jenkinsfile-cd not found")
        return 1

    expr = counting_expression()
    if expr is None:
        print("no REVS=$(...) assignment found in Jenkinsfile-cd — the rollback "
              "revision count moved, and this check is not looking at anything")
        return 1

    if not shutil.which("python3"):
        print("SKIPPED (python3 not on PATH)")
        return 0

    # Replace the helm invocation with the fixture, keeping everything the
    # pipeline actually does to helm's output.
    if "helm history" not in expr:
        print(f"the REVS expression no longer calls helm history:\n  {expr}")
        return 1

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        fh.write(THREE_REVISIONS)
        fixture = fh.name

    piped = expr.split("|", 1)
    if len(piped) != 2:
        print("the REVS expression does not pipe helm's output anywhere, so it "
              f"cannot be counting anything:\n  {expr}")
        return 1
    command = f"cat {fixture} | {piped[1]}"

    out = subprocess.run(["bash", "-c", command], capture_output=True, text=True)
    got = out.stdout.strip().splitlines()
    answer = got[-1] if got else ""

    if answer != "3":
        print("the rollback's revision count is wrong.")
        print(f"  expression : {expr}")
        print("  given      : three revisions, in helm's one-line JSON")
        print(f"  answered   : {answer!r}, expected '3'")
        print("")
        print("`helm history -o json` is ONE LINE, so `grep -c` counts lines and")
        print("always returns 1. With REVS=1 the `-lt 2` guard is always true and")
        print("helm rollback is never reached: every failed release reports")
        print("'no previous revision (first install)' while it keeps serving.")
        return 1

    print(f"the rollback counts 3 revisions from helm's one-line JSON "
          f"({piped[1].strip()[:48]}...)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
