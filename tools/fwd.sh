#!/bin/bash
# fwd.sh - Minimalist port forwarding manager for 3x-awg-adg-bundle
[ "$EUID" -ne 0 ] && echo "Run as root" && exit 1

STATE_FILE="/root/.vpn-forwarding-rules"
PUB_INT=$(ip route | grep default | awk '{print $5}' | head -1)
TEMP_RULES="/tmp/fwd_new_rules"
rm -f "$TEMP_RULES"

# 1. Show current forwardings
echo -e "\n--- Current Forwardings ---"
if [ ! -f "$STATE_FILE" ] || [ ! -s "$STATE_FILE" ]; then 
    echo "(none)"
else
    while IFS='|' read -r ip port proto ext id; do
        [ -n "$ip" ] && echo "$proto: $ip:$port -> $ext"
    done < "$STATE_FILE"
fi

# 2. Ask: Delete old redirects?
read -p "Delete old redirects? (y/N): " ans
if [[ "$ans" =~ ^[yYдД] ]]; then
    for t in nat filter; do
        iptables-save -t $t | grep "3x-awg-fwd" | sed 's/-A/-D/' > /tmp/fwd_del
        while read -r r; do [ -n "$r" ] && iptables -t $t $r; done < /tmp/fwd_del
    done
    rm -f "$STATE_FILE" /tmp/fwd_del
    echo "Old rules cleared."
fi

# 3 & 4. Configure new server / port
while true; do
    read -p "Configure new server? (Y/n): " ans
    [[ "$ans" =~ ^[nNнН] ]] && break
    read -p " Target IP: " tip
    [ -z "$tip" ] && continue
    while true; do
        read -p " Configure new port? (Y/n): " ans
        [[ "$ans" =~ ^[nNнН] ]] && break
        read -p "  Target Port: " tport
        read -p "  Protocol (tcp/udp/both) [both]: " proto
        proto=${proto:-both}
        ext=$tport
        if ss -tlnu | grep -q ":$ext "; then
            ext=$(shuf -i 10000-65000 -n 1)
            echo "  Port $tport busy, using random $ext"
        fi
        echo "${tip}|${tport}|${proto}|${ext}|${tip}-${tport}-${proto}-${ext}" >> "$TEMP_RULES"
    done
done

# 5. Apply and Save
if [ -f "$TEMP_RULES" ]; then
    echo "Applying rules..."
    iptables -t filter -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -t filter -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    
    while IFS='|' read -r ip port proto ext id; do
        [ -z "$ip" ] && continue
        [[ "$proto" == "both" || "$proto" == "tcp" ]] && {
            iptables -t nat -A PREROUTING -i $PUB_INT -p tcp --dport $ext -m comment --comment "3x-awg-fwd" -j DNAT --to-destination $ip:$port
            iptables -t filter -A FORWARD -i $PUB_INT -p tcp -d $ip --dport $port -m comment --comment "3x-awg-fwd" -j ACCEPT
            iptables -t nat -A POSTROUTING -p tcp -d $ip --dport $port -m comment --comment "3x-awg-fwd" -j MASQUERADE
        }
        [[ "$proto" == "both" || "$proto" == "udp" ]] && {
            iptables -t nat -A PREROUTING -i $PUB_INT -p udp --dport $ext -m comment --comment "3x-awg-fwd" -j DNAT --to-destination $ip:$port
            iptables -t filter -A FORWARD -i $PUB_INT -p udp -d $ip --dport $port -m comment --comment "3x-awg-fwd" -j ACCEPT
            iptables -t nat -A POSTROUTING -p udp -d $ip --dport $port -m comment --comment "3x-awg-fwd" -j MASQUERADE
        }
    done < "$TEMP_RULES"
    
    cat "$TEMP_RULES" >> "$STATE_FILE"
    rm -f "$TEMP_RULES"
    command -v netfilter-persistent >/dev/null && netfilter-persistent save
    echo "Done. Rules saved to $STATE_FILE"
fi
