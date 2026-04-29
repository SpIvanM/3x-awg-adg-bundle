is_yes_answer() {
    case "$1" in
        y|Y|yes|YES|Yes|д|Д|да|ДА|Да) return 0 ;;
        *) return 1 ;;
    esac
}

append_forwarding_rule() {
    local rule_target_ip="$1"
    local rule_target_port="$2"
    local rule_proto="$3"
    local rule_external_port="${4:-}"
    local rule_id="${5:-}"
    local rule_line

    rule_external_port="${rule_external_port:-$rule_target_port}"
    rule_id="${rule_id:-$(make_forwarding_rule_id "$rule_target_ip" "$rule_target_port" "$rule_proto" "$rule_external_port")}"
    rule_line="${rule_target_ip}|${rule_target_port}|${rule_proto}|${rule_external_port}|${rule_id}"

    if printf '%s\n' "${PORT_FORWARDING_RULES:-}" | awk -F'|' -v ip="$rule_target_ip" -v port="$rule_target_port" -v proto="$rule_proto" '$1 == ip && $2 == port && $3 == proto { found = 1 } END { exit found ? 0 : 1 }'; then
        return 0
    fi

    if [ -n "${PORT_FORWARDING_RULES:-}" ]; then
        PORT_FORWARDING_RULES="${PORT_FORWARDING_RULES}
${rule_line}"
    else
        PORT_FORWARDING_RULES="$rule_line"
    fi
}

make_forwarding_rule_id() {
    printf '%s-%s-%s-%s' "$1" "$2" "$3" "$4" | tr '.:/|' '----' | tr -cd 'A-Za-z0-9_-'
}

load_forwarding_rules_state() {
    PORT_FORWARDING_RULES=""
    PORT_FORWARDING_ENABLED=0

    if [ -f "${FORWARDING_STATE_FILE:-}" ] && [ "$ROTATE_CREDS" -eq 0 ]; then
        while IFS='|' read -r rule_target_ip rule_target_port rule_proto rule_external_port rule_id _rest; do
            case "$rule_target_ip" in ''|\#*) continue ;; esac
            [ -n "$rule_target_port" ] || continue
            [ -n "$rule_proto" ] || rule_proto="both"
            [ -n "$rule_external_port" ] || rule_external_port="$rule_target_port"
            append_forwarding_rule "$rule_target_ip" "$rule_target_port" "$rule_proto" "$rule_external_port" "$rule_id"
        done < "$FORWARDING_STATE_FILE"
    fi

    if [ -z "${PORT_FORWARDING_RULES:-}" ] && [ -f "$CREDS_FILE" ] && [ "$ROTATE_CREDS" -eq 0 ]; then
        local legacy_target_ip
        local legacy_awg_port
        local legacy_reality_port
        local legacy_fwd_awg_port
        local legacy_fwd_reality_port

        legacy_target_ip=$(read_cred_value "TARGET_IP" "$CREDS_FILE")
        legacy_awg_port=$(read_cred_value "TARGET_AWG_PORT" "$CREDS_FILE")
        legacy_reality_port=$(read_cred_value "TARGET_REALITY_PORT" "$CREDS_FILE")
        legacy_fwd_awg_port=$(read_cred_value "RELAY_FWD_AWG_PORT" "$CREDS_FILE")
        legacy_fwd_reality_port=$(read_cred_value "RELAY_FWD_REALITY_PORT" "$CREDS_FILE")

        if [ -n "$legacy_target_ip" ]; then
            [ -n "$legacy_awg_port" ] && append_forwarding_rule "$legacy_target_ip" "$legacy_awg_port" "udp" "${legacy_fwd_awg_port:-$legacy_awg_port}" "legacy-awg"
            [ -n "$legacy_reality_port" ] && append_forwarding_rule "$legacy_target_ip" "$legacy_reality_port" "tcp" "${legacy_fwd_reality_port:-$legacy_reality_port}" "legacy-reality"
        fi
    fi

    [ -n "${PORT_FORWARDING_RULES:-}" ] && PORT_FORWARDING_ENABLED=1
}

save_forwarding_rules_state() {
    if [ "${PORT_FORWARDING_ENABLED:-0}" -eq 1 ] && [ -n "${PORT_FORWARDING_RULES:-}" ]; then
        printf '%s\n' "${PORT_FORWARDING_RULES}" > "$FORWARDING_STATE_FILE"
        chmod 600 "$FORWARDING_STATE_FILE"
        return 0
    fi

    rm -f "$FORWARDING_STATE_FILE"
}

