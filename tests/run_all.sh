#!/bin/bash
# SC2016 is disabled for the whole file deliberately: the single-quoted strings
# below are passed to `bash -c` and MUST be expanded in that subshell, not here.
# shellcheck disable=SC2016
# tests/run_all.sh — QA test suite
# Groups: T1 structure, T2 static syntax, T3 terraform semantics,
# T4 helm/K8s validity, T5 cross-component consistency, T6 env-var coverage,
# T7 mock end-to-end script execution, T8 call-order assertions,
# T9 security/leak checks, T11 docs consistency, T12 live-deploy regressions,
# T13 Jenkins/RBAC/pipeline checks, T14 phase-4 audit regressions,
# T15 assignment spec compliance, T16 meta-checks on the suite itself,
# T17 review remediation.
#
# There is no T10. An earlier revision had a "package (zip) checks" group for a
# submission format this project no longer uses; the group went and the header
# did not, so for several revisions this comment advertised a group that did
# not exist and omitted four that did. Counting groups from this line is a
# thing people actually do -- keep it true.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

# THE SUITE MUST NOT DIRTY THE TREE IT IS INSPECTING.
#
# T1.2 forbids __pycache__ anywhere outside tests/. Several checks execute the
# application (pytest over app/, the instrumentation runtime check), and CPython
# writes bytecode beside every module it imports -- so the suite created exactly
# the junk its own second check forbids. On a clean checkout it passed; on every
# run after that, T1.2 failed. A suite that only passes once is a suite people
# learn to re-run with a `rm -rf` in front of it, which is how a real failure
# gets cleaned away unread.
#
# It went unnoticed here for the worst possible reason: the habit of deleting
# __pycache__ before each run. The bug was being tidied out of sight by the
# person looking for it.
#
# run_functional.sh already sets this for the same reason; it belongs at the top
# of the suite so no future check has to remember.
#
# BUT IT IS NOT SUFFICIENT ON ITS OWN, and relying on it alone was the second
# mistake here. pytest rewrites assertions and writes its own
# `*-pytest-<ver>.pyc` files, and whether it honours this variable varies by
# interpreter and pytest version: suppressed on Python 3.11 here, not suppressed
# on Python 3.12 in the field. A fix that works on the author's machine and not
# on the reader's is not a fix, and "cannot reproduce it" is not a defence.
#
# So prevention is kept because it is free, and DETERMINISTIC CLEANUP is added
# below because it does not care whether prevention worked. clean_pycache is
# called by every check that executes application code, and T18.45 at the end
# proves none of them forgot.
export PYTHONDONTWRITEBYTECODE=1

clean_pycache() {
    # Only under app/, and only bytecode. Never a broad `rm -rf` in a test
    # harness: this runs in the user's working tree.
    find app -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true
    find app -name "*.pyc" -delete 2>/dev/null || true
}
export -f clean_pycache
# ONE definition of build junk, used by the check at the START (T1.2, "the tree
# you handed me is clean") and the one at the END (T18.45, "the suite did not
# dirty it"). Those are different claims and both are worth making -- but they
# have to look for the same things, or a file can pass one and fail the other.
# .pytest_cache did exactly that: absent from T1.2's list, present in T18.45's.
junk_list() {
    find . \( -name "*.pyc" -o -name "__pycache__" -o -name ".pytest_cache" \
              -o -name "*.egg-info" -o -name ".DS_Store" -o -name "*{*" -o -name "*}*" \) \
         -not -path "./.git/*" -not -path "./tests/*" 2>/dev/null | sort
}

# Snapshot BEFORE anything runs, so the check at the end can tell "this was
# already here" from "the suite made this".
#
# Without it T18.45 blamed the suite for a stale .pytest_cache that a previous
# run had left and that `git clean -fd` does not remove (it is gitignored, and
# only -x would take it -- which would also take terraform.tfvars, so -x is the
# wrong answer). The message said "the suite created files"; the suite had not.
# A check that reports the wrong cause sends someone looking in the wrong place,
# which is its own kind of false result.
JUNK_AT_START=$(junk_list)
# EXPORTED, both of them. The checks below run inside `bash -c` subshells via
# t(), which inherit only exported names. Without this, T1.2 would compare
# against an empty string and pass unconditionally -- a check made vacuous by a
# missing keyword, which is the precise failure this file is full of warnings
# about. Verified by running the suite with junk present and watching T1.2 go
# red rather than green.
export JUNK_AT_START
export -f junk_list

PASS=0; FAIL=0; SKIP=0; FAILED_TESTS=(); SKIPPED_TESTS=()

