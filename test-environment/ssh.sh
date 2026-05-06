#!/bin/bash
# Description: SSH connection wrapper using .env/ configurations
# Usage: ./tools/ssh.sh <server-name>

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
        echo "  (No test-environment/.env directory found. Run ./tools/init_server.sh to create one)"
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

# Password reminder
if [ -f "$SERVER_DIR/password" ]; then
    echo "------------------------------------------------"
    echo "PASSWORD: $(cat "$SERVER_DIR/password")"
    echo "------------------------------------------------"
fi

echo "Connecting to $SERVER_NAME ($USER@$IP:$PORT)..."
ssh $SSH_OPTS "$USER@$IP"
