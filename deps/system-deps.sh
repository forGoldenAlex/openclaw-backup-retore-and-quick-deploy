#!/bin/bash
set -euo pipefail
echo "安装系统依赖..."
sudo apt-get update
sudo apt-get install -y \
    jq rsync zip unzip \
    python3-pip python3-full \
    podman

echo "安装 Playwright..."
pip3 install --break-system-packages playwright
export PATH="$HOME/.local/bin:$PATH"
playwright install chromium