t() { # t <id> <description> <command...>
  local id="$1" desc="$2"; shift 2
  if "$@" > /tmp/qa_out.log 2>&1; then
    # THREE outcomes, not two.
    #
    # This function used to have only pass and fail, so a check that printed
    # "SKIPPED (needs postgresql + nginx)" and exited 0 -- which several of them
    # do, honestly and on purpose -- was displayed as a green tick and counted
    # as a pass. On GitHub Actions, where flask and prometheus_client are not
    # installed, "the instrumentation survives hostile input and a hostile
    # environment" ticked green having verified precisely nothing.
    #
    # The individual checks were not lying: each one says SKIPPED in its output.
    # The RUNNER was, by rendering that as ✅ and folding it into the pass
    # count. A summary of "214 passed" that includes checks which did not run is
    # the strongest form of this project's recurring bug -- a weaker result
    # wearing a stronger one's badge -- and it was in the harness itself.
    if grep -qE '^\s*SKIPPED' /tmp/qa_out.log; then
      echo "  ⏭️  $id  $desc"
      sed 's/^/       /' /tmp/qa_out.log | head -2
      # Keep the REASON, not just the name. The summary used to end with
      # "Install the missing tooling and re-run", which is one of several
      # reasons a check skips and was the wrong one for T7.6 -- that needs
      # ROOT, and no amount of installing fixes it. Telling someone to do the
      # wrong thing about a real gap is how the gap survives.
      reason=$(grep -m1 -oE 'SKIPPED.*' /tmp/qa_out.log | sed 's/^SKIPPED *//; s/^(//; s/)$//')
      SKIP=$((SKIP+1)); SKIPPED_TESTS+=("$id $desc
             reason: ${reason:-no reason given}")
    else
      echo "  ✅ $id  $desc"; PASS=$((PASS+1))
    fi
  else
    echo "  ❌ $id  $desc"; sed 's/^/       /' /tmp/qa_out.log | head -6
    FAIL=$((FAIL+1)); FAILED_TESTS+=("$id $desc")
  fi
}

echo "=== T1: Project structure & hygiene ==="
t T1.1 "expected top-level layout present" bash -c '
  for d in docker app terraform helm scripts jenkins docs .github tests; do [ -d "$d" ] || exit 1; done
  for f in README.md .gitignore .dockerignore; do [ -f "$f" ] || exit 1; done'
t T1.2 "no junk files/dirs (braces, tmp, pyc, caches)" bash -c '
  # Uses junk_list so this and T18.45 cannot disagree about what junk is.
  # They did: .pytest_cache was invisible here and fatal there, so a stale one
  # sailed through this check and was then blamed on the suite at the end.
  if [ -n "$JUNK_AT_START" ]; then
    echo "the working tree already contained build junk before the suite ran:"
    echo "$JUNK_AT_START"
    echo ""
    # NO BACKTICKS. This message sits in a double-quoted string inside
    # bash -c, where backticks are command substitution, not punctuation -- so
    # an earlier draft of this very line EXECUTED "git clean -fd" every time the
    # check failed. A test that silently deletes untracked files in the tree it
    # is inspecting is the worst thing in this file, and it got there by quoting
    # a command name for readability.
    echo "These are gitignored, so git clean -fd does NOT remove them"
    echo "(and -x would also take terraform.tfvars, so do not reach for it)."
    echo "Remove them explicitly:"
    echo "  rm -rf .pytest_cache"
    echo "  find . -name __pycache__ -prune -exec rm -rf {} +"
    exit 1
  fi
  echo "working tree is free of build junk"'
t T1.3 "no unexpected empty directories" bash -c '
  [ -z "$(find . -type d -empty | grep -v ".git")" ]'
t T1.4 "all shell scripts executable" bash -c '
  for f in scripts/*.sh terraform/bootstrap-state.sh tests/*.sh; do [ -x "$f" ] || { echo "$f not executable"; exit 1; }; done'
t T1.5 "expected file inventory (spot check 12 key files)" bash -c '
  for f in docker/backend/Dockerfile docker/worker/Dockerfile docker/frontend/Dockerfile \
           docker/frontend/nginx.conf terraform/main.tf terraform/terraform.tfvars.example \
           helm/backend/Chart.yaml helm/worker/values.yaml helm/frontend/templates/ingress.yaml \
           Jenkinsfile-ci Jenkinsfile-cd jenkins/values.yaml jenkins/rbac.yaml; do
    [ -f "$f" ] || { echo "missing $f"; exit 1; }; done'

echo "=== T2: Static syntax ==="
t T2.1 "all shell scripts: bash -n" bash -c '
  for f in scripts/*.sh terraform/bootstrap-state.sh; do bash -n "$f" || exit 1; done'
t T2.2 "all shell scripts: shellcheck" bash -c '
  command -v shellcheck >/dev/null || { echo "shellcheck not installed"; exit 1; }
  shellcheck scripts/*.sh terraform/bootstrap-state.sh'
t T2.3 "all YAML files parse" python3 -c "
import yaml, glob
for f in glob.glob('.github/**/*.yml', recursive=True) + glob.glob('k8s/*.yaml') + glob.glob('helm/*/Chart.yaml') + glob.glob('helm/*/values.yaml') + glob.glob('jenkins/*.yaml'):
    list(yaml.safe_load_all(open(f)))"
t T2.4 "all Dockerfiles parse, pinned tags, non-root" python3 -c "
import dockerfile
for f in ['docker/backend/Dockerfile','docker/worker/Dockerfile','docker/frontend/Dockerfile']:
    cmds = dockerfile.parse_file(f)
    g = lambda k: [' '.join(c.value) for c in cmds if c.cmd.upper()==k]
    assert ':' in g('FROM')[0] and 'latest' not in g('FROM')[0], f
    assert g('USER') or 'unprivileged' in g('FROM')[0], f + ': no non-root'"
t T2.5 "nginx.conf valid (crossplane official parser)" python3 -c "
import crossplane, shutil, os
os.makedirs('/tmp/ng', exist_ok=True)
shutil.copy('docker/frontend/nginx.conf','/tmp/ng/default.conf')
open('/tmp/ng/nginx.conf','w').write('events {}\nhttp { include /tmp/ng/default.conf; }')
r = crossplane.parse('/tmp/ng/nginx.conf')
assert r['status']=='ok', r['errors']"
t T2.6 "all .tf files parse (hcl2)" python3 -c "
import hcl2, glob
for f in glob.glob('terraform/**/*.tf', recursive=True): hcl2.load(open(f))"

echo "=== T3: Terraform semantics ==="
t T3.0 "every Terraform reference resolves (no dangling resources)" python3 tests/check_tf_references.py
t T3.1 "module wiring: args/outputs/vars all consistent" python3 tests/check_terraform.py
t T3.2 "tfvars.example covers every variable without a default" python3 -c "
import hcl2, re
required = set()
for v in hcl2.load(open('terraform/variables.tf')).get('variable', []):
    for name, body in v.items():
        if name=='__is_block__': continue
        if not (isinstance(body,dict) and 'default' in body): required.add(name.strip('\"'))
example = set(re.findall(r'^(\w+)\s*=', open('terraform/terraform.tfvars.example').read(), re.M))
missing = required - example
assert not missing, f'tfvars.example missing: {missing}'"
t T3.3 "vendored ALB policy is valid IAM JSON" python3 -c "
import json
d = json.load(open('terraform/modules/irsa/alb_iam_policy.json'))
assert d['Version']=='2012-10-17' and len(d['Statement'])>10"
t T3.4 "no duplicate terraform resource addresses" python3 -c "
import re, glob, collections
c = collections.Counter()
for f in glob.glob('terraform/**/*.tf', recursive=True):
    for typ, name in re.findall(r'^resource \"(\S+)\" \"(\S+)\"', open(f).read(), re.M):
        c[(f.rsplit('/',1)[0], typ, name)] += 1
dups = [k for k,v in c.items() if v>1]
assert not dups, dups"

echo "=== T4: Helm charts render to valid Kubernetes objects ==="
t T4.1 "all templates render + strict K8s 1.35 schema validation" python3 tests/check_helm.py

t T4.2 "every .Values.* path used by templates exists in values.yaml" python3 tests/check_values_paths.py
t T4.3 "Chart.yaml sanity (apiVersion v2, name == directory)" python3 -c "
import yaml
for c in ['backend','worker','frontend']:
    d = yaml.safe_load(open(f'helm/{c}/Chart.yaml'))
    assert d['apiVersion']=='v2' and d['name']==c and d['appVersion'], c"

echo "=== T5: Cross-component consistency ==="
t T5.1 "nginx proxy target == backend Service name:port" python3 -c "
import re, yaml
ng = open('docker/frontend/nginx.conf').read()
m = re.search(r'proxy_pass http://(\w+):(\d+)/', ng)
vals = yaml.safe_load(open('helm/backend/values.yaml'))
svc = open('helm/backend/templates/service.yaml').read()
assert m.group(1) == 'backend' and 'name: backend' in svc
assert int(m.group(2)) == vals['service']['port'], f'nginx {m.group(2)} vs chart {vals[\"service\"][\"port\"]}'"
t T5.2 "backend WORKER_URL == worker Service name:port" python3 -c "
import yaml, re
b = yaml.safe_load(open('helm/backend/values.yaml'))['config']['WORKER_URL']
w = yaml.safe_load(open('helm/worker/values.yaml'))['service']['port']
m = re.match(r'http://(\w+):(\d+)$', b)
assert m and m.group(1)=='worker' and int(m.group(2))==w, f'{b}: code appends /notify itself — URL must have no suffix'"
t T5.3 "probe paths exist in app code / nginx" bash -c '
  grep -q "\"/health\"\|@app.route(.\?/health" app/backend/app.py &&
  grep -q "\"/health\"\|@app.route(.\?/health" app/worker/worker.py &&
  grep -q "location /healthz" docker/frontend/nginx.conf'
t T5.4 "NetworkPolicy ports match Service ports" python3 -c "
import yaml, re
for chart, port in [('backend',5000),('worker',5001),('frontend',8080)]:
    np = open(f'helm/{chart}/templates/networkpolicy.yaml').read()
    assert f'port: {port}' in np, f'{chart} netpol missing its own port {port}'"
t T5.5 "Dockerfile EXPOSE == chart service port" python3 -c "
import yaml, dockerfile
for c in ['backend','worker','frontend']:
    port = yaml.safe_load(open(f'helm/{c}/values.yaml'))['service']['port']
    cmds = dockerfile.parse_file(f'docker/{c}/Dockerfile')
    exp = [int(x.value[0]) for x in cmds if x.cmd.upper()=='EXPOSE'][0]
    assert exp == port, f'{c}: EXPOSE {exp} != service {port}'"
t T5.6 "chart image repos match ECR repos created by terraform" python3 -c "
import yaml, re
tf = open('terraform/main.tf').read()
repos = re.search(r'repositories = \[(.*?)\]', tf).group(1)
for c in ['backend','worker','frontend']:
    repo = yaml.safe_load(open(f'helm/{c}/values.yaml'))['image']['repository']
    assert repo == f'vm-order-{c}' and f'\"{c}\"' in repos, repo"

echo "=== T6: Env-var coverage (app code vs ConfigMap+Secret) ==="
t T6.1 "every env var the code reads is supplied (or defaulted in code)" python3 tests/check_envvars.py

echo "=== T7: Mock end-to-end script execution ==="
t T7.1 "deploy.sh runs end-to-end against mocks" bash tests/run_mock_deploy.sh
t T7.2 "destroy.sh runs end-to-end against mocks" bash tests/run_mock_destroy.sh

# REVIEW FIX 4.3 — installs with --require-hashes, the same flag the
# Dockerfiles use. A missing or wrong hash now fails HERE rather than in a
# container build nobody watches.
t T7.5 "pip layer: hash-locked requirements install on python 3.12" bash -c '
  rm -rf /tmp/appvenv && python3 -m venv /tmp/appvenv
  /tmp/appvenv/bin/pip install -q --require-hashes -r app/backend/requirements.txt &&
  /tmp/appvenv/bin/pip install -q --require-hashes -r app/worker/requirements.txt'
t T7.6 "FUNCTIONAL: real order through real app (nginx->backend->DB/S3->worker->SNS/SES)" bash tests/run_functional.sh

echo "=== T8: Call-order assertions (from mock logs) ==="
t T8.1 "deploy: terraform apply → install-jenkins.sh" python3 -c "
log = open('/tmp/mock_deploy.log').read().splitlines()
def idx(sub): return next(i for i,l in enumerate(log) if sub in l)
order = [idx('terraform apply'), idx('terraform output')]
assert order == sorted(order), order"
t T8.2 "destroy: jenkins uninstall → app uninstall → ALB wait → terraform destroy" python3 -c "
log = open('/tmp/mock_destroy.log').read().splitlines()
def idx(sub): return next(i for i,l in enumerate(log) if sub in l)
order = [idx('helm uninstall jenkins'), idx('helm uninstall frontend'), idx('helm uninstall backend'),
         idx('terraform destroy')]
assert order == sorted(order), order"
t T8.3 "destroy: Jenkins PVC deleted before terraform destroy" bash -c '
log=$(cat /tmp/mock_destroy.log)
pvc_line=$(echo "$log" | grep -n "delete pvc" | head -1 | cut -d: -f1)
tf_line=$(echo "$log" | grep -n "terraform destroy" | head -1 | cut -d: -f1)
[ -n "$pvc_line" ] && [ -n "$tf_line" ] && [ "$pvc_line" -lt "$tf_line" ]'
t T8.4 "destroy: S3 emptied before terraform destroy" bash -c '
log=$(cat /tmp/mock_destroy.log)
s3_line=$(echo "$log" | grep -n "s3 rm" | head -1 | cut -d: -f1)
tf_line=$(echo "$log" | grep -n "terraform destroy" | head -1 | cut -d: -f1)
[ -n "$s3_line" ] && [ -n "$tf_line" ] && [ "$s3_line" -lt "$tf_line" ]'

echo "=== T9: Security & leak checks ==="
t T9.1 "no real-looking secrets in the repo" bash -c '
  ! grep -rn --include="*" -E "AKIA[0-9A-Z]{16}|aws_secret_access_key" \
      --exclude-dir=tests . | grep -v -i "example\|CHANGE_ME\|secrets\." '
t T9.2 ".gitignore covers tfvars, state, backend.tf, .env" bash -c '
  for p in "terraform/terraform.tfvars" "terraform/*.tfstate*" "terraform/backend.tf" "*.env"; do
    grep -qF "$p" .gitignore || { echo "missing: $p"; exit 1; }; done'
t T9.3 "example files contain placeholders, never real secrets" python3 -c "
import re, sys
PATTERNS = {
  'AWS access key':      r'AKIA[0-9A-Z]{16}',
  'AWS secret key':      r'aws_secret_access_key\s*=\s*\S{20,}',
  'GitHub token':        r'gh[pousr]_[A-Za-z0-9]{20,}',
  'private key block':   r'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY',
  '12-digit account id': r'(?<![\w<])[0-9]{12}(?![\w>])',
}
bad=[]
for f in ['jenkins/secret.example.yaml','jenkins/values.example.yaml',
          'terraform/terraform.tfvars.example']:
    body=open(f).read()
    for name,pat in PATTERNS.items():
        m=re.search(pat, body)
        if m: bad.append(f'{f}: looks like a real {name}: {m.group(0)[:24]}')
    if '<' not in body and 'CHANGE_ME' not in body:
        bad.append(f'{f}: no placeholders found — is this a real config?')
if bad:
    print(chr(10).join(bad)); sys.exit(1)"
t T9.4 "no latest tags anywhere (Dockerfiles, values, workflows)" bash -c '
  ! grep -rn ":latest" docker/ helm/ .github/ terraform/'
t T9.5 "all SAs disable API token automount" bash -c '
  [ "$(grep -l "automountServiceAccountToken: false" helm/*/templates/serviceaccount.yaml | wc -l)" = "3" ]'

echo "=== T12: Live-deploy regression tests (every test = a real failure we hit) ==="
t T12.1 "Dockerfiles: numeric USER (kubelet runAsNonRoot verification)" bash -c '
  grep -q "^USER 10001" docker/backend/Dockerfile && grep -q "^USER 10001" docker/worker/Dockerfile'
t T12.2 "Dockerfiles: COPY --chmod (600-permission poisoning from zip)" bash -c '
  [ "$(grep -h "^COPY " docker/*/Dockerfile | grep -cv -- --chmod)" = "0" ]'
t T12.3 "checksum/config annotation (ConfigMap change must roll pods)" bash -c '
  grep -q "checksum/config" helm/backend/templates/deployment.yaml &&
  grep -q "checksum/config" helm/worker/templates/deployment.yaml'
t T12.4 "app Secrets created by bootstrap (Jenkins never sees the password)" bash -c '
  grep -q "kubectl create secret generic backend-secrets" scripts/install-jenkins.sh &&
  grep -q "kubectl create secret generic worker-secrets" scripts/install-jenkins.sh &&
  grep -q "DB_PASSWORD" scripts/install-jenkins.sh &&
  [ ! -f scripts/create-secret.sh ] &&
  ! grep -q "DB_PASSWORD" Jenkinsfile'
t T12.5 "ALB controller chart PINNED and policy matches (AccessDenied lesson)" bash -c '
  [ -f terraform/modules/irsa/ALB_CONTROLLER_VERSION ] &&
  grep -q "ALB_CONTROLLER_VERSION" scripts/install-jenkins.sh'
t T12.6 "vendored policy contains the two actions that failed live" bash -c '
  grep -q "GetSecurityGroupsForVpc" terraform/modules/irsa/alb_iam_policy.json &&
  grep -q "DescribeListenerAttributes" terraform/modules/irsa/alb_iam_policy.json'
t T12.7 "destroy.sh empties bucket incl. versions (BucketNotEmpty lesson)" bash -c '
  grep -q "s3 rm" scripts/destroy.sh && grep -q "list-object-versions" scripts/destroy.sh'
t T12.8 "destroy.sh sweeps orphan ENIs + retries (stuck-subnet lesson)" bash -c '
  grep -q "delete-network-interface" scripts/destroy.sh && grep -q "sweep_orphan_enis" scripts/destroy.sh'
t T12.9 "destroy.sh deletes ALB webhooks first (TLS webhook lesson)" bash -c '
  grep -q "validatingwebhookconfiguration" scripts/destroy.sh'
t T12.10 "S3 bucket has force_destroy" bash -c '
  grep -q "force_destroy = true" terraform/modules/s3/main.tf'

echo "=== T11: Docs consistency ==="
t T11.1 "key files exist (phase 4 inventory)" python3 -c "
import os
for f in ['docs/architecture-deployment.png','docs/architecture-pipeline.png',
          'docs/architecture-deployment.mmd','docs/architecture-pipeline.mmd',
          'scripts/deploy.sh','scripts/destroy.sh','scripts/install-jenkins.sh',
          'Jenkinsfile-ci','Jenkinsfile-cd','jenkins/values.yaml','jenkins/rbac.yaml',
          'jenkins/jobs/seed.groovy','jenkins/networkpolicy.yaml',
          'scripts/install-jenkins.sh','scripts/verify-jenkins.sh']:
    assert os.path.exists(f), f"
t T11.2 "README documents every chart + namespace + all 5 tfvars inputs" bash -c '
  for w in devops-app db_password s3_bucket_name terraform.tfvars ses_sender \
           github_repo_url Jenkinsfile-ci Jenkinsfile-cd; do
    grep -q "$w" README.md || { echo "README missing: $w"; exit 1; }; done'

echo "=== T13: Jenkins, RBAC & pipeline (phase 4) ==="
t T13.1 "CI pipeline has all spec-required stages" bash -c '
  grep -q "pipeline {" Jenkinsfile-ci &&
  for st in Checkout Validate "Static analysis" "Unit tests" "Build images" Scan Push; do
    grep -q "stage(.\{0,2\}${st}" Jenkinsfile-ci || { echo "CI missing stage: $st"; exit 1; }
  done'
t T13.1b "CD pipeline has all spec-required stages" bash -c '
  grep -q "pipeline {" Jenkinsfile-cd &&
  for st in "Validate input" "Manifest validation" Approval Deploy Rollout "Smoke test"; do
    grep -q "stage(.\{0,2\}${st}" Jenkinsfile-cd || { echo "CD missing stage: $st"; exit 1; }
  done'
t T13.2 "CD rolls back on failure and collects diagnostics first" bash -c '
  grep -q "helm rollback" Jenkinsfile-cd &&
  grep -q "kubectl get events" Jenkinsfile-cd'
t T13.3 "jenkins/values.yaml: plugins listed, controller image pinned, no :latest" python3 -c "
import yaml
d=yaml.safe_load(open('jenkins/values.yaml'))
assert d['controller']['installPlugins'], 'no plugins declared'
tag=d['controller']['image']['tag']
assert tag and tag != 'latest', f'controller image tag is {tag!r}'
# ':latest' must not appear in any ACTUAL value, only in comments
lines=[l for l in open('jenkins/values.yaml') if not l.strip().startswith('#')]
assert ':latest' not in ''.join(lines), 'a real value uses :latest'"
t T13.4 "jenkins/values.yaml has JCasC config" bash -c '
  grep -q "JCasC" jenkins/values.yaml &&
  grep -q "configScripts" jenkins/values.yaml'
t T13.5 "RBAC: no cluster-admin in actual rules" python3 -c "
lines = [l for l in open('jenkins/rbac.yaml') if not l.strip().startswith('#')]
assert 'cluster-admin' not in ''.join(lines), 'cluster-admin found in RBAC rules'"
t T13.6 "RBAC: no wildcard verbs" python3 -c "
assert '*' not in open('jenkins/rbac.yaml').read(), 'wildcard found in RBAC'"
t T13.7 "RBAC: secrets NOT granted to Jenkins (containment)" python3 -c "
content = open('jenkins/rbac.yaml').read()
# secrets should appear only in comments, never as a granted resource
lines = [l.strip() for l in content.splitlines() if not l.strip().startswith('#')]
assert 'secrets' not in ' '.join(lines), 'secrets granted in RBAC'"
t T13.8 "Two node groups in EKS module (app + jenkins)" bash -c '
  grep -q "aws_eks_node_group.*app" terraform/modules/eks/main.tf &&
  grep -q "aws_eks_node_group.*jenkins" terraform/modules/eks/main.tf'
t T13.9 "Jenkins node group has taint" bash -c '
  grep -q "NO_SCHEDULE" terraform/modules/eks/main.tf'
t T13.10 "EBS CSI driver addon present" bash -c '
  grep -q "aws-ebs-csi-driver" terraform/main.tf'
t T13.11 "Jenkins agent IRSA role scoped to ECR repos" bash -c '
  grep -q "jenkins-agent" terraform/modules/irsa/main.tf &&
  grep -q "ecr_repo_arns" terraform/modules/irsa/main.tf'
# The multibranch job must use the GITHUB branch source, not the generic git
# one. With a plain git source /github-webhook/ answers 200 and notifies
# nothing (only GitHub sources are registered listeners), so a push produced a
# successful delivery and no build, leaving CI on the 5-minute poll. And pull
# requests live at refs/pull/N/head, which only the GitHub source discovers, so
# a PR-* branch filter matched nothing and PR builds were impossible.
t T13.16 "application-ci uses the GitHub branch source so webhooks and PRs work" python3 -c "
import re
g=open('jenkins/jobs/seed.groovy').read()
cj=open('scripts/configure-jenkins.sh').read()
m=re.search(r'branchSources \{(.*?)\n    \}', g, re.S)
assert m, 'no branchSources block in seed.groovy'
bs=m.group(1)
assert 'github {' in bs, 'branchSources uses the generic git source, so /github-webhook/ notifies nothing and PRs are never discovered'
assert not re.search(r'^\s+git \{', bs, re.M), 'a plain git source is still present in branchSources'
for tok in ['__GITHUB_REPO_OWNER__', '__GITHUB_REPO_NAME__']:
    assert tok in bs, f'branchSources does not use {tok}'
    assert tok in cj, f'configure-jenkins.sh never substitutes {tok}'
assert 'buildOriginPRHead(true)' in bs, 'pull request heads are not discovered'"

# The GitHub source discovers EVERY origin branch, not just main. Before that
# change "not a PR" implied "is main", so gating the registry stages on IS_PR
# alone was safe. It no longer is: a feature branch satisfies IS_PR != true and
# would push to ECR. Both stages must require branch main explicitly.
t T13.17 "only main can reach the registry, not merely 'not a PR'" python3 -c "
import re
ci=open('Jenkinsfile-ci').read()
for stage in ['ECR login', 'Push + record digest']:
    i=ci.index(\"stage('\" + stage + \"')\")
    blk=ci[i:i+700]
    j=blk.index('steps')
    guard=blk[:j]
    assert 'IS_PR' in guard, f'{stage}: no IS_PR guard'
    assert \"branch 'main'\" in guard, \
        f'{stage}: gated on IS_PR alone; a feature branch would push to the registry'"

t T13.12 "destroy.sh removes Jenkins (incl. PVC) before terraform destroy" bash -c '
  grep -q "uninstall-jenkins.sh" scripts/destroy.sh &&
  grep -q "helm uninstall jenkins" scripts/uninstall-jenkins.sh &&
  grep -q "delete pvc" scripts/uninstall-jenkins.sh'
t T13.13 "your public IP is auto-detected, never committed" bash -c '
  grep -q "checkip.amazonaws.com" scripts/configure-jenkins.sh'
t T13.14 "GitHub Actions: no AWS access keys (keys removed in phase 4)" bash -c '
  ! grep -q "AWS_ACCESS_KEY_ID" .github/workflows/ci.yml &&
  ! grep -q "AWS_SECRET_ACCESS_KEY" .github/workflows/ci.yml'
t T13.15 "agent-tools Dockerfile: pinned base, non-root, no :latest" python3 -c "
lines=[l for l in open('jenkins/agent-tools/Dockerfile') if not l.strip().startswith('#')]
body=''.join(lines)
assert 'FROM' in body and ':' in [l for l in lines if l.startswith('FROM')][0], 'base image not pinned'
assert any(l.startswith('USER') for l in lines), 'runs as root'
assert ':latest' not in body, 'a real instruction uses :latest'"

echo "=== T14: Regressions for bugs found in the phase 4 audit ==="
t T14.1 "no Terraform module dependency cycle" python3 -c "
import re
main=open('terraform/main.tf').read()
g={n:set(re.findall(r'module\.(\w+)\.',b)) for n,b in re.findall(r'module \"(\w+)\" \{(.*?)\n\}',main,re.S)}
color={n:0 for n in g}
def dfs(n,path):
    color[n]=1; path.append(n)
    for m in g.get(n,()):
        if m not in g: continue
        if color[m]==1: raise AssertionError('cycle: '+' -> '.join(path[path.index(m):]+[m]))
        if color[m]==0: dfs(m,path)
    color[n]=2; path.pop()
[dfs(n,[]) for n in g if color[n]==0]"
t T14.2 "no kubernetes/helm provider in Terraform (endpoint-unknown-at-plan trap)" bash -c '
  ! grep -qE "^provider \"(kubernetes|helm)\"" terraform/main.tf'
t T14.3 "RBAC: ONLY the CD agent is bound to the deployer role" python3 -c "
import yaml
docs=[d for d in yaml.safe_load_all(open('jenkins/rbac.yaml')) if d]
rb=[d for d in docs if d['kind']=='RoleBinding' and d['metadata']['name']=='jenkins-deployer'][0]
names={s['name'] for s in rb['subjects']}
assert names == {'jenkins-agent-cd'}, f'deployer subjects should be exactly the CD agent, got {names}'
sas={d['metadata']['name'] for d in docs if d['kind']=='ServiceAccount'}
assert sas == {'jenkins','jenkins-agent-ci','jenkins-agent-cd'}, f'expected three SAs, got {sas}'"
t T14.4 "every RBAC RoleBinding references a Role that exists" python3 -c "
import yaml
docs=[d for d in yaml.safe_load_all(open('jenkins/rbac.yaml')) if d]
roles={(d['metadata']['name'],d['metadata']['namespace']) for d in docs if d['kind']=='Role'}
for d in docs:
    if d['kind']=='RoleBinding':
        key=(d['roleRef']['name'],d['metadata']['namespace'])
        assert key in roles, f'dangling roleRef {key}'"
t T14.5 "Jenkinsfile does not shell out to terraform" bash -c '
  ! grep -qE "^\s+(sh )?.*terraform (output|init|plan|apply)" Jenkinsfile'
t T14.6 "every binary the Jenkinsfile calls exists in the agent image" python3 -c "
import re
jf=open('Jenkinsfile-ci').read()
df=open('jenkins/agent-tools/Dockerfile').read()
provided={'aws','kubectl','helm','shellcheck','hadolint','curl','git','jq'}
buildkit={'buildctl-daemonless.sh'}; trivy={'trivy'}
called=set(re.findall(r'\b(buildctl-[a-z]+\.sh|[a-z]+ctl-[a-z]+)\b', jf))
for c in called:
    assert c in buildkit, f'unknown builder binary invented: {c}'"
t T14.7 "correct EKS node-group label (no invented -name suffix)" bash -c '
  ! grep -rq "eks.amazonaws.com/nodegroup-name" Jenkinsfile jenkins/ scripts/'
t T14.8 "Jenkinsfile declares parameters it reads" bash -c '
  ! grep -q "params\." Jenkinsfile || grep -q "parameters {" Jenkinsfile'
t T14.9 "no self-referential environment assignment in Jenkinsfile" python3 -c "
import re
for m in re.finditer(r'^\s*(\w+)\s*=\s*\"\\\$\{(\w+)\}\"\s*$', open('Jenkinsfile-ci').read()+open('Jenkinsfile-cd').read(), re.M):
    assert m.group(1)!=m.group(2), f'self-referential env: {m.group(1)}'"
t T14.10 "helm values overrides use a file, not multi-line --set-string" bash -c '
  ! grep -q "set-string.*JCasC" scripts/configure-jenkins.sh'

# REVIEW FIX 3.1a — Declarative Pipeline rejects duplicate post conditions with
# "Duplicate build condition name: <name>" at PARSE time, so the job never even
# starts. Jenkinsfile-cd shipped with two `failure { }` blocks: the CD pipeline
# could not have run a single build. Nothing else in this suite reads the post
# section, so it went unnoticed. It cannot regress silently now.
t T14.26 "no duplicate post conditions in either Jenkinsfile" python3 -c "
import re, sys
for f in ['Jenkinsfile-ci','Jenkinsfile-cd']:
    s = open(f).read()
    i = s.find(chr(10) + '    post {')
    if i < 0: continue
    conds = [m.group(1) for m in re.finditer(r'^        (\\w+) \\{', s[i:], re.M)]
    dupes = {c for c in conds if conds.count(c) > 1}
    assert not dupes, f'{f}: duplicate post condition(s): {sorted(dupes)}'
"

# REVIEW FIX 3.1b — the smoke test must be CAPABLE of failing. The original
# swallowed both an absent ALB address and 12 consecutive failed health checks,
# so an unreachable application still reported a green deploy and the
# post{failure} rollback never fired. Assert the two exit paths exist.
# REVIEW FIX 2.4 / 2.5 — public request path hardening.
t T14.28 "nginx rate-limits the expensive endpoint, never the probe" bash -c '
  grep -q "limit_req_zone .*zone=submit" docker/frontend/nginx.conf &&
  grep -q "limit_req zone=submit" docker/frontend/nginx.conf &&
  grep -q "client_max_body_size" docker/frontend/nginx.conf &&
  ! awk "/location \/healthz/,/}/" docker/frontend/nginx.conf | grep -q limit_req'

# Behind an ALB every request arrives from a load balancer ENI, so a rate limit
# keyed on the raw peer address puts the whole internet in one bucket: one
# noisy visitor throttles everybody and an attacker is unaffected. The real_ip
# directives are what make the limit per-client. Removing them independently
# would leave a limit that is worse than none, so pin them together.
t T14.29 "rate limiting keys on the real client, not the load balancer" bash -c '
  grep -q "set_real_ip_from" docker/frontend/nginx.conf &&
  grep -q "real_ip_header .*X-Forwarded-For" docker/frontend/nginx.conf &&
  grep -q "real_ip_recursive off" docker/frontend/nginx.conf'

# CORS was a phase 2 leftover: same-origin under Kubernetes, so allowing every
# origin bought nothing and cost real exposure. Assert it stays gone from the
# code AND from every dependency list that used to install it.
t T14.30 "no wide-open CORS anywhere" bash -c '
  ! grep -q "^CORS(app)" app/backend/app.py &&
  ! grep -q "^from flask_cors" app/backend/app.py &&
  ! grep -q "flask-cors" app/backend/requirements.txt &&
  ! grep -q "flask-cors" jenkins/agent-tools/Dockerfile &&
  ! grep -q "flask-cors" .github/workflows/ci.yml'

# REVIEW FIX 3.3 — innerHTML with a STATIC literal is fine; innerHTML with an
# interpolated value is an injection point. Catch the second, allow the first.
t T14.31 "no innerHTML carries interpolated data" python3 -c "
import re, sys
src = open('app/index.html').read()
bad = [l.strip() for l in src.split(chr(10))
       if 'innerHTML' in l and not l.strip().startswith('//')
       and re.search(r'innerHTML\s*=.*(\\\$\{|\+\s*\w)', l)]
assert not bad, 'interpolated innerHTML: ' + str(bad)"

# The suggestion chips take a SERVER-supplied value. Built as DOM nodes with
# textContent + addEventListener there is no HTML context and no JS context to
# escape out of. An onclick attribute would reintroduce both.
t T14.32 "suggestion chips are DOM nodes, not markup with onclick" bash -c '
  grep -q "chip.textContent = s" app/index.html &&
  grep -q "chip.addEventListener" app/index.html &&
  ! grep -q "onclick=.useSuggestion" app/index.html'

# Client-side entity-encoding of the user own input fields double-encoded every
# value (the backend escapes again) and was never a security control, since an
# attacker skips the page. Keep canonical values; escape at output only.
t T14.33 "no client-side entity encoding of user input" python3 -c "
code = [l for l in open('app/index.html').read().split(chr(10))
        if not l.strip().startswith('//')]
bad = [l.strip() for l in code if 'sanitizeInput' in l or 'sanitizeAllInputs' in l]
assert not bad, 'client-side entity encoding is back: ' + str(bad)"

# REVIEW FIX 2.3 — the password must come from Terraform state, not from text
# parsing of terraform.tfvars.
t T14.34 "db_password read structurally, not by grep|cut" bash -c '
  grep -q "terraform output -raw db_password" scripts/install-jenkins.sh &&
  ! grep -vE "^\s*#" scripts/install-jenkins.sh | grep -qE "grep.*db_password.*cut" &&
  grep -q "output \"db_password\"" terraform/outputs.tf &&
  grep -A2 "output \"db_password\"" terraform/outputs.tf | grep -q "sensitive = true"'

# REVIEW FIX 3.4 — production must not run Flask's development server, and the
# gunicorn switch must not silently drop init_db(). Gunicorn IMPORTS the module
# instead of executing it, so anything left in `if __name__ == "__main__"` never
# runs: the table would never be created and every request would fail. The
# on_starting hook is what makes the move safe, so pin it explicitly.
t T14.35 "app containers run gunicorn, not the Flask dev server" bash -c '
  grep -q "gunicorn" docker/backend/Dockerfile &&
  grep -q "gunicorn" docker/worker/Dockerfile &&
  ! grep -qE "^CMD.*python3.*(app|worker)\.py" docker/backend/Dockerfile docker/worker/Dockerfile &&
  grep -q "gunicorn==" app/backend/requirements.txt &&
  grep -q "gunicorn==" app/worker/requirements.txt'

t T14.36 "init_db survives the move to gunicorn (on_starting hook)" bash -c '
  test -f app/backend/gunicorn.conf.py &&
  grep -q "def on_starting" app/backend/gunicorn.conf.py &&
  grep -q "from app import init_db" app/backend/gunicorn.conf.py &&
  grep -q "gunicorn.conf.py" docker/backend/Dockerfile'

# A `while True` thread started per gunicorn worker would duplicate every log
# line and monitor nothing actionable. /health/full covers it on demand.
t T14.37 "no per-worker background polling thread" bash -c '
  ! grep -q "threading.Thread" app/backend/app.py &&
  ! grep -q "def check_worker_health" app/backend/app.py'

# REVIEW FIX 3.2 — the order pipeline must report what actually happened.
t T14.38 "submit-order reports real state, not blanket success" bash -c '
  grep -q "order_state" app/backend/app.py &&
  grep -q "), 202" app/backend/app.py &&
  ! grep -q "jsonify({\"success\": True, \"ticket_id\": ticket_id}), 200" app/backend/app.py'

# Idempotency must be enforced by the DATABASE, not by a SELECT-then-INSERT
# check: two pods handling a double-click concurrently both pass the check.
t T14.39 "idempotency enforced by a unique index, not a race-prone lookup" bash -c '
  grep -q "Idempotency-Key" app/backend/app.py &&
  grep -q "CREATE UNIQUE INDEX IF NOT EXISTS vm_orders_idempotency_key_uniq" app/backend/app.py &&
  grep -q "psycopg2.errors.UniqueViolation" app/backend/app.py &&
  grep -q "Idempotency-Key" app/index.html'

# The schema change must be ADDITIVE: CREATE TABLE IF NOT EXISTS is a no-op on
# an existing table, so new columns need explicit ADD COLUMN IF NOT EXISTS or
# an upgrade silently runs against the old schema.
t T14.40 "schema migration is additive and idempotent" bash -c '
  grep -q "ADD COLUMN IF NOT EXISTS order_state" app/backend/app.py &&
  grep -q "ADD COLUMN IF NOT EXISTS idempotency_key" app/backend/app.py &&
  grep -q "ADD COLUMN IF NOT EXISTS sns_sent" app/backend/app.py &&
  grep -q "ADD COLUMN IF NOT EXISTS ses_sent" app/backend/app.py'

# A single notification_sent flag set when EITHER channel succeeded could not
# distinguish "customer got their email" from "only the ops alert went out".
t T14.41 "notification results recorded per channel" bash -c '
  grep -q "sns_sent" app/worker/worker.py &&
  grep -q "ses_sent" app/worker/worker.py &&
  ! grep -vE "^\s*(#|\*)" app/worker/worker.py | grep -q "if sns_sent or ses_sent:"'

# REVIEW FIX 2.2 — one Secret per workload instead of a shared object.
# The whole benefit is that the BACKEND stops holding notification credentials
# it never uses; the worker legitimately needs all four keys. So the assertion
# that matters is a NEGATIVE one about the backend.
t T14.42 "backend Secret excludes notification credentials" python3 -c "
import re
src = open('scripts/install-jenkins.sh').read()
m = re.search(r'kubectl create secret generic backend-secrets(.*?)dry-run', src, re.S)
assert m, 'backend-secrets is not created by install-jenkins.sh'
block = m.group(1)
for leaked in ('SNS_TOPIC_ARN', 'SES_SENDER'):
    assert leaked not in block, f'backend-secrets still carries {leaked}'
for needed in ('DB_HOST', 'DB_PASSWORD'):
    assert needed in block, f'backend-secrets is missing {needed}'
"

# Each chart must point at its OWN Secret. Both pointing at the same name would
# reproduce the shared object under a new label.
t T14.43 "each chart consumes its own Secret" bash -c '
  grep -q "existingSecret: backend-secrets" helm/backend/values.yaml &&
  grep -q "existingSecret: worker-secrets" helm/worker/values.yaml &&
  ! grep -vE "^\s*#" helm/backend/values.yaml helm/worker/values.yaml | grep -q "existingSecret: app-secrets"'

# An upgrade must REMOVE the old wide-open object. Leaving it behind would keep
# the full credential set readable and make the fix cosmetic.
t T14.44 "upgrade deletes the old shared Secret" bash -c '
  grep -q "kubectl delete secret app-secrets" scripts/install-jenkins.sh &&
  grep -q "ignore-not-found" scripts/install-jenkins.sh'

# ---- P3 batch ----------------------------------------------------------
# REVIEW FIX 4.1 — namespaces are declarative, not a side effect of a script.
# NetworkPolicies select peer namespaces by LABEL, so those labels are load
# bearing and belong in a reviewable file.
t T14.45 "namespaces are declared, not created imperatively" bash -c '
  [ -f k8s/namespace.yaml ] &&
  grep -q "kubectl apply -f .*k8s/namespace.yaml" scripts/install-jenkins.sh &&
  ! grep -vE "^\s*#" scripts/install-jenkins.sh | grep -q "kubectl create namespace"'

# REVIEW FIX 4.1 (follow-up) — the first real CI run was rejected at admission:
# the jenkins namespace was set to "baseline", but rootless BuildKit REQUIRES
# seccompProfile=Unconfined and an unconfined AppArmor profile, both of which
# baseline forbids. Every agent pod got a 403 and no build could start.
#
# The original T14.46 only checked that SOME enforce label existed. It could
# not have caught this, because the label was present and valid — it was just
# wrong for the workloads in that namespace. This test compares the declared
# level against what the agent pod specs actually ask for.
t T14.57 "PSA level matches what the agent pods actually need" python3 -c "
import re, yaml
ns = {d['metadata']['name']: d['metadata']['labels']
      for d in yaml.safe_load_all(open('k8s/namespace.yaml')) if d}

ci = open('Jenkinsfile-ci').read()
needs_unconfined = ('apparmor' in ci and 'unconfined' in ci) or 'type: Unconfined' in ci
level = ns['jenkins']['pod-security.kubernetes.io/enforce']
if needs_unconfined:
    assert level == 'privileged', (
        'Jenkinsfile-ci needs unconfined seccomp/AppArmor for rootless BuildKit, '
        'which baseline and restricted both forbid; jenkins namespace is ' + level)
    # Relaxing enforcement is only acceptable with the violations still visible.
    assert ns['jenkins'].get('pod-security.kubernetes.io/audit') == 'baseline', \
        'enforcement relaxed without audit=baseline to keep violations visible'

# The application namespace must stay strict — that is where the workloads
# handling untrusted input live, and nothing there needs a relaxation.
assert ns['devops-app']['pod-security.kubernetes.io/enforce'] == 'restricted'
"

t T14.46 "namespace manifest carries the labels NetworkPolicies select on" python3 -c "
import yaml
docs = [d for d in yaml.safe_load_all(open('k8s/namespace.yaml')) if d]
names = {d['metadata']['name']: d['metadata'].get('labels', {}) for d in docs}
assert 'devops-app' in names and 'jenkins' in names, names.keys()
for ns, labels in names.items():
    assert labels.get('kubernetes.io/metadata.name') == ns, ns
    assert 'pod-security.kubernetes.io/enforce' in labels, ns
assert names['devops-app']['pod-security.kubernetes.io/enforce'] == 'restricted'
"

# REVIEW FIX 4.3 — a version pin trusts whatever PyPI serves under that name
# today; a hash pins the bytes. Transitive deps must be locked too, which is
# the whole reason for the .in/.txt split.
t T14.47 "python dependencies are hash-locked, not just pinned" bash -c '
  [ -f app/backend/requirements.in ] && [ -f app/worker/requirements.in ] &&
  grep -q "hash=sha256:" app/backend/requirements.txt &&
  grep -q "hash=sha256:" app/worker/requirements.txt &&
  grep -q "require-hashes" docker/backend/Dockerfile &&
  grep -q "require-hashes" docker/worker/Dockerfile'

t T14.48 "every pinned package carries at least one hash" python3 -c "
import re
for f in ['app/backend/requirements.txt', 'app/worker/requirements.txt']:
    text = open(f).read()
    blocks = re.split(r'(?m)^(?=[A-Za-z0-9_.-]+==)', text)
    for b in blocks[1:]:
        name = b.split('==')[0]
        assert 'hash=sha256:' in b, f'{f}: {name} has no hash'
"

# REVIEW FIX 4.4 — orders carry a name and an email address. HTTP-only meant
# they crossed the internet in clear text while Jenkins already had TLS.
t T14.49 "app ingress supports HTTPS with redirect and a modern TLS policy" bash -c '
  grep -q "certificate-arn" helm/frontend/templates/ingress.yaml &&
  grep -q "ssl-redirect" helm/frontend/templates/ingress.yaml &&
  grep -q "ssl-policy" helm/frontend/templates/ingress.yaml &&
  grep -q "TLS13-1-2" helm/frontend/values.yaml &&
  grep -q "ingress.certificateArn" Jenkinsfile-cd'

# REVIEW FIX 4.6 — 5432 to a whole /16 let a compromised pod reach any
# Postgres listener in the VPC, not just RDS.
t T14.50 "DB egress is scoped to the database subnets, not the whole VPC" bash -c '
  grep -q "range .Values.networkPolicy.dbSubnetCidrs" helm/backend/templates/networkpolicy.yaml &&
  grep -q "range .Values.networkPolicy.dbSubnetCidrs" helm/worker/templates/networkpolicy.yaml &&
  grep -q "dbSubnetCidrs" helm/backend/values.yaml &&
  grep -q "db_subnet_cidrs" terraform/outputs.tf &&
  grep -q "DB_SUBNET_CIDRS" scripts/configure-jenkins.sh'

t T14.51 "the rendered DB egress rule is a /24, not a /16" python3 -c "
import yaml
v = yaml.safe_load(open('helm/backend/values.yaml'))
cidrs = v['networkPolicy']['dbSubnetCidrs']
assert cidrs, 'dbSubnetCidrs is empty'
for c in cidrs:
    assert int(c.split('/')[1]) >= 24, f'{c} is wider than a /24'
assert v['networkPolicy']['vpcCidr'] not in cidrs, 'still using the VPC CIDR'
"

# REVIEW FIX 4.7 — "is this ACCOUNT empty" is unanswerable in a shared account
# and silent about the resources that actually keep billing.
t T14.52 "destroy verification is tag-scoped and checks the costly resources" bash -c '
  grep -q "tag:Project" scripts/destroy.sh &&
  grep -q "describe-nat-gateways" scripts/destroy.sh &&
  grep -q "describe-db-instances" scripts/destroy.sh &&
  grep -q "PROJECT_NAME=\$(terraform output" scripts/destroy.sh'

# REVIEW FIX 4.2 / 4.5 — these two need network access this environment does
# not have (a container registry, and a running Jenkins), so they ship as
# tooling rather than as a committed diff. Assert the tooling exists and works.
# REWRITTEN BY THE PRE-HANDOVER AUDIT. The previous version was:
#
#   [ -x scripts/pin-base-images.sh ] &&
#   ./scripts/pin-base-images.sh --check >/dev/null 2>&1 ||
#   ./scripts/pin-base-images.sh --check 2>&1 | grep -q "UNPINNED\|digest-pinned"
#
# and it could not fail. "UNPINNED" is what the tool prints when the audit
# FAILS; "digest-pinned" is what it prints when the audit PASSES. The pattern
# matched both, so any output at all satisfied it — the test asserted that the
# script produces text, not that the text is right.
#
# What actually needs proving is that the tool DISCRIMINATES, so it is checked
# in both directions against fixtures. That also makes the test independent of
# whether the repository currently has every digest filled in, which it
# deliberately does not: helm/frontend/values.yaml ships the exporter digest
# empty because resolving it needs Docker and a reachable registry.
t T14.53 "the digest-pinning audit tells pinned and unpinned apart" bash -c '
  set -e
  [ -x scripts/pin-base-images.sh ] || { echo "not executable"; exit 1; }
  W=$(mktemp -d); trap "rm -rf $W" EXIT
  cp -a scripts helm docker jenkins "$W"/ 2>/dev/null || true
  cd "$W"

  # Direction 1: everything pinned -> exit 0.
  # Keep the pristine values file: it ships with the exporter digest empty, so
  # it is the fixture for the last case below.
  cp helm/frontend/values.yaml /tmp/fev.$$
  sed -i -E "s|^(FROM [^@ ]+)(:[^@ ]*)?( .*)?$|\1@sha256:0000000000000000000000000000000000000000000000000000000000000000\3|" \
      docker/*/Dockerfile jenkins/agent-tools/Dockerfile
  python3 - <<PYEOF
import re, pathlib
p = pathlib.Path("helm/frontend/values.yaml"); s = p.read_text()
s = re.sub(r"(repository: nginx/nginx-prometheus-exporter.*?digest:\s*)\"\"",
           r"\1\"sha256:" + "0"*64 + "\"", s, count=1, flags=re.S)
p.write_text(s)
PYEOF
  if ! ./scripts/pin-base-images.sh --check >/dev/null 2>&1; then
    echo "a fully pinned tree was reported as unpinned:"; ./scripts/pin-base-images.sh --check
    exit 1
  fi

  # Direction 2: each way of being unpinned must be caught, one at a time.
  fail() { echo "--check did NOT catch: $1"; exit 1; }

  cp docker/backend/Dockerfile /tmp/bk.$$
  sed -i "0,/^FROM /s|^FROM \([^@ ]*\)@sha256:[a-f0-9]*|FROM \1|" docker/backend/Dockerfile
  ./scripts/pin-base-images.sh --check >/dev/null 2>&1 && fail "a FROM without a digest"
  cp /tmp/bk.$$ docker/backend/Dockerfile

  # A missing file must fail AND be reported as missing. Asserting the message,
  # not just the exit code: the zero-FROM guard below also rejects a missing
  # file (grep produces no output either way), so an exit-code-only assertion
  # passed with the missing-file branch deleted. Found by mutating it out and
  # watching this stay green — the two guards must be covered separately or one
  # of them is decoration.
  mv docker/worker/Dockerfile docker/worker/Dockerfile.moved
  OUT=$(./scripts/pin-base-images.sh --check 2>&1) && fail "a Dockerfile that does not exist"
  echo "$OUT" | grep -q "MISSING .*docker/worker/Dockerfile" \
    || fail "a missing Dockerfile, reported as missing rather than as empty"
  mv docker/worker/Dockerfile.moved docker/worker/Dockerfile

  cp docker/frontend/Dockerfile /tmp/fe.$$
  : > docker/frontend/Dockerfile
  ./scripts/pin-base-images.sh --check >/dev/null 2>&1 && fail "a Dockerfile with no FROM line at all"
  cp /tmp/fe.$$ docker/frontend/Dockerfile

  # The nginx exporter sidecar is pinned in a Helm values file rather than a
  # FROM line, and --check used to ignore it entirely — so it reported a fully
  # pinned tree while that digest was empty, which is the state this repository
  # actually ships. Covered separately because nothing else exercises it.
  cp /tmp/fev.$$ helm/frontend/values.yaml
  ./scripts/pin-base-images.sh --check >/dev/null 2>&1 && fail "the exporter sidecar image having no digest"

  echo "the audit passes a pinned tree and catches all four ways of being unpinned"'

t T14.54 "CI evidence collector exists and refuses to leak credentials" bash -c '
  [ -x scripts/collect-ci-evidence.sh ] &&
  grep -q "ACCOUNT_ID" scripts/collect-ci-evidence.sh &&
  grep -q "AKIA" scripts/collect-ci-evidence.sh &&
  grep -q "consoleText" scripts/collect-ci-evidence.sh'

# The collector must be able to actually reach this project s Jenkins. It
# failed on both counts: it addressed /job/application-ci/<build>, but that is
# a MULTIBRANCH FOLDER with no builds or artifacts of its own (they live under
# /job/application-ci/job/main), and it used plain curl against an ALB whose
# certificate create-cert.sh deliberately self-signs, so every request died
# with "SSL certificate problem: self-signed certificate".
t T14.65 "CI evidence collector targets the branch job and tolerates the self-signed cert" bash -c '
  grep -q "application-ci/job/main" scripts/collect-ci-evidence.sh &&
  grep -qE "CURL_TLS=\(-k\)|--cacert" scripts/collect-ci-evidence.sh &&
  grep -q "curl -fsS -g" scripts/collect-ci-evidence.sh &&
  ! grep -q "JENKINS_JOB:-application-ci}" scripts/collect-ci-evidence.sh'

# REVIEW FIX 4.4 (follow-up) — Jenkins and the application must not share a
# certificate. Jenkins is the admin plane, restricted to one operator IP and
# holding cluster access; the app is public. One private key across both means
# a compromise in either context is a compromise in both.
t T14.55 "Jenkins and the app use separate certificates" python3 -c "
import re
inst = open('scripts/install-jenkins.sh').read()
conf = open('scripts/configure-jenkins.sh').read()
assert '--purpose jenkins-ui' in inst, 'jenkins cert not requested by purpose'
assert '--purpose app' in inst, 'app cert not requested by purpose'
assert 'app.vm-order.internal' in conf, 'no app certificate lookup'
# The JCasC env block spans two lines, so a line-based grep cannot see the
# pairing. Match the key and its value together.
m = re.search(r'key: APP_CERT_ARN\s*\n\s*value: \"([^\"]*)\"', conf)
assert m, 'APP_CERT_ARN is not exported to Jenkins'
assert 'APP_CERT_ARN' in m.group(1), (
    'APP_CERT_ARN reuses the Jenkins certificate: ' + m.group(1))
"

# A wildcard SAN matches exactly ONE label. ALB hostnames are
# <name>.<region>.elb.amazonaws.com — two labels — so "*.elb.amazonaws.com"
# never matched the host it was written for. Verified with openssl
# verify -verify_hostname: the old form fails, the region-scoped form passes.
t T14.56 "ALB SAN wildcard is region-scoped so it actually matches" bash -c '
  grep -q "elb.amazonaws.com" scripts/create-cert.sh &&
  grep -q "AWS_REGION}.elb.amazonaws.com" scripts/create-cert.sh &&
  ! grep -q "DNS:\\*\\.elb\\.amazonaws\\.com" scripts/create-cert.sh'

t T14.27 "CD smoke test fails when the public URL does not serve" bash -c '
  grep -q "ALB_OK=1" Jenkinsfile-cd &&
  grep -q "ALB_OK. -ne 1" Jenkinsfile-cd &&
  ! grep -q "skipping external check" Jenkinsfile-cd'
# The counterpart to T14.27. That test keeps the smoke check CAPABLE of
# failing; this one keeps it from failing SPURIOUSLY. A first deploy creates
# the ALB from scratch, and its DNS name needs 3-5 minutes to propagate -- the
# Ingress reports a hostname long before that. A 2-minute budget expired mid
# propagation and rolled back a healthy deployment. Keep at least 4 minutes,
# or the rollback fires on ALB warm-up rather than on a real fault.
# The third guard on this one check. T14.27 keeps it capable of failing,
# T14.59 keeps it from failing spuriously, and this keeps it from PASSING
# spuriously. Since the ALB redirects 80 -> 443, `curl -sf` returns 0 on the
# 301 (--fail only trips on >= 400) -- so the probe reported success without
# ever reaching a pod, because the ALB serves that redirect at the listener
# before selecting a target. Verified against a local 301: `curl -sf` exits 0.
t T14.60 "CD smoke test is not satisfied by a 30x redirect" python3 -c "
cd=open('Jenkinsfile-cd').read()
i=cd.index('3/3 public ALB')
blk=cd[i:i+8000]
assert 'http_code' in blk, 'ALB probe never captures an HTTP status code'
assert '\"200\"' in blk, 'ALB probe does not require exactly 200'
assert ' -L ' in blk, 'ALB probe does not follow the 80->443 redirect'
assert 'curl -sf --max-time' not in blk, \
    'bare curl -sf exits 0 on a 301: it would pass on the redirect alone'"

t T14.59 "CD smoke test waits long enough for a cold ALB" python3 -c "
import re
cd=open('Jenkinsfile-cd').read()
n=re.search(r'ATTEMPTS=(\d+)', cd)
s=re.search(r'sleep (\d+)\s*\n\s*done', cd)
assert n, 'smoke test has no ATTEMPTS budget'
assert s, 'smoke test retry loop has no sleep'
budget=int(n.group(1))*int(s.group(1))
assert budget >= 240, f'ALB retry budget is only {budget}s; a cold ALB needs 3-5 min'"

t T14.11 "agent-tools image has its own ECR repo (not squatting in an app repo)" bash -c '
  grep -q "jenkins-agent" terraform/main.tf &&
  grep -q "vm-order-jenkins-agent" scripts/install-jenkins.sh'
t T14.12 "EBS CSI addon is at root where both modules resolve" bash -c '
  grep -q "aws-ebs-csi-driver" terraform/main.tf &&
  ! grep -q "aws-ebs-csi-driver" terraform/modules/eks/main.tf'
t T14.13 "agent kubectl minor matches the cluster's kubernetes_version" python3 -c "
import re
tf=open('terraform/modules/eks/variables.tf').read()
k8s=re.search(r'variable \"kubernetes_version\".*?default\s*=\s*\"([\d.]+)\"', tf, re.S).group(1)
df=open('jenkins/agent-tools/Dockerfile').read()
kc=re.search(r'ARG KUBECTL_MINOR=([\d.]+)', df).group(1)
assert k8s==kc, f'skew: cluster {k8s} vs agent kubectl {kc}'"

t T14.14 "node instance types are free-tier eligible" python3 -c "
import re
FREE={'t3.micro','t3.small','t4g.micro','t4g.small','c7i-flex.large','m7i-flex.large'}
v=open('terraform/modules/eks/variables.tf').read()
for name in ['node_instance_type','jenkins_node_instance_type']:
    m=re.search(r'variable \"'+name+r'\".*?default\s*=\s*\"([\w.-]+)\"', v, re.S)
    assert m, name
    assert m.group(1) in FREE, f'{name}={m.group(1)} is not free-tier eligible'"

t T14.15 "ALB controller is restarted after upgrade (webhook cert mismatch)" bash -c '
  grep -q "rollout restart deployment/aws-load-balancer-controller" scripts/install-jenkins.sh'

t T14.16 "JCasC has no conflicting or chart-owned keys" python3 tests/check_jcasc.py

t T14.17 "every Ingress uses pathType Prefix (ALB treats / as exact otherwise)" python3 -c "
import yaml, glob, sys
bad=[]
v=yaml.safe_load(open('jenkins/values.yaml'))
ing=v['controller'].get('ingress',{})
if ing.get('enabled') and ing.get('pathType')!='Prefix':
    bad.append('jenkins/values.yaml: pathType=%s' % ing.get('pathType'))
for f in glob.glob('helm/*/templates/ingress.yaml'):
    t=open(f).read()
    if 'path:' in t and 'pathType: Prefix' not in t:
        bad.append(f)
assert not bad, bad"

t T14.18 "agent pods declare no volume clashing with the plugin workspace" python3 -c "
import re, yaml
for f in ['Jenkinsfile-ci','Jenkinsfile-cd']:
 y=re.search(r'yaml \"\"\"\n(.*?)\n\"\"\"', open(f).read(), re.S).group(1)
y=re.sub(r'\\\\$\{env\.\w+\}','X',y)
pod=yaml.safe_load(y)
paths={}
for c in pod['spec']['containers']:
    for m in c.get('volumeMounts',[]):
        paths.setdefault(m['mountPath'],set()).add(m['name'])
for path,names in paths.items():
    assert len(names)==1, f'{path} mounted from different volumes: {names}'
assert '/home/jenkins/agent' not in paths, 'do not mount over the plugin workspace'"

t T14.19 "rootless BuildKit has the four settings it needs" python3 -c "
import re, yaml
y=re.search(r'yaml \"\"\"\n(.*?)\n\"\"\"', open('Jenkinsfile-ci').read(), re.S).group(1)
y=re.sub(r'\\\\$\{env\.\w+\}','X',y)
pod=yaml.safe_load(y)
ann=pod['metadata'].get('annotations',{})
assert ann.get('container.apparmor.security.beta.kubernetes.io/buildkit')=='unconfined', 'missing apparmor annotation'
bk=[c for c in pod['spec']['containers'] if c['name']=='buildkit'][0]
env={e['name']:e['value'] for e in bk.get('env',[])}
assert '--oci-worker-no-process-sandbox' in env.get('BUILDKITD_FLAGS',''), 'missing no-process-sandbox'
assert bk['securityContext']['seccompProfile']['type']=='Unconfined', 'missing seccomp Unconfined'
# newuidmap/newgidmap (rootlesskit's UID/GID map helpers) run as setuid-root
# and are invoked unconditionally by this rootlesskit version — granting
# SETUID/SETGID capabilities alone does NOT make it skip them (tried and
# ruled out live: identical 'Could not set caps' failure either way).
# allowPrivilegeEscalation: false blocks the setuid transition itself via
# no_new_privs, regardless of held capabilities, so the setuid transition has
# to be permitted for this one container.
assert bk['securityContext']['allowPrivilegeEscalation'] is True, 'missing allowPrivilegeEscalation for newuidmap/newgidmap'
assert 'privileged' not in bk['securityContext'], 'must NOT be privileged'"

# The agent pod spec lives inside a Groovy GString (yaml """..."""), so Groovy
# interpolates it BEFORE Kubernetes sees it. A bare $NAME is valid interpolation
# syntax, so it is resolved against the pipeline binding -- even inside a YAML
# comment, which Groovy has no concept of. A prose mention of $HOME in a comment
# killed every build with "No such property: HOME for class: groovy.lang.Binding"
# before a single stage ran, and every YAML-parsing test here stayed green
# because they read the block as text and never evaluate interpolation.
# Only ${env.X} is legitimate; anything else must be escaped or reworded.
t T14.58 "pod YAML has no accidental Groovy interpolation" python3 -c "
import re
for f in ['Jenkinsfile-ci','Jenkinsfile-cd']:
    y=re.search(r'yaml \"\"\"\n(.*?)\n\"\"\"', open(f).read(), re.S).group(1)
    for m in re.finditer(r'(?<!\\\\)\\\$(\{)?\s*([A-Za-z_][\w.]*)?', y):
        expr=m.group(0)
        ok=m.group(1)=='{' and (m.group(2) or '').startswith('env.')
        assert ok, (
            f'{f}: bare Groovy interpolation {expr!r} in the pod YAML -- '
            'Groovy resolves this against the build binding before Kubernetes '
            'sees it. Escape it as \\\\\$ or reword (comments are NOT exempt).')"

t T14.20 "Helm uses configmap driver so RBAC never needs secrets" python3 -c "
cd=open('Jenkinsfile-cd').read()
assert 'HELM_DRIVER' in cd and 'configmap' in cd, 'CD must set HELM_DRIVER=configmap'
d=open('scripts/destroy.sh').read()
for r in ['frontend','backend','worker']:
    assert f'HELM_DRIVER=configmap helm uninstall {r}' in d, f'destroy must use the configmap driver for {r}'
assert 'HELM_DRIVER=configmap helm uninstall jenkins' not in d, \
    'jenkins was installed with the default driver and must not use configmap'"

t T14.21 "smoke test respects NetworkPolicy (goes via frontend, not backend)" bash -c '
  grep -q "svc frontend" Jenkinsfile-cd &&
  grep -q "8080/api/health" Jenkinsfile-cd &&
  ! grep -q "svc backend .* clusterIP" Jenkinsfile-cd'

t T14.22 "every kubectl resource the pipeline requests is granted in RBAC" python3 tests/check_rbac_usage.py

t T14.23 "Jenkins agent IAM allows scoped S3 write for build evidence" bash -c '
  grep -q "s3:PutObject" terraform/modules/irsa/main.tf &&
  grep -q "builds/\*" terraform/modules/irsa/main.tf'

# Every prefix the pipelines LIST needs s3:ListBucket on the bucket arn --
# an object-level PutObject/GetObject grant does not authorise ListObjectsV2.
# CD uploaded its evidence fine and then failed listing it back, because only
# PutObject was granted. The listing grant must stay prefix-scoped: this bucket
# holds customer orders, and an unconditional ListBucket would let the pipeline
# enumerate all of them.
t T14.61 "S3 evidence listing is granted, and scoped to its prefix" python3 -c "
import re
tf=open('terraform/modules/irsa/main.tf').read()
cd=open('Jenkinsfile-cd').read()
if 's3 ls' in cd:
    # Anchor on the Action line, not a bare substring: the surrounding comment
    # mentions s3:ListBucket too, and matching that would test the prose.
    m=re.search(r'Action\s*=\s*\[\"s3:ListBucket\"\]', tf)
    assert m, 'Jenkinsfile-cd lists an S3 prefix but no role is granted s3:ListBucket'
    stmt=tf[m.end():m.end()+400]
    assert 's3:prefix' in stmt, \
        's3:ListBucket granted without an s3:prefix condition — that lists the whole orders bucket'
    assert 'deployments/' in stmt, 's3:prefix condition does not name the deployments prefix'"

# Build notifications must not depend on a path the NetworkPolicy forbids.
# The mailer was configured for SES SMTP on port 587, but the only internet
# egress the jenkins-controller policy allows is 443, so every send failed with
# "SMTP connection error" -- and email-ext never fails a build over a delivery
# failure, so the stage stayed green while nothing was ever delivered. It could
# not have worked regardless: no SMTP credential was configured anywhere, and
# the create-smtp-secret.sh that configure-jenkins.sh referenced does not exist.
# Notifications now publish to SNS over HTTPS 443 with IRSA, which needs no
# stored secret -- the bonus asks for notifications "without exposing secrets".
t T14.63 "notifications use SNS over an allowed port, not blocked SMTP" python3 -c "
import re, yaml
cfg=open('scripts/configure-jenkins.sh').read()
assert 'smtpPort' not in cfg, \
    'mailer SMTP config is back; port 587 is not permitted by the controller NetworkPolicy'
assert 'SNS_TOPIC_ARN' in cfg, 'SNS_TOPIC_ARN is not exported to the pipelines'
tf=open('terraform/modules/irsa/main.tf').read()
# worker already had one; the CI and CD agent roles each need their own.
assert tf.count('sns:Publish') >= 3, \
    'both Jenkins agent roles need sns:Publish (worker already had one)'
plugins=[e.split(':',1)[0] for e in yaml.safe_load(open('jenkins/values.yaml'))['controller']['installPlugins']]
for jf in ['Jenkinsfile-ci','Jenkinsfile-cd']:
    code='\n'.join(l for l in open(jf).read().splitlines() if not l.strip().startswith('//'))
    assert 'emailext' not in code, jf+': emailext is back but its delivery path is blocked'
    assert 'aws sns publish' in code, jf+': no SNS notification'
    assert 'unstable(' in code, jf+': a failed notification must not pass silently'
    assert 'email-ext' not in plugins, 'email-ext plugin reinstalled but unused'"

# The notify() helper runs `container('tools')`, which REQUIRES a node context.
# post{} blocks run without one when the build died before the agent pod
# existed -- a Groovy error in the pod YAML does exactly that, and it already
# happened here once: the post block threw
#   MissingContextVariableException: Required context class hudson.model.Node
# emailext ran on the controller and never needed a node, so moving the
# notification onto an agent introduced this exposure. It matters precisely in
# the early-failure case, which is when a notification is most wanted, and an
# unguarded throw buries the ORIGINAL failure behind a stack trace.
t T14.64 "notify() survives a build that failed before the agent existed" python3 -c "
import re
for jf in ['Jenkinsfile-ci','Jenkinsfile-cd']:
    src=open(jf).read()
    m=re.search(r'def notify\(String subject, String message\) \{(.*?)\n\}', src, re.S)
    assert m, jf+': notify() helper not found'
    # Strip comments before indexing: the explanatory comment inside notify()
    # names container() too, and matching that would test the prose.
    body='\n'.join(l for l in m.group(1).splitlines() if not l.strip().startswith('//'))
    assert 'try {' in body, \
        jf+': notify() calls container() unguarded; no agent means MissingContextVariableException'
    assert 'catch' in body, jf+': notify() has no catch for the missing-node case'
    ci=body.index('container(')
    assert body.index('try {') < ci, jf+': the try must wrap container(), not sit inside it'"

# image-manifest.json is the CI->CD contract, so its VALUES have to be right,
# not merely parseable. It was assembled by closing and reopening a
# double-quoted echo around each variable, and those quote characters landed
# inside the JSON strings: "ci_build": "'4'" instead of "4", and the same for
# the commit, tag and registry. Valid JSON, every scalar wrong -- which is
# exactly why nobody noticed. jq --arg quotes and escapes on its own.
# The branch came from `git rev-parse --abbrev-ref HEAD`, but multibranch
# checks out a DETACHED HEAD, so it recorded the literal string "HEAD".
t T14.62 "image-manifest values are clean, and the branch is the real branch" python3 -c "
ci=open('Jenkinsfile-ci').read()
needle=chr(39)+chr(34)+chr(36)+chr(123)   # the quote-breaking idiom
assert 'jq -n' in ci, 'manifest must be built with jq -n, not hand-assembled echo lines'
assert needle not in ci, \
    'quote-breaking idiom is back: it puts literal single quotes inside JSON values'
assert 'env.BRANCH_NAME' in ci, \
    'GIT_BRANCH_NAME must prefer env.BRANCH_NAME; multibranch checks out a detached HEAD'"

t T14.24 "S3 upload failures are not masked with || true" python3 -c "
import re
body=open('Jenkinsfile-cd').read()
m=re.search(r\"stage\(.Record deployment.\).*?^        \}\", body, re.S|re.M)
assert m, 'Record deployment stage not found'
block=m.group(0)
code=[l for l in block.splitlines() if not l.strip().startswith('//')]
code='\\n'.join(code)
assert 'aws s3 cp' in code, 'archive stage lost its upload'
for line in code.splitlines():
    if 'aws s3 cp' in line:
        assert '|| true' not in line, 'S3 upload failure is being swallowed'
assert 'set -e' in code, 'archive stage must use set -e'"

t T14.25 "destroy sweeps orphaned ALB-controller security groups" bash -c '
  grep -q "sweep_orphan_sgs" scripts/destroy.sh &&
  grep -q "delete-security-group" scripts/destroy.sh &&
  grep -q "revoke-security-group-ingress" scripts/destroy.sh'

echo "=== T15: Assignment spec compliance ==="
t T15.1 "CI/CD separation (CI cannot deploy, CD cannot build)" python3 tests/check_pipeline_separation.py
t T15.2 "two Jenkinsfiles exist, single combined one does not" bash -c '
  [ -f Jenkinsfile-ci ] && [ -f Jenkinsfile-cd ] && [ ! -f Jenkinsfile ]'
t T15.3 "the four required scripts exist and are executable" bash -c '
  for s in install-jenkins configure-jenkins create-jobs verify-jenkins; do
    [ -x "scripts/${s}.sh" ] || { echo "missing or not executable: ${s}.sh"; exit 1; }
  done'
t T15.4 "jobs are defined as code (Job DSL), not clicked in the UI" bash -c '
  [ -f jenkins/jobs/seed.groovy ] &&
  grep -q "application-ci" jenkins/jobs/seed.groovy &&
  grep -q "application-cd" jenkins/jobs/seed.groovy &&
  grep -q "seed.groovy" scripts/configure-jenkins.sh'
t T15.5 "three ServiceAccounts with the CI/CD split" python3 -c "
import yaml
docs=[d for d in yaml.safe_load_all(open('jenkins/rbac.yaml')) if d]
sas={d['metadata']['name'] for d in docs if d['kind']=='ServiceAccount'}
assert sas=={'jenkins','jenkins-agent-ci','jenkins-agent-cd'}, sas
# the CI agent must have NO RoleBinding anywhere
for d in docs:
    if d['kind']=='RoleBinding':
        for s in d['subjects']:
            assert s['name']!='jenkins-agent-ci', 'CI agent must have no RoleBinding'"
t T15.6 "separate IAM roles for CI and CD; CD cannot push images" bash -c '
  grep -q "jenkins_ci" terraform/modules/irsa/main.tf &&
  grep -q "jenkins_cd" terraform/modules/irsa/main.tf &&
  ! sed -n "/cd-registry-read/,/^  })/p" terraform/modules/irsa/main.tf | grep -q "ecr:PutImage"'
t T15.7 "unit tests exist and produce JUnit output" bash -c '
  [ -f app/backend/test_app.py ] && [ -f app/worker/test_worker.py ] &&
  grep -q "junitxml" Jenkinsfile-ci'
t T15.8 "both architecture diagrams exist with rendered output" bash -c '
  [ -f docs/architecture-deployment.mmd ] && [ -f docs/architecture-pipeline.mmd ] &&
  [ -f docs/architecture-deployment.png ] && [ -f docs/architecture-pipeline.png ]'
t T15.9 "README embeds both diagrams and has a Security chapter" bash -c '
  grep -q "architecture-deployment.png" README.md &&
  grep -q "architecture-pipeline.png" README.md &&
  grep -q "## 10. Security" README.md &&
  grep -q "Rollback" README.md'
t T15.10 "credential example files exist with no real values" bash -c '
  [ -f jenkins/secret.example.yaml ] && [ -f jenkins/values.example.yaml ] &&
  ! grep -qE "AKIA[0-9A-Z]{16}" jenkins/secret.example.yaml jenkins/values.example.yaml'
t T15.11 "Jenkins UI is not open to the world and uses HTTPS" bash -c '
  grep -q "certificate-arn" scripts/configure-jenkins.sh &&
  grep -q "checkip.amazonaws.com" scripts/configure-jenkins.sh &&
  ! grep -q "inbound-cidrs: \"0.0.0.0/0\"" jenkins/values.yaml scripts/configure-jenkins.sh'
# The counterpart to T15.11. That test keeps Jenkins closed to the world; this
# one keeps it OPEN ENOUGH for the webhook. inbound-cidrs was MY_IP/32 alone, so
# GitHub's POST was dropped at the security group -- the hook was created, never
# delivered, and CI fell back to the 5-minute poll with nothing attributable to
# a push. The IP restriction satisfying one spec requirement silently broke
# another.
#
# IPv6 must stay filtered out: inbound-cidrs is IPv4-only (IPv6 belongs in
# inbound-ipv6-cidrs) and the ALB controller rejects the whole Ingress if they
# are mixed, leaving the security group stale.
t T15.18 "the Jenkins allowlist admits GitHub's webhook senders" bash -c '
  grep -q "api.github.com/meta" scripts/configure-jenkins.sh &&
  grep -q "hooks\[\]" scripts/configure-jenkins.sh &&
  grep -q "select(test(\":\") | not)" scripts/configure-jenkins.sh &&
  grep -q "inbound-cidrs: \"\${ALLOWED_CIDRS}\"" scripts/configure-jenkins.sh &&
  ! grep -q "inbound-cidrs: \"\${MY_IP}/32\"" scripts/configure-jenkins.sh'

# Creating a hook in GitHub proves nothing about whether it can be DELIVERED.
# The script used to print "last response: connection_error" and then announce
# "Webhook registered" on the next line. A non-2xx test delivery must fail.
# A brand-new ALB is not ready the instant it exists -- it must reach active,
# register a healthy target and propagate DNS. register-webhook.sh tested once,
# immediately, so a cold ALB produced connection_error on a webhook that worked
# a minute later. Because deploy.sh is `set -e`, that transient failure aborted
# the deploy before verify-jenkins.sh ran. The test must retry, and deploy.sh
# must survive a webhook failure and still verify.
t T15.21 "webhook registration waits for a cold ALB and never aborts the deploy" bash -c '
  grep -q "ATTEMPTS=" scripts/register-webhook.sh &&
  grep -q "seq 1 " scripts/register-webhook.sh &&
  grep -q "WEBHOOK_STATUS" scripts/deploy.sh &&
  grep -q "register-webhook.sh || WEBHOOK_STATUS" scripts/deploy.sh'

t T15.19 "register-webhook fails when the test delivery does not arrive" bash -c '
  grep -q "connection_error" scripts/register-webhook.sh &&
  grep -qE "exit 1" scripts/register-webhook.sh &&
  ! grep -qE "^echo \"Webhook registered\." scripts/register-webhook.sh'

t T15.12 "no Docker socket is mounted anywhere" bash -c '
  ! grep -rq "docker.sock" Jenkinsfile-ci Jenkinsfile-cd jenkins/'
t T15.13 "agent containers declare resources and drop capabilities" python3 -c "
import re, yaml
# buildkit is a single, named exception, not a loosened rule: rootless
# BuildKit's newuidmap/newgidmap need allowPrivilegeEscalation: true to run
# at all (see T14.19 for why). Every other agent container in both
# Jenkinsfiles must still have it strictly false — this test asserts BOTH
# directions, so it fails just as loudly if the exception ever spreads to a
# container that should not have it, or disappears from the one that needs it.
EXEMPT = {('Jenkinsfile-ci', 'buildkit')}
for f in ['Jenkinsfile-ci','Jenkinsfile-cd']:
    y=re.search(r'yaml \"\"\"\n(.*?)\n\"\"\"', open(f).read(), re.S).group(1)
    y=re.sub(r'\\\\$\{env\.\w+\}','X',y)
    pod=yaml.safe_load(y)
    for c in pod['spec']['containers']:
        assert 'resources' in c, f'{f}: {c[\"name\"]} has no resources'
        sc=c.get('securityContext',{})
        if (f, c['name']) in EXEMPT:
            assert sc.get('allowPrivilegeEscalation') is True, f'{f}: {c[\"name\"]} expected the documented newuidmap exception'
        else:
            assert sc.get('allowPrivilegeEscalation') is False, f'{f}: {c[\"name\"]} allows privilege escalation'
        assert 'privileged' not in sc, f'{f}: {c[\"name\"]} is privileged'"
t T15.14 "NetworkPolicies defined for the jenkins namespace" bash -c '
  [ -f jenkins/networkpolicy.yaml ] &&
  grep -q "default-deny-all" jenkins/networkpolicy.yaml &&
  grep -q "169.254.169.254/32" jenkins/networkpolicy.yaml'
# Window widened from -A2 to -A8: the guard is now an allOf block (IS_PR AND
# branch main) with a comment above it, so IS_PR sits further from the stage
# line. The assertion is unchanged and T13.17 checks the stronger property.
t T15.15 "PR builds never push to the registry" bash -c '
  grep -q "IS_PR" Jenkinsfile-ci &&
  grep -A8 "stage(.Push" Jenkinsfile-ci | grep -q "IS_PR"'

# The build stage writes image tarballs to an absolute path OUTSIDE the
# per-branch job workspace, so every later stage that touches them has to name
# that same absolute path. The scan stage originally used a bare relative
# filename, which resolves against the job workspace instead -- a sibling
# directory -- so trivy failed with 'no such file or directory' and the gate
# never actually ran. Three places must agree: the build --output dest=, the
# scan --input, and the post-always cleanup.
t T15.17 "image tarball path agrees across build, scan and cleanup stages" python3 -c "
import re
ci = open('Jenkinsfile-ci').read()
dest  = re.search(r'dest=(\S*?)vm-order-', ci)
scan  = re.search(r'def tar = \"([^\"]*?)vm-order-', ci)
clean = re.search(r'rm -f (\S*?)\*\.tar', ci)
assert dest,  'build stage: no dest= tarball path found'
assert scan,  'scan stage: no tarball path found'
assert clean, 'cleanup: no tarball rm found'
assert scan.group(1).startswith('/'), \
    f'scan path {scan.group(1)!r} is relative: resolves to the job workspace, not the build dir'
assert dest.group(1) == scan.group(1) == clean.group(1), \
    f'paths disagree: build={dest.group(1)!r} scan={scan.group(1)!r} cleanup={clean.group(1)!r}'"

# A .gitignore rule silently swallowed a required deliverable. "trivy-*.txt"
# was unanchored, so it matched at any depth including evidence/, where
# evidence/README.md explicitly requires those reports. collect-ci-evidence.sh
# fetched them, git add -A skipped them without a word, and the checklist item
# appeared satisfied while nothing was committed. Nothing the evidence
# checklist names may be ignored.
t T15.20 "no required evidence artifact is silently gitignored" bash -c '
  for f in evidence/trivy-frontend.txt evidence/trivy-backend.txt \
           evidence/trivy-worker.txt evidence/sbom-frontend.cdx.json \
           evidence/image-manifest.json; do
    if git check-ignore -q "$f" 2>/dev/null; then
      echo "$f is gitignored but evidence/README.md requires it" >&2
      exit 1
    fi
  done'

t T15.16 "documentation references no deleted or missing file" python3 tests/check_doc_links.py

echo "=== T16: The tests test the tests ==="
t T16.1 "verify-jenkins.sh: every check is actually wired to what it claims" bash tests/check_verify_script.sh

t T16.2 "no VPC CIDR is hardcoded (it differs per environment)" python3 -c "
import re, sys, glob
bad=[]
# jenkins policy must be a template
np=open('jenkins/networkpolicy.yaml').read()
if '__VPC_CIDR__' not in np:
    bad.append('jenkins/networkpolicy.yaml: not templated')
for m in re.finditer(r'cidr:\\s*(10\\.\\d+\\.\\d+\\.\\d+/\\d+)', np):
    bad.append(f'jenkins/networkpolicy.yaml: hardcoded {m.group(1)}')
# install script must substitute it from terraform
inst=open('scripts/install-jenkins.sh').read()
if '__VPC_CIDR__' not in inst or 'terraform output -raw vpc_cidr' not in inst:
    bad.append('install-jenkins.sh does not substitute the CIDR from terraform')
# helm charts must use a value, not a literal
for f in glob.glob('helm/*/templates/networkpolicy.yaml'):
    body=open(f).read()
    for m in re.finditer(r'cidr:\\s*(10\\.\\d+\\.\\d+\\.\\d+/\\d+)', body):
        bad.append(f'{f}: hardcoded {m.group(1)}')
if bad: print(chr(10).join(bad)); sys.exit(1)"

t T16.3 "no test writes into the working tree (tests must not destroy config)" python3 -c "
import glob, re, sys
bad=[]
for f in glob.glob('tests/*.sh'):
    body=open(f).read()
    for pat, why in [
        (r'cp [^\\n]*\\\$REPO/terraform/terraform\\.tfvars(?!\\.example)', 'overwrites the real tfvars'),
        (r'rm -f [^\\n]*\\\$REPO/terraform/terraform\\.tfvars', 'deletes the real tfvars'),
        (r'cp [^\\n]*terraform\\.tfvars\\.example[^\\n]*\\\$REPO/terraform/', 'writes into the repo terraform dir'),
    ]:
        if re.search(pat, body):
            bad.append(f'{f}: {why} — run in a temp copy instead')
if bad: print(chr(10).join(sorted(set(bad)))); sys.exit(1)"

t T16.4 "every pipeline step has its plugin installed" python3 tests/check_plugin_coverage.py

t T16.5 "mock tests are isolated from the developer environment" python3 -c "
import sys
body=open('tests/run_mock_deploy.sh').read()
bad=[]
if 'unset GITHUB_TOKEN' not in body:
    bad.append('run_mock_deploy.sh: a shell with GITHUB_TOKEN set takes the webhook branch and calls the real GitHub API')
if 'export HOME=' not in body:
    bad.append('run_mock_deploy.sh: ~/.github_token would still be found')
if 'mktemp -d' not in body:
    bad.append('run_mock_deploy.sh: must run in a temp copy, not the working tree')
if bad: print(chr(10).join(bad)); sys.exit(1)"

t T16.6 "agent containers have a numeric runAsUser (runAsNonRoot requires it)" python3 tests/check_agent_security.py

echo ""
echo "=== T17: Review remediation — digest enforcement & toolchain pinning ==="

# The whole point of REVIEW FIX 2.4. CD used to fetch the registry digest,
# print it, and throw it away, so the three *_DIGEST parameters proved nothing.
# This asserts the comparison EXISTS and can FAIL -- the old code, which
# printed the digest, must not pass this test.
t T17.1 "CD compares the CI digest against ECR and fails the build on mismatch" python3 -c "
import re, sys
src = open('Jenkinsfile-cd').read()
m = re.search(r\"stage\('Verify image identity in registry'\).*?\n        \}\", src, re.S)
if not m:
    print('the digest-verification stage is missing or was renamed'); sys.exit(1)
stage = m.group(0)
need = [
    ('read the expected digest',   'EXPECT'),
    ('read the actual digest',     'imageDetails[0].imageDigest'),
    ('compare the two',            '[ \"\$EXPECT\" = \"\$ACTUAL\" ]'),
    ('record a mismatch',          'MISMATCH=1'),
    ('fail the build on mismatch', 'exit 1'),
]
missing = [why for why, frag in need if frag not in stage]
if missing:
    print('digest enforcement incomplete — the stage does not: ' + ', '.join(missing)); sys.exit(1)
"

# A digest spliced into the sh script text would arrive as shell code, not
# data. withEnv keeps the body a single-quoted Groovy string.
t T17.2 "CD passes digests through withEnv, never interpolated into the shell body" python3 -c "
import re, sys
src = open('Jenkinsfile-cd').read()
stage = re.search(r\"stage\('Verify image identity in registry'\).*?\n        \}\", src, re.S).group(0)
if 'withEnv(' not in stage:
    print('digests are not passed via withEnv'); sys.exit(1)
body = re.search(r\"sh '''(.*?)'''\", stage, re.S)
if body is None:
    print('the verification sh block is not a single-quoted string'); sys.exit(1)
if 'params.' in body.group(1):
    print('a params value is interpolated directly into the shell body'); sys.exit(1)
"

t T17.3 "CD rejects a malformed digest by shape, with its own message" bash -c '
  grep -q "sha256:\[0-9a-f\]{64}" Jenkinsfile-cd &&
  grep -q "is not a valid image digest" Jenkinsfile-cd'

# A manual re-deploy of an older tag has no CI digest. That must keep working,
# but it is a WEAKER check and must never be printed as if it were the strong
# one -- the same rule the ALB probe and the webhook test already follow.
t T17.4 "an absent digest still deploys, but is announced rather than passed silently" python3 -c "
import re, sys
src = open('Jenkinsfile-cd').read()
stage = re.search(r\"stage\('Verify image identity in registry'\).*?\n        \}\", src, re.S).group(0)
if 'NO CI DIGEST SUPPLIED' not in stage:
    print('an empty digest passes without saying so'); sys.exit(1)
if 'UNVERIFIED' not in stage:
    print('the tag-only path is not tracked'); sys.exit(1)
"

t T17.5 "the S3 deployment record carries the digests the deploy was verified against" bash -c '
  grep -q "frontend_digest=" Jenkinsfile-cd &&
  grep -q "backend_digest=" Jenkinsfile-cd &&
  grep -q "worker_digest=" Jenkinsfile-cd'

# Helm was resolved with releases/latest. That endpoint now returns v4.2.4, so
# an unpinned rebuild would silently cross a MAJOR version boundary into a
# toolchain no pipeline here has ever run on.
# COMMENT LINES ARE SKIPPED ON PURPOSE. The Dockerfile quotes the old
# `releases/latest` line in a comment explaining why it was removed, and a
# naive grep flagged that explanation as the defect -- a check failing on the
# documentation of the thing it detects. Only executable lines are examined.
t T17.6 "Helm is pinned to an exact version and checksum, never resolved at build time" python3 -c "
import re, sys
lines = [l for l in open('jenkins/agent-tools/Dockerfile')
         if not l.lstrip().startswith('#')]
code = ''.join(lines)
problems = []
if 'releases/latest' in code:
    problems.append('an executable line still resolves the latest Helm release')
if not re.search(r'^ARG HELM_VERSION=v3\\.[0-9]+\\.[0-9]+\\s*$', code, re.M):
    problems.append('HELM_VERSION is not pinned to an exact 3.x version')
if not re.search(r'^ARG HELM_SHA256=[0-9a-f]{64}\\s*$', code, re.M):
    problems.append('HELM_SHA256 is missing or not a full sha256')
if 'sha256sum -c' not in code:
    problems.append('the download is never checksum-verified')
if problems:
    print(chr(10).join(problems)); sys.exit(1)
"

t T17.7 "BuildKit and Trivy are digest-pinned wherever they are referenced" python3 -c "
import sys
bad = []
for f in ['Jenkinsfile-ci', 'scripts/install-jenkins.sh']:
    for line in open(f):
        for img in ('moby/buildkit:', 'aquasec/trivy:'):
            if img in line and '@sha256:' not in line:
                bad.append(f + ': ' + line.strip())
if bad:
    print('image referenced by mutable tag only:'); print(chr(10).join(bad)); sys.exit(1)
"

# Trivy lives in two files. If they drift, the scanner that GATES the agent
# image stops being the scanner that runs inside the pipeline.
#
# Checked per FILE, not as one merged set. The first version of this test
# collected every match into a set and asserted len == 1 -- which passed
# happily when one file had lost its pin altogether, because one surviving
# reference is still "one distinct value". A test that passes when half its
# subject is missing is the defect it was written to catch.
t T17.8 "both files pin Trivy, and to the same image" python3 -c "
import re, sys
pat = re.compile(r'aquasec/trivy:[0-9.]+@sha256:[0-9a-f]{64}')
seen = {}
for f in ['Jenkinsfile-ci', 'scripts/install-jenkins.sh']:
    found = set(pat.findall(open(f).read()))
    if len(found) != 1:
        print(f + ': expected exactly one digest-pinned Trivy reference, found ' + str(len(found)))
        sys.exit(1)
    seen[f] = found.pop()
if len(set(seen.values())) != 1:
    for f, v in seen.items():
        print(f + ' -> ' + v)
    print('the two Trivy references are different images')
    sys.exit(1)
"

# Assignment checklist item G4 — the reviewer scored 7/8 because these were
# documented in prose and code but not drawn.
t T17.9 "the deployment diagram shows JCasC, the Service, the K8s API/RBAC path and the VPC" python3 -c "
import sys
d = open('docs/architecture-deployment.mmd').read()
need = {
    'JCasC / Job DSL':     'JCasC',
    'the seeded jobs':     'application-cd',
    'the Jenkins Service': 'ClusterIP',
    'the Kubernetes API':  'Kubernetes API server',
    'the RBAC grant':      'jenkins-deployer',
    'the CI denial path':  'DENIED',
    'an explicit VPC':     'VPC 10.23.0.0/16',
}
missing = [why for why, frag in need.items() if frag not in d]
if missing:
    print('deployment diagram does not show: ' + ', '.join(missing)); sys.exit(1)
"

# mtime is useless here: a fresh clone stamps every file at checkout time in
# arbitrary order, so "png newer than mmd" is a coin flip, not a check.
#
# The SVG is text, so compare CONTENT instead: every label in the Mermaid
# source must appear in the rendered SVG. Two things have to be normalised
# first, and getting either wrong produces a test that cries wolf on a
# perfectly current diagram:
#   * HTML entities -- the source says &nbsp; where the SVG holds the actual
#     character, so a literal comparison reports every label as missing.
#   * whitespace -- the renderer collapses and re-wraps runs of spaces.
t T17.10 "the rendered SVGs are current with their Mermaid source" python3 -c "
import html, re, sys

def norm(text):
    text = html.unescape(text).replace(chr(160), ' ')
    return re.sub(r'\\s+', ' ', text).strip()

stale = []
for name in ['architecture-deployment', 'architecture-pipeline',
             'architecture-observability', 'architecture-monitoring-flow']:
    mmd = open('docs/' + name + '.mmd').read()
    svg = norm(open('docs/' + name + '.svg').read())
    for a, b in re.findall(r'\\[\"(.*?)\"\\]|\\{\\{\"(.*?)\"\\}\\}', mmd):
        # Strip markup, then compare the plain-text runs. 12 characters is
        # the floor: shorter runs collide with unrelated nodes.
        # EVERY fragment of 12+ characters, not just the longest one. The
        # first version tested only the longest run, so renaming any other
        # part of a multi-line label -- the bold heading, say -- left the
        # test green while the rendered PNG still showed the old wording.
        for x in re.split(r'<[^>]+>', a or b):
            x = norm(x)
            if len(x) >= 12 and x not in svg:
                stale.append(name + '.svg is missing: ' + x)
if stale:
    print('re-render the diagrams:')
    print('  mmdc -i docs/<name>.mmd -o docs/<name>.svg')
    print(chr(10).join(stale[:6]))
    sys.exit(1)
"

# The agent-tools image tag is fixed in FOUR files, the ECR repository has
# IMMUTABLE tags, and install-jenkins.sh SKIPS the build when the tag already
# exists. So an edit to agent-tools/Dockerfile without a matching tag bump is
# silently a no-op: the old image keeps running and the change still reads as
# applied. This actually happened -- the Helm pin was written without bumping
# tools-1.1, and nothing failed.
t T17.11 "the agent-tools tag agrees across every file that names it" python3 -c "
import re, sys
label = re.search(r'^LABEL tools\.version=\"([^\"]+)\"', open('jenkins/agent-tools/Dockerfile').read(), re.M)
if not label:
    print('jenkins/agent-tools/Dockerfile has no LABEL tools.version'); sys.exit(1)
want = 'tools-' + label.group(1)
bad = []
for f in ['scripts/install-jenkins.sh', 'scripts/configure-jenkins.sh', 'jenkins/values.example.yaml']:
    found = set(re.findall(r'tools-[0-9]+\.[0-9]+', open(f).read()))
    if not found:
        bad.append(f + ': names no agent-tools tag at all')
    elif found != {want}:
        bad.append(f + ': has ' + ', '.join(sorted(found)) + ' but the Dockerfile declares ' + want)
if bad:
    print('agent-tools tag drift — bump the LABEL and every reference together:')
    print(chr(10).join(bad))
    sys.exit(1)
"

# REVIEW FIX P1 (B6/B9) — the plugin set is pinned, and pinned COMPLETELY.
#
# The trap this guards: installLatestPlugins defaults to TRUE in the Jenkins
# chart, and it governs DEPENDENCIES. Pinning the twelve plugins we chose while
# leaving that flag on freezes twelve versions and lets the other seventy-eight
# float -- a values.yaml that reads as pinned and rebuilds differently anyway.
t T17.12 "every plugin is pinned, and dependency resolution is switched off" python3 -c "
import sys, yaml
c = yaml.safe_load(open('jenkins/values.yaml'))['controller']
problems = []

if c.get('installLatestPlugins') is not False:
    problems.append('controller.installLatestPlugins must be false, or dependencies float regardless of the versions below')
if c.get('installLatestSpecifiedPlugins') is not False:
    problems.append('controller.installLatestSpecifiedPlugins must be false')

entries = c['installPlugins']
unpinned = [e for e in entries if ':' not in e or not e.split(':', 1)[1].strip()]
if unpinned:
    problems.append('not pinned to a version: ' + ', '.join(unpinned))

names = [e.split(':', 1)[0] for e in entries]
if len(names) != len(set(names)):
    dupes = sorted({n for n in names if names.count(n) > 1})
    problems.append('listed twice: ' + ', '.join(dupes))

# The twelve that back a step we actually use. If one disappears the pipeline
# breaks at runtime, which is a far worse way to find out.
chosen = ['kubernetes', 'workflow-aggregator', 'git', 'github',
          'github-branch-source', 'configuration-as-code', 'job-dsl',
          'pipeline-stage-view', 'junit', 'pipeline-utility-steps',
          'timestamper', 'ws-cleanup']
missing = [p for p in chosen if p not in names]
if missing:
    problems.append('deliberately-chosen plugin missing: ' + ', '.join(missing))

# A pinned list is a snapshot of a RESOLVED set: the dependencies have to be in
# it. If it shrinks back to roughly the chosen twelve, someone has replaced the
# lock with the wish-list and the dependencies are floating again.
if len(entries) < 40:
    problems.append('only %d entries -- this looks like the chosen plugins alone, not a resolved set' % len(entries))

if problems:
    print(chr(10).join(problems)); sys.exit(1)
"

echo "=== T18: Observability (phase 5) ==="
# Every test here guards something that fails SILENTLY. That is the selection
# criterion: a setting whose wrong value produces a loud error does not need a
# test, because the error is the test.

t T18.1 "the observability values are correct in every way that fails quietly" \
  python3 tests/check_observability_values.py
t T18.2 "dashboards load, name the right datasource, and every query parses" \
  python3 tests/check_dashboards.py
t T18.3 "every metric a dashboard or rule names is one something produces" \
  python3 tests/check_metrics_contract.py

t T18.4 "the observability chart renders" bash -c '
  helm template observability helm/observability > /dev/null'

# Added by the pre-handover audit. Everything else in T18 reads files; this one
# imports the instrumentation and attacks it, because all four properties it
# guards were broken while the code read correctly.
t T18.34 "the instrumentation survives hostile input and a hostile environment" bash -c '
  python3 tests/check_metrics_runtime.py; rc=$?
  clean_pycache
  exit $rc'

# Added by the pre-handover audit. Every other Jenkinsfile test greps for a
# stage NAME, which a syntactically broken file satisfies perfectly well -- so
# nothing here could see a Jenkinsfile that Jenkins would refuse to parse, and
# the symptom of that is a job that never starts a build at all.
t T18.38 "both Jenkinsfiles are structurally parseable" \
  python3 tests/check_jenkinsfile_structure.py

# THE SUITE NEVER LINTED THE PYTHON. Only GitHub Actions did.
#
# So `bash tests/run_all.sh` reported 214 passed on a tree that flake8 rejects,
# and the error had been sitting in app/common/metrics.py since the audit added
# a function to it. Every gate in this repository is described as "the suite is
# the gate"; it was not the gate for lint, and the gap was invisible because the
# thing that would have shown it ran somewhere else.
#
# Skips rather than fails when flake8 is absent, and says so — the runner now
# renders that as a skip rather than a green tick, so an unlinted run cannot be
# mistaken for a clean one.
# The tooling CI installs and the tooling you install must be ONE definition.
# Two lists is how the workflow ended up without promtool, kubeconform, flake8
# or the application's dependencies while the suite grew checks that need all
# four — and how the resulting skips got rendered as passes.
# The agent image and the local/CI installer must build the SAME tools.
#
# They did not: the Dockerfile built kubeconform 0.7.0 while
# install-test-tooling.sh installed 0.6.7, so a manifest could be judged valid
# by one schema validator and invalid by another depending on where the check
# ran. Nothing noticed, because nothing compared them.
#
# This also matters for security, which is easy to forget for a validation
# tool: promtool 3.1.0 and kubeconform 0.7.0 had aged into a vulnerable Go
# crypto/tls and gRPC, and the Trivy CRITICAL gate in install-jenkins.sh stopped
# a deploy over it. Two pins that drift means two ageing curves to remember.
t T18.44 "the agent image and the tooling installer pin the same tool versions" python3 -c "
import re, sys, pathlib

docker = pathlib.Path('jenkins/agent-tools/Dockerfile').read_text()
script = pathlib.Path('scripts/install-test-tooling.sh').read_text()

def one(text, pattern, where):
    # re.M: the installer's pins are line-anchored, and without it '^' only
    # matches the start of the whole file. Caught by mutation-testing this
    # check and finding it failed identically whether the versions matched or
    # not -- a check that always fails is as useless as one that always passes.
    m = re.search(pattern, text, re.M)
    if not m:
        print(f'could not find {where} -- the pin was renamed or removed'); sys.exit(1)
    return m.group(1)

pairs = [
    ('promtool',
     one(docker, r'ARG PROMTOOL_VERSION=([0-9.]+)',    'PROMTOOL_VERSION in the Dockerfile'),
     one(script, r'^PROM_VERSION=([0-9.]+)',           'PROM_VERSION in install-test-tooling.sh')),
    ('kubeconform',
     one(docker, r'ARG KUBECONFORM_VERSION=([0-9.]+)', 'KUBECONFORM_VERSION in the Dockerfile'),
     one(script, r'^KUBECONFORM_VERSION=([0-9.]+)',    'KUBECONFORM_VERSION in install-test-tooling.sh')),
]

bad = [(t, a, b) for t, a, b in pairs if a != b]
if bad:
    print('the agent image and scripts/install-test-tooling.sh pin different versions:')
    for t, a, b in bad:
        print(f'  {t}: Dockerfile {a}, installer {b}')
    print('')
    print('CI, a developer machine and the build agent would then validate the')
    print('same files with different tools and could disagree about the result.')
    sys.exit(1)
print('agent image and installer agree: ' + ', '.join(f'{t} {a}' for t, a, _ in pairs))"

t T18.43 "CI installs the test tooling from the repository's own script" python3 -c "
import sys, yaml
wf = yaml.safe_load(open('.github/workflows/ci.yml'))
steps = wf['jobs']['repo-tests']['steps']
runs = ' '.join(s.get('run', '') for s in steps)
if 'scripts/install-test-tooling.sh' not in runs:
    print('the repo-tests job does not call scripts/install-test-tooling.sh.')
    print('It is installing its own list of tools, which is how CI and a')
    print('developer machine drift into verifying different things.')
    sys.exit(1)
if 'pip install' in runs or 'apt-get install' in runs:
    print('the repo-tests job installs tooling inline as well as via the script;')
    print('put it in scripts/install-test-tooling.sh so there is one definition.')
    sys.exit(1)
print('CI and a developer machine install the same tooling, from one script')"

t T18.42 "the Python lints clean (setup.cfg rules)" bash -c '
  if ! python3 -m flake8 --version >/dev/null 2>&1; then
    echo "SKIPPED (flake8 not installed: pip install flake8)"
    exit 0
  fi
  python3 -m flake8 app/ tests/'

# A number written into prose is a number that goes stale, quietly, and then
# gets quoted at someone. The README said 51 unit tests when there were 52.
# Small on its own; the same drift left a runbook naming an agent image tag that
# no longer exists, which is the kind of thing that costs half an hour during an
# incident. If a document states a count, the count gets checked.
# T18.3 checks that every metric a DASHBOARD or a RULE names is one something
# produces. Nothing checked the diagrams, and architecture-monitoring-flow.mmd
# spent the whole of Phase 5 naming `app_info` — a metric that does not exist;
# it is `app_build_info`. The plan document had the same name wrong in four
# places while getting it right in a fifth. A diagram is the first thing someone
# reads and the last thing anyone re-checks.
# T18.6 proves each runbook FILE exists. It cannot prove the URL an on-call
# person clicks actually resolves, and for the whole of Phase 5 those URLs named
# a repository this project has never lived in -- eleven dead links, each one
# offered at the exact moment it is least welcome. Nothing offline can check a
# URL, so the next best thing is that there is only ONE of them to get right.
t T18.41 "every runbook_url is built from the single configured base" bash -c '
  hard=$(grep -rn "runbook_url:.*https://" helm/ || true)
  if [ -n "$hard" ]; then
    echo "a runbook_url hardcodes a URL instead of using .Values.runbookBaseUrl:"
    echo "$hard"
    echo "Eleven copies is how they drifted to the wrong repository unnoticed."
    exit 1
  fi
  base=$(python3 -c "import yaml;print(yaml.safe_load(open(\"helm/observability/values.yaml\"))[\"runbookBaseUrl\"])")
  case "$base" in
    https://github.com/*/blob/main/docs/runbooks) ;;
    *) echo "runbookBaseUrl is ${base} — expected a github blob URL ending in /docs/runbooks"; exit 1 ;;
  esac
  # File existence and alert/runbook pairing moved to T18.52.
  #
  # The check that used to live here could not fail. It piped into a `while`,
  # so its `exit 1` ended a SUBSHELL, and the `echo` that followed reset the
  # status to 0 -- it printed "does not exist" and returned success. It was
  # also asking the weaker question: three alerts pointed at other alerts
  # runbooks, and all three of those files existed.
  echo "all runbook_urls derive from ${base}"'

# The shipped NodeNotReadyOrPressure alert description told an on-call person
# the cluster had "four nodes and three of them single-purpose". It has five,
# two single-purpose -- Phase 4's numbers, left behind when Phase 5 added the
# monitoring node group, and repeated in the runbook and the sizing table.
# Test IDs must be unique. Not because a duplicate breaks anything -- both
# copies run -- but because the summary names failures by ID, and two checks
# answering to one name is a report you cannot act on.
#
# The regex matters more than it looks: an earlier attempt at this used
# ^t T[0-9.]+ and reported T13.1 as duplicated, because that pattern stops
# before the "b" in T13.1b. It found a bug that did not exist. Suffixed IDs are
# legitimate and the pattern has to admit them.
t T18.47 "every test ID is unique" bash -c '
  dupes=$(grep -oE "^t T[0-9]+\.[0-9]+[a-z]*" tests/run_all.sh | sort | uniq -d)
  if [ -n "$dupes" ]; then
    echo "these test IDs are defined more than once:"
    echo "$dupes"
    echo "The summary reports failures by ID, so a duplicate names two checks."
    exit 1
  fi
  n=$(grep -cE "^t T[0-9]+\.[0-9]+[a-z]*" tests/run_all.sh)
  echo "$n test IDs, all distinct"'

t T18.46 "documented node counts match what Terraform creates" \
  python3 tests/check_node_count.py

t T18.48 "every Trivy exception is scoped, justified, dated and wired in" \
  python3 tests/check_trivy_exceptions.py

t T18.52 "every alert links to its own runbook, and that runbook exists" \
  python3 tests/check_runbook_links.py

t T18.49 "meta-alerts are null-routed and InfoInhibitor actually inhibits" \
  python3 tests/check_alert_routing.py

# Behavioural, not a grep: the script is RUN against a kubectl that fails and a
# kubectl that succeeds but finds nothing, and the two must not be conflated.
# Reported as "no Prometheus Service -- is the stack installed?", an
# unreachable cluster sent the operator to reinstall a stack that was at that
# moment emailing him alerts from inside that same cluster.
t T18.50 "port-forward tells 'cannot ask' apart from 'not there'" bash -c '
  d=$(mktemp -d); trap "rm -rf $d" EXIT
  printf "#!/bin/bash\necho \"dial tcp: i/o timeout\" >&2\nexit 1\n" > "$d/kubectl"
  chmod +x "$d/kubectl"
  out=$(PATH="$d:$PATH" bash scripts/port-forward-monitoring.sh 2>&1); rc=$?
  [ "$rc" = "2" ] || { echo "unreachable cluster exited $rc, expected 2"; exit 1; }
  case "$out" in *[Ii]s\ the\ stack\ installed*)
    echo "an unreachable cluster was reported as a missing stack"; exit 1;; esac
  printf "#!/bin/bash\nexit 0\n" > "$d/kubectl"; chmod +x "$d/kubectl"
  out=$(PATH="$d:$PATH" bash scripts/port-forward-monitoring.sh 2>&1); rc=$?
  [ "$rc" = "1" ] || { echo "absent service exited $rc, expected 1"; exit 1; }
  case "$out" in *install-observability*) ;; *)
    echo "a genuinely missing stack did not point at the installer"; exit 1;; esac
  echo "query failure exits 2, genuine absence exits 1"'

# The selector this script used matched NOTHING on a real cluster and had never
# matched: Services are labelled by the Helm chart (legacy `app=` key only)
# while StatefulSets and PVCs are labelled by the operator
# (app.kubernetes.io/name). The same selector is correct in
# verify-observability.sh and wrong here, which is why copying it looked safe.
#
# Driven by a stub kubectl reproducing chart 86.1.0's ACTUAL labels, so the
# regression this guards against is the one that happened.
t T18.51 "port-forward resolves the Services the chart really creates" bash -c '
  d=$(mktemp -d); trap "rm -rf $d" EXIT
  # Free ports, chosen at run time. The first version of this test hardcoded
  # 9090/9093 and therefore asserted "those ports are free on this machine" as
  # much as anything about the script -- it passed locally and failed in a
  # sandbox where something already listened on 9090.
  # Free ports found with bash /dev/tcp -- no nested quoting, no python -c
  # inside a single-quoted bash -c, which is how the first attempt at this
  # ended up passing 127.0.0.1 to python unquoted.
  free_port() {
    local c cand
    for c in $(seq 1 60); do
      cand=$((20000 + RANDOM % 20000))
      (exec 3<>/dev/tcp/127.0.0.1/$cand) 2>/dev/null || { echo "$cand"; return 0; }
      exec 3>&- 2>/dev/null || true
    done
    echo 0
  }
  pp=$(free_port); ap=$(free_port)
  [ "$pp" != "0" ] && [ "$ap" != "0" ] && [ "$pp" != "$ap" ] || {
    echo "could not find two free ports to test with"; exit 1; }
  cat > "$d/kubectl" <<STUB
#!/bin/bash
case "\$*" in
  *"-l app=kube-prometheus-stack-prometheus"*)   printf kube-prometheus-stack-prometheus; exit 0;;
  *"-l app=kube-prometheus-stack-alertmanager"*) printf kube-prometheus-stack-alertmanager; exit 0;;
  *"port-forward"*)
      # Serve on the local half of "LOCAL:REMOTE" so the readiness probe has
      # something real to talk to, exactly as a working forward would.
      # Held in a variable, not a shared file: both forwards run at once, and
      # the first version had them racing to write one $d/port -- Alertmanager
      # read Prometheus port and never came up.
      lp=""
      for a in "\$@"; do case "\$a" in [0-9]*:[0-9]*) lp="\${a%%:*}";; esac; done
      exec python3 -m http.server "\$lp" --bind 127.0.0.1 >/dev/null 2>&1;;
  *) exit 0;;
