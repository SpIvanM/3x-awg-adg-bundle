# ==============================================================================
# 5. УСТАНОВКА AMNEZIAWG
# ==============================================================================
log "Проверка AmneziaWG..."
if command -v awg >/dev/null 2>&1 && [ -f /etc/amnezia/amneziawg/awg0.conf ]; then
    warn "AmneziaWG уже настроен, пропускаем переустановку."
else
    ensure_awg_build_dependencies
    if grep -qi "ubuntu" /etc/os-release; then
        log "Используем PPA для Ubuntu..."
        apt install -y software-properties-common python3-launchpadlib gnupg2
        add-apt-repository -y ppa:amnezia/ppa
        apt update
        apt install -y amneziawg
    else
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
mkdir -p /etc/amnezia/amneziawg
chmod 700 /etc/amnezia/amneziawg

AWG_PORT=51820
load_existing_awg_credentials

# Параметры обфускации (Рандомизация для защиты от сигнатурного анализа ТСПУ 2026)
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

[ -z "$SERVER_PRIV" ] && SERVER_PRIV=$(awg genkey)
[ -z "$CLIENT_PRIV" ] && CLIENT_PRIV=$(awg genkey)
[ -z "$CLIENT_PSK" ] && CLIENT_PSK=$(awg genpsk)
[ -n "$SERVER_PRIV" ] && [ -z "$SERVER_PUB" ] && SERVER_PUB=$(printf '%s' "$SERVER_PRIV" | awg pubkey)
[ -n "$CLIENT_PRIV" ] && [ -z "$CLIENT_PUB" ] && CLIENT_PUB=$(printf '%s' "$CLIENT_PRIV" | awg pubkey)

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

# Правила NAT и маршрутизации (TPROXY активен)
PostUp = iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $PUB_INT -j MASQUERADE
# DNAT: перенаправляем DNS от VPN-клиентов (порт 53) -> AdGuardHome (порт $ADG_DNS_PORT)
PostUp = iptables -t nat -A PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT
PostUp = iptables -t nat -A PREROUTING -i awg0 -p tcp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT

# TProxy Routing (REDIRECT AWG traffic to Xray)
PostUp = ip rule add fwmark 1 table 100 2>/dev/null || true
PostUp = ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null || true
PostUp = iptables -t mangle -N AWG_TPROXY 2>/dev/null || true
PostUp = iptables -t mangle -F AWG_TPROXY
PostUp = iptables -t mangle -A AWG_TPROXY -d 0.0.0.0/8 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d 10.0.0.0/8 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d 100.64.0.0/10 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d 127.0.0.0/8 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d 169.254.0.0/16 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d 172.16.0.0/12 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d 192.168.0.0/16 -p tcp ! --dport 53 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d 192.168.0.0/16 -p udp ! --dport 53 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d 224.0.0.0/4 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d 240.0.0.0/4 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -d $SERVER_IP -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -p udp --dport 53 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -p tcp --dport 53 -j RETURN
PostUp = iptables -t mangle -A AWG_TPROXY -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1
PostUp = iptables -t mangle -A AWG_TPROXY -p udp -j TPROXY --on-port 12345 --tproxy-mark 1
PostUp = iptables -t mangle -A PREROUTING -i awg0 -j AWG_TPROXY
# UFW видит TProxy-пакеты как non-local и может уронить их в ufw-not-local без явного allow по mark.
PostUp = iptables -I INPUT 1 -i awg0 -m mark --mark 1 -m comment --comment awg-tproxy-input -j ACCEPT

PostDown = iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o $PUB_INT -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D PREROUTING -i awg0 -p udp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT 2>/dev/null || true
PostDown = iptables -t nat -D PREROUTING -i awg0 -p tcp --dport 53 -j REDIRECT --to-port $ADG_DNS_PORT 2>/dev/null || true
PostDown = iptables -t mangle -D PREROUTING -i awg0 -j AWG_TPROXY 2>/dev/null || true
PostDown = iptables -t mangle -F AWG_TPROXY 2>/dev/null || true
PostDown = iptables -t mangle -X AWG_TPROXY 2>/dev/null || true
PostDown = iptables -D INPUT -i awg0 -m mark --mark 1 -m comment --comment awg-tproxy-input -j ACCEPT 2>/dev/null || true
PostDown = ip rule del fwmark 1 table 100 2>/dev/null || true
PostDown = ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null || true

[Peer]
PublicKey = $CLIENT_PUB
PresharedKey = $CLIENT_PSK
AllowedIPs = 10.8.0.2/32
EOF

cleanup_legacy_awg_dns_redirects
systemctl enable awg-quick@awg0
systemctl restart awg-quick@awg0 || err "Не удалось поднять awg0. Проверьте сборку модуля AmneziaWG для $(uname -r)."

# Конфигурация клиента
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
