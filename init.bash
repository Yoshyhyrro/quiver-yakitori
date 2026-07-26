#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] Initializing C23 + Chicken Scheme + PyTorch Project Environment..."

# Create directory hierarchy
mkdir -p src/c src/scheme python tests build

# Check required commands
for cmd in cmake chicken-config csc python3; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "[WARNING] Command '$cmd' not found in PATH. Please install it."
    fi
done

echo "[INFO] Make executable permissions..."
chmod +x init.bash

echo "[INFO] Initialization completed successfully."