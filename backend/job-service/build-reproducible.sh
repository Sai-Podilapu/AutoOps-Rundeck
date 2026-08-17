#!/usr/bin/env bash
#
# Reproducible image build for job-service.
#
# A plain `docker build` is NOT reproducible: BuildKit stamps layer metadata with
# the wall clock and adds provenance/SBOM attestations that embed build-time data.
# This script pins every non-deterministic input so the SAME source always yields
# the SAME image digest:
#
#   * SOURCE_DATE_EPOCH        fixed build clock (matches pom.xml outputTimestamp)
#   * --provenance/--sbom off  attestations embed timestamps + builder identity
#   * rewrite-timestamp=true   normalizes every layer's file mtimes to the epoch
#   * docker-container driver   the default "docker" driver can't do the above
#
# The Dockerfile itself is already reproducible-clean (digest-pinned bases, exact
# apk pins, hash-locked pip with hash-based .pyc, deterministic jar, apk.log removed).
#
# Usage:
#   ./build-reproducible.sh                       # -> job-service.oci.tar + prints digest
#   ./build-reproducible.sh myrepo/job-service:1.0 --push   # build and push that ref
#
set -euo pipefail

# 2025-01-01T00:00:00Z — keep in lockstep with <project.build.outputTimestamp> in pom.xml.
export SOURCE_DATE_EPOCH=1735689600
BUILDER=reproducible
IMAGE="${1:-job-service:repro}"
PUSH="${2:-}"

# One-time: a docker-container builder (supports rewrite-timestamp / oci export).
if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  docker buildx create --name "$BUILDER" --driver docker-container --bootstrap >/dev/null
fi

if [ "$PUSH" = "--push" ]; then
  OUTPUT="type=registry,name=${IMAGE},rewrite-timestamp=true"
else
  OUTPUT="type=oci,dest=job-service.oci.tar,name=${IMAGE},rewrite-timestamp=true"
fi

docker buildx build \
  --builder "$BUILDER" \
  --provenance=false --sbom=false \
  --output "$OUTPUT" \
  "$(dirname "$0")"

# Report the manifest digest (the reproducible identifier).
if [ "$PUSH" != "--push" ]; then
  python -c "import tarfile,json; t=tarfile.open('job-service.oci.tar'); \
print('image digest:', json.load(t.extractfile('index.json'))['manifests'][0]['digest'])" \
    2>/dev/null || echo "built job-service.oci.tar (inspect index.json for the digest)"
fi
