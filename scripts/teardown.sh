#!/usr/bin/env bash
# Tear down the demo: sandboxes, providers, gateway, services, SPIRE.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OS=(openshell --gateway zt2 --gateway-endpoint http://127.0.0.1:18083)

echo "== sandboxes, providers, profiles =="
for sbx in $("${OS[@]}" sandbox list 2>/dev/null | awk 'NR>1 {print $1}'); do
    "${OS[@]}" sandbox delete "$sbx" 2>&1 | tail -1 || true
done
for prov in $("${OS[@]}" provider list 2>/dev/null | awk 'NR>1 {print $1}'); do
    "${OS[@]}" provider delete "$prov" >/dev/null 2>&1 || true
done
# Profiles are immutable per ID, so a fresh setup requires them gone.
for prof in $("${OS[@]}" profile list 2>/dev/null | awk 'NR>1 && $1 ~ /^zt2-/ {print $1}'); do
    "${OS[@]}" profile delete "$prof" >/dev/null 2>&1 || true
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

echo "Done. VM hosts entry for token-issuer.zt-demo.svc was left in place"
echo "(harmless; remove with: podman machine ssh \"sudo sed -i '' /token-issuer.zt-demo.svc/d /etc/hosts\")."
