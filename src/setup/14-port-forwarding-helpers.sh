prompt_target_details() {
    [ -c /dev/tty ] || err "Для настройки relay требуется интерактивный ввод target-параметров через /dev/tty."

    if [ -f "$CREDS_FILE" ] && [ "$ROTATE_CREDS" -eq 0 ]; then
        TARGET_IP=$(read_cred_value "TARGET_IP" "$CREDS_FILE")
        TARGET_AWG_PORT=$(read_cred_value "TARGET_AWG_PORT" "$CREDS_FILE")
        TARGET_REALITY_PORT=$(read_cred_value "TARGET_REALITY_PORT" "$CREDS_FILE")
        TARGET_DNS_PORT=$(read_cred_value "TARGET_DNS_PORT" "$CREDS_FILE")
        RELAY_FWD_AWG_PORT=$(read_cred_value "RELAY_FWD_AWG_PORT" "$CREDS_FILE")
        RELAY_FWD_REALITY_PORT=$(read_cred_value "RELAY_FWD_REALITY_PORT" "$CREDS_FILE")
    fi

    TARGET_AWG_PORT="${TARGET_AWG_PORT:-53}"
    TARGET_REALITY_PORT="${TARGET_REALITY_PORT:-443}"

    log "Relay: ввод параметров target-сервера для будущего forwarding."

    local entered_value
    while true; do
        printf 'Target IP [%s]: ' "${TARGET_IP:-required}" >/dev/tty
        IFS= read -r entered_value </dev/tty
        entered_value=$(trim_cr_value "$entered_value")
        [ -n "$entered_value" ] && TARGET_IP="$entered_value"
        [ -n "${TARGET_IP:-}" ] && break
    done

    printf 'Target AWG UDP port [%s]: ' "$TARGET_AWG_PORT" >/dev/tty
    IFS= read -r entered_value </dev/tty
    entered_value=$(trim_cr_value "$entered_value")
    [ -n "$entered_value" ] && TARGET_AWG_PORT="$entered_value"

    printf 'Target Reality TCP port [%s]: ' "$TARGET_REALITY_PORT" >/dev/tty
    IFS= read -r entered_value </dev/tty
    entered_value=$(trim_cr_value "$entered_value")
    [ -n "$entered_value" ] && TARGET_REALITY_PORT="$entered_value"

    while true; do
        printf 'Target DNS port [%s]: ' "${TARGET_DNS_PORT:-required}" >/dev/tty
        IFS= read -r entered_value </dev/tty
        entered_value=$(trim_cr_value "$entered_value")
        [ -n "$entered_value" ] && TARGET_DNS_PORT="$entered_value"
        [ -n "${TARGET_DNS_PORT:-}" ] && break
    done

    case "$TARGET_AWG_PORT:$TARGET_REALITY_PORT:$TARGET_DNS_PORT" in
        *[!0-9:]*|'') err "Target-порты должны быть числовыми: AWG=${TARGET_AWG_PORT}, Reality=${TARGET_REALITY_PORT}, DNS=${TARGET_DNS_PORT}." ;;
    esac

}

is_relay_forward_port_available() {
    local port="$1"
    local proto="$2"

    case "$port" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1

    case ":53:${AWG_PORT:-}:443:${REALITY_PORT:-}:${ADG_PORT:-}:${ADG_DNS_PORT:-}:${RELAY_FWD_AWG_PORT:-}:${RELAY_FWD_REALITY_PORT:-}:" in
        *":${port}:"*) return 1 ;;
    esac

    if [ "$proto" = "udp" ]; then
        ! ss -H -lun "sport = :${port}" 2>/dev/null | grep -q .
    else
        ! ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
    fi
}

choose_relay_forward_port() {
    local preferred_port="$1"
    local proto="$2"
    local candidate

    if is_relay_forward_port_available "$preferred_port" "$proto"; then
        echo "$preferred_port"
        return
    fi

    for _i in $(seq 1 100); do
        candidate=$(shuf -i 10000-65000 -n 1)
        if is_relay_forward_port_available "$candidate" "$proto"; then
            echo "$candidate"
            return
        fi
    done

    err "Не удалось подобрать свободный внешний relay-forward порт для ${proto}."
}

iptables_ensure_rule() {
    local table="$1"
    local chain="$2"
    shift 2

    if [ "$table" = "filter" ]; then
        iptables -C "$chain" "$@" 2>/dev/null || iptables -A "$chain" "$@"
    else
        iptables -t "$table" -C "$chain" "$@" 2>/dev/null || iptables -t "$table" -A "$chain" "$@"
    fi
}

iptables_delete_rule() {
    local table="$1"
    local chain="$2"
    shift 2

    if [ "$table" = "filter" ]; then
        iptables -D "$chain" "$@" 2>/dev/null || true
    else
        iptables -t "$table" -D "$chain" "$@" 2>/dev/null || true
    fi
}