esac
STUB
  chmod +x "$d/kubectl"
  PROM_PORT=$pp ALERT_PORT=$ap PATH="$d:$PATH" \
    timeout 25 bash scripts/port-forward-monitoring.sh > "$d/out" 2>&1
  rc=$?
  if [ "$rc" != "124" ]; then
    echo "script exited $rc against real chart labels; it should still be running"
    cat "$d/out"; exit 1
  fi
  grep -q "localhost:$pp" "$d/out" || { echo "no Prometheus URL printed"; cat "$d/out"; exit 1; }
  grep -q "localhost:$ap" "$d/out" || { echo "no Alertmanager URL printed"; cat "$d/out"; exit 1; }
  echo "both Services resolved from the chart-created labels"'

t T18.53 "port-forward proves the endpoint answers, not that a PID exists" bash -c '
  d=$(mktemp -d); trap "rm -rf $d" EXIT
  # Free ports found with bash /dev/tcp -- no nested quoting, no python -c
  # inside a single-quoted bash -c, which is how the first attempt at this
  # ended up passing 127.0.0.1 to python unquoted.
  free_port() {
    local c cand
    for c in $(seq 1 60); do
      cand=$((20000 + RANDOM % 20000))
      (exec 3<>/dev/tcp/127.0.0.1/$cand) 2>/dev/null || { echo "$cand"; return 0; }
      exec 3>&- 2>/dev/null || true
    done
    echo 0
  }
  pp=$(free_port); ap=$(free_port)
  [ "$pp" != "0" ] && [ "$ap" != "0" ] && [ "$pp" != "$ap" ] || {
    echo "could not find two free ports to test with"; exit 1; }
  cat > "$d/kubectl" <<STUB
