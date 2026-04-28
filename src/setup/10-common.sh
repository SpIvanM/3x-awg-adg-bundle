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

trim_cr_value() {
    printf '%s' "$1" | tr -d '\r'
}

validate_stack() {
    local agh_service_name="$1"

    log "Валидация AmneziaWG и AdGuardHome..."
    systemctl restart awg-quick@awg0 || err "Не удалось поднять awg0 после настройки."
    systemctl restart "$agh_service_name" || err "Не удалось перезапустить ${agh_service_name}."

    ss -lntup | grep -Eq ':51820 ' || err "AmneziaWG не слушает порт 51820."
    dig @127.0.0.1 -p "${ADG_DNS_PORT}" example.com +short | grep -q . || err "AdGuardHome не отвечает на локальные DNS-запросы."
    awg show | grep -q '^interface: awg0' || err "AmneziaWG interface awg0 не поднялся."
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
