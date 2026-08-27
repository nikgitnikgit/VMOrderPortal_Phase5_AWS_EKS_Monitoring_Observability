# jenkins/agent-tools/Dockerfile
# Pre-baked tools image for Jenkins agent Pods (both CI and CD).
#
# Building tools into the image avoids apt-get on every build (~2 min saved)
# and removes the failure mode where a package mirror is down mid-pipeline.
#
# Runs as a non-root user. Pinned base image, never :latest. This image is
# itself scanned by Trivy in install-jenkins.sh before it is pushed.

FROM debian:12.9-slim@sha256:12c396bd585df7ec21d5679bb6a83d4878bc4415ce926c9e5ea6426d23c60bdc

# THE TAG THIS IMAGE IS PUBLISHED UNDER. Bump it in the SAME commit as any
# change to this file.
#
# vm-order-jenkins-agent has IMMUTABLE tags, and install-jenkins.sh skips the
# build entirely when the tag already exists in ECR:
#
#     already in ECR — skipping build
#
# So editing this Dockerfile WITHOUT bumping the tag does not fail loudly --
# it silently keeps running the old image, and every change here becomes a
# no-op that still reads as applied. T17.11 asserts this label matches the tag
# the scripts publish, so the two can no longer drift apart.
LABEL tools.version="1.4"

# REVIEW FIX 1.3 (hadolint DL4006) — several RUN steps below pipe `curl` into
# `tar`. The default /bin/sh reports only the exit status of the LAST command
# in a pipeline, so a truncated or 404 download still produces a "successful"
# layer and a broken binary gets baked into the image. That failure surfaces
# mid-pipeline, hours later, as "helm: not found".
# With pipefail the pipeline fails on the curl, and the build fails here.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# xz-utils is required: shellcheck ships as .tar.xz and `tar xJ` cannot
# unpack it without xz, which debian-slim does not include.
# `apt-get upgrade` matters here: the base image tag is pinned for
# reproducibility, but pinning also freezes whatever CVEs shipped with it.
# Upgrading pulls the patched versions Debian has released since (this cleared
# 2 CRITICAL findings in libgnutls30). Unfixable CVEs remain — see the note on
# --ignore-unfixed in scripts/install-jenkins.sh.
# hadolint ignore=DL3008
RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        unzip \
        xz-utils \
        git \
        jq \
        python3 \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

# --- Python tooling for the CI lint and test stages ---
# hadolint ignore=DL3013
RUN pip3 install --no-cache-dir --break-system-packages \
        pytest==8.3.4 \
        pytest-cov==6.0.0 \
        flake8==7.1.1 \
        flask==3.1.0 \
        psycopg2-binary==2.9.9 \
        boto3==1.37.0 \
        requests==2.32.3 \
        prometheus-client==0.21.1

# --- AWS CLI v2 ---
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscli.zip \
    && unzip -q /tmp/awscli.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscli.zip

# --- kubectl: minor version matched to the EKS cluster ---
# kubectl supports only +/- 1 minor of skew from the API server, so this must
# track terraform/modules/eks/variables.tf. Patch resolved at build time.
ARG KUBECTL_MINOR=1.35
RUN KUBECTL_VERSION=$(curl -fsSL "https://dl.k8s.io/release/stable-${KUBECTL_MINOR}.txt") \
    && curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client

# --- Helm ---
# REVIEW FIX P1 — PINNED. This step used to read:
#
#     HELM_VERSION=$(curl -fsSL .../helm/releases/latest | jq -r .tag_name)
#
# with a comment arguing that resolving latest keeps Helm's vendored CVEs
# current, and that ECR tag immutability made the image reproducible anyway.
# The CVE half of that reasoning is sound. The reproducibility half is not:
# an immutable tag pins the image you already built, not the image the next
# `docker build` of this identical Dockerfile produces.
#
# That distinction stopped being academic. `releases/latest` now returns
# v4.2.4 -- Helm 4 shipped, and a rebuild of this file would silently cross a
# MAJOR version boundary into a toolchain that never ran a single pipeline
# here. `helm lint`, `helm upgrade --install` and the CD dry-run would all be
# executing on software no evidence in this repository was collected with.
#
# So: pinned to the current 3.x patch, which keeps the CVE currency the old
# comment was protecting (v3.21.4 is 3.x's newest, not a stale 3.15) without
# the major-version jump. Moving to Helm 4 is a decision to make deliberately,
# behind a test run -- not a side effect of rebuilding an image.
#
# Checksummed, because a pinned version means nothing if the bytes behind the
# URL can change. sha256sum -c fails the build rather than baking in whatever
# arrived. Update both values together; see README section 10.9.
ARG HELM_VERSION=v3.21.4
ARG HELM_SHA256=61f88ab166748cb19604d7884cb100ae9ccb13804ddeb98e08af167eacbb6a14
RUN curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tgz \
    && echo "${HELM_SHA256}  /tmp/helm.tgz" | sha256sum -c - \
    && tar xz -C /tmp -f /tmp/helm.tgz \
    && mv /tmp/linux-amd64/helm /usr/local/bin/helm \
    && rm -rf /tmp/linux-amd64 /tmp/helm.tgz \
    && helm version

# --- ShellCheck ---
ARG SHELLCHECK_VERSION=0.10.0
RUN curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
    | tar xJ -C /tmp \
    && mv "/tmp/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck \
    && rm -rf /tmp/shellcheck-*

# --- Hadolint ---
ARG HADOLINT_VERSION=2.12.0
RUN curl -fsSLo /usr/local/bin/hadolint \
      "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-Linux-x86_64" \
    && chmod +x /usr/local/bin/hadolint

# --- Phase 5: validating the observability objects in CI ---------------------
# promtool     parses PromQL and checks PrometheusRule files
# kubeconform  validates rendered manifests, including custom resources, against
#              JSON schemas -- vendored in tests/crd-schemas so validation is
#              hermetic and needs no network at build time
#
# Both are pinned by version, and the version is an ARG so a bump is one visible
# line in a diff rather than a moving `latest`.
#
# NOT installed: yq. Two unrelated programs use that name with incompatible
# syntax, so scripts/validate-observability.sh extracts rule specs with python3
# instead -- which is already here and behaves the same everywhere.

# --- promtool (from the Prometheus release tarball) ---
ARG PROMTOOL_VERSION=3.1.0
RUN curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${PROMTOOL_VERSION}/prometheus-${PROMTOOL_VERSION}.linux-amd64.tar.gz" \
    | tar xz -C /tmp \
    && mv "/tmp/prometheus-${PROMTOOL_VERSION}.linux-amd64/promtool" /usr/local/bin/promtool \
    && rm -rf /tmp/prometheus-* \
    && promtool --version

# --- kubeconform ---
ARG KUBECONFORM_VERSION=0.7.0
RUN curl -fsSL "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" \
    | tar xz -C /tmp \
    && mv /tmp/kubeconform /usr/local/bin/kubeconform \
    && kubeconform -v

# Non-root. UID 1000 matches the Jenkins agent convention and the fsGroup
# set on the agent Pod, so the shared workspace volume is writable.
RUN groupadd -g 1000 jenkins && useradd -u 1000 -g 1000 -m jenkins
USER 1000
WORKDIR /home/jenkins

CMD ["sleep", "infinity"]
