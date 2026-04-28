reset_cascade_state() {
    CASCADE_ENABLED=0
    CASCADE_MODE=""
    CASCADE_VLESS=""
    CASCADE_ADDRESS=""
    CASCADE_ADDRESS_IP=""
    CASCADE_PORT=""
    CASCADE_UUID=""
    CASCADE_FLOW=""
    CASCADE_PBK=""
    CASCADE_SNI=""
    CASCADE_SID=""
    CASCADE_FP=""
    CASCADE_SPX=""
    FINAL_MODE="direct"
}

parse_cascade_vless_uri() {
    local parser_output parser_status

    [ -n "$CASCADE_VLESS" ] || err "Пустой --cascade-vless. Передайте полный vless:// URI."

    set +e
    parser_output=$(
        CASCADE_VLESS_INPUT="$CASCADE_VLESS" python3 - <<'PY' 2>&1
from urllib.parse import parse_qs, unquote, urlparse
import os

uri = os.environ.get("CASCADE_VLESS_INPUT", "").strip()
if not uri:
    raise SystemExit("Missing cascade VLESS URI.")

try:
    u = urlparse(uri)
except ValueError as exc:
    raise SystemExit(f"Invalid VLESS URI: {exc}")

if u.scheme != "vless":
    raise SystemExit("Unsupported scheme: expected vless")

uuid = unquote(u.username or "")
host = u.hostname or ""
if not uuid:
    raise SystemExit("Missing VLESS user UUID.")
if not host:
    raise SystemExit("Missing VLESS upstream host.")

try:
    port = u.port or 443
except ValueError as exc:
    raise SystemExit(f"Invalid VLESS port: {exc}")

q = {k: v[-1] for k, v in parse_qs(u.query, keep_blank_values=True).items()}
required = ["security", "type", "encryption", "pbk", "sni", "sid"]
for key in required:
    if key not in q or not q[key]:
        raise SystemExit(f"Missing required VLESS query field: {key}")

if q.get("security") != "reality":
    raise SystemExit("Only security=reality is supported in v1")
if q.get("type") != "tcp":
    raise SystemExit("Only type=tcp is supported in v1")
if q.get("encryption") != "none":
    raise SystemExit("Only encryption=none is supported in v1")

flow = q.get("flow", "xtls-rprx-vision") or "xtls-rprx-vision"
fp = q.get("fp", "chrome") or "chrome"
spx = unquote(q.get("spx", "/") or "/")

print(host)
print(port)
print(uuid)
print(flow)
print(q["pbk"])
print(q["sni"])
print(q["sid"])
print(fp)
print(spx)
PY
    )
    parser_status=$?
    set -e

    [ "$parser_status" -eq 0 ] || err "Не удалось разобрать --cascade-vless: $parser_output"

    CASCADE_ADDRESS=$(printf '%s\n' "$parser_output" | sed -n '1p')
    CASCADE_PORT=$(printf '%s\n' "$parser_output" | sed -n '2p')
    CASCADE_UUID=$(printf '%s\n' "$parser_output" | sed -n '3p')
    CASCADE_FLOW=$(printf '%s\n' "$parser_output" | sed -n '4p')
    CASCADE_PBK=$(printf '%s\n' "$parser_output" | sed -n '5p')
    CASCADE_SNI=$(printf '%s\n' "$parser_output" | sed -n '6p')
    CASCADE_SID=$(printf '%s\n' "$parser_output" | sed -n '7p')
    CASCADE_FP=$(printf '%s\n' "$parser_output" | sed -n '8p')
    CASCADE_SPX=$(printf '%s\n' "$parser_output" | sed -n '9p')

    [ -n "$CASCADE_ADDRESS" ] || err "Cascade parser returned an empty host."
    [ -n "$CASCADE_PORT" ] || err "Cascade parser returned an empty port."
    [ -n "$CASCADE_UUID" ] || err "Cascade parser returned an empty UUID."
    [ -n "$CASCADE_PBK" ] || err "Cascade parser returned an empty Reality public key."
    [ -n "$CASCADE_SNI" ] || err "Cascade parser returned an empty SNI."
    [ -n "$CASCADE_SID" ] || err "Cascade parser returned an empty shortId."
}

resolve_cascade_upstream_address() {
    local resolver_output resolver_status

    [ -n "$CASCADE_ADDRESS" ] || err "Cascade parser returned an empty host."

    set +e
    resolver_output=$(
        CASCADE_ADDRESS_INPUT="$CASCADE_ADDRESS" python3 - <<'PY' 2>&1
from ipaddress import ip_address
from socket import AF_INET, AF_INET6, getaddrinfo
import os

host = os.environ.get("CASCADE_ADDRESS_INPUT", "").strip()
if not host:
    raise SystemExit("Missing cascade upstream host.")

try:
    ip_address(host)
except ValueError:
    infos = getaddrinfo(host, None)
    ipv4 = next((info[4][0] for info in infos if info[0] == AF_INET), "")
    ipv6 = next((info[4][0] for info in infos if info[0] == AF_INET6), "")
    resolved = ipv4 or ipv6
    if not resolved:
        raise SystemExit(f"Unable to resolve cascade upstream host: {host}")
    print(resolved)
else:
    print(host)
PY
    )
    resolver_status=$?
    set -e

    [ "$resolver_status" -eq 0 ] || err "Не удалось определить IP каскадного upstream: $resolver_output"

    CASCADE_ADDRESS_IP=$(printf '%s\n' "$resolver_output" | sed -n '1p')
    [ -n "$CASCADE_ADDRESS_IP" ] || err "Resolved cascade upstream IP is empty."

    if [ "$CASCADE_ADDRESS" != "$CASCADE_ADDRESS_IP" ]; then
        log "Cascade upstream ${CASCADE_ADDRESS} resolved to ${CASCADE_ADDRESS_IP} for outbound use."
    fi
}

configure_cascade_mode() {
    if [ -n "$CASCADE_MODE_ARG" ] && [ "$CASCADE_MODE_ARG" != "auto" ]; then
        err "Only --cascade-mode auto is supported in v1."
    fi

    reset_cascade_state

    if [ -n "$CASCADE_VLESS_ARG" ]; then
        CASCADE_VLESS="$CASCADE_VLESS_ARG"
        CASCADE_MODE="${CASCADE_MODE_ARG:-auto}"
        parse_cascade_vless_uri
        resolve_cascade_upstream_address
        CASCADE_ENABLED=1
        FINAL_MODE="direct"
        log "Cascade mode теперь влияет только на DNS-выход AdGuardHome; AWG-трафик остаётся direct."
        return 0
    fi

    [ -z "$CASCADE_MODE_ARG" ] || err "--cascade-mode requires --cascade-vless."
}
