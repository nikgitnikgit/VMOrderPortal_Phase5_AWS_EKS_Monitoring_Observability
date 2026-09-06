#!/usr/bin/env python3
"""tests/check_trivy_exceptions.py — a security exception must stay an exception.

An ignore file is the one artefact in a pipeline whose whole purpose is to make
a failing check pass. Left alone it does not rot loudly: it goes on suppressing
findings long after the reason expired, and the gate above it keeps printing
green. That is this project's recurring bug in its purest form — a weaker check
wearing a stronger one's badge — so the ignore file gets a test of its own.

Five things are asserted, and each one has a specific failure in mind:

  1. NOT AT THE REPOSITORY ROOT. Trivy auto-discovers .trivyignore.yaml from the
     working directory. A root-level copy would silently apply to the
     application image scan in Jenkinsfile-ci, which scans Python images that
     have no business inheriting an exception written for a Go binary.

  2. EVERY RULE IS SCOPED. A bare `id:` with no `paths` and no `purls`
     suppresses that CVE everywhere in the image, including in a package added
     next year by someone who never read this file.

  3. EVERY RULE IS JUSTIFIED. `statement` must be present and long enough to be
     an argument rather than a shrug. "false positive" is not a statement.

  4. EVERY RULE EXPIRES, AND THE WARNING ARRIVES EARLY. `expired_at` must exist
     and be in the future -- and the suite fails GRACE_DAYS before the date, not
     on it. An exception that lapses on the day you next deploy fails the deploy;
     one that warns three weeks out gets fixed at a desk.

  5. THE FILE IS ACTUALLY WIRED IN. scripts/install-jenkins.sh must pass
     --ignorefile in EVERY branch that runs Trivy. It has two -- a local binary
     and a containerised fallback -- and the container branch also needs the
     file bind-mounted, or --ignorefile names a path that does not exist inside
     the container. An unwired ignore file is not harmless: the build fails on
     a finding that is documented three directories away, and the next person
     concludes the documentation is wrong.

Deleting the ignore file is always a valid way to pass this check. That is the
intended end state, not a loophole.
"""
import datetime
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
IGNORE = REPO / "jenkins/agent-tools/.trivyignore.yaml"
INSTALLER = REPO / "scripts/install-jenkins.sh"

# How long before expiry the suite starts failing.
GRACE_DAYS = 21
# Short enough that "CVE not exploitable" does not count as reasoning.
MIN_STATEMENT = 80


