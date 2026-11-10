#!/usr/bin/env bash
# Shared helpers for scenario scripts. Driver-neutral: everything
# backend-specific (gateway endpoint, sandbox lifecycle, SVID fetches,
# URL variables) lives in scripts/drivers/lib-${ZT2_DRIVER}.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${STATE_DIR:-$ROOT/.zt2-state}"
mkdir -p "$STATE_DIR"

# DocsClaw agent wiring shared by the A2A scenarios. The model provider
# and its three non-secret environment variables are Stage A artifacts;
# the API key itself stays in the provider, never in the sandbox.
MODEL_PROVIDER="${MODEL_PROVIDER:-docsclaw-model}"
SANDBOX_ENV=()

ZT2_DRIVER="${ZT2_DRIVER:-podman}"
DRIVER_FILE="$ROOT/scripts/drivers/lib-${ZT2_DRIVER}.sh"
if [[ ! -f "$DRIVER_FILE" ]]; then
    printf "unknown ZT2_DRIVER '%s' (no driver file at %s)\n" "$ZT2_DRIVER" "$DRIVER_FILE" >&2
    exit 1
fi
# shellcheck source=drivers/lib-podman.sh
source "$DRIVER_FILE"

# sandbox_spiffe_id ID — the SPIFFE ID of sandbox ID, identical across
# drivers (the trust domain and sandbox path are deployment-wide
# constants, not per-driver).
sandbox_spiffe_id() {
    echo "spiffe://openshell.local/openshell/sandbox/$1"
}

sandbox_id() {
    # Capture before parsing: awk's early exit closes the pipe and the
    # openshell CLI panics on the broken stdout, which pipefail turns
    # into a failed poll on Linux.
    local out
    out="$("${OS[@]}" sandbox get "$1" 2>/dev/null)" || return 1
    awk '/Id:/ {print $2; exit}' <<<"$out"
}

# create_sandbox NAME PROVIDER [IMAGE] [EXTRA_PROVIDER] -- creates a
# long-lived sandbox and prints its ID. The default image stays
# curlimages/curl so scenarios 1-6 are unchanged; agent sandboxes pass
# AGENT_IMAGE and a second provider for the model endpoint.
# sandbox create blocks on the bootstrap command, so run it detached.
create_sandbox() {
    local name="$1" provider="$2"
    local image="${3:-docker.io/curlimages/curl:latest}"
    local extra_provider="${4:-}"
    local providers=(--provider "$provider")
    [[ -n "$extra_provider" ]] && providers+=(--provider "$extra_provider")
    "${OS[@]}" sandbox delete "$name" >/dev/null 2>&1 || true
    # Deletion is asynchronous. Reusing the name while the old sandbox is
    # still going away makes get/create race with the old ID, and the
    # exposed service route then points at a sandbox that is gone.
    for _ in $(seq 1 20); do
        "${OS[@]}" sandbox get "$name" >/dev/null 2>&1 || break
        sleep 2
    done
    sleep 3
    pre_create_cleanup "$name"
    nohup "${OS[@]}" sandbox create --name "$name" \
        --from "$image" \
        "${providers[@]}" "${SANDBOX_ENV[@]}" --keep --no-tty --detach -- sleep infinity \
        >"$STATE_DIR/$name-create.log" 2>&1 &
    for _ in $(seq 1 60); do
        if id="$(sandbox_id "$name" 2>/dev/null)" && [[ -n "$id" ]]; then
            echo "$id"
            return 0
        fi
        sleep 2
    done
    echo "sandbox $name did not become ready; see $STATE_DIR/$name-create.log" >&2
    return 1
}

