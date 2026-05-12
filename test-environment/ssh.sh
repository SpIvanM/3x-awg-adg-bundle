#!/bin/bash
# Description: SSH connection wrapper using .env/ configurations
# Usage: ./test-environment/ssh.sh <server-name>

# Handle askpass requests
if [ "$1" == "--askpass" ]; then
    echo "$SSHPASS_TEMP"
    exit 0
fi

SERVER_NAME=$1

# Change to project root if script is run from tools/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

if [ -z "$SERVER_NAME" ]; then
    echo "Usage: $0 <server-name>"
    echo "Available servers:"
    if [ -d "test-environment/.env" ]; then
        SERVERS=$(ls -d test-environment/.env/*/ 2>/dev/null)
        if [ -n "$SERVERS" ]; then
            echo "$SERVERS" | xargs -n 1 basename
        else
            echo "  (No server subdirectories found in test-environment/.env/)"
        fi
    else
        echo "  (No test-environment/.env directory found. Run ./test-environment/init_server.sh to create one)"
    fi
    exit 1
fi

SERVER_DIR="test-environment/.env/$SERVER_NAME"

if [ ! -d "$SERVER_DIR" ]; then
    echo "Error: Server configuration for '$SERVER_NAME' not found in $SERVER_DIR"
    exit 1
fi

# Read config files (stripping whitespace and line endings)
IP=$(cat "$SERVER_DIR/ip" 2>/dev/null | tr -d '\r\n ')
PORT=$(cat "$SERVER_DIR/port" 2>/dev/null | tr -d '\r\n ')
USER=$(cat "$SERVER_DIR/user" 2>/dev/null | tr -d '\r\n ')
KEY_PATH=$(cat "$SERVER_DIR/key" 2>/dev/null | tr -d '\r\n ')

# Defaults
PORT=${PORT:-22}
USER=${USER:-root}

if [ -z "$IP" ]; then
    echo "Error: IP address not found in $SERVER_DIR/ip"
    exit 1
fi

SSH_OPTS="-p $PORT"

# Key logic
if [ -n "$KEY_PATH" ]; then
    if [ -f "$KEY_PATH" ]; then
        SSH_OPTS="$SSH_OPTS -i $KEY_PATH"
    elif [ -f "$SERVER_DIR/$KEY_PATH" ]; then
        SSH_OPTS="$SSH_OPTS -i $SERVER_DIR/$KEY_PATH"
    else
        # If it's not a file path, maybe it's the key itself? 
        # (Not recommended but we can handle it if we want to save to a temp file)
        # For now, just warn.
        echo "Warning: Key file '$KEY_PATH' not found."
    fi
fi

# Function to install sshpass
install_sshpass() {
    echo "sshpass is not installed. Attempting to install..."
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update && sudo apt-get install -y sshpass
    elif command -v brew >/dev/null 2>&1; then
        brew install esolitos/ipa/sshpass
    elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        if command -v choco >/dev/null 2>&1; then
            choco install -y sshpass
        elif command -v scoop >/dev/null 2>&1; then
            scoop install sshpass
        fi
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y sshpass
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y sshpass
    fi
}

# Password reminder and sshpass logic
SSH_CMD="ssh"
if [ -f "$SERVER_DIR/password" ]; then
    PASSWORD=$(cat "$SERVER_DIR/password" | tr -d '\r\n')
    if [ -n "$PASSWORD" ]; then
        if command -v sshpass >/dev/null 2>&1; then
            export SSHPASS="$PASSWORD"
            SSH_CMD="sshpass -e ssh"
            echo "Using sshpass for automatic login..."
        else
            # Zero-dependency fallback using SSH_ASKPASS
            export SSHPASS_TEMP="$PASSWORD"
            export SSH_ASKPASS="$(realpath "$0")"
            export SSH_ASKPASS_REQUIRE=force
            # We need to use a fake DISPLAY on Linux/WSL to trigger ASKPASS
            if [ -z "$DISPLAY" ]; then export DISPLAY=":0"; fi
            
            echo "Using SSH_ASKPASS for automatic login (no sshpass needed)..."
        fi
    fi
fi

echo "Connecting to $SERVER_NAME ($USER@$IP:$PORT)..."
$SSH_CMD $SSH_OPTS "$USER@$IP"
