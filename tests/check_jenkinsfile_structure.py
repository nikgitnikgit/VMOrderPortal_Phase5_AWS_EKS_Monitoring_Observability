#!/usr/bin/env python3
"""tests/check_jenkinsfile_structure.py — the Jenkinsfiles must be parseable.

WHY THIS EXISTS

A Declarative Pipeline with unbalanced braces, or a block nested one level
wrong, is rejected by Jenkins at PARSE time. Not the stage — the whole job.
`application-cd` simply never starts a build, and the only symptom is a red
cross with "WorkflowScript: unexpected token" long after the change was merged.

Nothing in this repository could see that. Every other Jenkinsfile test here
greps for the presence of a stage name, which a syntactically broken file
satisfies perfectly well. This was written after an audit added two
`catchError` wrappers to Jenkinsfile-cd and there was no way to check the
result short of running Jenkins.

WHAT IT CAN AND CANNOT DO

This is a brace/paren balance and nesting check, not a Groovy parser: it strips
comments and string literals — including the ''' … ''' shell heredocs, which are
full of braces and parentheses that mean nothing to Groovy — and then verifies
the structure. It will not catch a misspelled step name or a bad argument.

Said plainly so the check is not mistaken for a stronger one: passing here means
the file is well-formed, NOT that Jenkins will accept every step in it.
"""
import re
import sys

FILES = ("Jenkinsfile-ci", "Jenkinsfile-cd")

# Blocks that must appear exactly once at the top level of `pipeline { }`.
REQUIRED_TOP = ("agent", "environment", "stages", "post")


def strip_noise(src: str) -> str:
    """Remove triple-quoted strings, ordinary strings and comments.

    Order matters: triple-quoted first, or the closing ''' of a shell block is
    read as three empty single-quoted strings and everything after it shifts.
    """
    out = []
    i, n = 0, len(src)
    while i < n:
        three = src[i:i + 3]
        if three in ("'''", '"""'):
            end = src.find(three, i + 3)
            if end == -1:
                return "\x00UNTERMINATED_TRIPLE_QUOTE"
            # Keep the newlines so reported line numbers stay honest.
            out.append("\n" * src.count("\n", i, end + 3))
            i = end + 3
            continue
        c = src[i]
        if c in "'\"":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            if j >= n:
                return "\x00UNTERMINATED_STRING"
            i = j + 1
            continue
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j == -1 else j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            if j == -1:
                return "\x00UNTERMINATED_BLOCK_COMMENT"
            out.append("\n" * src.count("\n", i, j + 2))
            i = j + 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


problems = []

for path in FILES:
    try:
        raw = open(path).read()
    except OSError as exc:
        problems.append(f"{path}: cannot be read ({exc})")
        continue

    code = strip_noise(raw)
    if code.startswith("\x00"):
        problems.append(f"{path}: {code[1:].lower().replace('_', ' ')}")
        continue

    # --- balance, reported at the line where it first goes wrong ------------
    depth, line, bad = 0, 1, None
    for ch in code:
        if ch == "\n":
            line += 1
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth < 0 and bad is None:
                bad = line
    if bad is not None:
        problems.append(f"{path}:{bad} closes a brace that was never opened")
    elif depth != 0:
        problems.append(
            f"{path}: {depth} brace(s) left open at end of file — "
            "Jenkins rejects the whole job at parse time, so no build ever starts")

    parens = code.count("(") - code.count(")")
    if parens != 0:
        problems.append(f"{path}: {abs(parens)} unbalanced parenthesis/es")

    # --- the declarative skeleton ------------------------------------------
    if not re.search(r"^\s*pipeline\s*\{", code, re.M):
        problems.append(f"{path}: no top-level `pipeline {{` block")
        continue

    # Depth 1 == directly inside `pipeline { }`.
    depth, top_level = 0, []
    token = ""
    for ch in code:
        if ch == "{":
            if depth == 1:
                name = token.strip().split()[-1] if token.strip() else ""
                if name.isidentifier():
                    top_level.append(name)
            depth += 1
            token = ""
        elif ch == "}":
            depth -= 1
            token = ""
        elif ch in " \t\n":
            token += " "
        else:
            token += ch

    for required in REQUIRED_TOP:
        if top_level.count(required) == 0:
            problems.append(f"{path}: no `{required}` block directly inside pipeline")
        elif top_level.count(required) > 1:
            # Declarative rejects duplicates outright. A duplicate `post` is the
            # exact mistake REVIEW FIX 3.1a in Jenkinsfile-cd records: two
            # `failure` conditions made the job unparseable, so it had never run.
            problems.append(
                f"{path}: `{required}` appears {top_level.count(required)} times at the top level; "
                "Declarative Pipeline rejects duplicate blocks")

    # Duplicate post conditions, same reasoning.
    post_body = re.search(r"\bpost\s*\{", code)
    if post_body:
        start = post_body.end()
        d, end = 1, start
        while end < len(code) and d:
            d += (code[end] == "{") - (code[end] == "}")
            end += 1
        inner = code[start:end - 1]
        d, conds = 0, []
        tok = ""
        for ch in inner:
            if ch == "{":
                # `token += " "` on whitespace and then take the LAST word --
                # not `tok = ""`, which was the first version of this loop and
                # meant the space in `failure {` cleared the name before the
                # brace was reached. The duplicate-post check then found
                # nothing, ever. Caught by injecting a second `failure` block
                # and watching this stay green.
                name = tok.strip().split()[-1] if tok.strip() else ""
                if d == 0 and name.isidentifier():
                    conds.append(name)
                d += 1
                tok = ""
            elif ch == "}":
                d -= 1
                tok = ""
            elif ch in " \t\n":
                tok += " "
            else:
                tok += ch
        dupes = {c for c in conds if conds.count(c) > 1}
        if dupes:
            problems.append(
                f"{path}: duplicate post condition(s) {sorted(dupes)} — "
                "'Duplicate build condition name' is a parse error, not a warning")

if problems:
    print("Jenkinsfile structure problems:")
    for p in problems:
        print("  " + p)
    sys.exit(1)

print("Jenkinsfile-ci and Jenkinsfile-cd are balanced, with one each of "
      "agent/environment/stages/post and no duplicate post conditions "
      "(balance only — this is not a Groovy parser)")
