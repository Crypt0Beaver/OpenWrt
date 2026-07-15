#!/bin/bash
set -e
CONFIG="${1:-rm1800-wifi}"
OPENWRT="${OPENWRT:-$HOME/openwrt}"
HERE="$(cd "$(dirname "$0")" && pwd)"   # repo root, where this script + scripts/ live

cd "$OPENWRT"
CONFIG_FILE="$HERE/configs/${CONFIG}.config" "$HERE/scripts/mutate.sh" "$CONFIG"
make -j$(nproc) || make -j1 V=s
