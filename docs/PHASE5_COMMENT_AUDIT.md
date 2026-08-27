# Comment audit — proposal, nothing changed yet

> **STATUS: still an open proposal, and deliberately so.** No comment has been
> edited. Phase 5 was built and audited without acting on any of it, because
> none of these are defects — they are questions of house style in prose that is
> already accurate. The list is kept so the decision is recorded rather than
> forgotten; it is not pending work, and nothing depends on it.
>
> Its two companions are gone: `PHASE5_CLEANUP_PROPOSAL.md` described removals
> that were carried out in `75eedb4` and so had become a document claiming
> nothing had been deleted after 42 files were, and `REVIEW_REMEDIATION.md` was
> the Phase 4 review log — the one item in it that was still open is now stated
> plainly in README §13.

Audited every comment in every tracked file for references to the review and
phase process that produced them. **176 sites** carry that residue.

**The finding in one line:** almost none of these comments should be *deleted* —
the marker in front of them should be. The pattern is nearly always
`REVIEW FIX 4.6 — <a genuinely useful explanation>`. Strip the marker and the
comment stops reading as a review tracker and starts reading as what it
actually is: why the code is written this way.

---

## Category 1 — `REVIEW FIX N.M` markers · **107 sites, 42 files**

Every one follows the same shape. Two real examples:

```diff
- # REVIEW FIX 4.7 — captured HERE, before destroy. After destroy the state is
+ # Captured HERE, before destroy. After destroy the state is
    empty and `terraform output` returns nothing, so reading it at verification
    time would silently fall back to the default and check the wrong tag.

- # REVIEW FIX 3.4 — was: CMD ["python3", "app.py"], i.e. Flask's development
+ # Was: CMD ["python3", "app.py"], i.e. Flask's development
    server. Werkzeug is single-threaded by default, prints a production warning
    into the pod log on every start, and is not built to face traffic.
```

The rationale survives intact. Only the bookkeeping goes. Mechanical: strip
`REVIEW FIX N.M — `, capitalise the first surviving word.

### The knock-on, and I was wrong about it

In the cleanup proposal I argued for keeping `docs/REVIEW_REMEDIATION.md`
(1,248 lines) **because** 90 of these markers index into it. That was the whole
case for it. Strip the markers and the case disappears with them — the document
becomes a tracker for a Phase 3 review, with nothing left pointing at it.

**So: if you approve Category 1, `docs/REVIEW_REMEDIATION.md` should go too**,
along with the sentence at `README.md:614` that names it. I recommended keeping
it before; that recommendation was conditional on the markers staying, and you
have just removed the condition.

---

## Category 2 — the grading process itself · **8 sites**

These do not describe the code, they describe someone marking it.

| File | Now | Proposed |
|---|---|---|
| `tests/run_all.sh:1338` | "the reviewer scored 7/8 because these were documented in prose and code but not drawn" | drop the sentence; the test's own description already says what it checks |
| `app/backend/app.py:98` | "the review asked for channel-specific state, not a replacement" | "channel-specific state was needed, not a replacement" |
| `app/worker/test_worker.py:93` | "the review identified the behaviour they pinned as…" | "the behaviour they pinned was identified as…" |
| `app/backend/gunicorn.conf.py:50` | "useful when the reviewer asks which hop is slow" | "useful when you need to know which hop is slow" |
| `k8s/namespace.yaml:29` | "discovered later by a reviewer" | "discovered later, in production" |
| `scripts/collect-ci-evidence.sh:11` | "a reviewer reading the repository sees no…" | "anyone reading the repository sees no…" |
| `jenkins/values.example.yaml:8` | "so a reviewer can see what is injected" | "so a reader can see what is injected" |
| `tests/check_doc_links.py:4` | "how a reviewer following the docs ends up at a dead end" | "how someone following the docs ends up at a dead end" |

---

## Category 3 — `LESSON` shout-markers · **3 sites**

`helm/backend/templates/deployment.yaml`, `helm/worker/templates/deployment.yaml`
(`LIVE-DEPLOY LESSON:`) and `terraform/modules/s3/main.tf` (`LIVE-DESTROY
LESSON:`). Same treatment as Category 1 — the body is a real incident report
and stays; the diary heading goes.

Say if you would rather keep these. They are the only marker in the repo that
flags "this comment exists because something broke in production", and there is
an argument for that signal.

---

## Category 4 — `phase N` references · **48 sites, three different kinds**

### 4a · Stale titles that will simply be wrong · 14 sites — **change these**

Two of them escape the repository entirely:

