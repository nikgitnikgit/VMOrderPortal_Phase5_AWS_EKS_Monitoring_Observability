#!/usr/bin/env python3
"""tests/check_agent_image_deps.py — the agent image must satisfy what CI runs.

WHY THIS REPLACED A NARROWER CHECK

The first version of this rule looked only at what `app/` imports, because the
bug it was written for was `prometheus_client` missing from the agent image and
breaking `pytest app/`. It fixed that instance and missed the class.

CI does not only run pytest. Jenkinsfile-ci also runs
`./scripts/validate-observability.sh`, which executes inline Python and calls
`tests/check_metrics_contract.py`, and both `import yaml`. pyyaml was not in the
image either, so the validation stage failed in the field with

    ModuleNotFoundError: No module named 'yaml'

on a repository whose offline suite was 218 green -- because the offline suite
runs on a machine where pyyaml is installed, and the check that was supposed to
model the agent image was looking at the wrong files.

So this walks what CI ACTUALLY EXECUTES:

    Jenkinsfile-ci
      -> the scripts it invokes
           -> inline `import` statements inside those scripts
           -> the tests/*.py those scripts call
      -> the python modules it runs directly

and requires every third-party module reachable that way to be installed in
jenkins/agent-tools/Dockerfile.

WHAT IT DELIBERATELY DOES NOT DO

It does not require every module used anywhere in tests/ -- check_terraform.py
needs hcl2 and check_helm.py needs kubernetes_validate, and CI runs neither.
Installing packages the pipeline never imports would be dead weight in an image
that a CRITICAL vulnerability gate scans, and this project has already lost a
deploy to an unnecessary binary's CVE.
"""
import ast
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent

# Import name -> distribution name, where they differ.
DIST_FOR_MODULE = {
    "yaml": "pyyaml",
    "psycopg2": "psycopg2-binary",
    "prometheus_client": "prometheus-client",
    "kubernetes_validate": "kubernetes-validate",
    "hcl2": "python-hcl2",
}
# Modules that are local to this repository, not packages.
LOCAL = {"metrics", "app", "worker", "conftest", "test_app", "test_worker"}
# Importable because something else pulls them in. Taken from a real venv built
# with the image's pip line, not guessed.
TRANSITIVE = {
    "boto3": ["botocore", "s3transfer", "jmespath", "dateutil", "six", "urllib3"],
    "flask": ["werkzeug", "jinja2", "click", "itsdangerous", "blinker", "markupsafe"],
    "requests": ["certifi", "charset_normalizer", "idna", "urllib3"],
    "pytest": ["pluggy", "iniconfig", "packaging"],
    "pytest-cov": ["coverage"],
}


def installed_in_image():
    docker = (REPO / "jenkins/agent-tools/Dockerfile").read_text()
    block = re.search(r"RUN pip3 install[^\n]*\n((?:\s+\S+==\S+\s*\\?\n)+)", docker)
    if not block:
        sys.exit("could not find the pip install block in jenkins/agent-tools/Dockerfile")
    dists = {m.group(1).lower() for m in re.finditer(r"([A-Za-z0-9_.-]+)==", block.group(1))}
    mods = set(dists)
    # Map distribution names back to what an `import` would say.
    for mod, dist in DIST_FOR_MODULE.items():
        if dist in dists:
            mods.add(mod)
    for dist, deps in TRANSITIVE.items():
        if dist in dists:
            mods.update(deps)
    return dists, mods


def third_party_imports(text, source):
    """Every non-stdlib module imported by a chunk of Python."""
    found = {}
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return found
    for node in ast.walk(tree):
        names = []
        if isinstance(node, ast.Import):
            names = [a.name.split(".")[0] for a in node.names]
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            names = [node.module.split(".")[0]]
        for m in names:
            if m in sys.stdlib_module_names or m in LOCAL:
                continue
            found.setdefault(m, source)
    return found


def inline_python_imports(script_path):
    """Imports inside heredocs and `python3 -c` blocks in a shell script.

    Parsed line-wise rather than by extracting whole programs: the heredocs here
    are nested inside quoted shell variables and are not reliably separable, and
    a false positive costs one unnecessary package while a false negative costs
    a broken pipeline.
    """
    found = {}
    text = script_path.read_text()
    for line in text.splitlines():
        m = re.match(r"\s*(?:import|from)\s+([a-zA-Z_][a-zA-Z0-9_]*)", line)
        if not m:
            continue
        mod = m.group(1)
        if mod in sys.stdlib_module_names or mod in LOCAL:
            continue
        found.setdefault(mod, str(script_path.relative_to(REPO)))
    # `import a, b, c` on one line.
    for m in re.finditer(r"^\s*import\s+([a-zA-Z_][\w,\s]*)$", text, re.M):
        for mod in (x.strip() for x in m.group(1).split(",")):
            if mod and mod not in sys.stdlib_module_names and mod not in LOCAL:
                found.setdefault(mod, str(script_path.relative_to(REPO)))
    return found


def main():
    ci = (REPO / "Jenkinsfile-ci").read_text()
    needed = {}

    # 1. Scripts the pipeline invokes.
    for name in sorted(set(re.findall(r"\./(scripts/[a-z0-9-]+\.sh)", ci))):
        script = REPO / name
        if not script.exists():
            print(f"Jenkinsfile-ci calls {name}, which does not exist")
            return 1
        needed.update(inline_python_imports(script))
        # 2. tests/*.py those scripts call.
        for called in set(re.findall(r"(tests/[a-z0-9_]+\.py)", script.read_text())):
            t = REPO / called
            if t.exists():
                needed.update(third_party_imports(t.read_text(), called))

    # 3. Python the pipeline runs directly.
    for target in set(re.findall(r"python3 -m pytest\s+(\S+)", ci)):
        d = REPO / target.rstrip("/")
        if d.is_dir():
            for f in d.rglob("*.py"):
                needed.update(third_party_imports(f.read_text(), str(f.relative_to(REPO))))
    for called in set(re.findall(r"python3\s+(tests/[a-z0-9_]+\.py)", ci)):
        t = REPO / called
        if t.exists():
            needed.update(third_party_imports(t.read_text(), called))

    if not needed:
        print("found no Python imports reachable from Jenkinsfile-ci -- this check "
              "is not looking at anything, which is not the same as passing")
        return 1

    dists, mods = installed_in_image()
    missing = {m: src for m, src in needed.items() if m not in mods}

    if missing:
        print("the CI agent image is missing modules the pipeline imports:")
        for m, src in sorted(missing.items()):
            print(f"  {m:<22} imported by {src}   (install {DIST_FOR_MODULE.get(m, m)})")
        print("")
        print("Jenkinsfile-ci runs these inside the agent image, which installs its")
        print("own package list -- requirements.txt is never installed there. Add to")
        print("the pip3 block in jenkins/agent-tools/Dockerfile AND bump")
        print("LABEL tools.version, or install-jenkins.sh reuses the old image.")
        return 1

    print(f"the agent image satisfies all {len(needed)} modules reachable from "
          f"Jenkinsfile-ci ({', '.join(sorted(needed))})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