# sandbox_curl NAME URL EXPECTED_SUBSTRING [ATTEMPTS] — curl from inside
# the sandbox, retrying while the SVID propagates. Sets SANDBOX_CURL_OUTPUT.
sandbox_curl() {
    local name="$1" url="$2" expected="$3" attempts="${4:-18}"
    local output=""
    for i in $(seq 1 "$attempts"); do
        if output="$("${OS[@]}" sandbox exec --name "$name" --no-tty -- \
            curl -sS --max-time 15 "$url" 2>&1)"; then
            if [[ "$output" == *"$expected"* ]]; then
                SANDBOX_CURL_OUTPUT="$output"
                return 0
            fi
        fi
        sleep 2
    done
    echo "timed out waiting for $url to return '$expected'; last output:" >&2
    echo "$output" >&2
    return 1
}

# sandbox_upload NAME LOCAL [DEST] — copy a directory into a sandbox.
# DEST is the PARENT directory: a local agent/ lands as <dest>/agent,
# and the default destination is the driver's WORKSPACE_DIR.
# --no-git-ignore because the config directory
# lives under STATE_DIR, outside any work tree.
sandbox_upload() {
    local name="$1" local_path="$2" dest="${3:-$WORKSPACE_DIR}"
    "${OS[@]}" sandbox upload --no-git-ignore "$name" "$local_path" "$dest"
}

# sandbox_ask NAME PROMPT EXPECTED [ATTEMPTS] — run one prompt through
# the agent config at $WORKSPACE_DIR/agent, retrying while the SVID
# propagates (the supervisor caches a failed token grant). Stdout is the
# answer only; the tool trace goes to stderr. Sets SANDBOX_ASK_OUTPUT
# and SANDBOX_ASK_TRACE.
sandbox_ask() {
    local name="$1" prompt="$2" expected="$3" attempts="${4:-18}"
    local output="" trace=""
    for _ in $(seq 1 "$attempts"); do
        if output="$("${OS[@]}" sandbox exec --name "$name" --no-tty -- \
            docsclaw ask --config-dir "$WORKSPACE_DIR/agent" --trace "$prompt" 2>"$STATE_DIR/$name-ask.err")"; then
            trace="$(cat "$STATE_DIR/$name-ask.err")"
            if [[ "$output" == *"$expected"* ]]; then
                SANDBOX_ASK_OUTPUT="$output"
                SANDBOX_ASK_TRACE="$trace"
                return 0
            fi
        fi
        sleep 3
    done
    SANDBOX_ASK_OUTPUT="$output"
    SANDBOX_ASK_TRACE="$trace"
    return 1
}

# show_trace — print the tool calls from SANDBOX_ASK_TRACE in a compact
# form for the audience.
show_trace() {
    grep -E '^\s*(->|<-|←|→)' <<<"${SANDBOX_ASK_TRACE:-}" | sed 's/^/  /' || true
}

# service_url SANDBOX SERVICE — print the gateway's URL for an exposed
# sandbox service. Empty when the service is not exposed.
service_url() {
    local sandbox="$1" service="$2"
    "${OS[@]}" service list -o json 2>/dev/null |
        python3 -c '
import json, sys
want = sys.argv[1], sys.argv[2]
for svc in json.load(sys.stdin).get("services") or []:
    if (svc.get("sandbox"), svc.get("service")) == want:
        print(svc.get("url", ""))
        break
' "$sandbox" "$service"
}

# ensure_model_provider — create the DocsClaw model provider once per
# gateway. The credential key is the profile's env var name, and the key
# travels only in the command environment, never on argv.
ensure_model_provider() {
    if "${OS[@]}" provider list 2>/dev/null | awk 'NR>1 {print $1}' |
        grep -qx "$MODEL_PROVIDER"; then
        return 0
    fi
    if [[ -z "${LLM_API_KEY:-}" ]]; then
        printf "LLM_API_KEY is required to create the model provider %s\n" \
            "$MODEL_PROVIDER" >&2
        return 1
    fi
    LLM_API_KEY="$LLM_API_KEY" "${OS[@]}" provider create --name "$MODEL_PROVIDER" \
        --type docsclaw-model --credential LLM_API_KEY >/dev/null
}

