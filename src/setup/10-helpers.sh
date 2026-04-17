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

configure_cascade_mode() {
    if [ -n "$CASCADE_MODE_ARG" ] && [ "$CASCADE_MODE_ARG" != "auto" ]; then
        err "Only --cascade-mode auto is supported in v1."
    fi

    reset_cascade_state

    if [ -n "$CASCADE_VLESS_ARG" ]; then
        CASCADE_VLESS="$CASCADE_VLESS_ARG"
        CASCADE_MODE="${CASCADE_MODE_ARG:-auto}"
        parse_cascade_vless_uri
        CASCADE_ENABLED=1
        FINAL_MODE="cascade-auto"
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
    T_PORT="$T_PORT" \
    ADG_DNS_PORT="$ADG_DNS_PORT" \
    ADG_HTTP_PROXY_PORT="$ADG_HTTP_PROXY_PORT" \
    CASCADE_ENABLED="$CASCADE_ENABLED" \
    CASCADE_ADDRESS="$CASCADE_ADDRESS" \
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

vpn_default_rule = {
    "type": "field",
    "ruleTag": "vpn-default",
    "inboundTag": ["tproxy-in"],
    "outboundTag": "direct-out",
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
            "tag": "tproxy-in",
            "listen": "0.0.0.0",
            "port": int(os.environ["T_PORT"]),
            "protocol": "dokodemo-door",
            "settings": {
                "network": "tcp,udp",
                "followRedirect": True,
            },
            "sniffing": {
                "enabled": True,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": True,
            },
            "streamSettings": {
                "sockopt": {
                    "tproxy": "tproxy",
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
                    "regexp:\\\\.ru$",
                    "regexp:\\\\.su$",
                    "regexp:\\\\.xn--p1ai$",
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
            vpn_default_rule,
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
                    "address": os.environ["CASCADE_ADDRESS"],
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
    vpn_default_rule["outboundTag"] = "exit-us"

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

    [ -n "$SERVER_PRIV" ] && SERVER_PUB=$(printf '%s' "$SERVER_PRIV" | awg pubkey)
    [ -n "$CLIENT_PRIV" ] && CLIENT_PUB=$(printf '%s' "$CLIENT_PRIV" | awg pubkey)
}

validate_stack() {
    local agh_service_name="$1"

    log "Валидация Xray, AmneziaWG и AdGuardHome..."
    xray run -test -config /usr/local/etc/xray/config.json || err "Xray config validation failed."
    systemctl restart xray || err "Не удалось перезапустить xray."
    systemctl restart awg-quick@awg0 || err "Не удалось поднять awg0 после настройки."
    systemctl restart "$agh_service_name" || err "Не удалось перезапустить ${agh_service_name}."

    ss -lntup | grep -Eq ':443 ' || err "Xray не слушает порт 443."
    ss -lntup | grep -Eq ':12345 ' || err "Xray не слушает TProxy порт 12345."
    ss -lntup | grep -Eq ':51820 ' || err "AmneziaWG не слушает порт 51820."
    dig @127.0.0.1 -p "${ADG_DNS_PORT}" example.com +short | grep -q . || err "AdGuardHome не отвечает на локальные DNS-запросы."
    awg show | grep -q '^interface: awg0' || err "AmneziaWG interface awg0 не поднялся."
    sysctl -n net.ipv4.conf.all.src_valid_mark | grep -qx '1' || err "src_valid_mark не включён, TProxy-marked пакеты могут отбрасываться policy routing."
    iptables -C INPUT -i awg0 -m mark --mark 1 -m comment --comment awg-tproxy-input -j ACCEPT \
        || err "Нет INPUT-исключения для marked TProxy-пакетов awg0: UFW может дропать AWG интернет-трафик."
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
