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

AWG_PORT=53
mark_step "AmneziaWG: resolve AWG key binary"
AWG_KEY_BIN="$(resolve_awg_key_bin || true)"
[ -n "$AWG_KEY_BIN" ] || err "Не найден awg/wg после установки AmneziaWG."
mark_step "AmneziaWG: load existing credentials"
load_existing_awg_credentials
AWG_PORT=53

# Параметры обфускации (Рандомизация для защиты от сигнатурного анализа ТСПУ 2026)
mark_step "AmneziaWG: generate obfuscation parameters"
ensure_awg_obfuscation_params
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
MTU = 1280
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
MTU = 1280
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
