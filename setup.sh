#!/bin/bash
# Name: vps-vpn-triad (assembled source bootstrap)
# Description: Bootstrap layer for the modular 3x-ui + AmneziaWG + AdGuardHome installer.
# Assembled from source modules:
#   - src/setup/00-bootstrap.sh
#   - src/setup/10-helpers.sh
#   - src/setup/20-system.sh
#   - src/setup/30-xray.sh
#   - src/setup/40-awg.sh
#   - src/setup/50-adguard.sh
#   - src/setup/60-firewall.sh
#   - src/setup/70-output.sh
# Usage: curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh | sudo bash [--mode target|relay] [-r | --rotate]
# Behavior: Updates sysctl, installs OS packages, compiles AmneziaWG kernel module, sets up AdGuard Home, prepares 3x-ui installation command. In relay mode additionally configures L4 port forwarding to the target VPS.
# Returns: Configured VPN stack with connection details.
# Fails: If run without root privileges or with an invalid --mode value.
# ==============================================================================
# Комплексный скрипт настройки Debian 11/Ubuntu: OS Optimization + 3x-ui + AmneziaWG + AdGuardHome
# ==============================================================================

set -Ee
export DEBIAN_FRONTEND=noninteractive
export RANDFILE=/tmp/.rnd

# Глобальные переменные и пути
SCRIPT_VERSION="3.0.0"
XRAY_VERSION_PIN="25.1.30"
CREDS_FILE="/root/.vpn-credentials"
LOG_FILE="/var/log/vpn-setup.log"
LAST_RUN_FILE="/root/.vpn-setup-last-run"
DEPLOY_MODE="target"
CURRENT_STEP="bootstrap"

mark_step() {
    CURRENT_STEP="$1"
    log "Шаг: ${CURRENT_STEP}"
}

# Обработка аргументов
ROTATE_CREDS=0
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --rotate|-r) ROTATE_CREDS=1; shift ;;
        --mode)
            if [ -z "${2:-}" ]; then
                echo "[ERROR] Аргумент --mode требует значение: target или relay" >&2
                exit 1
            fi
            if [ "$2" != "target" ] && [ "$2" != "relay" ]; then
                echo "[ERROR] Недопустимое значение --mode: $2. Используйте target или relay." >&2
                exit 1
            fi
            DEPLOY_MODE="$2"
            shift 2
            ;;
        *)
            echo "[ERROR] Неизвестный аргумент: $1" >&2
            exit 1
            ;;
    esac
done

# Логирование (перенаправление вывода в файл и консоль)
exec > >(tee -a "$LOG_FILE") 2>&1

# Цвета для вывода
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"

