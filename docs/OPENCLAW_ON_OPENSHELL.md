# Run OpenClaw in OpenShell

This guide runs the OpenClaw reference image in an OpenShell sandbox on a remote OpenShift cluster. It assumes the OpenShell gateway is already deployed and running.

## Tested versions

| Component | Version |
| --- | --- |
| OpenShell CLI | `0.1.3` |
| OpenShell gateway | `0.1.3-rhaiv.3` |
| OpenClaw | `2026.9.5` (`ec9c1a1`) |
| OpenClaw image | `quay.io/opendatahub/odh-openshell-sandbox-openclaw@sha256:b977255e7ee9a8e3cea95bc8ba3ad08a93c5e9ad335984e2db1282b80eb82441` |
| Image source revision | `217024d0ffd452bcd06c638729d6545c71fa922f` |

The image digest is a multi-architecture manifest for `linux/amd64` and `linux/arm64`. On October 16, 2026, the mutable `odh-stable` tag pointed to this digest. Pin the digest to make repeated deployments use the same image.

The image is an unsupported OpenDataHub reference composition, not RHOAI product content. Its [source README](https://github.com/opendatahub-io/openshell/blob/217024d0ffd452bcd06c638729d6545c71fa922f/deploy/konflux/openclaw/README.md) describes its contents and support status.

## Prerequisites

Install these tools on the client machine:

- OpenShell CLI `0.1.3`.
- OpenShift CLI (`oc`) with access to the cluster.
- OpenSSL for optional certificate verification.

Verify the OpenShell CLI before continuing:

```shell
command -v openshell
openshell --version
```

The version command must report `openshell 0.1.3`.

## Export the connection settings

Run these exports in each terminal that issues setup commands:

```shell
export OPENSHELL_NAMESPACE=openshell-0-1-3
export OPENSHELL_GATEWAY_SERVICE=openshell-0-1-3
export OPENSHELL_TLS_SECRET=openshell-client-tls
export OPENSHELL_LOCAL_PORT=18083

export OPENSHELL_GATEWAY=test-013
export OPENSHELL_WORKSPACE=openclaw-test-013
export OPENCLAW_SANDBOX=openclaw-native

export OPENCLAW_IMAGE='quay.io/opendatahub/odh-openshell-sandbox-openclaw@sha256:b977255e7ee9a8e3cea95bc8ba3ad08a93c5e9ad335984e2db1282b80eb82441'
export MODEL_BASE_URL='https://api.enmaas.devshift.net/v1'
export MODEL_ID='rits/zai-org/glm-5-3'
```

`OPENSHELL_GATEWAY` and `OPENSHELL_WORKSPACE` are read directly by the OpenShell CLI. The other variables keep the remaining commands consistent.

## Forward the gateway port

Keep the port-forward running in its own terminal:

```shell
oc -n "$OPENSHELL_NAMESPACE" port-forward \
  "svc/$OPENSHELL_GATEWAY_SERVICE" \
  "$OPENSHELL_LOCAL_PORT:8080"
```

The local gateway endpoint is `https://127.0.0.1:18083`. The generated server certificate includes `127.0.0.1` in its subject alternative names, so the CLI can verify the endpoint without disabling TLS verification.

## Install the mTLS client bundle

The CLI loads the gateway certificate authority, client certificate, and client key from `~/.config/openshell/gateways/<gateway-name>/mtls/`.

Create that directory and copy the generated bundle from the cluster:

```shell
export OPENSHELL_MTLS_DIR="$HOME/.config/openshell/gateways/$OPENSHELL_GATEWAY/mtls"

mkdir -p "$OPENSHELL_MTLS_DIR"
chmod 700 "$OPENSHELL_MTLS_DIR"

(
  umask 077
  oc -n "$OPENSHELL_NAMESPACE" get secret "$OPENSHELL_TLS_SECRET" \
    -o jsonpath='{.data.ca\.crt}' | base64 -d > "$OPENSHELL_MTLS_DIR/ca.crt"
  oc -n "$OPENSHELL_NAMESPACE" get secret "$OPENSHELL_TLS_SECRET" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > "$OPENSHELL_MTLS_DIR/tls.crt"
  oc -n "$OPENSHELL_NAMESPACE" get secret "$OPENSHELL_TLS_SECRET" \
    -o jsonpath='{.data.tls\.key}' | base64 -d > "$OPENSHELL_MTLS_DIR/tls.key"
)
```

Check the files and verify that the client certificate chains to the copied CA:

```shell
chmod 600 "$OPENSHELL_MTLS_DIR/ca.crt" \
  "$OPENSHELL_MTLS_DIR/tls.crt" \
  "$OPENSHELL_MTLS_DIR/tls.key"

openssl verify \
  -CAfile "$OPENSHELL_MTLS_DIR/ca.crt" \
  "$OPENSHELL_MTLS_DIR/tls.crt"
```

Do not use `--gateway-insecure`. The copied CA supports full server certificate verification, and the client certificate provides mTLS authentication.

## Register and verify the gateway

Register the port-forwarded endpoint under the same name used for the mTLS directory:

```shell
openshell gateway add \
  "https://127.0.0.1:$OPENSHELL_LOCAL_PORT" \
  --local \
  --name "$OPENSHELL_GATEWAY"

openshell status
```

The status output should report:

```text
Gateway: test-013
Server: https://127.0.0.1:18083
Status: Connected
Authentication: Authenticated (mTLS transport)
Version: 0.1.3-rhaiv.3
```

If the gateway is already registered, skip `gateway add` and run `openshell status`.

## Create the workspace

List the gateway workspaces:

```shell
openshell workspace list
```

Create the OpenClaw workspace if `openclaw-test-013` is not present:

```shell
OPENSHELL_WORKSPACE=default openshell workspace create \
  --name "$OPENSHELL_WORKSPACE"
```

## Define the model provider

Save the following profile as `model-provider-profile.yaml`:

```yaml
id: openclaw-model
display_name: EnMaaS GLM for OpenClaw
description: OpenAI-compatible EnMaaS GLM endpoint
category: inference
inference_capable: true
credentials:
  - name: api_key
    description: EnMaaS API key
    env_vars: [CUSTOM_API_KEY]
    required: true
    auth_style: bearer
    header_name: authorization
discovery:
  credentials: [api_key]
endpoints:
  - host: api.enmaas.devshift.net
    port: 443
    protocol: rest
    access: read-write
    enforcement: enforce
binaries: [/usr/bin/node]
```

The endpoint host and port must match `MODEL_BASE_URL`. OpenShell binds the API key and network access to `/usr/bin/node` and this endpoint.

Validate and import the profile:

```shell
openshell profile lint -f model-provider-profile.yaml
openshell profile import -f model-provider-profile.yaml --global
```

Read the API key without adding it to shell history or a process argument, then create the provider:

```shell
read -rs "CUSTOM_API_KEY?EnMaaS API key: "; echo
export CUSTOM_API_KEY

openshell provider create \
  --name model \
  --type openclaw-model \
  --global-profile \
  --credential CUSTOM_API_KEY

unset CUSTOM_API_KEY
```

OpenShell stores the credential in the gateway credential store. The sandbox receives a scoped placeholder, not the API key value.

Verify the provider:

```shell
openshell provider list
```

## Create and onboard the OpenClaw sandbox

Create the sandbox directly from the pinned reference image. Attach the provider during creation so the initial OpenClaw process receives the credential placeholder and endpoint policy.

```shell
openshell sandbox create \
  --name "$OPENCLAW_SANDBOX" \
  --from "$OPENCLAW_IMAGE" \
  --provider model \
  --no-auto-providers \
  --env "MODEL_BASE_URL=$MODEL_BASE_URL" \
  --env "MODEL_ID=$MODEL_ID" \
  --env MODEL_CONTEXT_WINDOW=128000 \
  --env MODEL_MAX_TOKENS=4096 \
  --env MODEL_REASONING=false \
  --detach \
  --restart-policy never \
  -- bash -lc 'openclaw-start --version && exec sleep infinity'
```

`openclaw-start` writes `/sandbox/.openclaw/openclaw.json` on the first run. Later invocations reuse that configuration. The `sleep infinity` process keeps the sandbox ready after onboarding and after you exit the OpenClaw TUI.

Use the published image and its `/usr/local/bin/openclaw-start` command directly. This setup does not build a derived image or replace the startup script.

## Verify a model turn

Run a non-interactive prompt first:

```shell
openshell sandbox exec "$OPENCLAW_SANDBOX" -- \
  openclaw-start agent exec 'Reply with exactly: native-image-ok'
```

The final output should contain:

```text
native-image-ok
```

## Open the interactive TUI

Start an interactive OpenClaw session:

```shell
openshell sandbox exec --tty "$OPENCLAW_SANDBOX" -- \
  openclaw-start
```

Exiting the TUI does not stop the sandbox because its main process continues to run.

## Reconnect later

For a later session:

1. Start the `oc port-forward` command.
2. Export `OPENSHELL_GATEWAY`, `OPENSHELL_WORKSPACE`, and `OPENCLAW_SANDBOX`.
3. Run the TUI command again.

Check the sandbox before reconnecting:

```shell
openshell sandbox get "$OPENCLAW_SANDBOX"
openshell sandbox provider list "$OPENCLAW_SANDBOX"
```

## Adjust reasoning and response limits

The setup disables model reasoning and uses a 4,096-token output limit for faster interactive tests. You can switch between faster responses and higher reasoning without recreating the sandbox.

### Configure faster responses

Disable reasoning and reduce the output limit:

```shell
openshell sandbox exec "$OPENCLAW_SANDBOX" -- \
  openclaw config set \
  'models.providers.openshell-model.models[0].reasoning' \
  false --strict-json

openshell sandbox exec "$OPENCLAW_SANDBOX" -- \
  openclaw config set \
  'models.providers.openshell-model.models[0].maxTokens' \
  4096 --strict-json
```

### Configure higher reasoning

Enable reasoning and increase the output limit:

```shell
openshell sandbox exec "$OPENCLAW_SANDBOX" -- \
  openclaw config set \
  'models.providers.openshell-model.models[0].reasoning' \
  true --strict-json

openshell sandbox exec "$OPENCLAW_SANDBOX" -- \
  openclaw config set \
  'models.providers.openshell-model.models[0].maxTokens' \
  32768 --strict-json
```

Check the active model settings:

```shell
openshell sandbox exec "$OPENCLAW_SANDBOX" -- \
  openclaw config get \
  'models.providers.openshell-model.models[0]'
```

Restart the TUI after changing these values. Higher reasoning with a large output allowance can add substantial latency.