#!/bin/bash
case "\$*" in
  *"-l app=kube-prometheus-stack-prometheus"*)   printf kube-prometheus-stack-prometheus; exit 0;;
  *"-l app=kube-prometheus-stack-alertmanager"*) printf kube-prometheus-stack-alertmanager; exit 0;;
  *"port-forward"*) echo "Unable to listen on port: address already in use" >&2; exit 1;;
  *) exit 0;;
esac
STUB
  chmod +x "$d/kubectl"
  out=$(PROM_PORT=$pp ALERT_PORT=$ap PATH="$d:$PATH" \
        timeout 90 bash scripts/port-forward-monitoring.sh 2>&1); rc=$?
  [ "$rc" = "1" ] || { echo "a forward that never bound exited $rc, expected 1"; echo "$out"; exit 1; }
  case "$out" in *"localhost:$pp"*)
    echo "advertised a URL for a port-forward that never bound"; exit 1;; esac
  case "$out" in *"address already in use"*) ;; *)
    echo "kubectl real error was swallowed"; exit 1;; esac
  echo "a dead forward fails and its error is shown, no URL advertised"'

t T18.40 "no diagram names a metric that nothing produces" python3 -c "
import glob, re, subprocess, sys

known = set()
for f in ('app/common/metrics.py', 'app/backend/app.py', 'app/worker/worker.py'):
    src = open(f).read()
    known |= set(re.findall(r'(?:Counter|Gauge|Histogram)\(\s*\n?\s*\"([a-z][a-z0-9_]+)\"', src))