# create_agent_service NAME PROVIDER PORT — create an agent sandbox
# (AGENT_IMAGE plus the model provider) and expose PORT with bearer
# passthrough. Prints the created sandbox ID; the service URL is read
# afterwards with service_url.
create_agent_service() {
    local name="$1" provider="$2" port="$3"
    local id
    # Failures inside a command substitution cannot lean on `set -e`
    # (bash disables it there unless inherit_errexit is set), so every
    # step is checked explicitly: otherwise an empty ID is reported as a
    # successful creation and the caller registers it.
    ensure_model_provider || return 1
    SANDBOX_ENV=(
        --env "LLM_PROVIDER=${LLM_PROVIDER:-openai}"
        --env "LLM_BASE_URL=${LLM_BASE_URL:?LLM_BASE_URL is required for agent scenarios}"
        --env "LLM_MODEL=${LLM_MODEL:?LLM_MODEL is required for agent scenarios}"
    )
    id="$(create_sandbox "$name" "$provider" "$AGENT_IMAGE" "$MODEL_PROVIDER")" || {
        SANDBOX_ENV=()
        return 1
    }
    SANDBOX_ENV=()
    "${OS[@]}" service expose "$name" "$port" agent \
        --authorization-mode bearer-passthrough >/dev/null || return 1
    echo "$id"
}

# render_alice_a2a_profile — render agent A's profile with this driver's
# values and import it. The peer endpoint carries a runtime value, so the
# profile is replaced per run rather than imported once at setup.
render_alice_a2a_profile() {
    mkdir -p "$STATE_DIR/profiles"
    sed -e "s|@DOC_HOST@|$(doc_host engineering)|" \
        -e "s|@DOC_PORT@|$(doc_port engineering)|" \
        -e "s|@A2A_HOST@|$A2A_HOST|" \
        -e "s|@A2A_PORT@|$A2A_PORT|" \
        -e "s|@ALLOWED_IPS@|$(allowed_ips_line)|" \
        "$ROOT/deploy/${ZT2_DRIVER}/profiles/alice-a2a.yaml.in" \
        >"$STATE_DIR/profiles/alice-a2a.yaml"
    import_profile_runtime zt2-alice-a2a-v2 "$STATE_DIR/profiles/alice-a2a.yaml"
}

