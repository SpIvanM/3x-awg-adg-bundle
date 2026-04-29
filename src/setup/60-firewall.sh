# ==============================================================================
# 7. НАСТРОЙКА SSH И ФАЕРВОЛА
# ==============================================================================
mark_step "Firewall: UFW and SSH"
log "Настройка UFW..."
if [ "$DEPLOY_MODE" = "relay" ]; then
    ensure_relay_forward_ports
fi

if ss -tlnp | grep -q ':2244'; then
    warn "SSH уже на порту 2244, настраиваем правила для него."
    ufw allow 2244/tcp 2>/dev/null || true
else
    ufw allow 22/tcp 2>/dev/null || true
fi

ufw default allow outgoing
if [ "$DEPLOY_MODE" = "relay" ]; then
    mark_step "Firewall: relay local allow Reality 443/tcp"
else
    mark_step "Firewall: target allow Reality 443/tcp"
fi
ufw allow 443/tcp
if [ "$DEPLOY_MODE" = "relay" ]; then
    mark_step "Firewall: relay local allow AdGuardHome web"
else
    mark_step "Firewall: target allow AdGuardHome web"
fi
ufw allow ${ADG_PORT}/tcp
if [ "$DEPLOY_MODE" = "relay" ]; then
    mark_step "Firewall: relay local allow AWG 53/udp"
else
    mark_step "Firewall: target allow AWG 53/udp"
fi
ufw allow ${AWG_PORT}/udp
if [ "$DEPLOY_MODE" = "relay" ]; then
    mark_step "Firewall: relay forward allow external AWG"
    ufw allow ${RELAY_FWD_AWG_PORT}/udp
    mark_step "Firewall: relay forward allow external Reality"
    ufw allow ${RELAY_FWD_REALITY_PORT}/tcp
fi
# Разрешаем трафик к AGH DNS порту от VPN-клиентов (DNAT: awg0:53 -> 0.0.0.0:ADG_DNS_PORT)
if [ "$DEPLOY_MODE" = "relay" ]; then
    mark_step "Firewall: relay local allow AdGuardHome DNS from awg0"
else
    mark_step "Firewall: target allow AdGuardHome DNS from awg0"
fi
ufw allow in on awg0 to any port ${ADG_DNS_PORT}
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
ufw --force enable
if [ "$DEPLOY_MODE" = "relay" ]; then
    setup_port_forwarding
fi

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