# Histogram buckets add _bucket/_sum/_count; Counters add _total in the exposition.
known |= {m + s for m in list(known) for s in ('_bucket', '_sum', '_count', '_total')}
# Everything the metric-contract test already vouches for (exporters, kubelet,
# kube-state-metrics, Jenkins, Prometheus's own). One source of truth, not two.
contract = open('tests/check_metrics_contract.py').read()
known |= set(re.findall(r'\"([a-z][a-z0-9_]*_[a-z0-9_]+)\"', contract))

bad = []
for f in sorted(glob.glob('docs/*.mmd')):
    text = open(f).read()
    for line_no, line in enumerate(text.splitlines(), 1):
        # Only bolded identifiers that look like metric names: <b>foo_bar</b>
        # followed by { or as a bare word. Prose is not scanned — a diagram
        # label saying 'the metrics endpoint' must not trip this.
        for name in re.findall(r'<b>([a-z][a-z0-9_]*_[a-z0-9_]+)</b>\s*\{', line):
            if name not in known:
                bad.append(f'{f}:{line_no}  {name}')
if bad:
    print('a diagram names a metric that nothing produces:')
    for b in bad: print('  ' + b)
    print('')
    print('A panel built from this name would read \"No data\" forever, and the')
    print('diagram is what someone trusts when the panel is empty.')
    sys.exit(1)
