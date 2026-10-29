#!/usr/bin/env bash
# Tear down the demo: sandboxes, providers, gateway, services, SPIRE.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../deploy/podman/spire/common.sh
source "$ROOT/deploy/podman/spire/common.sh"
OS=(openshell --gateway zt2 --gateway-endpoint http://127.0.0.1:18083)

echo "== sandboxes, providers, profiles =="
for sbx in $("${OS[@]}" sandbox list 2>/dev/null | awk 'NR>1 {print $1}'); do
    "${OS[@]}" sandbox delete "$sbx" 2>&1 | tail -1 || true
done
for prov in $("${OS[@]}" provider list 2>/dev/null | awk 'NR>1 {print $1}'); do
    "${OS[@]}" provider delete "$prov" >/dev/null 2>&1 || true
done
# Profiles are immutable per ID, so a fresh setup requires them gone.
# Best-effort like the rest of teardown, but a failed deletion is
# reported: a leftover profile will break the next setup.
for prof in $("${OS[@]}" profile list 2>/dev/null | awk 'NR>1 && $1 ~ /^zt2-/ {print $1}'); do
    if ! "${OS[@]}" profile delete "$prof" >/dev/null 2>&1; then
        printf "warning: failed to delete profile %s (the next setup will fail if it persists)\n" "$prof" >&2
    fi
done

echo "== containers =="
for c in zt2-gateway zt2-token-issuer \
    zt2-document-engineering zt2-document-finance zt2-document-admin \
    zt2-document-hr zt2-document-public \
    zt2-spire-agent zt2-spire-oidc zt2-spire-server; do
    podman rm -f "$c" >/dev/null 2>&1 || true
done

echo "== network =="
podman network rm zt2 >/dev/null 2>&1 || true

if [[ "$ZT2_HOST_OS" == "linux" ]]; then
    if grep -q "token-issuer.zt-demo.svc" /etc/hosts; then
        echo "== hosts entry =="
        sudo sed -i "/token-issuer.zt-demo.svc/d" /etc/hosts
        echo "Removed token-issuer.zt-demo.svc from /etc/hosts."
    fi
    echo "Done."
else
    echo "Done. VM hosts entry for token-issuer.zt-demo.svc was left in place"
    echo "(harmless; remove with: podman machine ssh \"sudo sed -i '' /token-issuer.zt-demo.svc/d /etc/hosts\")."
fi
