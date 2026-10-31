#!/usr/bin/env bash
# Build the v2 service images for linux/amd64 on the RHEL 10 homelab
# host (podman --remote --connection rhel) and push them to quay.io.
#
# quay.io credentials must exist on the REMOTE host (they are used by
# the remote podman push); `podman --remote --connection rhel login
# quay.io` sets them up.
#
# Quay.io supports two-segment paths only: quay.io/<ns>/<repo>.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONNECTION="${ZT2_PODMAN_CONNECTION:-rhel}"
NAMESPACE="${ZT2_QUAY_NS:-panni}"
TAG="${ZT2_IMAGE_TAG:-v2}"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf "required command '%s' not found\n" "$1" >&2
        exit 1
    }
}
require_cmd podman

REMOTE=(podman --remote --connection "$CONNECTION")

if ! "${REMOTE[@]}" info >/dev/null 2>&1; then
    printf "cannot reach the podman connection '%s' (try: podman system connection list)\n" "$CONNECTION" >&2
    exit 1
fi
# Push credentials live on the remote host; probe with a lightweight
# authenticated call and point at the fix.
if ! "${REMOTE[@]}" login quay.io --tls-verify </dev/null >/dev/null 2>&1; then
    printf "quay.io credentials missing on '%s'. Fix:\n  podman --remote --connection %s login quay.io\n" "$CONNECTION" "$CONNECTION" >&2
    exit 1
fi

build() {
    local name="$1" containerfile="$2"
    local image="quay.io/${NAMESPACE}/${name}:${TAG}"
    printf '== building %s (linux/amd64 on %s) ==\n' "$image" "$CONNECTION"
    # The remote connection transfers the build context automatically.
    "${REMOTE[@]}" build --platform linux/amd64 \
        -t "$image" -f "$containerfile" "$ROOT"
    "${REMOTE[@]}" push "$image"
    printf '== pushed %s ==\n' "$image"
}

build zt2-token-issuer "$ROOT/deploy/podman/Containerfile.token-issuer"
build zt2-document-service "$ROOT/deploy/podman/Containerfile.document-service"
