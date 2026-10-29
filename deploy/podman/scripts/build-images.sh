#!/usr/bin/env bash
# Build the demo service images.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

IMAGE_PREFIX="${IMAGE_PREFIX:-localhost/zt2}"
podman build -t "${IMAGE_PREFIX}/token-issuer" -f "${SCRIPT_DIR}/../Containerfile.token-issuer" "$REPO_ROOT"
podman build -t "${IMAGE_PREFIX}/document-service" -f "${SCRIPT_DIR}/../Containerfile.document-service" "$REPO_ROOT"
printf "built %s/token-issuer and %s/document-service\n" "$IMAGE_PREFIX" "$IMAGE_PREFIX"