# require_agent_env — the model endpoint is an outside dependency the
# demo cannot invent. Fail with a usage exit (2) rather than a scenario
# failure so the harness does not report a policy result it never tested.
require_agent_env() {
    local missing=()
    [[ -n "${LLM_API_KEY:-}" ]] || missing+=(LLM_API_KEY)
    [[ -n "${LLM_BASE_URL:-}" ]] || missing+=(LLM_BASE_URL)
    [[ -n "${LLM_MODEL:-}" ]] || missing+=(LLM_MODEL)
    if [[ ${#missing[@]} -gt 0 ]]; then
        printf "missing %s: agent scenarios need an OpenAI-compatible endpoint\n" \
            "${missing[*]}" >&2
        exit 2
    fi
}

# agent_log NAME — print an agent's docsclaw log from inside its sandbox.
agent_log() {
    "${OS[@]}" sandbox exec --name "$1" --no-tty -- cat "$WORKSPACE_DIR/serve.log"
}

# agent_provider NAME PROFILE_ID USER — create a provider holding a
# fresh subject token. Subject tokens expire after 30 minutes, so the
# provider is recreated per run rather than reused.
agent_provider() {
    local name="$1" profile_id="$2" user="$3"
    local subject
    subject="$(curl -fsS "$DEMO_SUBJECT_URL/demo-subject-token?user=$user" |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
    "${OS[@]}" provider delete "$name" >/dev/null 2>&1 || true
    "${OS[@]}" provider create --name "$name" --type "$profile_id" \
        --credential "subject_token=$subject" >/dev/null
}

# write_agent_config SRC DEST CALLER_SVID [PEER_URL HR_PEER_URL] — copy
# an agent's prompt and card into DEST/agent and render its
# agent-config.yaml with the driver's hosts. DocsClaw reads the agent's
# workspace from tools.workspace, so @WORKSPACE@ is the driver's
# WORKSPACE_DIR (the K8s driver mounts the PVC at /sandbox).
write_agent_config() {
    local src="$1" dest="$2" caller_svid="$3"
    local peer_url_value="${4:-}" hr_peer_url_value="${5:-}"
    local agent dept
    agent="$(basename "$src")"
    case "$agent" in
        hr-analyst) dept=hr ;;
        *) dept=engineering ;;
    esac
    mkdir -p "$dest/agent"
    cp "$src/system-prompt.txt" "$src/agent-card.json" "$dest/agent/"
    if [[ -f "$src/agent-config.a2a.yaml.in" ]]; then
        sed -e "s|@WORKSPACE@|$WORKSPACE_DIR|" \
            -e "s|@DOC_HOST@|$(doc_host "$dept")|" \
            -e "s|@DOC_PORT@|$(doc_port "$dept")|" \
            -e "s|@PEER_URL@|$peer_url_value|" \
            -e "s|@HR_PEER_URL@|$hr_peer_url_value|" \
            "$src/agent-config.a2a.yaml.in" >"$dest/agent/agent-config.yaml"
    else
        sed -e "s|@WORKSPACE@|$WORKSPACE_DIR|" \
            -e "s|@DOC_HOST@|$(doc_host "$dept")|" \
            -e "s|@DOC_PORT@|$(doc_port "$dept")|" \
            -e "s|@JWKS_URL@|$(jwks_url)|" \
            -e "s|@CALLER_SVID@|$caller_svid|" \
            "$src/agent-config.yaml.in" >"$dest/agent/agent-config.yaml"
    fi
}

# start_docsclaw_serve NAME — start the agent service inside a sandbox.
# --host 0.0.0.0 is required whenever inbound auth is on: docsclaw then
# defaults the bind address to loopback, which the service proxy cannot
# reach.
start_docsclaw_serve() {
    local name="$1" code
    code="$("${OS[@]}" sandbox exec --name "$name" --no-tty -- sh -c \
        "nohup docsclaw serve --config-dir $WORKSPACE_DIR/agent --host 0.0.0.0 --port 8000 >$WORKSPACE_DIR/serve.log 2>&1 & sleep 2; curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/health")" || true
    if [[ "$code" != "200" ]]; then
        printf "docsclaw serve did not become healthy in %s (got '%s')\n" \
            "$name" "$code" >&2
        "${OS[@]}" sandbox exec --name "$name" --no-tty -- sh -c \
            "cat $WORKSPACE_DIR/serve.log" >&2 || true
        return 1
    fi
}

# wait_for_health AGENT_URL [ATTEMPTS] — poll an agent's /health through
# the path the scenario will use. The service route needs a moment after
# registration and the relay is useless until the agent listens.
wait_for_health() {
    local url="$1" attempts="${2:-30}" code=""
    for _ in $(seq 1 "$attempts"); do
        code="$(service_curl "${url%/}/health" -m 5 -o /dev/null -w '%{http_code}' || true)"
        if [[ "$code" == "200" ]]; then
            return 0
        fi
        sleep 2
    done
    printf "%s did not return 200 on /health (last: %s)\n" "${url%/}" "$code" >&2
    return 1
}

# remove_sandbox NAME — delete a sandbox and wait until the name is free.
# Deleting a sandbox does not release the provider it used, and a profile
# cannot be replaced while a provider references it, so callers tear down
# in that order.
remove_sandbox() {
    local name="$1"
    "${OS[@]}" sandbox delete "$name" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        "${OS[@]}" sandbox get "$name" >/dev/null 2>&1 || return 0
        sleep 2
    done
    printf "sandbox %s did not go away\n" "$name" >&2
    return 1
}

# import_profile_runtime PROFILE_ID FILE — (re)import a profile that
# carries a runtime value. Profiles are immutable per ID, so the old one
# must be deleted first; that means dropping the providers built from it
# (their sandboxes must already be gone).
import_profile_runtime() {
    local id="$1" file="$2"
    local prov
    mkdir -p "$STATE_DIR/profiles"
    for prov in $("${OS[@]}" provider list 2>/dev/null |
        awk -v t="$id" 'NR>1 && $2==t {print $1}'); do
        "${OS[@]}" provider delete "$prov" >/dev/null 2>&1 || true
    done
    "${OS[@]}" profile delete "$id" >/dev/null 2>&1 || true
    "${OS[@]}" profile lint -f "$file" >/dev/null
    "${OS[@]}" profile import -f "$file" >/dev/null
}

# mint_final_token SANDBOX_ID AUDIENCE SCOPE USER — mint a final access
# token out of band with the same two exchanges scenario 6 performs; a
# sandbox never sees the token its supervisor injects.
#
# On Podman the SVID fetch registers a probe container that the gateway
# deletes the sandbox over once it exits (see fetch_supervisor_svid), so
# callers must pass a sandbox they do not need afterwards.
mint_final_token() {
    local sandbox_id="$1" audience="$2" scope="$3" user="$4"
    local spiffe_id subject gateway supervisor intermediate
    spiffe_id="$(sandbox_spiffe_id "$sandbox_id")"

    subject="$(curl -fsS "$DEMO_SUBJECT_URL/demo-subject-token?user=$user" |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
    gateway="$(fetch_gateway_svid)"
    supervisor="$(fetch_supervisor_svid "$sandbox_id")"
    if [[ -z "$gateway" || -z "$supervisor" ]]; then
        printf "mint_final_token: could not fetch gateway/supervisor SVIDs\n" >&2
        return 1
    fi

    intermediate="$(curl -fsS -X POST "$ISSUER_LOCAL/token" \
        -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
        -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe" \
        -d "client_assertion=$gateway" \
        -d "subject_token=$subject" \
        -d "audience=$spiffe_id" |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')"
    curl -fsS -X POST "$ISSUER_LOCAL/token" \
        -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
        -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe" \
        -d "client_assertion=$supervisor" \
        -d "subject_token=$intermediate" \
        -d "audience=$audience" -d "scope=$scope" |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'
}

# decode_jwt TOKEN — print a JWT's header and claims as JSON. Uses
# python3, which the harness already requires, so the scripts do not need
# a separate jwt CLI. The signature is decoded, not verified: this is for
# showing what a token carries, never for trusting it.
decode_jwt() {
    local token="$1" header payload
    header="${token%%.*}"
    payload="${token#*.}"
    payload="${payload%%.*}"
    python3 - "$header" "$payload" <<'PY'
import base64
import binascii
import json
import sys


def decode(segment):
    segment = segment.strip()
    padded = segment + "=" * (-len(segment) % 4)
    standard = padded.replace("-", "+").replace("_", "/")
    return json.loads(base64.b64decode(standard))


try:
    print(json.dumps(
        {"header": decode(sys.argv[1]), "payload": decode(sys.argv[2])},
        indent=2,
    ))
except (ValueError, binascii.Error) as err:
    sys.exit(f"decode_jwt: not a decodable JWT segment: {err}")
PY
}

pass() { printf "  \033[32m✅ PASS\033[0m %s\n" "$1"; }
fail() { printf "  \033[31m❌ FAIL\033[0m %s\n" "$1"; exit 1; }

scenario_header() {
    printf "\n%s\n  %s\n%s\n" "──────────────────────────────────────────────" "$1" "──────────────────────────────────────────────"
}
