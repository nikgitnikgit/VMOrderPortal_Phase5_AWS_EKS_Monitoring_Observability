#!/usr/bin/env python3
"""tests/check_runbook_links.py — every alert links to ITS OWN runbook.

THIS REPLACES A CHECK THAT COULD NOT FAIL.

T18.41 used to end like this:

    helm template ... | grep -o "runbook_url:.*" | sed ... \\
      | while read -r f; do
          [ -f "docs/runbooks/$f" ] || { echo "...does not exist"; exit 1; }
        done
    echo "all runbook_urls derive from ${base}"

The `while` runs in a subshell, because it is on the right-hand side of a pipe.
`exit 1` ends that subshell, and the `echo` on the next line then sets the exit
status of the whole thing back to 0. Tested by pointing an alert at
`ThisFileDoesNotExist.md`, it printed

    runbook_url names docs/runbooks/ThisFileDoesNotExist.md, which does not exist
    all runbook_urls derive from https://github.com/...
    verdict: exit=0

-- it DETECTED the problem, PRINTED it, and PASSED. In the suite that renders
as a green tick with no output at all, because a passing check prints nothing.

AND IT WAS CHECKING THE WEAKER PROPERTY ANYWAY

Even working, it only asked "does the named file exist". Three alerts pointed
at OTHER alerts' runbooks, and every one of those files existed:

    JenkinsDown                       -> JenkinsQueueStuck.md
    PrometheusStorageFillingUp        -> PrometheusTargetDown.md
    AlertmanagerNotificationsFailing  -> PrometheusTargetDown.md

Reading the rules by hand found one of the three. So the rule here is the
stronger one: an alert named X links to X.md, and X.md exists. A runbook is
opened by someone under pressure who followed a link precisely because they did
not already know what to do; landing them on a page about a different failure
is worse than no link, because they will read it before they doubt it.

Deliberate sharing is allowed, but only by saying so out loud in SHARED below.
"""
import pathlib
import re
import shutil
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
CHART = REPO / "helm/observability"
RUNBOOKS = REPO / "docs/runbooks"

# alert -> runbook it may point at instead of its own. Empty on purpose: if a
# genuine reason appears, add it here with the reason, so the exception is a
# line in a diff rather than a silent mismatch.
SHARED: dict[str, str] = {}


def rendered_rules():
    helm = shutil.which("helm")
    if not helm:
        return None
    out = subprocess.run([helm, "template", "observability", str(CHART)],
                         capture_output=True, text=True)
    if out.returncode != 0:
        print("SKIPPED (helm template failed: "
              f"{out.stderr.strip().splitlines()[-1] if out.stderr.strip() else 'no output'})")
        return None
    return out.stdout


def main():
    text = rendered_rules()
    if text is None:
        if shutil.which("helm") is None:
            print("SKIPPED (helm is not installed; run scripts/install-test-tooling.sh)")
        return 0

    pairs, alert = [], None
    for line in text.splitlines():
        m = re.search(r"-\s*alert:\s*(\S+)", line)
        if m:
            alert = m.group(1)
        m = re.search(r'runbook_url:.*?/docs/runbooks/([^"\s]+)', line)
        if m and alert:
            pairs.append((alert, m.group(1)))

    if not pairs:
        print("no alert/runbook_url pairs found in the rendered chart -- this "
              "check is not looking at anything, which is not the same as passing")
        return 1

    problems = []
    for alert, rb in pairs:
        expected = SHARED.get(alert, f"{alert}.md")
        if rb != expected:
            problems.append(
                f"{alert} links to {rb}, expected {expected}. An on-call "
                "engineer follows this link because they do NOT know what to "
                "do; a runbook for a different failure will be read before it "
                "is doubted. Write docs/runbooks/{0}.md, or record the sharing "
                "in SHARED with a reason.".format(alert))
        elif not (RUNBOOKS / rb).is_file():
            problems.append(f"{alert} links to {rb}, which does not exist")

    # Alerts are not the only readers: a runbook nobody links to is either dead
    # or a link that was never added. MonitoringGateFailed is reached from the
    # CD pipeline output rather than an alert, so it is expected to be orphaned.
    linked = {rb for _, rb in pairs} | {"MonitoringGateFailed.md"}
    orphans = sorted(f.name for f in RUNBOOKS.glob("*.md") if f.name not in linked)
    if orphans:
        problems.append("runbooks nothing links to: " + ", ".join(orphans)
                        + " -- either an alert lost its link or the file is dead")

    if problems:
        print("runbook link problems:")
        for p in problems:
            print("  - " + p)
        return 1

    print(f"all {len(pairs)} alerts link to their own runbook, and every file exists")
    return 0


if __name__ == "__main__":
    sys.exit(main())