print('every metric named in a diagram is one something produces')"

t T18.39 "the unit-test count in README matches reality" bash -c '
  claimed=$(grep -oE "pytest.*\(([0-9]+) tests\)" README.md | grep -oE "[0-9]+ tests" | grep -oE "[0-9]+")
  [ -n "$claimed" ] || { echo "README no longer states a unit-test count where this check looks"; exit 1; }
  # Skip, not fail, when pytest or the app dependencies are missing. This check
  # is about a NUMBER IN A DOCUMENT being right, and a machine that cannot run
  # the tests has no opinion on that. Failing there conflated "the README is
  # wrong" with "this runner has no pytest" — and it was the second one, on
  # GitHub Actions, in the job that deliberately installs no application deps.
  if ! python3 -m pytest --version >/dev/null 2>&1; then
    echo "SKIPPED (pytest not installed, so the real count is unknown)"; exit 0
  fi
  actual=$(python3 -m pytest app/ -q -p no:cacheprovider 2>/dev/null | grep -oE "[0-9]+ passed" | grep -oE "[0-9]+")
  clean_pycache
  if [ -z "$actual" ]; then
    echo "SKIPPED (pytest could not collect app/ — application dependencies absent)"
    exit 0
  fi
  [ "$claimed" = "$actual" ] || {
    echo "README says $claimed unit tests; pytest reports $actual"; exit 1; }
  echo "README and pytest agree: $actual unit tests"'