log() { echo -e "${GREEN}[INFO] $1${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
err() { echo -e "${RED}[ERROR] [${CURRENT_STEP:-unknown}] $1${RESET}"; exit 1; }
on_script_error() {
    local exit_code="$1"
    local signal="$2"
    local failing_command="$3"

    warn "Скрипт прерван (${signal}) на шаге: ${CURRENT_STEP:-unknown}. Команда: ${failing_command:-unknown}. Код: ${exit_code}. Лог: $LOG_FILE"
}

log "Версия скрипта: ${SCRIPT_VERSION}"
log "Режим развёртывания: ${DEPLOY_MODE}"

trap 'on_script_error "$?" "ERR" "$BASH_COMMAND"' ERR
trap 'on_script_error 130 "INT" "$BASH_COMMAND"' INT
trap 'on_script_error 143 "TERM" "$BASH_COMMAND"' TERM

if [ "$EUID" -ne 0 ]; then
  err "Запустите скрипт от имени root (sudo -i)"
fi

# Проверяем, запускался ли скрипт уже сегодня (для пропуска apt-операций)
TODAY=$(date +%Y-%m-%d)
LAST_RUN=$(cat "$LAST_RUN_FILE" 2>/dev/null || echo "")
if [ "$LAST_RUN" = "$TODAY" ]; then
    SKIP_APT=1
    warn "Скрипт уже запускался сегодня ($TODAY). Пропускаем обновление OS (только перегенерация настроек)."
else
    SKIP_APT=0
fi

install_xray_core() {
    local current_xray_version=""

    if command -v xray >/dev/null 2>&1; then
        current_xray_version=$(xray version 2>/dev/null | awk 'NR==1 {print $2}')
    fi

    if [ "$current_xray_version" = "$XRAY_VERSION_PIN" ] && systemctl list-unit-files 2>/dev/null | grep -q '^xray\.service'; then
        systemctl enable xray >/dev/null 2>&1 || true
        return 0
    fi

    if [ -n "$current_xray_version" ] && [ "$current_xray_version" != "$XRAY_VERSION_PIN" ]; then
        warn "Обнаружен Xray ${current_xray_version}. Переключаемся на pinned-версию ${XRAY_VERSION_PIN} из-за регрессии TProxy/TCP в более новых релизах."
    else
        log "Установка Xray-core ${XRAY_VERSION_PIN} через официальный инсталлятор..."
    fi

    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version "$XRAY_VERSION_PIN"
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1 || true
}

resolve_xray_bin() {
    command -v xray 2>/dev/null || true
}

resolve_awg_key_bin() {
    # Prefer the stable WireGuard CLI for key material; fall back to awg if needed.
    command -v wg 2>/dev/null || command -v awg 2>/dev/null || true
}

trim_cr_value() {
    printf '%s' "$1" | tr -d '\r'
}

read_cred_value() {
    local key="$1"
    local file="$2"
    local raw

    raw=$(grep "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)
    trim_cr_value "$raw"
}

read_config_assignment() {
    local prefix="$1"
    local file="$2"
    local raw

    raw=$(grep "^${prefix}" "$file" 2>/dev/null | head -n1 | cut -d'=' -f2- | xargs || true)
    trim_cr_value "$raw"
}

read_url_port() {
    local key="$1"
    local file="$2"
    local raw

    raw=$(grep "^${key}=" "$file" 2>/dev/null | head -n1 | sed -e 's|.*:| |' -e 's|/.*||' | xargs || true)
    trim_cr_value "$raw"
}

_parse_x25519_output() {
    local raw
    raw=$(printf '%s' "$1" | tr -d '\r')
    local priv pub
    priv=$(printf '%s\n' "$raw" | sed -nE 's|^PrivateKey:[[:space:]]*([A-Za-z0-9+/=_-]+).*|\1|p' | head -n1)
    pub=$(printf '%s\n' "$raw" | sed -nE 's|^Password \(PublicKey\):[[:space:]]*([A-Za-z0-9+/=_-]+).*|\1|p' | head -n1)
    [ -n "$priv" ] || priv=$(printf '%s\n' "$raw" | sed -nE 's|^Private key:[[:space:]]*([A-Za-z0-9+/=_-]+).*|\1|p' | head -n1)
    [ -n "$pub" ] || pub=$(printf '%s\n' "$raw" | sed -nE 's|^Public key:[[:space:]]*([A-Za-z0-9+/=_-]+).*|\1|p' | head -n1)
    printf '%s\n%s' "$priv" "$pub"
}

generate_reality_keys() {
    local raw_output priv_pub

    raw_output="$("$XRAY_BIN" x25519 2>&1 || true)"
    priv_pub=$(_parse_x25519_output "$raw_output")
    XRAY_PRIVATE_KEY=$(printf '%s\n' "$priv_pub" | sed -n '1p')
    XRAY_PUBLIC_KEY=$(printf '%s\n' "$priv_pub" | sed -n '2p')

    if [ -n "$XRAY_PRIVATE_KEY" ] && [ -n "$XRAY_PUBLIC_KEY" ]; then
        return 0
    fi

    warn "xray x25519 вернул нераспознанный вывод. Пробуем openssl-fallback."
    warn "Сырой вывод: $(printf '%s' "$raw_output" | head -c 400)"
    local fallback_priv fallback_out fallback_pub
    fallback_priv=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')
    fallback_out="$("$XRAY_BIN" x25519 -i "$fallback_priv" 2>&1 || true)"
    fallback_pub=$(printf '%s\n' "$(_parse_x25519_output "$fallback_out")" | sed -n '2p')
    XRAY_PRIVATE_KEY="$fallback_priv"
    XRAY_PUBLIC_KEY="$fallback_pub"

    [ -n "$XRAY_PRIVATE_KEY" ] || err "Не удалось получить private key Reality."
    [ -n "$XRAY_PUBLIC_KEY" ] || err "Не удалось получить public key Reality. Вывод xray: $(printf '%s' "$fallback_out" | head -c 400)"
}

remove_legacy_xui() {
    systemctl stop x-ui 2>/dev/null || true
    systemctl disable x-ui 2>/dev/null || true
    rm -f /etc/systemd/system/x-ui.service
    rm -rf /usr/local/x-ui /etc/x-ui
    systemctl daemon-reload >/dev/null 2>&1 || true
}

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

write_xray_config() {
    mkdir -p /usr/local/etc/xray

    SERVER_IP="$SERVER_IP" \
    XRAY_PORT="$XRAY_PORT" \
    XRAY_UUID="$XRAY_UUID" \
    XRAY_PRIVATE_KEY="$XRAY_PRIVATE_KEY" \
    XRAY_SHORT_ID="$XRAY_SHORT_ID" \
    ADG_DNS_PORT="$ADG_DNS_PORT" \
    ADG_HTTP_PROXY_PORT="$ADG_HTTP_PROXY_PORT" \
    CASCADE_ENABLED="$CASCADE_ENABLED" \
    CASCADE_ADDRESS="$CASCADE_ADDRESS" \
    CASCADE_ADDRESS_IP="$CASCADE_ADDRESS_IP" \
    CASCADE_PORT="$CASCADE_PORT" \
    CASCADE_UUID="$CASCADE_UUID" \
    CASCADE_FLOW="$CASCADE_FLOW" \
    CASCADE_PBK="$CASCADE_PBK" \
    CASCADE_SNI="$CASCADE_SNI" \
    CASCADE_SID="$CASCADE_SID" \
    CASCADE_FP="$CASCADE_FP" \
    CASCADE_SPX="$CASCADE_SPX" \
    python3 - <<'PY' > /usr/local/etc/xray/config.json
import json
import os
import sys

server_ip = os.environ["SERVER_IP"]
cascade_enabled = os.environ.get("CASCADE_ENABLED", "0") == "1"
cascade_address_ip = os.environ.get("CASCADE_ADDRESS_IP") or os.environ["CASCADE_ADDRESS"]

direct_outbound = {
    "tag": "direct-out",
    "protocol": "freedom",
    "settings": {
        "domainStrategy": "UseIPv4",
    },
    "streamSettings": {
        "sockopt": {
            "mark": 2,
        },
    },
}

block_outbound = {
    "tag": "block-out",
    "protocol": "blackhole",
}

adg_http_proxy_rule = {
    "type": "field",
    "ruleTag": "adg-http-proxy",
    "inboundTag": ["adg-http-proxy-in"],
    "outboundTag": "direct-out",
}

config = {
    "log": {
        "access": "none",
        "dnsLog": False,
        "error": "",
        "loglevel": "warning",
        "maskAddress": "",
    },
    "dns": {
        "servers": [
            f"udp://127.0.0.1:{os.environ['ADG_DNS_PORT']}",
        ],
        "queryStrategy": "UseIPv4",
    },
    "inbounds": [
        {
            "tag": "reality-in",
            "listen": "0.0.0.0",
            "port": int(os.environ["XRAY_PORT"]),
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "email": "reality-default",
                        "flow": "xtls-rprx-vision",
                        "id": os.environ["XRAY_UUID"],
                    }
                ],
                "decryption": "none",
            },
            "sniffing": {
                "enabled": True,
                "destOverride": ["http", "tls", "quic", "fakedns"],
                "metadataOnly": True,
                "routeOnly": True,
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "google.com:443",
                    "privateKey": os.environ["XRAY_PRIVATE_KEY"],
                    "serverNames": ["google.com", "www.google.com"],
                    "shortIds": [os.environ["XRAY_SHORT_ID"]],
                    "show": False,
                    "xver": 0,
                },
                "tcpSettings": {
                    "header": {
                        "type": "none",
                    },
                },
            },
        },
        {
            "tag": "adg-http-proxy-in",
            "listen": "127.0.0.1",
            "port": int(os.environ["ADG_HTTP_PROXY_PORT"]),
            "protocol": "http",
            "settings": {
                "allowTransparent": False,
            },
        },
    ],
    "outbounds": [
        direct_outbound,
        block_outbound,
    ],
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "ruleTag": "ru-domains",
                "domain": [
                    "regexp:\\.ru$",
                    "regexp:\\.su$",
                    "regexp:\\.xn--p1ai$",
                ],
                "outboundTag": "direct-out",
            },
            {
                "type": "field",
                "ruleTag": "ru-ips",
                "ip": [
                    "geoip:ru",
                    "geoip:private",
                ],
                "outboundTag": "direct-out",
            },
            {
                "type": "field",
                "ruleTag": "entry-server-self",
                "ip": [
                    "127.0.0.0/8",
                    "10.0.0.0/8",
                    "100.64.0.0/10",
                    "169.254.0.0/16",
                    "172.16.0.0/12",
                    "192.168.0.0/16",
                    f"{server_ip}/32",
                ],
                "outboundTag": "direct-out",
            },
            {
                "type": "field",
                "ruleTag": "reality-server-egress",
                "inboundTag": ["reality-in"],
                "outboundTag": "direct-out",
            },
            adg_http_proxy_rule,
            {
                "type": "field",
                "ruleTag": "block-bittorrent",
                "protocol": ["bittorrent"],
                "outboundTag": "block-out",
            },
        ],
    },
}

