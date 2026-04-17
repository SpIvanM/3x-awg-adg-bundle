# ==============================================================================
# 6. УСТАНОВКА И НАСТРОЙКА ADGUARD HOME
# ==============================================================================
log "Установка AdGuardHome..."
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