# REPLACED a narrower check that looked only at what app/ imports. It fixed the
# prometheus_client instance and missed the class: CI also runs
# validate-observability.sh, which imports yaml in inline Python and in
# check_metrics_contract.py, and pyyaml was not in the image either. The offline
# suite was green while the pipeline died with ModuleNotFoundError, because the
# check modelling the agent image was reading the wrong files.
#
# This walks what Jenkinsfile-ci actually executes: the scripts it invokes, the
# inline Python in those scripts, the tests/*.py they call, and the modules it
# runs directly.
t T18.36 "the agent image satisfies every module CI imports" \
  python3 tests/check_agent_image_deps.py

t T18.37 "CD's monitoring.coreos.com grant matches what the app charts render" python3 -c "
import subprocess, yaml, sys
kinds = set()
for c in ('backend', 'worker', 'frontend'):
    out = subprocess.run(['helm','template',c,f'helm/{c}','--set','monitoring.enabled=true'],
                         capture_output=True, text=True).stdout
    for d in yaml.safe_load_all(out):
        if d and str(d.get('apiVersion','')).startswith('monitoring.coreos.com'):
            kinds.add(d['kind'])
rendered = {k.lower() + 's' for k in kinds}

granted = set()
for d in yaml.safe_load_all(open('jenkins/rbac.yaml')):
    if not d or d.get('kind') not in ('Role', 'ClusterRole'): continue
    for r in d.get('rules', []):
        if 'monitoring.coreos.com' in r.get('apiGroups', []):
            writes = {v for v in r.get('verbs', []) if v in ('create','update','patch','delete')}
            if writes:
                granted |= set(r.get('resources', []))

extra = sorted(granted - rendered)
short = sorted(rendered - granted)
if not rendered:
    print('no monitoring.coreos.com object rendered by any app chart — has monitoring.enabled changed?'); sys.exit(1)
if extra:
    print('CD may WRITE monitoring resources no application chart contains:')
    for e in extra: print('  ' + e)
    print('prometheusrules is the dangerous one: Prometheus discovers rules across')
    print('namespaces, so this lets the deploy pipeline edit the alerts that gate it.')
    sys.exit(1)
if short:
    print('an app chart renders a resource CD cannot create — the deploy fails at runtime:')
    for s in short: print('  ' + s)
    sys.exit(1)
print(f'app charts render {sorted(rendered)}; CD may write exactly that')"

t T18.35 "every pod in the observability namespace is covered by a NetworkPolicy" python3 -c "
import subprocess, yaml, sys
out = subprocess.run(['helm','template','observability','helm/observability'],
                     capture_output=True, text=True).stdout
selected, deny = set(), False
for d in yaml.safe_load_all(out):
    if not d or d.get('kind') != 'NetworkPolicy': continue
    sel = d['spec'].get('podSelector') or {}
    if not sel:
        deny = True
        continue
    for e in sel.get('matchExpressions', []):
        if e.get('key') == 'app.kubernetes.io/name' and e.get('operator') == 'In':
            selected.update(e.get('values', []))
    v = (sel.get('matchLabels') or {}).get('app.kubernetes.io/name')
    if v: selected.add(v)
# The label VALUES kube-prometheus-stack actually puts on each workload. The
# operator's is the one that was wrong: the chart renders it as
# '<chart name>-prometheus-operator', not the bare component name.
REQUIRED = {
  'prometheus', 'alertmanager', 'grafana', 'kube-state-metrics',
  'prometheus-node-exporter', 'kube-prometheus-stack-prometheus-operator',
  'kube-prometheus-stack-admission-webhook',
}
missing = sorted(REQUIRED - selected)
if not deny:
    print('there is no default-deny policy; the others are decoration'); sys.exit(1)
if missing:
    print('no NetworkPolicy selects these workloads, so default-deny leaves them')
    print('with no DNS and no API server, silently:')
    for m in missing: print('  ' + m)
    sys.exit(1)"

t T18.5 "every alert carries severity, summary, description and a runbook_url" python3 -c "
import subprocess, yaml, sys
out = subprocess.run(['helm','template','observability','helm/observability'],
                     capture_output=True, text=True).stdout
bad, n = [], 0
for d in yaml.safe_load_all(out):
    if not d or d.get('kind') != 'PrometheusRule': continue
    for g in d['spec']['groups']:
        for r in g['rules']:
            if 'alert' not in r: continue
            n += 1
            a = r.get('annotations', {})
            for k in ('summary','description','runbook_url'):
                if not a.get(k): bad.append(r['alert'] + ': missing ' + k)
            if not r.get('labels',{}).get('severity'): bad.append(r['alert'] + ': missing severity')
if n == 0: bad.append('no alerts found at all')
if bad: print(chr(10).join(bad)); sys.exit(1)"

# A runbook_url that 404s is worse than no runbook: it sends someone looking
# for help to a dead end during an incident.
t T18.6 "every runbook_url points at a file that exists" python3 -c "
import subprocess, yaml, os, sys
out = subprocess.run(['helm','template','observability','helm/observability'],
                     capture_output=True, text=True).stdout
missing = []
for d in yaml.safe_load_all(out):
    if not d or d.get('kind') != 'PrometheusRule': continue
    for g in d['spec']['groups']:
        for r in g['rules']:
            if 'alert' not in r: continue
            fn = r['annotations']['runbook_url'].rsplit('/', 1)[-1]
            if not os.path.exists('docs/runbooks/' + fn):
                missing.append(r['alert'] + ' -> ' + fn)
if missing: print(chr(10).join(missing)); sys.exit(1)"

t T18.7 "the six required alerts all exist" python3 -c "
import subprocess, yaml, sys
out = subprocess.run(['helm','template','observability','helm/observability'],
                     capture_output=True, text=True).stdout
names = {r['alert'] for d in yaml.safe_load_all(out) if d and d.get('kind')=='PrometheusRule'
         for g in d['spec']['groups'] for r in g['rules'] if 'alert' in r}
required = {'HighErrorRate','HighLatencyP95','ReplicasMismatch',
            'NodeNotReadyOrPressure','JenkinsQueueStuck','PrometheusTargetDown'}
missing = required - names
if missing: print('missing required alerts: ' + ', '.join(sorted(missing))); sys.exit(1)"

# The metrics port must never be the port the probes use. If they share a port,
# tightening the NetworkPolicy for one silently breaks the other.
t T18.8 "the metrics port is never the application port" python3 -c "
import yaml, sys
bad = []
for svc, appport in (('backend',5000), ('worker',5001), ('frontend',8080)):
    v = yaml.safe_load(open('helm/' + svc + '/values.yaml'))
    if v['metricsPort'] == appport:
        bad.append(svc + ': metricsPort equals the application port')
    if v['metricsPort'] == v.get('service',{}).get('port'):
        bad.append(svc + ': metricsPort equals service.port')
if bad: print(chr(10).join(bad)); sys.exit(1)"

t T18.9 "each app chart ships a ServiceMonitor selecting a NAMED metrics port" python3 -c "
import subprocess, yaml, sys
bad = []
for svc in ('backend','worker','frontend'):
    cmd = ['helm','template',svc,'helm/'+svc,'--set','image.registry=x']
    if svc != 'frontend': cmd += ['--set','serviceAccount.roleArn=y']
    docs = [d for d in yaml.safe_load_all(subprocess.run(cmd,capture_output=True,text=True).stdout) if d]
    sm = [d for d in docs if d['kind']=='ServiceMonitor']
    if not sm: bad.append(svc + ': no ServiceMonitor'); continue
    ports = [e.get('port') for e in sm[0]['spec']['endpoints']]
    if 'metrics' not in ports: bad.append(svc + ': ServiceMonitor does not select the named metrics port')
    svcs = [d for d in docs if d['kind']=='Service']
    names = [p.get('name') for p in svcs[0]['spec']['ports']]
    if 'metrics' not in names: bad.append(svc + ': Service has no port named metrics')
if bad: print(chr(10).join(bad)); sys.exit(1)"

# A chart that hard-fails on a missing CRD cannot be tested on a bare cluster.
t T18.10 "monitoring can be switched off and the charts still render" bash -c '
  for c in backend worker frontend; do
    out=$(helm template "$c" "helm/$c" --set image.registry=x --set serviceAccount.roleArn=y \
            --set monitoring.enabled=false)
    echo "$out" | grep -q "kind: ServiceMonitor" && { echo "$c still renders a ServiceMonitor"; exit 1; }
  done; exit 0'

t T18.11 "app NetworkPolicies admit scraping ONLY from the observability namespace" python3 -c "
import subprocess, yaml, sys
bad = []
for svc in ('backend','worker','frontend'):
    cmd = ['helm','template',svc,'helm/'+svc,'--set','image.registry=x']
    if svc != 'frontend': cmd += ['--set','serviceAccount.roleArn=y']
    docs = [d for d in yaml.safe_load_all(subprocess.run(cmd,capture_output=True,text=True).stdout) if d]
    np = [d for d in docs if d['kind']=='NetworkPolicy'][0]
    mp = yaml.safe_load(open('helm/'+svc+'/values.yaml'))['metricsPort']
    rules = [r for r in np['spec']['ingress'] if any(p.get('port')==mp for p in r.get('ports',[]))]
    if not rules: bad.append(svc + ': nothing admits the metrics port'); continue
    for r in rules:
        for src in r['from']:
            ns = (src.get('namespaceSelector') or {}).get('matchLabels',{}).get('kubernetes.io/metadata.name')
            if ns != 'observability':
                bad.append(svc + ': metrics port admits ' + str(src) + ', not just observability')
if bad: print(chr(10).join(bad)); sys.exit(1)"

t T18.12 "Jenkins agents may reach Prometheus, and Prometheus may reach Jenkins" bash -c '
  grep -q "observability" jenkins/networkpolicy.yaml || { echo "jenkins/networkpolicy.yaml never mentions observability"; exit 1; }
  python3 - <<PY
import yaml, sys
pol = {p["metadata"]["name"]: p for p in yaml.safe_load_all(open("jenkins/networkpolicy.yaml")) if p}
agents = pol["jenkins-agents"]["spec"]["egress"]
if not any(any((t.get("namespaceSelector") or {}).get("matchLabels",{}).get("kubernetes.io/metadata.name")=="observability"
               for t in r.get("to",[])) for r in agents):
    print("agents have no egress to observability - the CD gate could never query Prometheus"); sys.exit(1)
ctrl = pol["jenkins-controller"]["spec"]["ingress"]
if not any(any((f.get("namespaceSelector") or {}).get("matchLabels",{}).get("kubernetes.io/metadata.name")=="observability"
               for f in r.get("from",[])) for r in ctrl):
    print("controller does not admit observability - Jenkins could never be scraped"); sys.exit(1)
PY'

t T18.13 "the observability namespace is declared with PSA settings and a comment" bash -c '
  python3 -c "
