#!/bin/bash
# fwd.sh - Minimalist port forwarding manager for 3x-awg-adg-bundle
[ "$EUID" -ne 0 ] && echo "Run as root" && exit 1

STATE_FILE="/root/.vpn-forwarding-rules"
PUB_INT=$(ip route | grep default | awk '{print $5}' | head -1)
RULES=""

# Load existing rules
[ -f "$STATE_FILE" ] && RULES=$(cat "$STATE_FILE")

# 1. Show current forwardings
echo -e "\n--- Current Forwardings ---"
if [ -z "$RULES" ]; then echo "(none)"; else
    while IFS='|' read -r ip port proto ext id; do
        [ -n "$ip" ] && echo "$proto: $ip:$port -> $ext"
    done <<< "$RULES"
fi

# 2. Ask: Delete old redirects?
read -p "Delete old redirects? (y/N): " ans
if [[ "$ans" =~ ^[yYдД] ]]; then
    # Cleanup iptables by comment
    for t in nat filter; do
        iptables-save -t $t | grep "3x-awg-fwd" | sed 's/-A/-D/' | while read -r r; do
            [ -n "$r" ] && iptables -t $t $r
        done
    done
    RULES=""
    echo "Old rules cleared."
fi

# 3 & 4. Configure new server / port
while read -p "Configure new server? (Y/n): " ans && [[ ! "$ans" =~ ^[nNнН] ]]; do
    read -p " Target IP: " tip
    [ -z "$tip" ] && continue
    while read -p " Configure new port? (Y/n): " ans && [[ ! "$ans" =~ ^[nNнН] ]]; do
        read -p "  Target Port: " tport
        read -p "  Protocol (tcp/udp/both) [both]: " proto
        proto=${proto:-both}
        
        # Simple port availability / selection (use tport if free, else random)
        ext=$tport
        if ss -tlnu | grep -q ":$ext "; then
            ext=$(shuf -i 10000-65000 -n 1)
            echo "  Port $tport busy, using random $ext"
        fi
        
        id="${tip}-${tport}-${proto}-${ext}"
        line="${tip}|${tport}|${proto}|${ext}|${id}"
        RULES="${RULES}${RULES:+$'\n'}$line"
    done
done

# 5. Apply and Save
if [ -n "$RULES" ]; then
    echo "Applying rules..."
    iptables -t filter -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -t filter -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    
    while IFS='|' read -r ip port proto ext id; do
        [ -z "$ip" ] && continue
        protos="tcp udp"; [ "$proto" != "both" ] && protos="$proto"
        for p in $protos; do
            iptables -t nat -A PREROUTING -i $PUB_INT -p $p --dport $ext -m comment --comment "3x-awg-fwd" -j DNAT --to-destination $ip:$port
            iptables -t filter -A FORWARD -i $PUB_INT -p $p -d $ip --dport $port -m comment --comment "3x-awg-fwd" -j ACCEPT
            iptables -t nat -A POSTROUTING -p $p -d $ip --dport $port -m comment --comment "3x-awg-fwd" -j MASQUERADE
        done
    done <<< "$RULES"
    
    echo "$RULES" > "$STATE_FILE"
    # Persist if possible
    command -v netfilter-persistent >/dev/null && netfilter-persistent save
    echo "Done. Rules saved to $STATE_FILE"
fi