collect_forwarding_rules() {
    [ -c /dev/tty ] || err "Для настройки forwarding требуется интерактивный ввод через /dev/tty."

    local answer
    local target_ip
    local target_port
    local proto

    printf 'Настроить проброс портов с этого сервера? [y/N]: ' >/dev/tty
    IFS= read -r answer </dev/tty
    answer=$(trim_cr_value "$answer")
    if ! is_yes_answer "$answer"; then
        PORT_FORWARDING_RULES=""
        PORT_FORWARDING_ENABLED=0
        log "Port forwarding не настроен: оператор выбрал обычный direct-режим."
        return 0
    fi

    PORT_FORWARDING_ENABLED=1

    while true; do
        target_ip=""
        while true; do
            printf 'Target IP: ' >/dev/tty
            IFS= read -r target_ip </dev/tty
            target_ip=$(trim_cr_value "$target_ip")
            [ -n "$target_ip" ] && break
            warn "Target IP обязателен для forwarding."
        done

        while true; do
            target_port=""
            while true; do
                printf 'Target port: ' >/dev/tty
                IFS= read -r target_port </dev/tty
                target_port=$(trim_cr_value "$target_port")
                case "$target_port" in
                    ''|*[!0-9]*) warn "Target port должен быть числом." ;;
                    *) break ;;
                esac
            done

            printf 'Protocol [tcp, udp или both] (default both): ' >/dev/tty
            IFS= read -r proto </dev/tty
            proto=$(trim_cr_value "$proto")
            proto="${proto:-both}"
            case "$proto" in
                tcp|udp|both) ;;
                *) warn "Неизвестный protocol '${proto}', используется both."; proto="both" ;;
            esac

            append_forwarding_rule "$target_ip" "$target_port" "$proto"

            printf 'Добавить еще порт для этого target? [y/N]: ' >/dev/tty
            IFS= read -r answer </dev/tty
            answer=$(trim_cr_value "$answer")
            is_yes_answer "$answer" || break
        done

        printf 'Добавить еще target-сервер? [y/N]: ' >/dev/tty
        IFS= read -r answer </dev/tty
        answer=$(trim_cr_value "$answer")
        is_yes_answer "$answer" || break
    done
}

prompt_target_details() {
    log "Relay: интерактивная настройка optional port forwarding."
    load_forwarding_rules_state
    collect_forwarding_rules
}

is_relay_forward_port_available() {
    local port="$1"
    local proto="$2"
    local reserved_ports=":22:2244:53:${AWG_PORT:-}:443:${REALITY_PORT:-}:${ADG_PORT:-}:${ADG_DNS_PORT:-}:${FORWARDING_SELECTED_EXTERNAL_PORTS:-}:"

    case "$port" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1

    case "$reserved_ports" in
        *":${port}:"*) return 1 ;;
    esac

    case "$proto" in
        udp)
            ! ss -H -lun "sport = :${port}" 2>/dev/null | grep -q .
            ;;
        tcp)
            ! ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
            ;;
        both|'')
            ! ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q . && \
            ! ss -H -lun "sport = :${port}" 2>/dev/null | grep -q .
            ;;
        *)
            return 1
            ;;
    esac
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
    [ "${PORT_FORWARDING_ENABLED:-0}" -eq 1 ] || return 0
    [ -n "${PORT_FORWARDING_RULES:-}" ] || return 0

    local normalized_rules=""
    local rule_line
    local rule_target_ip
    local rule_target_port
    local rule_proto
    local rule_external_port
    local rule_id

    FORWARDING_SELECTED_EXTERNAL_PORTS=""

    while IFS= read -r rule_line; do
        [ -n "$rule_line" ] || continue
        IFS='|' read -r rule_target_ip rule_target_port rule_proto rule_external_port rule_id <<EOF
$rule_line
EOF
        rule_proto="${rule_proto:-both}"
        if [ -z "${rule_external_port:-}" ] || ! is_relay_forward_port_available "$rule_external_port" "$rule_proto"; then
            rule_external_port=$(choose_relay_forward_port "$rule_target_port" "$rule_proto")
        fi
        rule_id="${rule_id:-$(make_forwarding_rule_id "$rule_target_ip" "$rule_target_port" "$rule_proto" "$rule_external_port")}"

        if [ -z "$normalized_rules" ]; then
            normalized_rules="${rule_target_ip}|${rule_target_port}|${rule_proto}|${rule_external_port}|${rule_id}"
        else
            normalized_rules="${normalized_rules}
${rule_target_ip}|${rule_target_port}|${rule_proto}|${rule_external_port}|${rule_id}"
        fi
        FORWARDING_SELECTED_EXTERNAL_PORTS="${FORWARDING_SELECTED_EXTERNAL_PORTS:+${FORWARDING_SELECTED_EXTERNAL_PORTS}:}${rule_external_port}"
    done <<EOF