if cascade_enabled:
    exit_us_outbound = {
        "tag": "exit-us",
        "protocol": "vless",
        "settings": {
            "vnext": [
                {
                    "address": cascade_address_ip,
                    "port": int(os.environ["CASCADE_PORT"]),
                    "users": [
                        {
                            "id": os.environ["CASCADE_UUID"],
                            "encryption": "none",
                            "flow": os.environ["CASCADE_FLOW"],
                        }
                    ],
                }
            ]
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "serverName": os.environ["CASCADE_SNI"],
                "publicKey": os.environ["CASCADE_PBK"],
                "shortId": os.environ["CASCADE_SID"],
                "fingerprint": os.environ["CASCADE_FP"],
                "spiderX": os.environ["CASCADE_SPX"],
            },
            "sockopt": {
                "mark": 2,
            },
        },
    }
    config["outbounds"].append(exit_us_outbound)
    adg_http_proxy_rule["outboundTag"] = "exit-us"

json.dump(config, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
}

cleanup_legacy_adguard_units() {
    systemctl stop AdGuardHome 2>/dev/null || true
    systemctl stop adguardhome 2>/dev/null || true
    systemctl disable adguardhome 2>/dev/null || true
    rm -f /etc/systemd/system/adguardhome.service
    rm -rf /etc/systemd/system/adguardhome.service.d
    systemctl daemon-reload >/dev/null 2>&1 || true
}

ensure_awg_build_dependencies() {
    local header_pkg="linux-headers-$(uname -r)"

    apt install -y git build-essential dkms libmnl-dev libelf-dev "$header_pkg" \
        || err "Не удалось установить точные kernel headers (${header_pkg}) для сборки AmneziaWG."
}

load_existing_awg_credentials() {
    local awg_key_bin="${AWG_KEY_BIN:-}"

    if [ -z "$awg_key_bin" ]; then
        awg_key_bin="$(resolve_awg_key_bin || true)"
    fi

    if [ -f "$CREDS_FILE" ] && [ "$ROTATE_CREDS" -eq 0 ]; then
        log "Загрузка существующих credentials AmneziaWG из $CREDS_FILE..."
        SERVER_PRIV=$(read_cred_value "AWG_SERVER_PRIV" "$CREDS_FILE")
        CLIENT_PRIV=$(read_cred_value "AWG_CLIENT_PRIV" "$CREDS_FILE")
        CLIENT_PSK=$(read_cred_value "AWG_CLIENT_PSK" "$CREDS_FILE")
        AWG_PORT=$(read_cred_value "AWG_PORT" "$CREDS_FILE")
        JC=$(read_cred_value "AWG_JC" "$CREDS_FILE")
        JMIN=$(read_cred_value "AWG_JMIN" "$CREDS_FILE")
        JMAX=$(read_cred_value "AWG_JMAX" "$CREDS_FILE")
        S1=$(read_cred_value "AWG_S1" "$CREDS_FILE")
        S2=$(read_cred_value "AWG_S2" "$CREDS_FILE")
        H1=$(read_cred_value "AWG_H1" "$CREDS_FILE")
        H2=$(read_cred_value "AWG_H2" "$CREDS_FILE")
        H3=$(read_cred_value "AWG_H3" "$CREDS_FILE")
        H4=$(read_cred_value "AWG_H4" "$CREDS_FILE")
    fi

    if [ -z "$SERVER_PRIV" ] || [ -z "$CLIENT_PRIV" ] || [ -z "$CLIENT_PSK" ]; then
        if [ -f /etc/amnezia/amneziawg/awg0.conf ] && [ -f /root/amnezia_client.conf ] && [ "$ROTATE_CREDS" -eq 0 ]; then
            log "Восстанавливаем существующие credentials AmneziaWG из текущих конфигов..."
            SERVER_PRIV=$(read_config_assignment "PrivateKey = " /etc/amnezia/amneziawg/awg0.conf)
            CLIENT_PRIV=$(read_config_assignment "PrivateKey = " /root/amnezia_client.conf)
            CLIENT_PSK=$(read_config_assignment "PresharedKey = " /root/amnezia_client.conf)
            AWG_PORT=$(read_config_assignment "ListenPort = " /etc/amnezia/amneziawg/awg0.conf)
            JC=$(read_config_assignment "Jc = " /etc/amnezia/amneziawg/awg0.conf)
            JMIN=$(read_config_assignment "Jmin = " /etc/amnezia/amneziawg/awg0.conf)
            JMAX=$(read_config_assignment "Jmax = " /etc/amnezia/amneziawg/awg0.conf)
            S1=$(read_config_assignment "S1 = " /etc/amnezia/amneziawg/awg0.conf)
            S2=$(read_config_assignment "S2 = " /etc/amnezia/amneziawg/awg0.conf)
            H1=$(read_config_assignment "H1 = " /etc/amnezia/amneziawg/awg0.conf)
            H2=$(read_config_assignment "H2 = " /etc/amnezia/amneziawg/awg0.conf)
            H3=$(read_config_assignment "H3 = " /etc/amnezia/amneziawg/awg0.conf)
            H4=$(read_config_assignment "H4 = " /etc/amnezia/amneziawg/awg0.conf)
        fi
    fi

    [ -n "$awg_key_bin" ] || err "Не найден awg/wg для восстановления ключей AmneziaWG."

    if [ -n "$SERVER_PRIV" ]; then
        SERVER_PUB=$(printf '%s' "$SERVER_PRIV" | "$awg_key_bin" pubkey)
    fi

    if [ -n "$CLIENT_PRIV" ]; then
        CLIENT_PUB=$(printf '%s' "$CLIENT_PRIV" | "$awg_key_bin" pubkey)
    fi
}

