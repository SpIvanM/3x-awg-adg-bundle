#!/bin/bash
# iperf3-server.sh - Install and configure iperf3 server with random port
[ "$EUID" -ne 0 ] && echo "Run as root" && exit 1

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
RESET="\e[0m"

log() { echo -e "${GREEN}[INFO] $1${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
err() { echo -e "${RED}[ERROR] $1${RESET}"; exit 1; }

IPERF3_PORT_STATE="/root/.iperf3-port"
SYSTEMD_UNIT="iperf3-server"
UNIT_FILE="/etc/systemd/system/${SYSTEMD_UNIT}.service"

find_free_port() {
    local port
    local attempts=0
    while [ $attempts -lt 100 ]; do
        port=$(shuf -i 10000-65000 -n 1)
        if ! ss -tlnu | grep -q ":${port} "; then
            echo "$port"
            return
        fi
        attempts=$((attempts + 1))
    done
    err "Could not find a free port after 100 attempts."
}

if command -v iperf3 >/dev/null 2>&1; then
    log "iperf3 is already installed."
else
    log "Installing iperf3..."
    apt-get update -qq && apt-get install -y -qq iperf3 || err "Failed to install iperf3."
    log "iperf3 installed."
fi

if [ -f "$IPERF3_PORT_STATE" ] && systemctl -q is-active "$SYSTEMD_UNIT" 2>/dev/null; then
    EXISTING_PORT=$(cat "$IPERF3_PORT_STATE")
    warn "iperf3-server is already running on port ${EXISTING_PORT}."
    echo ""
    echo "  iperf3 server: $(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1):${EXISTING_PORT}"
    echo ""
    log "To change the port, stop the service first: systemctl stop ${SYSTEMD_UNIT}"
    exit 0
fi

PORT=$(find_free_port)
log "Selected port: ${PORT}"

cat <<EOF > "$UNIT_FILE"
[Unit]
Description=iperf3 server
After=network.target

[Service]
ExecStart=/usr/bin/iperf3 --server --port ${PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "$PORT" > "$IPERF3_PORT_STATE"

systemctl daemon-reload
systemctl enable "$SYSTEMD_UNIT" >/dev/null 2>&1
systemctl restart "$SYSTEMD_UNIT" || err "Failed to start ${SYSTEMD_UNIT}."

if systemctl -q is-active "$SYSTEMD_UNIT"; then
    log "iperf3-server service is active."
else
    err "iperf3-server service failed to start."
fi

log "Opening port ${PORT}/tcp in UFW..."
ufw allow "${PORT}/tcp" >/dev/null 2>&1 || warn "UFW rule may not have been added."

PUBLIC_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)

echo ""
echo -e "${GREEN}========================================${RESET}"
echo -e "${GREEN}  iperf3 server is ready${RESET}"
echo -e "${GREEN}========================================${RESET}"
echo ""
echo "  Connect from client:"
echo "    iperf3 -c ${PUBLIC_IP} -p ${PORT}"
echo ""
echo "  Service:  systemctl status ${SYSTEMD_UNIT}"
echo "  Port file: ${IPERF3_PORT_STATE}"
echo ""