${PORT_FORWARDING_RULES}
EOF

    PORT_FORWARDING_RULES="$normalized_rules"
}

cleanup_port_forwarding() {
    [ "$DEPLOY_MODE" = "relay" ] || return 0
    [ "${PORT_FORWARDING_ENABLED:-0}" -eq 1 ] || return 0
    [ -n "${PORT_FORWARDING_RULES:-}" ] || return 0

    iptables_delete_rule filter FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "3x-awg relay fwd established" -j ACCEPT

    local rule_line
    local rule_target_ip
    local rule_target_port
    local rule_proto
    local rule_external_port
    local rule_id
    local fwd_proto
    local rule_comment

    while IFS= read -r rule_line; do
        [ -n "$rule_line" ] || continue
        IFS='|' read -r rule_target_ip rule_target_port rule_proto rule_external_port rule_id <<EOF
$rule_line
EOF
        rule_external_port="${rule_external_port:-$rule_target_port}"
        rule_id="${rule_id:-$(make_forwarding_rule_id "$rule_target_ip" "$rule_target_port" "$rule_proto" "$rule_external_port")}"
        for fwd_proto in $(forwarding_rule_protocols "$rule_proto"); do
            rule_comment="3x-awg-fwd:${rule_id}:${fwd_proto}"
            iptables_delete_rule nat PREROUTING -i "$PUB_INT" -p "$fwd_proto" --dport "$rule_external_port" -m comment --comment "$rule_comment prerouting" -j DNAT --to-destination "${rule_target_ip}:${rule_target_port}"
            iptables_delete_rule filter FORWARD -i "$PUB_INT" -p "$fwd_proto" -d "$rule_target_ip" --dport "$rule_target_port" -m comment --comment "$rule_comment forward" -j ACCEPT
            iptables_delete_rule nat POSTROUTING -p "$fwd_proto" -d "$rule_target_ip" --dport "$rule_target_port" -m comment --comment "$rule_comment postrouting" -j MASQUERADE
        done
    done <<EOF
${PORT_FORWARDING_RULES}
EOF
}

forwarding_rule_protocols() {
    case "$1" in
        tcp) echo "tcp" ;;
        udp) echo "udp" ;;
        both|'') echo "tcp udp" ;;
        *) echo "tcp udp" ;;
    esac
}

setup_port_forwarding() {
    [ "$DEPLOY_MODE" = "relay" ] || return 0
    [ "${PORT_FORWARDING_ENABLED:-0}" -eq 1 ] || return 0
    [ -n "${PORT_FORWARDING_RULES:-}" ] || return 0

    mark_step "Relay forwarding: cleanup old owned rules"
    cleanup_port_forwarding

    ensure_relay_forward_ports

    mark_step "Relay forwarding: install transparent NAT rules"
    iptables_ensure_rule filter FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -m comment --comment "3x-awg relay fwd established" -j ACCEPT

    local rule_line
    local rule_target_ip
    local rule_target_port
    local rule_proto
    local rule_external_port
    local rule_id
    local fwd_proto
    local rule_comment

    while IFS= read -r rule_line; do
        [ -n "$rule_line" ] || continue
        IFS='|' read -r rule_target_ip rule_target_port rule_proto rule_external_port rule_id <<EOF
$rule_line
EOF
        rule_external_port="${rule_external_port:-$rule_target_port}"
        rule_id="${rule_id:-$(make_forwarding_rule_id "$rule_target_ip" "$rule_target_port" "$rule_proto" "$rule_external_port")}"
        for fwd_proto in $(forwarding_rule_protocols "$rule_proto"); do
            rule_comment="3x-awg-fwd:${rule_id}:${fwd_proto}"
            iptables_ensure_rule nat PREROUTING -i "$PUB_INT" -p "$fwd_proto" --dport "$rule_external_port" -m comment --comment "$rule_comment prerouting" -j DNAT --to-destination "${rule_target_ip}:${rule_target_port}"
            iptables_ensure_rule filter FORWARD -i "$PUB_INT" -p "$fwd_proto" -d "$rule_target_ip" --dport "$rule_target_port" -m comment --comment "$rule_comment forward" -j ACCEPT
            iptables_ensure_rule nat POSTROUTING -p "$fwd_proto" -d "$rule_target_ip" --dport "$rule_target_port" -m comment --comment "$rule_comment postrouting" -j MASQUERADE
        done
    done <<EOF
${PORT_FORWARDING_RULES}
EOF

    persist_iptables_rules
    save_forwarding_rules_state
}
