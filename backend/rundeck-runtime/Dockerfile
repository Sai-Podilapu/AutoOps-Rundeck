# ============================================================
# The AutoOps execution runtime — Rundeck, plus every binary job-service used
# to provide.
#
# This image is the thing that REPLACES job-service. AutoOps used to ship a
# container with terraform, kubectl, python3 and the AWS CLI baked in at pinned
# versions, and ran tenant steps inside it. Rundeck's stock image has none of
# those, so a `terraform` step translated into a Rundeck script step would fail
# at 3am with "command not found" rather than at authoring time.
#
# Pinned by DIGEST, not tag. `rundeck/rundeck:5.8.0` is a moving target — the
# publisher can repoint it — and this container executes customer infrastructure
# changes, so "the image we tested" and "the image running" must be the same
# bytes. Re-pin with:
#     docker buildx imagetools inspect rundeck/rundeck:<tag>
# ============================================================
FROM rundeck/rundeck:5.8.0@sha256:8aebd86c96f21ec11f96c648f682d872cc3894077a6c64f1ede286aec4fb7c54

USER root

# Versions are pinned for the same reason the digest is: a step that ran green
# yesterday must not change behaviour because a mirror moved. Bump these
# deliberately, not implicitly.
# Every one of these was VERIFIED to resolve before being written down — an
# invented version number fails the build minutes in, which is exactly what
# happened with a guessed OpenTofu 1.9.8. Check a bump the same way:
#   curl -sIL -o /dev/null -w '%{http_code}\n' <the download url>
ARG TERRAFORM_VERSION=1.12.6
ARG KUBECTL_VERSION=1.36.4
ARG AWSCLI_VERSION=2.19.5

# The base is Debian/Ubuntu-derived, so apt — not apk.
#   ssh client  : `ssh` steps, and Rundeck's own default node executor
#   python3     : `pyscript` steps
#   powershell  : NOT installed. See "Known gaps" in the service README —
#                 pwsh on Linux does not run the Windows-only cmdlets the
#                 AutoOps script library is written against, so shipping it
#                 would make `powershell` steps fail confusingly rather than
#                 fail clearly.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        unzip \
        git \
        jq \
        openssh-client \
        python3 \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

# boto3 for pyscript steps that talk to AWS. Installed into a venv because the
# base image's python is externally managed (PEP 668) and a bare pip install
# is refused.
#
# A WRAPPER, not a symlink. CPython locates a venv by walking up from the path
# it was INVOKED as, looking for pyvenv.cfg — so a symlink at
# /usr/local/bin/autoops-python makes it look in /usr/local, find nothing,
# fall back to system site-packages, and fail with ModuleNotFoundError: boto3
# while every other runtime in this image reports healthy. `exec` keeps the
# process (and its signals and exit code) intact.
RUN python3 -m venv /opt/autoops-py \
    && /opt/autoops-py/bin/pip install --no-cache-dir \
        boto3==1.35.76 \
        requests==2.32.3 \
    && printf '#!/bin/sh\nexec /opt/autoops-py/bin/python3 "$@"\n' \
        > /usr/local/bin/autoops-python \
    && chmod +x /usr/local/bin/autoops-python

# OpenTofu is used rather than HashiCorp Terraform: it is the CLI-compatible
# fork under an open licence, which is what job-service already ran. A
# `terraform` step's HCL is unchanged.
RUN ARCH="$(dpkg --print-architecture)" \
    && curl -fsSL -o /tmp/tofu.zip \
        "https://github.com/opentofu/opentofu/releases/download/v${TERRAFORM_VERSION}/tofu_${TERRAFORM_VERSION}_linux_${ARCH}.zip" \
    && unzip -q /tmp/tofu.zip -d /usr/local/bin tofu \
    && chmod +x /usr/local/bin/tofu \
    # Steps and the script library both say `terraform`; the binary is tofu.
    && ln -s /usr/local/bin/tofu /usr/local/bin/terraform \
    && rm -f /tmp/tofu.zip

RUN ARCH="$(dpkg --print-architecture)" \
    && curl -fsSL -o /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
    && chmod +x /usr/local/bin/kubectl

# The AWS CLI backs `awslambda` steps. Rundeck OSS has no native Lambda step —
# that one is Enterprise-only — so the translator emits `aws lambda invoke`.
RUN ARCH="$(uname -m)" \
    && curl -fsSL -o /tmp/awscli.zip \
        "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}-${AWSCLI_VERSION}.zip" \
    && unzip -q /tmp/awscli.zip -d /tmp \
    && /tmp/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli \
    && rm -rf /tmp/awscli.zip /tmp/aws

# Fail the BUILD if a runtime is missing, rather than discovering it when a
# tenant's production step exits 127.
RUN set -e; \
    for bin in terraform tofu kubectl aws python3 autoops-python ssh git jq; do \
        command -v "$bin" >/dev/null || { echo "MISSING: $bin"; exit 1; }; \
    done; \
    echo "runtime check passed:"; \
    terraform version | head -1; \
    kubectl version --client=true 2>/dev/null | head -1 || true; \
    aws --version; \
    # Not just "does the interpreter exist" — does it actually resolve the
    # packages a pyscript step will import. The symlink-vs-wrapper bug passed
    # a presence check and failed here.
    autoops-python -c "import boto3, requests; print('python deps ok', boto3.__version__)"

USER rundeck