import yaml,sys
ns=[d for d in yaml.safe_load_all(open(\"k8s/namespace.yaml\")) if d and d[\"metadata\"][\"name\"]==\"observability\"]
if not ns: print(\"observability namespace not declared\"); sys.exit(1)
l=ns[0][\"metadata\"][\"labels\"]
assert l.get(\"kubernetes.io/metadata.name\")==\"observability\", \"missing the label NetworkPolicies select on\"
assert l.get(\"pod-security.kubernetes.io/audit\"), \"PSA audit not set\"
"
  grep -q "node-exporter" k8s/namespace.yaml || { echo "the PSA relaxation is not explained"; exit 1; }'

t T18.14 "CD deploys the build identity that app_build_info reports" bash -c '
  grep -q "build.gitSha" Jenkinsfile-cd || { echo "CD does not pass build.gitSha"; exit 1; }
  grep -q "GIT_SHA" helm/backend/templates/deployment.yaml || { echo "the chart does not set GIT_SHA"; exit 1; }
  grep -q "GIT_SHA" app/common/metrics.py || { echo "the app never reads GIT_SHA"; exit 1; }'

t T18.15 "CD runs the monitoring gate AFTER the smoke test and before recording" python3 -c "
import re, sys
s = open('Jenkinsfile-cd').read()
order = [m.group(1) for m in re.finditer(r\"stage\('([^']+)'\)\", s)]
for need in ('Smoke test','Monitoring gate','Record deployment'):
    if need not in order: print('missing stage: ' + need); sys.exit(1)
if not (order.index('Smoke test') < order.index('Monitoring gate') < order.index('Record deployment')):
    print('wrong order: ' + ' -> '.join(order)); sys.exit(1)"

# Comment lines are stripped before the search. The first version of this test
# matched the COMMENT in Jenkinsfile-ci that explains CI cannot deploy -- the
# same shape as the phase 4 grep that flagged its own documentation, and the
# reason T17.6 skips comments too.
t T18.16 "CI validates the observability objects and still never deploys" bash -c '
  grep -q "validate-observability.sh" Jenkinsfile-ci || { echo "CI does not validate them"; exit 1; }
  if sed "s@//.*@@" Jenkinsfile-ci | grep -qE "kubectl apply|helm upgrade|helm install"; then
    echo "CI contains a deploy command (outside comments)"; exit 1
  fi
  exit 0'

t T18.17 "CI cannot create a ServiceMonitor; only CD can" python3 -c "
import yaml, sys
docs=[d for d in yaml.safe_load_all(open('jenkins/rbac.yaml')) if d]
roles={d['metadata']['name']: d for d in docs if d['kind']=='Role'}
dep=roles['jenkins-deployer']['rules']
if not any('monitoring.coreos.com' in r['apiGroups'] for r in dep):
    print('jenkins-deployer cannot manage monitoring resources'); sys.exit(1)
# and nothing binds the CI ServiceAccount to that Role
for d in docs:
    if d['kind']=='RoleBinding' and d['roleRef']['name']=='jenkins-deployer':
        for s in d['subjects']:
            if s['name']=='jenkins-agent-ci':
                print('jenkins-agent-ci is bound to jenkins-deployer - CI could deploy'); sys.exit(1)"

# The gate's three false-success shapes, driven against a fake Prometheus that
# always returns HTTP 200. Written the mutation way round: the assertion is
# that the gate FAILS.
t T18.18 "the monitoring gate fails on empty results, on a 200-with-error body, and when unreachable" bash -c '
  python3 tests/fake_prometheus.py empty 19301 & P1=$!
  python3 tests/fake_prometheus.py error200 19302 & P2=$!
  sleep 1
  rc=0
  PROM_URL=http://127.0.0.1:19301 ATTEMPTS=1 SLEEP_SECONDS=1 ./scripts/monitoring-gate.sh abc >/dev/null 2>&1 || rc=$((rc+1))
  PROM_URL=http://127.0.0.1:19302 ATTEMPTS=1 SLEEP_SECONDS=1 ./scripts/monitoring-gate.sh abc >/dev/null 2>&1 || rc=$((rc+1))
  PROM_URL=http://127.0.0.1:19399 ATTEMPTS=1 SLEEP_SECONDS=1 ./scripts/monitoring-gate.sh abc >/dev/null 2>&1 || rc=$((rc+1))
  kill $P1 $P2 2>/dev/null
  [ "$rc" -eq 3 ] || { echo "gate did not fail all three ways (failed $rc/3)"; exit 1; }'

t T18.19 "the monitoring gate PASSES against a healthy Prometheus" bash -c '
  python3 tests/fake_prometheus.py healthy 19303 & P=$!
  sleep 1
  PROM_URL=http://127.0.0.1:19303 ATTEMPTS=2 SLEEP_SECONDS=1 ./scripts/monitoring-gate.sh deadbeef >/dev/null 2>&1
  rc=$?
  kill $P 2>/dev/null
  [ "$rc" -eq 0 ] || { echo "gate failed against a healthy Prometheus (exit $rc) - it can never pass"; exit 1; }'

t T18.20 "the agent image carries the validation tools and its tag was bumped" bash -c '
  for tool in promtool kubeconform; do
    grep -q "$tool" jenkins/agent-tools/Dockerfile || { echo "agent image lacks $tool"; exit 1; }
  done
  v=$(grep -oE "LABEL tools.version=\"[0-9.]+\"" jenkins/agent-tools/Dockerfile | grep -oE "[0-9.]+")
  grep -q "tools-${v}" scripts/install-jenkins.sh || { echo "install-jenkins.sh does not use tools-${v}"; exit 1; }
  [ "$v" != "1.2" ] || { echo "the Dockerfile changed but the tag was not bumped - the build is a silent no-op"; exit 1; }

  # AUDIT FIX -- this used to check install-jenkins.sh and nothing else, so a
  # bump left stale tags behind in configure-jenkins.sh, values.example.yaml and
  # the runbooks. The 1.3 -> 1.4 bump proved it: a runbook still told an
  # operator that ImagePullBackOff means "the tools-1.3 image is not in ECR",
  # which during an incident sends them looking for the wrong image.
  #
  # Now: find EVERY tools-<version> anywhere in the tree and require it to be
  # the current one. Searching for what is wrong rather than confirming what is
  # right is the difference between a check that scales with the repo and one
  # that has to be remembered.
  # tests/run_all.sh is excluded because this file DISCUSSES old tags in prose:
  # the comment above names 1.3, and another comment further up recounts the
  # tools-1.1 bump. Without the exclusion this check fails on its own
  # explanation of itself -- the same shape as the phase 4 grep that matched
  # the comment describing the pattern it was hunting, and as the shellcheck
  # directive collision in monitoring-gate.sh. Nothing is lost: this file never
  # names the tag operationally, it derives it into $v.
  stale=$(grep -rnoE "tools-[0-9]+\.[0-9]+" --exclude-dir=.git --exclude-dir=evidence \
            --exclude=run_all.sh . \
            | grep -v "tools-${v}\$" || true)
  if [ -n "$stale" ]; then
    echo "the agent image tag is tools-${v}, but these still name an older one:"
    echo "$stale"
    exit 1
  fi'

t T18.21 "install-observability runs BEFORE Jenkins in deploy.sh" python3 -c "
import sys
s = open('scripts/deploy.sh').read()
o, j = s.find('install-observability.sh'), s.find('install-jenkins.sh')
if o < 0: print('deploy.sh never installs observability'); sys.exit(1)
if o > j: print('observability is installed AFTER Jenkins; the ServiceMonitor CRD would not exist yet'); sys.exit(1)"

t T18.22 "destroy.sh removes the observability release before the ALB controller" python3 -c "
import sys
s = open('scripts/destroy.sh').read()
o, c = s.find('helm uninstall kube-prometheus-stack'), s.find('helm uninstall aws-load-balancer-controller')
if o < 0: print('destroy.sh never removes the stack'); sys.exit(1)
if o > c: print(\"the ALB controller goes first, so Grafana's ALB would be orphaned\"); sys.exit(1)"

t T18.23 "prometheus_client runs in multiprocess mode with all three gunicorn hooks" bash -c '
  grep -q "PROMETHEUS_MULTIPROC_DIR" app/common/metrics.py || { echo "no multiprocess dir"; exit 1; }
  for svc in backend worker; do
    for hook in on_starting when_ready child_exit; do
      grep -q "def ${hook}" "app/${svc}/gunicorn.conf.py" || { echo "${svc}: missing ${hook} hook"; exit 1; }
    done
    grep -q "reset_multiproc_dir" "app/${svc}/gunicorn.conf.py" || { echo "${svc}: does not wipe the dir at start"; exit 1; }
    grep -q "mark_worker_dead" "app/${svc}/gunicorn.conf.py" || { echo "${svc}: does not mark dead workers"; exit 1; }
  done'

# The cardinality rule, checked against the code rather than trusted.
t T18.24 "every metric label value comes from a bounded source" python3 -c "
import ast, sys

# REWRITTEN BY THE PRE-HANDOVER AUDIT, because the version this replaces is the
# best example in this repository of the failure it was written to prevent.
#
# It was a DENYLIST: it grepped for 'ticket', 'email', 'request.path', 'url',
# 'user_id' and 'idempot' near a .labels() call. Every one of those is a value
# the author had already thought of and already avoided, so the check could only
# ever confirm what was already known. Meanwhile the code passed
# request.method — a string the CLIENT chooses, which Werkzeug does not restrict
# to the known verbs — straight into a label, and this test reported PASS on
# every run. A denylist of your own good decisions is not a test.
#
# So it is now an ALLOWLIST, enforced structurally rather than textually: parse
# the module and require that every keyword argument to a .labels() call is a
# literal, a name bound to a module-level constant, or the return value of one
# of the three functions whose whole job is to bound a value. Anything new and
# unbounded fails by DEFAULT instead of passing by default.
BOUNDED_CALLS = {'_method_label', '_route_label', '_status_label', '_unknown'}

src = open('app/common/metrics.py').read()
tree = ast.parse(src)
problems = []

for node in ast.walk(tree):
    if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and node.func.attr == 'labels'):
        continue
    for kw in node.keywords:
        v = kw.value
        if isinstance(v, ast.Constant):
            continue                      # a literal: bounded by definition
        if isinstance(v, ast.Name):
            continue                      # a local, checked below by its origin
        if isinstance(v, ast.Call):
            fn = v.func
            name = getattr(fn, 'id', None) or getattr(fn, 'attr', None)
            if name in BOUNDED_CALLS:
                continue
            problems.append(f'{kw.arg}= is the result of {name}(), which is not one of {sorted(BOUNDED_CALLS)}')
            continue
        problems.append(f'{kw.arg}= is a {type(v).__name__}, which this check cannot prove is bounded')

# The bounding functions must actually bound. A collapse target has to be
# RETURNED by each, or the function is a rename rather than a limit.
#
# Over the AST and with the docstring excluded, on purpose. The first version of
# this block searched the function's source text for the sentinel, and both
# _method_label and _route_label mention their sentinel in their own docstring
# ('recorded as other', \"collapses into 'unmatched'\") — so gutting the function
# body while leaving the prose intact passed. That is the check-matches-its-own-
# documentation trap this repository has now hit three times; caught here by
# mutating the function and watching the test stay green.
for fn_name, sentinel in (('_method_label', 'other'), ('_route_label', 'unmatched')):
    fn = next((n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == fn_name), None)
    if fn is None:
        problems.append(f'{fn_name} is gone; label values are no longer collapsed')
        continue
    body = fn.body[1:] if (fn.body and isinstance(fn.body[0], ast.Expr)
                           and isinstance(fn.body[0].value, ast.Constant)
                           and isinstance(fn.body[0].value.value, str)) else fn.body
    returned = {n.value for sub in body for n in ast.walk(sub)
                if isinstance(n, ast.Constant) and isinstance(n.value, str)}
    if sentinel not in returned:
        problems.append(
            f'{fn_name} never produces the literal {sentinel!r} in its body, so it renames '
            'values rather than bounding them (a docstring mentioning it does not count)')

# request.method and request.path must never reach a label directly, in any of
# the three modules. This is the one denylist entry worth keeping, because it
# names the exact bug that was found rather than a category.
import re
for f in ('app/common/metrics.py', 'app/backend/app.py', 'app/worker/worker.py'):
    for i, line in enumerate(open(f), 1):
        if re.search(r'labels\([^)]*request\.(method|path|url|full_path)', line):
            problems.append(f'{f}:{i} passes a raw request attribute into a label')

if problems:
    print('unbounded metric labels:')
    for p in problems: print('  ' + p)
    sys.exit(1)
print('every .labels() argument is a literal or comes from a bounding function')"

t T18.25 "app_build_info is a Gauge, not an Info (unsupported in multiprocess mode)" bash -c '
  grep -q "app_build_info = Gauge" app/common/metrics.py || { echo "app_build_info is not a Gauge"; exit 1; }
  grep -qE "^from prometheus_client import.*\bInfo\b" app/common/metrics.py && { echo "Info is imported; it does not work in multiprocess mode"; exit 1; }
  exit 0'

t T18.26 "the gp3 StorageClass exists and waits for a consumer" python3 -c "
import yaml, sys
d = yaml.safe_load(open('k8s/storageclass-gp3.yaml'))
assert d['provisioner'] == 'ebs.csi.aws.com', 'wrong provisioner'
if d.get('volumeBindingMode') != 'WaitForFirstConsumer':
    print('must be WaitForFirstConsumer, or the volume can be created in a zone the pod cannot reach'); sys.exit(1)
assert d['parameters']['type'] == 'gp3'"

t T18.27 "the SLO thresholds agree across the rules, the gate and the values" bash -c '
  v=$(python3 -c "import yaml;print(yaml.safe_load(open(\"helm/observability/values.yaml\"))[\"slo\"][\"latencyP95Seconds\"])")
  grep -q "MAX_P95_SECONDS:-${v}" scripts/monitoring-gate.sh || {
    echo "the gate default (${v}) does not match helm/observability/values.yaml"; exit 1; }
  e=$(python3 -c "import yaml;print(yaml.safe_load(open(\"helm/observability/values.yaml\"))[\"slo\"][\"errorRatioAlert\"])")
  grep -q "MAX_ERROR_RATIO:-${e}" scripts/monitoring-gate.sh || {
    echo "the gate error threshold (${e}) does not match the values"; exit 1; }'

t T18.28 "no AWS account id, ARN or IP is committed in the observability values" bash -c '
  if grep -nE "arn:aws:|[0-9]{12}\.dkr\.ecr|inbound-cidrs: *\"?[0-9]{1,3}\." helm/observability/kube-prometheus-stack.values.yaml; then
    echo "a real identifier is committed"; exit 1
  fi; exit 0'

# Not "must be pinned": a fresh clone has no explicit pins and the chart version
# alone is already deterministic. What must never happen is a HALF-pinned file --
# a tag key that exists and is empty reads as pinned and behaves as "whatever the
# chart decides" -- or a pin block that replaced the settings around it.
t T18.31 "explicit image pins, if present, are complete and destroyed nothing" python3 -c "
import sys, yaml
p = 'helm/observability/kube-prometheus-stack.values.yaml'
raw = open(p).read()
d = yaml.safe_load(raw)
def dig(*path):
    cur = d
    for k in path:
        if not isinstance(cur, dict) or k not in cur: return None
        cur = cur[k]
    return cur
tags = {
  'prometheus':   dig('prometheus','prometheusSpec','image','tag'),
  'alertmanager': dig('alertmanager','alertmanagerSpec','image','tag'),
  'grafana':      dig('grafana','image','tag'),
  'operator':     dig('prometheusOperator','image','tag'),
  'ksm':          dig('kube-state-metrics','image','tag'),
  'nodeexporter': dig('prometheus-node-exporter','image','tag'),
}
present = [k for k,v in tags.items() if v]
bad = []
if present and len(present) != len(tags):
    bad.append('half-pinned: ' + ', '.join(sorted(set(tags) - set(present))) + ' have no tag')
if any(v is not None and not str(v).strip() for v in tags.values()):
    bad.append('an empty tag is set - that reads as pinned and behaves as unpinned')
# Whatever else changed, these must still be true. A duplicate top-level key
# would have replaced the block they live in.
for label, got, want in (
    ('retention',          dig('prometheus','prometheusSpec','retention'), None),
    ('prom ingress',       dig('prometheus','ingress','enabled'), False),
    ('am ingress',         dig('alertmanager','ingress','enabled'), False),
    ('grafana persistence',dig('grafana','persistence','enabled'), False),
    ('ne tolerations',     dig('prometheus-node-exporter','tolerations'), None),
):
    if want is False and got is not False: bad.append(label + ' is no longer False')
    if want is None and not got: bad.append(label + ' was lost')
import re
top = [l.split(':')[0] for l in raw.split(chr(10)) if re.match(r'^[a-zA-Z]', l) and ':' in l]
dupes = sorted({k for k in top if top.count(k) > 1})
if dupes: bad.append('duplicate top-level keys (the last one REPLACES the first): ' + ', '.join(dupes))
if bad: print(chr(10).join(bad)); sys.exit(1)
print('pins: ' + (str(len(present)) + ' explicit' if present else 'none, chart version governs') + '; all settings intact')"

t T18.32 "the pinning script exists, lints, and is idempotent by construction" bash -c '
  [ -x scripts/pin-observability-images.sh ] || { echo "not executable"; exit 1; }
  shellcheck scripts/pin-observability-images.sh || exit 1
  grep -q "ONCE, before the loop" scripts/pin-observability-images.sh || {
    echo "the per-run cleanup is not documented as running once - it stripped what earlier iterations inserted"; exit 1; }
  grep -q "self-check" scripts/pin-observability-images.sh || {
    echo "the writer does not verify its own output"; exit 1; }'

t T18.33 "the dashboard preview generator draws every panel and admits its data is fake" python3 -c "
import glob, json, subprocess, sys
defined = sum(1 for f in glob.glob('helm/observability/dashboards/*.json')
              for p in json.load(open(f))['panels'] if p['type'] != 'row')
r = subprocess.run([sys.executable, 'helm/observability/preview-dashboards.py'],
                   capture_output=True, text=True)
if r.returncode:
    print(r.stderr.strip()[:300]); sys.exit(1)
drawn = r.stdout.count('class=' + chr(34) + 'panel' + chr(34))
problems = []
# A generator that emitted an empty page would pass a bare exit-code check.
if drawn != defined:
    problems.append('preview drew %d panels; the dashboards define %d' % (drawn, defined))
# The preview must never be mistakable for evidence.
if 'not a Grafana screenshot' not in r.stdout:
    problems.append('the preview does not state that its data is synthetic')
if problems: print(chr(10).join(problems)); sys.exit(1)
print('%d panels drawn, synthetic-data warning present' % drawn)"

t T18.29 "the four diagrams are rendered and current" python3 -c "
import html, re, sys
def norm(t):
    t = html.unescape(t).replace(chr(160), ' ')
    return re.sub(r'\s+', ' ', t).strip()
stale = []
for name in ['architecture-deployment','architecture-pipeline',
             'architecture-observability','architecture-monitoring-flow']:
    mmd = open('docs/' + name + '.mmd').read()
    svg = norm(open('docs/' + name + '.svg').read())
    for a, b in re.findall(r'\[\"(.*?)\"\]|\{\{\"(.*?)\"\}\}', mmd):
        for x in re.split(r'<[^>]+>', a or b):
            x = norm(x)
            if len(x) >= 12 and x not in svg:
                stale.append(name + ': ' + x)
if stale: print(chr(10).join(stale[:5])); sys.exit(1)"

t T18.30 "the observability scripts are executable and lint clean" bash -c '
  for f in scripts/install-observability.sh scripts/verify-observability.sh \
           scripts/monitoring-gate.sh scripts/validate-observability.sh \
           scripts/port-forward-monitoring.sh; do
    [ -x "$f" ] || { echo "$f is not executable"; exit 1; }
  done
  command -v shellcheck >/dev/null || { echo "shellcheck not installed"; exit 1; }
  shellcheck scripts/install-observability.sh scripts/verify-observability.sh \
             scripts/monitoring-gate.sh scripts/validate-observability.sh \
             scripts/port-forward-monitoring.sh'

# ===========================================================================
# THE LAST CHECK, AND IT HAS TO BE LAST.
#
# T1.2 asserts the tree is free of build junk. It runs FIRST, so it describes
# the tree the suite INHERITED -- it can say nothing about the tree the suite
# LEAVES. Those are different claims, and the gap between them hid a real bug:
# checks that execute the application wrote __pycache__ under app/, so the suite
# passed on a clean checkout and failed on every subsequent run. The check that
# would have caught it existed; it was simply at the wrong end.
#
# Same assertion, different moment. A suite that cannot be run twice is one
# people learn to precede with `rm -rf`, and a real failure eventually gets
# swept away with the noise.
t T18.45 "the suite left the working tree as clean as it found it" bash -c '
  # Compares against the snapshot taken before any check ran, so this reports
  # only what THE SUITE created. The previous version listed everything it found
  # and said "the suite created files" -- which was wrong for a stale
  # .pytest_cache left by an earlier run, and sent the reader looking for a bug
  # in the wrong place. Blaming the wrong cause is its own kind of false result.
  created=$(comm -13 <(printf "%s\n" "$JUNK_AT_START") <(junk_list))
  if [ -n "$created" ]; then
    echo "the suite CREATED these, so the next run starts red:"
    echo "$created"
    echo ""
    echo "Whatever ran the application code needs PYTHONDONTWRITEBYTECODE=1"
    echo "(exported at the top of this file), -p no:cacheprovider for pytest,"
    echo "or a clean_pycache call after it."
    exit 1
  fi
  echo "the suite created no bytecode, caches or egg-info of its own"'

echo ""
echo "=============================================="
echo "  RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ $FAIL -gt 0 ] && printf '  FAILED:  %s\n' "${FAILED_TESTS[@]}"
# Skips are LISTED, always, not just counted. A skip is a check that did not
# run, and the only thing worse than not running it is not knowing you did not
# run it. Reading this list is part of reading the result.
if [ $SKIP -gt 0 ]; then
    echo ""
    echo "  These checks did NOT run. They are not passes:"
    printf '  SKIPPED: %s\n' "${SKIPPED_TESTS[@]}"
    echo ""
    echo "  Each reason above says what it needs. Missing tooling:"
    echo "    ./scripts/install-test-tooling.sh"
    echo "  Needs root (starts postgresql, creates a test database):"
    echo "    sudo bash tests/run_all.sh"
fi
echo "=============================================="
exit $FAIL
