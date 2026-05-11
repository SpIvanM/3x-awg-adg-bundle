#!/bin/bash
# Description: Initialize a new server configuration in .env/
# Usage: ./test-environment/init_server.sh <server-name> [ip] [port] [user]

SERVER_NAME=$1
IP=$2
PORT=${3:-22}
USER=${4:-root}

if [ -z "$SERVER_NAME" ]; then
    echo "Usage: $0 <server-name> [ip] [port] [user]"
    exit 1
fi

SERVER_DIR="test-environment/.env/$SERVER_NAME"

mkdir -p "$SERVER_DIR"

if [ -n "$IP" ]; then echo "$IP" > "$SERVER_DIR/ip"; fi
if [ ! -f "$SERVER_DIR/ip" ]; then touch "$SERVER_DIR/ip"; fi

echo "$PORT" > "$SERVER_DIR/port"
echo "$USER" > "$SERVER_DIR/user"

if [ ! -f "$SERVER_DIR/key" ]; then touch "$SERVER_DIR/key"; fi
if [ ! -f "$SERVER_DIR/password" ]; then touch "$SERVER_DIR/password"; fi

echo "Success: Configuration for '$SERVER_NAME' initialized in $SERVER_DIR"
echo "Please edit the files in $SERVER_DIR to set the actual values."
