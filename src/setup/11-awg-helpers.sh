resolve_awg_key_bin() {
    # Prefer the stable WireGuard CLI for key material; fall back to awg if needed.
    command -v wg 2>/dev/null || command -v awg 2>/dev/null || true
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

cleanup_legacy_awg_dns_redirects() {
    iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-port "${ADG_DNS_PORT}" 2>/dev/null || true
    iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j REDIRECT --to-port "${ADG_DNS_PORT}" 2>/dev/null || true
}

ensure_awg_obfuscation_params() {
    # Preserve restored AmneziaWG noise parameters; fill only missing values.
    [ -z "$JC" ] && JC=$(shuf -i 3-12 -n 1)
    [ -z "$JMIN" ] && JMIN=$(shuf -i 40-70 -n 1)
    [ -z "$JMAX" ] && JMAX=$(shuf -i 700-1200 -n 1)
    [ -z "$S1" ] && S1=$(shuf -i 15-150 -n 1)
    [ -z "$S2" ] && S2=$(shuf -i 151-250 -n 1)
    [ -z "$H1" ] && H1=$(shuf -i 100000000-999999999 -n 1)
    [ -z "$H2" ] && H2=$(shuf -i 100000000-999999999 -n 1)
    [ -z "$H3" ] && H3=$(shuf -i 100000000-999999999 -n 1)
    [ -z "$H4" ] && H4=$(shuf -i 100000000-999999999 -n 1)
}
