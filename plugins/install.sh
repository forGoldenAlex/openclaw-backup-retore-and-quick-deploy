#!/bin/bash
set -euo pipefail
# install.sh — 安装第三方 OpenClaw 插件
#
# 安装顺序：
#   1. openclaw-weixin（微信渠道，需 Gateway 在线后扫码认证）
#   2. openclaw-lark（飞书渠道，需 Gateway 在线后扫码认证）
#
# 注意: lossless-claw 已在 restore.sh Step 5 安装，此处不重复

echo "=== 安装第三方 OpenClaw 插件 ==="
echo ""

# 检查 openclaw 命令
if ! command -v openclaw &> /dev/null; then
    echo "⚠️  openclaw 命令不存在，请先安装 OpenClaw"
    echo "   参考: https://docs.openclaw.ai"
    exit 1
fi

# 1. OpenClaw WeChat
echo "[1/2] openclaw-weixin（微信渠道）..."
echo "  ⚠️  安装后需要扫二维码认证"
npx -y @tencent-weixin/openclaw-weixin-cli@latest install
echo "  ✓ 安装完成"

# 2. OpenClaw Lark
echo "[2/2] openclaw-lark（飞书渠道）..."
echo "  ⚠️  安装后需要扫二维码认证"
npx -y @larksuite/openclaw-lark install
echo "  ✓ 安装完成"

echo ""
echo "=== 插件安装完成 ==="
echo ""
echo "⚠️  后续操作："
echo "  1. Lark: 扫码认证"
echo "  2. WeChat: 扫码认证"
echo "  3. 重启 Gateway: openclaw gateway restart"
echo ""
openclaw plugins list 2>/dev/null || true
