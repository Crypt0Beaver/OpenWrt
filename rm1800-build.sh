#!/bin/bash
set -e
cd "$(dirname "$0")"
CONFIG="${1:-rm1800-wifi}"
~/rm1800-build/scripts/mutate.sh "$CONFIG"   # the ONE shared script, from the symlinked repo clone
make -j$(nproc) || make -j1 V=s