validate_stack() {
    local agh_service_name="$1"

    log "Валидация Xray, AmneziaWG и AdGuardHome..."
    xray run -test -config /usr/local/etc/xray/config.json || err "Xray config validation failed."
    systemctl restart xray || err "Не удалось перезапустить xray."
    systemctl restart awg-quick@awg0 || err "Не удалось поднять awg0 после настройки."
    systemctl restart "$agh_service_name" || err "Не удалось перезапустить ${agh_service_name}."

    ss -lntup | grep -Eq ':443 ' || err "Xray не слушает порт 443."
    ss -lntup | grep -Eq ':51820 ' || err "AmneziaWG не слушает порт 51820."
    dig @127.0.0.1 -p "${ADG_DNS_PORT}" example.com +short | grep -q . || err "AdGuardHome не отвечает на локальные DNS-запросы."
    awg show | grep -q '^interface: awg0' || err "AmneziaWG interface awg0 не поднялся."
}

cleanup_legacy_awg_dns_redirects() {
    iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-port "${ADG_DNS_PORT}" 2>/dev/null || true
    iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j REDIRECT --to-port "${ADG_DNS_PORT}" 2>/dev/null || true
}

ensure_swapfile() {
    local swapfile="/swapfile"
    local swap_size="1G"
    local fstab_line="/swapfile none swap sw 0 0 # 3x-awg-adg-bundle"

    if swapon --show --noheadings 2>/dev/null | grep -q .; then
        warn "Swap уже активен, пропускаем создание swapfile."
        return 0
    fi

    if [ -f "$swapfile" ]; then
        log "Используем существующий swapfile ${swapfile}."
    else
        log "Создание swapfile ${swapfile} (${swap_size})..."
        if command -v fallocate >/dev/null 2>&1; then
            if ! fallocate -l "$swap_size" "$swapfile"; then
                warn "fallocate не сработал, используем dd для создания swapfile."
                dd if=/dev/zero of="$swapfile" bs=1M count=1024 status=none
            fi
        else
            dd if=/dev/zero of="$swapfile" bs=1M count=1024 status=none
        fi
        chmod 600 "$swapfile"
        mkswap "$swapfile" >/dev/null
    fi

    chmod 600 "$swapfile"
    if ! grep -qF "$fstab_line" /etc/fstab; then
        echo "$fstab_line" >> /etc/fstab
    fi
    swapon "$swapfile"
    log "Swapfile активирован: ${swapfile}"
}

# ==============================================================================
# 1. БАЗОВАЯ ОПТИМИЗАЦИЯ И БЕЗОПАСНОСТЬ OS
# ==============================================================================
mark_step "System: swapfile and OS packages"
ensure_swapfile

