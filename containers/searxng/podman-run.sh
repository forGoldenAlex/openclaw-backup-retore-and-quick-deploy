#!/bin/bash
set -euo pipefail
# podman-run.sh — SearXNG 容器启动脚本
#
# 用法: ./podman-run.sh [start|stop|status]
# 默认: start

ACTION="${1:-start}"

case "$ACTION" in
    start)
        if podman container inspect searxng &>/dev/null; then
            echo "searxng 容器已存在，启动中..."
            podman start searxng
        else
            echo "创建并启动 searxng 容器..."
            podman run -d --name searxng \
                -p 8080:8080 \
                -v searxng-data:/etc/searxng:z \
                -e SEARXNG_BASE_URL=http://localhost:8080/ \
                -e SEARXNG_SECRET_KEY=$(openssl rand -hex 32) \
                docker.io/searxng/searxng:latest
        fi
        echo "✓ searxng 运行在 http://localhost:8080"
        ;;
    stop)
        podman stop searxng 2>/dev/null || true
        echo "✓ searxng 已停止"
        ;;
    status)
        if podman container inspect searxng &>/dev/null; then
            podman inspect searxng --format '{{.State.Status}}'
        else
            echo "not found"
        fi
        ;;
    *)
        echo "用法: $0 [start|stop|status]"
        exit 1
        ;;
esac
