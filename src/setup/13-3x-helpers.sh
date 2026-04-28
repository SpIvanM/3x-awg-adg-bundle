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