persist_iptables_rules() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save
    elif command -v iptables-save >/dev/null 2>&1; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
    else
        warn "iptables правила применены, но не сохранены: netfilter-persistent и iptables-save недоступны."
    fi
}

ensure_relay_forward_ports() {
    [ "$DEPLOY_MODE" = "relay" ] || return 0

    RELAY_FWD_AWG_PORT=$(choose_relay_forward_port "${RELAY_FWD_AWG_PORT:-}" "udp")
    RELAY_FWD_REALITY_PORT=$(choose_relay_forward_port "${RELAY_FWD_REALITY_PORT:-}" "tcp")
}

cleanup_port_forwarding() {
    [ "$DEPLOY_MODE" = "relay" ] || return 0
    [ -n "${TARGET_IP:-}" ] || return 0
    [ -n "${RELAY_FWD_AWG_PORT:-}" ] || [ -n "${RELAY_FWD_REALITY_PORT:-}" ] || return 0

    iptables_delete_rule filter FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "3x-awg relay fwd established" -j ACCEPT

    if [ -n "${RELAY_FWD_AWG_PORT:-}" ]; then
        iptables_delete_rule nat PREROUTING -i "$PUB_INT" -p udp --dport "$RELAY_FWD_AWG_PORT" -m comment --comment "3x-awg relay fwd awg prerouting" -j DNAT --to-destination "${TARGET_IP}:${TARGET_AWG_PORT}"
        iptables_delete_rule filter FORWARD -i "$PUB_INT" -p udp -d "$TARGET_IP" --dport "$TARGET_AWG_PORT" -m comment --comment "3x-awg relay fwd awg forward" -j ACCEPT
        iptables_delete_rule nat POSTROUTING -p udp -d "$TARGET_IP" --dport "$TARGET_AWG_PORT" -m comment --comment "3x-awg relay fwd awg postrouting" -j MASQUERADE
    fi

    if [ -n "${RELAY_FWD_REALITY_PORT:-}" ]; then
        iptables_delete_rule nat PREROUTING -i "$PUB_INT" -p tcp --dport "$RELAY_FWD_REALITY_PORT" -m comment --comment "3x-awg relay fwd reality prerouting" -j DNAT --to-destination "${TARGET_IP}:${TARGET_REALITY_PORT}"
        iptables_delete_rule filter FORWARD -i "$PUB_INT" -p tcp -d "$TARGET_IP" --dport "$TARGET_REALITY_PORT" -m comment --comment "3x-awg relay fwd reality forward" -j ACCEPT
        iptables_delete_rule nat POSTROUTING -p tcp -d "$TARGET_IP" --dport "$TARGET_REALITY_PORT" -m comment --comment "3x-awg relay fwd reality postrouting" -j MASQUERADE
    fi
}

setup_port_forwarding() {
    [ "$DEPLOY_MODE" = "relay" ] || return 0

    [ -n "${TARGET_IP:-}" ] || err "TARGET_IP не задан для relay forwarding."

    mark_step "Relay forwarding: cleanup old owned rules"
    cleanup_port_forwarding

    ensure_relay_forward_ports

    mark_step "Relay forwarding: install transparent NAT rules"
    iptables_ensure_rule nat PREROUTING -i "$PUB_INT" -p udp --dport "$RELAY_FWD_AWG_PORT" -m comment --comment "3x-awg relay fwd awg prerouting" -j DNAT --to-destination "${TARGET_IP}:${TARGET_AWG_PORT}"
    iptables_ensure_rule nat PREROUTING -i "$PUB_INT" -p tcp --dport "$RELAY_FWD_REALITY_PORT" -m comment --comment "3x-awg relay fwd reality prerouting" -j DNAT --to-destination "${TARGET_IP}:${TARGET_REALITY_PORT}"
    iptables_ensure_rule filter FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "3x-awg relay fwd established" -j ACCEPT
    iptables_ensure_rule filter FORWARD -i "$PUB_INT" -p udp -d "$TARGET_IP" --dport "$TARGET_AWG_PORT" -m comment --comment "3x-awg relay fwd awg forward" -j ACCEPT
    iptables_ensure_rule filter FORWARD -i "$PUB_INT" -p tcp -d "$TARGET_IP" --dport "$TARGET_REALITY_PORT" -m comment --comment "3x-awg relay fwd reality forward" -j ACCEPT
    iptables_ensure_rule nat POSTROUTING -p udp -d "$TARGET_IP" --dport "$TARGET_AWG_PORT" -m comment --comment "3x-awg relay fwd awg postrouting" -j MASQUERADE
    iptables_ensure_rule nat POSTROUTING -p tcp -d "$TARGET_IP" --dport "$TARGET_REALITY_PORT" -m comment --comment "3x-awg relay fwd reality postrouting" -j MASQUERADE

    persist_iptables_rules
}
