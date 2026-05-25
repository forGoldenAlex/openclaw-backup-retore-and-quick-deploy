#!/bin/bash
set -euo pipefail
#
# backup.sh — OpenClaw 备份脚本 v6
# 原则：只备份用户增量，不备份系统自带内容
#
# 用法: ./backup.sh [--with-memory]
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENCLAW_HOME="$HOME/.openclaw"
BACKUP="$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo ""
log_info "=========================================="
log_info "OpenClaw 备份 v6 — 用户增量 + Memory"
log_info "=========================================="
echo ""

# 依赖检查
for cmd in python3 zip sha256sum; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "缺少依赖: $cmd"
        exit 1
    fi
done
if ! command -v jq &>/dev/null; then
    log_warn "jq 未安装（恢复时需要，备份时可跳过）"
fi

### 1. 提取用户增量 (openclaw.json.delta) ###
log_info "[1/9] 提取用户增量..."
python3 "$SCRIPT_DIR/scripts/extract-delta.py"

### 2. 备份 credentials ###
log_info "[2/9] 备份 credentials..."
CRED_BACKUP="$BACKUP/credentials"
mkdir -p "$CRED_BACKUP"
rm -f "$CRED_BACKUP"/*.json
cred_count=0
if [ -d "$OPENCLAW_HOME/credentials" ]; then
    for f in "$OPENCLAW_HOME/credentials"/*.json; do
        [ -f "$f" ] || continue
        cp "$f" "$CRED_BACKUP/"
        cred_count=$((cred_count + 1))
    done
    chmod -f 600 "$CRED_BACKUP"/*.json 2>/dev/null || true
fi
echo "  → ${cred_count} 个 credential 文件"

### 3. 打包自定义 Skill ###
log_info "[3/9] 打包自定义 Skill..."
bash "$SCRIPT_DIR/scripts/pack-skills.sh"

### 4. 漂白 workspace MD 文件 ###
log_info "[4/9] 漂白 workspace 文件..."
python3 "$SCRIPT_DIR/scripts/sanitize-md.py"

### 5. 导出依赖 ###
log_info "[5/9] 导出依赖..."
bash "$SCRIPT_DIR/scripts/export-deps.sh"

### 6. 备份容器配置 ###
log_info "[6/9] 备份容器配置..."
CONTAINER_BACKUP="$BACKUP/containers/searxng"
mkdir -p "$CONTAINER_BACKUP"
if podman container inspect searxng &>/dev/null; then
    # 备份用户自定义 settings.yml（如果存在于 volume 中）
    podman exec searxng cat /etc/searxng/settings.yml > "$CONTAINER_BACKUP/settings.yml" 2>/dev/null || true
    echo "  ✓ searxng 容器配置已备份"
else
    echo "  ⚠ searxng 容器未运行，跳过"
fi
# podman-run.sh 已在版本控制中

### 7. 导出 searxng 镜像 ###
log_info "[7/9] 导出 searxng 镜像..."
CONTAINER_BACKUP="$BACKUP/containers/searxng"
mkdir -p "$CONTAINER_BACKUP"
if podman image exists docker.io/searxng/searxng:latest 2>/dev/null; then
    rm -f "$CONTAINER_BACKUP/searxng.tar"
    podman save -o "$CONTAINER_BACKUP/searxng.tar" docker.io/searxng/searxng:latest
    echo "  ✓ searxng 镜像已导出"
else
    echo "  ⚠ searxng 镜像不存在，跳过"
fi

### 8. 备份 memory 系统 ###
log_info "[8/9] 备份 memory 系统..."
MEMORY_BACKUP="$BACKUP/memory"
mkdir -p "$MEMORY_BACKUP"

# 8a. workspace/memory/*.md 已在 Step 4 由 sanitize-md.py 处理

# 8b. SQLite 数据库（仅 lcm.db — main.sqlite 可从 memory/*.md 重建）
sqlite_count=0
if [ -f "$OPENCLAW_HOME/lcm.db" ]; then
    cp "$OPENCLAW_HOME/lcm.db" "$MEMORY_BACKUP/"
    sqlite_count=$((sqlite_count + 1))
    echo "  ✓ lcm.db"
fi
echo "  → ${sqlite_count} 个 SQLite 数据库"

# 8c. lcm-files 目录（Lossless Context Memory 文件缓存）
if [ -d "$OPENCLAW_HOME/lcm-files" ]; then
    cp -r "$OPENCLAW_HOME/lcm-files" "$MEMORY_BACKUP/"
    echo "  ✓ lcm-files/ ($(du -sh "$OPENCLAW_HOME/lcm-files" | cut -f1))"
fi

### 9. 打包 + 校验 ###
log_info "[9/9] 打包与校验..."

# 9a. 校验关键文件
if python3 -c "import json; json.load(open('$BACKUP/config/openclaw.json.delta'))" 2>/dev/null; then
    echo "  ✓ delta JSON 有效"
else
    log_error "  delta JSON 无效！"
fi
cred_count=$(ls "$BACKUP/credentials"/*.json 2>/dev/null | wc -l)
echo "  ✓ credentials: ${cred_count} 个"
skill_count=$(ls "$BACKUP/skills"/*.skill 2>/dev/null | wc -l)
echo "  ✓ skills: ${skill_count} 个"

# 9b. 打包
ARCHIVE="$SCRIPT_DIR/../openclaw-backup.tar.gz"
tar -czf "$ARCHIVE" -C "$SCRIPT_DIR/.." openclaw-backup
ARCHIVE_SIZE=$(du -sh "$ARCHIVE" | cut -f1)
echo "  ✓ 打包完成: openclaw-backup.tar.gz (${ARCHIVE_SIZE})"

# 9c. SHA256 校验
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"
echo "  ✓ SHA256: $(cat $ARCHIVE.sha256)"

echo ""
log_info "=========================================="
log_info "备份完成！"
log_info "=========================================="
echo ""
echo "  目录: $BACKUP"
echo "  打包: $ARCHIVE (${ARCHIVE_SIZE})"
echo ""
du -sh "$BACKUP/config" "$BACKUP/credentials" "$BACKUP/skills" "$BACKUP/workspace" "$BACKUP/deps" "$BACKUP/containers" "$BACKUP/memory" 2>/dev/null || true
echo ""
log_info "下一步:"
echo "  scp $ARCHIVE user@新机器:~/"
echo "  在新机器上: tar -xzf openclaw-backup.tar.gz && cd openclaw-backup && ./restore.sh"