def main():
    problems = []

    # ---------------------------------------------------------------- (1)
    for stray in (".trivyignore", ".trivyignore.yaml", ".trivyignore.yml"):
        if (REPO / stray).exists():
            problems.append(
                f"{stray} is at the repository root. Trivy auto-discovers it "
                "from the working directory, so it would also apply to the "
                "application image scan in Jenkinsfile-ci. Move it beside the "
                "Dockerfile it describes and pass it with --ignorefile.")

    # ---------------------------------------------------------------- (1b)
    # THE APPLICATION IMAGE GATE TAKES NO EXCEPTIONS, AND THAT IS DELIBERATE.
    #
    # Jenkinsfile-ci scans frontend, backend and worker. Those are built from
    # nginx-unprivileged:alpine and python:3.12-slim and contain no Go binaries
    # at all -- Python wheels, a static index.html and an nginx config -- so
    # they cannot carry the finding the agent image exception was written for,
    # and there is no reason for them to inherit it.
    #
    # Two ways that could stop being true. A root-level ignore file, caught
    # above, because Trivy auto-discovers from the working directory and CI's
    # working directory is the repository root. And someone adding --ignorefile
    # to the CI scans directly, caught here. Neither is hypothetical: the whole
    # reason the agent file lives in jenkins/agent-tools/ is that the obvious
    # place to put it would have silenced this gate too.
    ci = REPO / "Jenkinsfile-ci"
    if ci.exists():
        ci_text = ci.read_text()
        ci_scans = re.findall(r"trivy image[^\"']*", ci_text)
        if not ci_scans:
            problems.append(
                "found no Trivy invocation in Jenkinsfile-ci — either the "
                "application image scan moved, or this check has stopped "
                "looking at anything")
        for scan in ci_scans:
            if "--ignorefile" in scan or "trivyignore" in scan:
                problems.append(
                    "a Trivy scan in Jenkinsfile-ci passes an ignore file. The "
                    "application images contain no Go binaries and must not "
                    "inherit the agent image's exception. If they genuinely "
                    "need one, give them their own file and argue it there.")

    if not IGNORE.exists():
        # The good ending. Nothing is being suppressed.
        if problems:
            print("Trivy exception problems:")
            for p in problems:
                print("  - " + p)
            return 1
        print("no Trivy ignore file — nothing is being suppressed")
        return 0

    try:
        import yaml
    except ImportError:
        print("SKIPPED (pyyaml is not installed; run scripts/install-test-tooling.sh)")
        return 0

    doc = yaml.safe_load(IGNORE.read_text()) or {}
    rules = doc.get("vulnerabilities") or []
    if not rules:
        problems.append(
            f"{IGNORE.relative_to(REPO)} exists but declares no vulnerabilities. "
            "An ignore file that ignores nothing is confusing rather than safe — "
            "delete it.")

    today = datetime.date.today()
    for i, rule in enumerate(rules):
        where = rule.get("id") or f"rule #{i + 1}"

        if not rule.get("id"):
            problems.append(f"{where}: has no `id`, so it matches every finding")

        # ------------------------------------------------------------ (2)
        if not rule.get("paths") and not rule.get("purls"):
            problems.append(
                f"{where}: no `paths` and no `purls` — this suppresses the CVE "
                "across the whole image, not just the binary it was argued about")

        # ------------------------------------------------------------ (3)
        statement = (rule.get("statement") or "").strip()
        if len(statement) < MIN_STATEMENT:
            problems.append(
                f"{where}: `statement` is {len(statement)} characters, minimum "
                f"{MIN_STATEMENT}. Say why the vulnerable code path cannot be "
                "reached and what has to happen for the entry to be removed.")

        # ------------------------------------------------------------ (4)
        expiry = rule.get("expired_at")
        if expiry is None:
            problems.append(
                f"{where}: no `expired_at`. An exception without an expiry date "
                "is a permanent decision taken by whoever was unblocking a build "
                "that afternoon.")
        else:
            if isinstance(expiry, str):
                try:
                    expiry = datetime.date.fromisoformat(expiry.strip())
                except ValueError:
                    problems.append(f"{where}: `expired_at` is not a yyyy-mm-dd date")
                    expiry = None
            elif isinstance(expiry, datetime.datetime):
                expiry = expiry.date()
            elif not isinstance(expiry, datetime.date):
                problems.append(f"{where}: `expired_at` is not a date")
                expiry = None

            if isinstance(expiry, datetime.date):
                left = (expiry - today).days
                if left < 0:
                    problems.append(
                        f"{where}: EXPIRED {-left} days ago ({expiry}). Trivy is "
                        "no longer honouring it, so the build is failing. Check "
                        "whether upstream shipped the fix; bump the pinned "
                        "version and delete this entry, or re-argue it.")
                elif left <= GRACE_DAYS:
                    problems.append(
                        f"{where}: expires in {left} days ({expiry}). Re-check "
                        "upstream NOW, while this is a test failure at a desk "
                        "rather than a failed deploy.")

    # -------------------------------------------------------------------- (5)
    if IGNORE.exists() and INSTALLER.exists():
        text = INSTALLER.read_text()

        # Join backslash continuations into whole logical statements FIRST.
        #
        # The first version of this searched forward from the matched line, and
        # reported that the containerised scan had no bind-mount. It does have
        # one -- on the line ABOVE the line that names the image, which forward
        # extraction could never see. A check that reads half a command and
        # reports on the whole one is exactly the failure mode this file exists
        # to catch, so it is worth saying that it happened here.
        statements, buf = [], []
        for line in text.splitlines():
            buf.append(line)
            if not line.rstrip().endswith("\\"):
                statements.append("\n".join(buf))
                buf = []
        if buf:
            statements.append("\n".join(buf))

        scans = [s for s in statements
                 if re.search(r"(^|\s)trivy(:\S+)?\s[^\n]*\bimage\b", s)
                 or re.search(r"aquasec/trivy\S*\s+image\b", s)]
        if not scans:
            problems.append(
                "found no Trivy invocation in scripts/install-jenkins.sh — this "
                "check is not looking at anything, which is not the same as passing")
        for stmt in scans:
            first = stmt.splitlines()[0].strip()
            if "--ignorefile" not in stmt:
                problems.append(
                    "a Trivy scan in install-jenkins.sh does not pass "
                    f"--ignorefile:\n      {first}\n    The exception file "
                    "would not apply there, and the build would fail on a "
                    "finding that is documented in the repository.")
            if "aquasec/trivy" in stmt and ".trivyignore.yaml:" not in stmt:
                problems.append(
                    "the containerised Trivy scan passes --ignorefile but does "
                    "not bind-mount the file into the container, so it names a "
                    "path that does not exist there.")

    if problems:
        print("Trivy exception problems:")
        for p in problems:
            print("  - " + p)
        print("")
        print("An ignore file is the one thing in a pipeline whose job is to make")
        print("a failing check pass. It gets held to a higher standard, not a")
        print("lower one. Deleting it always passes this check.")
        return 1

    n = len(rules)
    soonest = min((r["expired_at"] for r in rules if r.get("expired_at")), default=None)
    print(f"{n} Trivy exception(s), each scoped, justified and dated"
          + (f"; soonest expiry {soonest}" if soonest else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