- **`jenkins/values.yaml:248`** — the JCasC system message reads
  `VM Order Portal — Phase 4 CI/CD`. That is **printed on the Jenkins home
  page** for anyone who opens it.
- **`scripts/create-cert.sh:79`** — the certificate subject contains
  `OU=DevOps Phase 4`. That is **baked into a real TLS certificate** served by
  the ALB.

The rest are file headers and banners: `terraform/main.tf:1,5`,
`terraform/variables.tf:1`, `terraform/modules/eks/main.tf:3`,
`jenkins/rbac.yaml:1`, `scripts/deploy.sh:13,19`, `scripts/destroy.sh:3,22`,
`.github/workflows/ci.yml:2`, and four test-group labels in `tests/run_all.sh`
(255, 269, 357, 367).

### 4b · Real engineering history · 6 sites — **keep the lesson, drop the numbering**

These explain why something looks the way it does, and deleting them would lose
information. But "phase 2" means nothing to anyone outside this course, so name
the thing instead of the phase:

| File | Now | Proposed |
|---|---|---|
| `docker/frontend/nginx.conf:2–3` | "Phase 2 had: `proxy_pass http://{{ backend_private_ip }}:5000/` (Ansible-templated IP)" | "The EC2/Ansible version templated a private IP in here…" |
| `app/backend/app.py:25` | "It was a phase 2 leftover" | "It was a leftover from the EC2 deployment" |
| `terraform/modules/irsa/main.tf:2–3` | "the phase 3 replacement for phase 2 EC2 instance profiles" | "replaces EC2 instance profiles" |
| `terraform/variables.tf:76` | "LOWERCASE only (lesson learned in phase 2!)" | "LOWERCASE only — S3 rejects uppercase bucket names" |
| `terraform/modules/eks/main.tf:95` | "nodes are PRIVATE — phase 2 lesson kept" | "nodes are PRIVATE — deliberate, not a default" |
| `terraform/modules/s3/main.tf:6` | "a phase 2 lesson relearned the hard way" | "relearned the hard way" |

### 4c · "unchanged from phase N" noise · 28 sites — **delete the reference**

`docker/{backend,worker,frontend}/Dockerfile`, `helm/*/templates/deployment.yaml`
(×4), `terraform/modules/vpc/{main,variables}.tf`, `terraform/modules/rds/{main,variables}.tf`,
`terraform/modules/eks/{main,variables}.tf`, `terraform/terraform.tfvars.example`,
`setup.cfg`, `Jenkinsfile-cd:434`.

"Application code (unchanged from phase 2)" tells a reader nothing about the
code and everything about a repository they cannot see. Where a sentence has
substance after the phase reference, the substance stays.

---

## Category 5 — leave alone · **10 sites**

Comments that point at a test which exists right now: `See T14.58`,
`See T14.59`, `See T14.60`, `See T17.11`, `T14.62`, and similar. These are live
cross-references, not history — following one lands on a test that runs today.

`evidence/README.md` also mentions "a reviewer of Phase 4" and that is accurate:
it explains where Phase 4's evidence went.

---

## Also in scope, since you said "all files"

`README.md` carries 5 phase/review references, including the line that names
`docs/REVIEW_REMEDIATION.md`. It is the operator's manual, so it should describe
the system rather than the history that produced it. Same treatment.

---

## Totals

| Category | Sites | Action |
|---|---:|---|
| 1 · `REVIEW FIX` markers | 107 | strip marker, keep rationale |
| 2 · grading process | 8 | reword |
| 3 · `LESSON` markers | 3 | strip marker, keep body |
| 4a · stale titles | 14 | rewrite (2 of them are user-visible) |
| 4b · real history | 6 | keep, drop the phase numbering |
| 4c · "unchanged from phase N" | 28 | delete the reference |
| 5 · live test pointers | 10 | **no change** |
| README | 5 | reword |
| **plus** `docs/REVIEW_REMEDIATION.md` | 1,248 lines | delete, once nothing indexes into it |

No test asserts on comment text — I checked. The only risk is the four test-group
*labels* in `tests/run_all.sh` that say "phase 4", and those are display strings.

---

## What I need from you

1. **Categories 1, 2, 4a, 4c** — approve as one batch?
2. **Category 3** — strip the `LESSON` markers, or keep them as a deliberate
   "this broke in production once" signal?
3. **Category 4b** — reword to name the thing instead of the phase, or leave?
4. **`docs/REVIEW_REMEDIATION.md`** — delete, now that the case for keeping it
   is gone?