if [ "$SKIP_APT" -eq 0 ]; then
    mark_step "System: apt update and base packages"
    log "Очистка устаревших репозиториев (удаление bullseye-backports)..."
    sed -i '/bullseye-backports/d' /etc/apt/sources.list
    rm -f /etc/apt/sources.list.d/*backports*.list 2>/dev/null || true

    log "Обновление системы и установка базовых пакетов..."
    apt update && apt upgrade -y
    # Базовые пакеты и точные headers текущего ядра для детерминированной сборки AWG.
    apt install -y curl wget mc ufw fail2ban nano iptables iptables-persistent \
                   jq openssl whois qrencode dnsutils python3 wireguard-tools "linux-headers-$(uname -r)" \
        || err "Не удалось установить обязательные пакеты и точные kernel headers для $(uname -r)."
    # Обновляем дату последнего полного запуска
    date +%Y-%m-%d > "$LAST_RUN_FILE"
else
    log "Пропуск apt-операций (fast mode). Убеждаемся в наличии jq, openssl, python3 и dig..."
    command -v jq >/dev/null 2>&1 || apt install -y jq
    command -v openssl >/dev/null 2>&1 || apt install -y openssl
    command -v python3 >/dev/null 2>&1 || apt install -y python3
    command -v dig >/dev/null 2>&1 || apt install -y dnsutils
    command -v wg >/dev/null 2>&1 || apt install -y wireguard-tools
fi

if [ "$SKIP_APT" -eq 0 ]; then
    mark_step "System: editor defaults"
    log "Настройка редактора mcedit по умолчанию..."
    update-alternatives --set editor /usr/bin/mcedit || true
    export EDITOR=mcedit
    if ! grep -q "export EDITOR=mcedit" ~/.bashrc; then
        echo 'export EDITOR=mcedit' >> ~/.bashrc
    fi
fi

mark_step "System: sysctl hardening"
log "Оптимизация sysctl (сеть, BBR, лимиты)..."
# Удаляем устаревший файл (может содержать ключи из прошлых версий скрипта)
rm -f /etc/sysctl.d/99-custom-net.conf
cat <<EOF > /etc/sysctl.d/99-custom-net.conf
fs.file-max = 1048576
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 10000
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
EOF
sysctl --system 2>&1 | grep -v 'Invalid argument' | grep -v '^$' | head -20 || true

# ==============================================================================
# 2. УСТАНОВКА XRAY
# ==============================================================================
mark_step "System: Xray bootstrap"
log "Проверка и установка Xray-core..."
SERVER_IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)
PUB_INT=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
XRAY_PORT=443

# Загружаем или генерируем новые credentials Xray
if [ -f "$CREDS_FILE" ] && [ "$ROTATE_CREDS" -eq 0 ]; then
    log "Загрузка существующих credentials Xray из $CREDS_FILE..."
    XRAY_UUID=$(read_cred_value "XRAY_UUID" "$CREDS_FILE")
    XRAY_PRIVATE_KEY=$(read_cred_value "XRAY_PRIVATE_KEY" "$CREDS_FILE")
    XRAY_PUBLIC_KEY=$(read_cred_value "XRAY_PUBLIC_KEY" "$CREDS_FILE")
    XRAY_SHORT_ID=$(read_cred_value "XRAY_SHORT_ID" "$CREDS_FILE")
    ADG_DNS_PORT=$(read_cred_value "ADG_DNS_PORT" "$CREDS_FILE")
    ADG_HTTP_PROXY_PORT=$(read_cred_value "ADG_HTTP_PROXY_PORT" "$CREDS_FILE")
    CASCADE_ENABLED=$(read_cred_value "CASCADE_ENABLED" "$CREDS_FILE")
    CASCADE_MODE=$(read_cred_value "CASCADE_MODE" "$CREDS_FILE")
    CASCADE_VLESS=$(read_cred_value "CASCADE_VLESS" "$CREDS_FILE")
    CASCADE_ADDRESS=$(read_cred_value "CASCADE_ADDRESS" "$CREDS_FILE")
    CASCADE_PORT=$(read_cred_value "CASCADE_PORT" "$CREDS_FILE")
    CASCADE_UUID=$(read_cred_value "CASCADE_UUID" "$CREDS_FILE")
    CASCADE_FLOW=$(read_cred_value "CASCADE_FLOW" "$CREDS_FILE")
    CASCADE_PBK=$(read_cred_value "CASCADE_PBK" "$CREDS_FILE")
    CASCADE_SNI=$(read_cred_value "CASCADE_SNI" "$CREDS_FILE")
    CASCADE_SID=$(read_cred_value "CASCADE_SID" "$CREDS_FILE")
    CASCADE_FP=$(read_cred_value "CASCADE_FP" "$CREDS_FILE")
    CASCADE_SPX=$(read_cred_value "CASCADE_SPX" "$CREDS_FILE")
    FINAL_MODE=$(read_cred_value "FINAL_MODE" "$CREDS_FILE")
fi

# Generate or restore Reality keys only after Xray is present and the binary is resolved.
mark_step "System: load Xray credentials"
# Если после загрузки переменные пустые, генерируем заново
[ -z "$XRAY_UUID" ] && XRAY_UUID=$(cat /proc/sys/kernel/random/uuid)
[ -z "$XRAY_SHORT_ID" ] && XRAY_SHORT_ID=$(openssl rand -hex 8)

# Prepare the AdGuard DNS listener port early so Xray can point to the final value.
[ -z "$ADG_DNS_PORT" ] && ADG_DNS_PORT=$(shuf -i 10000-65000 -n 1)
[ -z "$ADG_HTTP_PROXY_PORT" ] && ADG_HTTP_PROXY_PORT=$(shuf -i 10000-65000 -n 1)

if systemctl is-active --quiet xray 2>/dev/null && [ -x /usr/local/bin/xray ]; then
    warn "Xray уже установлен и работает. Перегенерируем конфиг."
else
    install_xray_core
    # Ждём появления бинарника Xray (до 10 секунд)
    for i in $(seq 1 10); do command -v xray >/dev/null 2>&1 && break; sleep 1; done
    command -v xray >/dev/null 2>&1 || err "Бинарный файл xray не найден после установки"
fi

XRAY_BIN="$(resolve_xray_bin || true)"
[ -n "$XRAY_BIN" ] || err "Бинарный файл xray не найден после установки."

mark_step "System: derive Reality keys"
if [ -n "$XRAY_PRIVATE_KEY" ] && [ -z "$XRAY_PUBLIC_KEY" ]; then
    log "В credentials Xray найден private key Reality, восстанавливаем public key..."
    DERIVED_OUTPUT="$("$XRAY_BIN" x25519 -i "$XRAY_PRIVATE_KEY" 2>&1 || true)"
    XRAY_PUBLIC_KEY=$(printf '%s\n' "$(_parse_x25519_output "$DERIVED_OUTPUT")" | sed -n '2p')
fi

if [ -z "$XRAY_PRIVATE_KEY" ] || [ -z "$XRAY_PUBLIC_KEY" ]; then
    log "Генерация Reality credentials Xray..."
    generate_reality_keys
fi

[ -n "$XRAY_PRIVATE_KEY" ] || err "Не удалось получить private key Reality."
[ -n "$XRAY_PUBLIC_KEY" ] || err "Не удалось получить public key Reality."
[ -n "$XRAY_SHORT_ID" ] || err "Не удалось сгенерировать shortId Reality."

# ==============================================================================
# 3. ОЧИСТКА LEGACY XRAY CONTROL PLANE
# ==============================================================================
mark_step "Xray: cleanup legacy x-ui and build VLESS link"
log "Удаление legacy x-ui, если он остался от предыдущих версий..."
remove_legacy_xui
configure_cascade_mode

if [ "$CASCADE_ENABLED" -eq 1 ]; then
    log "Cascade mode включён: upstream Reality exit-us используется только для DNS-выхода AdGuardHome."
else
    log "Cascade mode выключен: AWG идёт direct, а DNS upstream AdGuardHome остаётся на локальном Xray HTTP proxy."
fi

VLESS_LINK="vless://$XRAY_UUID@$SERVER_IP:$XRAY_PORT?type=tcp&security=reality&encryption=none&flow=xtls-rprx-vision&pbk=$XRAY_PUBLIC_KEY&headerType=none&fp=chrome&spx=%2F&sni=google.com&sid=$XRAY_SHORT_ID#VLESS-Reality-Default"

# ==============================================================================
# 5. УСТАНОВКА AMNEZIAWG
# ==============================================================================
log "Проверка AmneziaWG..."
mark_step "AmneziaWG: check installation state"
if command -v awg >/dev/null 2>&1 && [ -f /etc/amnezia/amneziawg/awg0.conf ]; then
    warn "AmneziaWG уже настроен, пропускаем переустановку."
else
    mark_step "AmneziaWG: install build dependencies"
    ensure_awg_build_dependencies
    if grep -qi "ubuntu" /etc/os-release; then
        mark_step "AmneziaWG: install Ubuntu package"
        log "Используем PPA для Ubuntu..."
        apt install -y software-properties-common python3-launchpadlib gnupg2
        add-apt-repository -y ppa:amnezia/ppa
        apt update
        apt install -y amneziawg
    else
        mark_step "AmneziaWG: build Debian module"
        log "Сборка AmneziaWG из исходников (Debian)..."
        (
            cd /usr/src
            rm -rf amneziawg-linux-kernel-module amneziawg-tools
            git clone https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git
            cd amneziawg-linux-kernel-module/src
            make dkms-install || make install
        )
        (
            cd /usr/src
            rm -rf amneziawg-tools
            git clone https://github.com/amnezia-vpn/amneziawg-tools.git
            cd amneziawg-tools/src
            make install
        )
    fi
fi
log "Генерация ключей и конфигурации AmneziaWG..."
mark_step "AmneziaWG: prepare config directory"
mkdir -p /etc/amnezia/amneziawg
chmod 700 /etc/amnezia/amneziawg

AWG_PORT=51820
mark_step "AmneziaWG: resolve AWG key binary"
AWG_KEY_BIN="$(resolve_awg_key_bin || true)"
[ -n "$AWG_KEY_BIN" ] || err "Не найден awg/wg после установки AmneziaWG."
mark_step "AmneziaWG: load existing credentials"
load_existing_awg_credentials

# Параметры обфускации (Рандомизация для защиты от сигнатурного анализа ТСПУ 2026)
mark_step "AmneziaWG: generate obfuscation parameters"
[ -z "$JC" ] && JC=$(shuf -i 3-12 -n 1)
[ -z "$JMIN" ] && JMIN=$(shuf -i 40-70 -n 1)
[ -z "$JMAX" ] && JMAX=$(shuf -i 700-1200 -n 1)
[ -z "$S1" ] && S1=$(shuf -i 15-150 -n 1)
[ -z "$S2" ] && S2=$(shuf -i 151-250 -n 1)
[ -z "$H1" ] && H1=$(shuf -i 100000000-999999999 -n 1)
[ -z "$H2" ] && H2=$(shuf -i 100000000-999999999 -n 1)
[ -z "$H3" ] && H3=$(shuf -i 100000000-999999999 -n 1)
[ -z "$H4" ] && H4=$(shuf -i 100000000-999999999 -n 1)
# Случайный порт DNS для AdGuardHome (не 53 — DNAT-редирект в awg0.conf)
[ -z "$ADG_DNS_PORT" ] && ADG_DNS_PORT=$(shuf -i 10000-65000 -n 1)

mark_step "AmneziaWG: generate server private key"
[ -z "$SERVER_PRIV" ] && SERVER_PRIV=$("$AWG_KEY_BIN" genkey)
mark_step "AmneziaWG: generate client private key"
[ -z "$CLIENT_PRIV" ] && CLIENT_PRIV=$("$AWG_KEY_BIN" genkey)
mark_step "AmneziaWG: generate client preshared key"
[ -z "$CLIENT_PSK" ] && CLIENT_PSK=$("$AWG_KEY_BIN" genpsk)
mark_step "AmneziaWG: derive public keys"
if [ -n "$SERVER_PRIV" ] && [ -z "$SERVER_PUB" ]; then
    SERVER_PUB=$(printf '%s' "$SERVER_PRIV" | "$AWG_KEY_BIN" pubkey)
fi

if [ -n "$CLIENT_PRIV" ] && [ -z "$CLIENT_PUB" ]; then
    CLIENT_PUB=$(printf '%s' "$CLIENT_PRIV" | "$AWG_KEY_BIN" pubkey)
fi

mark_step "AmneziaWG: write awg0.conf"
cat <<EOF > /etc/amnezia/amneziawg/awg0.conf
[Interface]
Address = 10.8.0.1/24
ListenPort = $AWG_PORT
PrivateKey = $SERVER_PRIV
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

# AWG-клиенты выходят напрямую через публичный интерфейс. DNS по-прежнему идёт в AdGuardHome.
PostUp = iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $PUB_INT -j MASQUERADE
# DNAT: перенаправляем DNS от VPN-клиентов (порт 53) -> AdGuardHome (порт $ADG_DNS_PORT)
PostUp = iptables -t nat -A PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT
PostUp = iptables -t nat -A PREROUTING -i awg0 -p tcp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT

PostDown = iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o $PUB_INT -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT 2>/dev/null || true
PostDown = iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT 2>/dev/null || true

[Peer]
PublicKey = $CLIENT_PUB
PresharedKey = $CLIENT_PSK
AllowedIPs = 10.8.0.2/32
EOF

mark_step "AmneziaWG: cleanup legacy DNS redirects"
cleanup_legacy_awg_dns_redirects
mark_step "AmneziaWG: enable awg-quick@awg0"
systemctl enable awg-quick@awg0
mark_step "AmneziaWG: restart awg-quick@awg0"
systemctl restart awg-quick@awg0 || err "Не удалось поднять awg0. Проверьте сборку модуля AmneziaWG для $(uname -r)."

# Конфигурация клиента
mark_step "AmneziaWG: write amnezia_client.conf"
cat <<EOF > /root/amnezia_client.conf
[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.8.0.2/32
DNS = 10.8.0.1
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $SERVER_PUB
PresharedKey = $CLIENT_PSK
Endpoint = $SERVER_IP:$AWG_PORT
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
chmod 600 /root/amnezia_client.conf

# ==============================================================================
# 6. УСТАНОВКА И НАСТРОЙКА ADGUARD HOME
# ==============================================================================
log "Установка AdGuardHome..."
mark_step "AdGuardHome: load credentials and install binary"
# DNS на случайном порту $ADG_DNS_PORT — systemd-resolved отключать не нужно

# Загружаем или генерируем новые credentials AdGuardHome
if [ -f "$CREDS_FILE" ] && [ "$ROTATE_CREDS" -eq 0 ]; then
    log "Загрузка существующих credentials AdGuardHome из $CREDS_FILE..."
    ADG_PORT=$(read_url_port "ADG_URL" "$CREDS_FILE")
    ADG_USER=$(read_cred_value "ADG_USER" "$CREDS_FILE")
    ADG_PASS=$(read_cred_value "ADG_PASS" "$CREDS_FILE")
    ADG_DNS_PORT=$(read_cred_value "ADG_DNS_PORT" "$CREDS_FILE")
fi

# Если пустые, генерируем заново
[ -z "$ADG_PORT" ] && ADG_PORT=$(shuf -i 10000-65000 -n 1)
[ -z "$ADG_USER" ] && ADG_USER=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)
[ -z "$ADG_PASS" ] && ADG_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)
[ -z "$ADG_DNS_PORT" ] && ADG_DNS_PORT=$(shuf -i 10000-65000 -n 1)
command -v mkpasswd >/dev/null || apt install -y whois
ADG_HASH=$(mkpasswd -m bcrypt "$ADG_PASS")

# Устанавливаем AdGuardHome только если бинарника нет
if [ ! -f "/opt/AdGuardHome/AdGuardHome" ]; then
    log "Установка AdGuardHome..."
    curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v
else
    warn "AdGuardHome бинарник уже существует, пропуск установки."
fi

# Всегда перезаписываем конфиг (новые порт, логин, пароль)
mark_step "AdGuardHome: write YAML config"
log "Применение конфигурации AdGuardHome..."

# Останавливаем активные инстансы и удаляем legacy lower-case unit.
cleanup_legacy_adguard_units

cat <<EOF > /opt/AdGuardHome/AdGuardHome.yaml
http:
  pprof:
    port: 6060
    enabled: false
  address: 0.0.0.0:$ADG_PORT
  session_ttl: 720h
users:
  - name: $ADG_USER
    password: $ADG_HASH
auth_attempts: 5
block_auth_min: 15
http_proxy: "http://127.0.0.1:$ADG_HTTP_PROXY_PORT/"
language: ru
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: $ADG_DNS_PORT
  upstream_dns:
    - https://cloudflare-dns.com/dns-query
    - https://dns.google/dns-query
  cache_size: 4194304
filtering:
  safe_search:
    enabled: true
    bing: true
    duckduckgo: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
    name: AdAway Default Blocklist
    id: 2
EOF

# Регистрируем systemd-юнит AdGuardHome. Используем одно canonical имя сервиса.
AGH_SVC_NAME="AdGuardHome"
mark_step "AdGuardHome: register systemd unit"
if ! systemctl list-unit-files 2>/dev/null | grep -qi 'AdGuardHome\.service'; then
    log "Регистрация AdGuardHome в systemd..."
    /opt/AdGuardHome/AdGuardHome -s install 2>/dev/null || true
    systemctl daemon-reload
fi

if ! systemctl list-unit-files 2>/dev/null | grep -qi 'AdGuardHome\.service'; then
    cat <<UNIT > /etc/systemd/system/AdGuardHome.service
[Unit]
Description=AdGuard Home: Network-level blocker
After=syslog.target network-online.target

[Service]
User=root
WorkingDirectory=/opt/AdGuardHome
ExecStart=/opt/AdGuardHome/AdGuardHome -s run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
fi

# Добавляем override: запускать ПОСЛЕ awg0
mark_step "AdGuardHome: configure after-awg override"
mkdir -p "/etc/systemd/system/${AGH_SVC_NAME}.service.d"
cat <<OVERRIDE > "/etc/systemd/system/${AGH_SVC_NAME}.service.d/after-awg.conf"
[Unit]
After=awg-quick@awg0.service network-online.target
Wants=awg-quick@awg0.service network-online.target
[Service]
Restart=on-failure
RestartSec=5
OVERRIDE

systemctl daemon-reload
mark_step "AdGuardHome: enable and restart service"
systemctl enable "${AGH_SVC_NAME}" 2>/dev/null || true

# Ждём интерфейс awg0 (до 15с), затем стартуем
for _i in $(seq 1 15); do ip link show awg0 > /dev/null 2>&1 && break; sleep 1; done
systemctl restart "${AGH_SVC_NAME}"

# Проверяем что AGH реально слушает на ADG_DNS_PORT
for _i in $(seq 1 10); do ss -ulnp | grep ":${ADG_DNS_PORT} " > /dev/null 2>&1 && break; sleep 1; done
if ss -ulnp | grep ":${ADG_DNS_PORT} " > /dev/null 2>&1; then
    log "AdGuardHome DNS (порт ${ADG_DNS_PORT}) слушает — OK"
else
    warn "AdGuardHome НЕ слушает на порту ${ADG_DNS_PORT}! Проверьте: journalctl -u ${AGH_SVC_NAME} -n 50"
fi

# Пишем прямой конфиг Xray после того, как известен финальный DNS-порт AGH.
mark_step "Xray: write direct config after AdGuardHome"
log "Запись прямого конфига Xray..."
write_xray_config
xray run -test -config /usr/local/etc/xray/config.json || err "Xray config validation failed."
log "Перезапуск xray для применения конфигурации..."
systemctl restart xray
# Ждём поднятия Xray на порту 443
for _i in $(seq 1 15); do ss -tlnp | grep ':443 ' > /dev/null 2>&1 && break; sleep 1; done
if ss -tlnp | grep ':443 ' > /dev/null 2>&1; then
    log "Xray Reality (порт 443) слушает — OK"
else
    err "Xray НЕ слушает на порту 443! Проверьте: journalctl -u xray -n 50"
fi

# ==============================================================================
# 7. НАСТРОЙКА SSH И ФАЕРВОЛА
# ==============================================================================
mark_step "Firewall: UFW and SSH"
log "Настройка UFW..."
if ss -tlnp | grep -q ':2244'; then
    warn "SSH уже на порту 2244, настраиваем правила для него."
    ufw allow 2244/tcp 2>/dev/null || true
else
    ufw allow 22/tcp 2>/dev/null || true
fi

ufw default allow outgoing
ufw allow 443/tcp
ufw allow ${ADG_PORT}/tcp
ufw allow ${AWG_PORT}/udp
# Разрешаем трафик к AGH DNS порту от VPN-клиентов (DNAT: awg0:53 -> 0.0.0.0:ADG_DNS_PORT)
ufw allow in on awg0 to any port ${ADG_DNS_PORT}
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
ufw --force enable
if ! ss -tlnp | grep -q ':2244'; then
    log "Изменение порта SSH на 2244..."
    sed -i '/^#\?Port /d' /etc/ssh/sshd_config
    echo "Port 2244" >> /etc/ssh/sshd_config
    mkdir -p /etc/ssh/sshd_config.d
    echo "Port 2244" > /etc/ssh/sshd_config.d/custom_port.conf 2>/dev/null || true
    systemctl restart sshd
    sleep 2
    if ss -tlnp | grep -q ':2244'; then
        ufw allow 2244/tcp 2>/dev/null || true
        ufw delete allow 22/tcp 2>/dev/null || true
        log "SSH порт 2244 активен"
    fi
fi

# Настройка Fail2Ban для SSH
mark_step "Firewall: Fail2Ban"
log "Настройка Fail2Ban (SSH)..."
cat <<EOF > /etc/fail2ban/jail.d/vpn-bundle.local
[sshd]
enabled = true
port = 2244
mode = aggressive
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
systemctl restart fail2ban

mark_step "Firewall: validate stack"
validate_stack "${AGH_SVC_NAME}"

# ==============================================================================
# 8. ОЧИСТКА И УДАЛЕНИЕ ИНСТРУМЕНТОВ СБОРКИ
# ==============================================================================
mark_step "Finalize: cleanup build tools"
log "Удаление инструментов сборки (Hardening) и очистка кэша..."
if [ "$SKIP_APT" -eq 0 ]; then
    # Удаляем пакеты сборки (dkms оставляем для пересборки модуля при обновлении ядра)
    apt purge -y git build-essential libelf-dev libmnl-dev > /dev/null 2>&1 || true
    apt autoremove -y > /dev/null 2>&1
    apt clean
    rm -rf /usr/src/amneziawg-linux-kernel-module
    rm -rf /usr/src/amneziawg-tools
else
    log "Пропуск очистки apt (fast mode)."
fi

# ==============================================================================
# 9. СОХРАНЕНИЕ CREDENTIALS И ФИНАЛЬНЫЙ ВЫВОД
# ==============================================================================
mark_step "Finalize: persist credentials and print output"
cat <<CREDS > "$CREDS_FILE"
# 3x-awg-adg-bundle credentials (v${SCRIPT_VERSION})
# Generated: $(date -Iseconds)
# ====================================
SSH_PORT=2244
XRAY_PORT=443
XRAY_UUID=${XRAY_UUID}
XRAY_PRIVATE_KEY=${XRAY_PRIVATE_KEY}
XRAY_PUBLIC_KEY=${XRAY_PUBLIC_KEY}
XRAY_SHORT_ID=${XRAY_SHORT_ID}
VLESS_LINK=${VLESS_LINK}
CASCADE_ENABLED=${CASCADE_ENABLED}
CASCADE_MODE=${CASCADE_MODE}
CASCADE_VLESS=${CASCADE_VLESS}
CASCADE_ADDRESS=${CASCADE_ADDRESS}
CASCADE_PORT=${CASCADE_PORT}
CASCADE_UUID=${CASCADE_UUID}
CASCADE_FLOW=${CASCADE_FLOW}
CASCADE_PBK=${CASCADE_PBK}
CASCADE_SNI=${CASCADE_SNI}
CASCADE_SID=${CASCADE_SID}
CASCADE_FP=${CASCADE_FP}
CASCADE_SPX=${CASCADE_SPX}
FINAL_MODE=${FINAL_MODE}
ADG_URL=http://${SERVER_IP}:${ADG_PORT}/
ADG_USER=${ADG_USER}
ADG_PASS=${ADG_PASS}
ADG_DNS_PORT=${ADG_DNS_PORT}
ADG_HTTP_PROXY_PORT=${ADG_HTTP_PROXY_PORT}
AWG_PORT=${AWG_PORT}
AWG_SERVER_PRIV=${SERVER_PRIV}
AWG_CLIENT_PRIV=${CLIENT_PRIV}
AWG_CLIENT_PSK=${CLIENT_PSK}
AWG_JC=${JC}
AWG_JMIN=${JMIN}
AWG_JMAX=${JMAX}
AWG_S1=${S1}
AWG_S2=${S2}
AWG_H1=${H1}
AWG_H2=${H2}
AWG_H3=${H3}
AWG_H4=${H4}
AWG_CLIENT_CONF=/root/amnezia_client.conf
CREDS
chmod 600 "$CREDS_FILE"


log "Установка и настройка успешно завершены!"
echo -e "\n=================================================================="
echo -e "${GREEN}SSH доступ:${RESET}"
echo -e "Порт: ${YELLOW}2244${RESET}"

echo -e "\n${GREEN}Xray Reality:${RESET}"
echo -e "Порт: ${YELLOW}443${RESET}"
echo -e "Конфиг: ${YELLOW}/usr/local/etc/xray/config.json${RESET}"
echo -e "Дефолтная ссылка VLESS (Reality): ${YELLOW}${VLESS_LINK}${RESET}"
echo -e "Режим маршрутизации: ${YELLOW}${FINAL_MODE}${RESET}"
echo -e "\n${GREEN}AdGuardHome:${RESET}"
echo -e "Админка (Web UI): ${YELLOW}http://${SERVER_IP}:${ADG_PORT}/${RESET}"
echo -e "DNS реальный порт: ${YELLOW}${ADG_DNS_PORT}${RESET} (клиент видит 10.8.0.1:53 через DNAT)"
echo -e "User: ${YELLOW}${ADG_USER}${RESET} / Pass: ${YELLOW}${ADG_PASS}${RESET}"
echo -e "Безопасный поиск: ${GREEN}ВКЛЮЧЕН${RESET}"

echo -e "\n${GREEN}AmneziaWG:${RESET}"
echo -e "Конфиг сохранен в: ${YELLOW}/root/amnezia_client.conf${RESET}"
echo -e "${YELLOW}--- СОДЕРЖИМОЕ CONFIG-ФАЙЛА (для копирования) ---${RESET}"
cat /root/amnezia_client.conf
echo -e "${YELLOW}--- КОНЕЦ КОНФИГА ---${RESET}"

echo -e "\nQR-код для мобильного клиента:"
qrencode -t ansiutf8 < /root/amnezia_client.conf

echo -e "\n${GREEN}Все credentials сохранены:${RESET} ${YELLOW}${CREDS_FILE}${RESET}"
echo -e "==================================================================\n"
echo -e "${RED}ВНИМАНИЕ: Выполните 'sudo reboot' для окончательной активации AmneziaWG!${RESET}\n"
