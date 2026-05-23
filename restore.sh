#!/bin/bash
set -euo pipefail
#
# restore.sh — OpenClaw 恢复脚本 v7
# 14 步流程：准备 → 依赖 → 配置 → 插件 → 合并 → 数据 → Gateway → 容器 → Memory → 验证
# v7: 插件在合并 delta 前安装（避免 stale），channels 字段 v5.7 兼容
#
# 用法: ./restore.sh [备份目录]
#       默认备份目录为脚本所在目录
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP="${1:-$SCRIPT_DIR}"
OPENCLAW_HOME="$HOME/.openclaw"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

TOTAL_STEPS=14

echo ""
log_info "=========================================="
log_info "OpenClaw 恢复 v7 — 14 步流程"
log_info "=========================================="
echo ""

# 检查备份目录
if [ ! -d "$BACKUP" ]; then
    log_error "备份目录不存在: $BACKUP"
    exit 1
fi

DELTA_FILE="$BACKUP/config/openclaw.json.delta"
if [ ! -f "$DELTA_FILE" ]; then
    log_error "用户增量文件不存在: $DELTA_FILE"
    log_error "请先在原机器上运行 ./backup.sh"
    exit 1
fi

### Phase 1: 准备 ###

### Step 1: 检测 + 安装/重置 ###
log_step "1/${TOTAL_STEPS} 检测 OpenClaw..."
if command -v openclaw &>/dev/null; then
    echo "  ✓ openclaw 已安装: $(openclaw --version 2>/dev/null || echo 'unknown')"
    read -p "  是否恢复出厂设置（完全重置，包括 credentials）? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "  执行 openclaw reset --scope full --yes..."
        # 如果配置已损坏，reset 会失败，先删除配置文件
        if ! openclaw reset --scope full --yes 2>/dev/null; then
            log_warn "  reset 失败（配置可能已损坏）"
            read -p "  是否强制删除 ~/.openclaw 目录? [y/N] " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                rm -rf "$OPENCLAW_HOME"
                echo "  ✓ 已删除 ~/.openclaw 目录"
            else
                echo "  跳过，保留现有目录"
            fi
        else
            echo "  ✓ 恢复出厂完成"
        fi
    fi
else
    echo "  openclaw 未安装，开始全新安装..."
    
    # 确保 Node 24+ 可用
    if ! command -v npm &>/dev/null || ! command -v node &>/dev/null; then
        echo "  安装 Node 24（推荐版本）..."
        command -v curl &>/dev/null || sudo apt-get install -y -qq curl
        curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
        sudo apt-get install -y nodejs
        echo "  ✓ Node $(node -v) / npm $(npm -v)"
    fi

    # 配置 npm 全局目录（非 root 安装）
    NPM_GLOBAL="$HOME/.npm-global"
    mkdir -p "$NPM_GLOBAL"
    npm config set prefix "$NPM_GLOBAL" 2>/dev/null || true

    # 检查 PATH
    if [[ ":$PATH:" != *":$NPM_GLOBAL/bin:"* ]]; then
        echo "  将 $NPM_GLOBAL/bin 添加到 PATH..."
        export PATH="$NPM_GLOBAL/bin:$PATH"
        SHELL_RC="$HOME/.bashrc"
        if [ -f "$HOME/.zshrc" ] && [ -n "${ZSH_VERSION:-}" ]; then
            SHELL_RC="$HOME/.zshrc"
        fi
        if ! grep -q '.npm-global/bin' "$SHELL_RC" 2>/dev/null; then
            echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$SHELL_RC"
        fi
    fi

    # 询问是否使用大陆镜像
    read -p "  是否使用大陆 npm 镜像（淘宝源）? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        npm config set registry https://registry.npmmirror.com
        echo "  ✓ npm 已切换到淘宝镜像"
    fi

    echo "  安装 openclaw..."
    read -p "  是否指定版本? (默认最新) [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        read -p "  输入版本号 (如 2026.5.7): " OC_VERSION
        npm install -g "openclaw@${OC_VERSION}"
    else
        npm install -g openclaw
    fi

    if command -v openclaw &>/dev/null; then
        echo "  ✓ openclaw 安装成功: $(openclaw --version 2>/dev/null)"
    else
        log_error "  openclaw 安装失败"
        log_error "  手动安装命令："
        echo "    mkdir -p ~/.npm-global"
        echo "    npm config set prefix ~/.npm-global"
        echo "    export PATH=~/.npm-global/bin:\$PATH"
        echo "    npm install -g openclaw"
        exit 1
    fi
fi

### Step 2: 初始化 OpenClaw（使用 onboard 生成完整配置）###
log_step "2/${TOTAL_STEPS} 初始化 OpenClaw..."
if [ ! -f "$OPENCLAW_HOME/openclaw.json" ]; then
    echo "  运行 openclaw onboard（生成完整配置，包括 models 数组）..."
    openclaw onboard --non-interactive \
        --auth-choice skip \
        --mode local \
        --accept-risk \
        --skip-health 2>/dev/null || {
        log_warn "  onboard 失败，尝试 setup..."
        openclaw setup --non-interactive --mode local 2>/dev/null || true
    }
    echo "  ✓ 初始化完成"
else
    echo "  ✓ openclaw.json 已存在，跳过初始化"
fi

### Phase 2: 依赖 ###

### Step 3: 统一依赖安装 ###
log_step "3/${TOTAL_STEPS} 安装依赖..."

# 3a. jq（合并 delta 必需）
if command -v jq &>/dev/null; then
    echo "  ✓ jq 已安装: $(jq --version 2>/dev/null || echo 'unknown')"
else
    echo "  安装 jq（需要 sudo）..."
    sudo -v
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq jq
    elif command -v yum &>/dev/null; then
        sudo yum install -y jq
    elif command -v brew &>/dev/null; then
        brew install jq
    else
        log_error "  无法自动安装 jq，请手动安装后重试"
        exit 1
    fi
    if command -v jq &>/dev/null; then
        echo "  ✓ jq 安装成功"
    else
        log_error "  jq 安装失败，请手动安装后重试"
        exit 1
    fi
fi

# 3b. 系统依赖（可选）
read -p "  是否安装系统依赖（需要 sudo）? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if [ -f "$BACKUP/deps/system-deps.sh" ]; then
        sudo -v && bash "$BACKUP/deps/system-deps.sh"
    else
        log_warn "  未找到 deps/system-deps.sh，跳过"
    fi
else
    echo "  跳过系统依赖"
fi

# 3c. pip 镜像（可选）— 先设置镜像再安装依赖
read -p "  是否设置 pip 清华镜像? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    pip3 config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple 2>/dev/null || true
    echo "  ✓ pip 已切换到清华镜像"
else
    echo "  跳过 pip 镜像"
fi

# 3d. pip 应用依赖（可选）
read -p "  是否安装 pip 应用依赖? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if [ -f "$BACKUP/deps/pip-requirements.txt" ]; then
        # Ubuntu 24.04+ PEP 668 需要 --break-system-packages
        pip3 install --break-system-packages -r "$BACKUP/deps/pip-requirements.txt"
        echo "  ✓ pip 依赖已安装"
    else
        log_warn "  未找到 deps/pip-requirements.txt，跳过"
    fi
else
    echo "  跳过 pip 依赖"
fi

# 3e. 国内容器镜像（可选）
read -p "  是否配置国内容器镜像（DaoCloud 代理）? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    MIRROR_CONF="$HOME/.config/containers/registries.conf"
    mkdir -p "$(dirname "$MIRROR_CONF")"
    cat > "$MIRROR_CONF" << 'EOF'
unqualified-search-registries = ["docker.io"]
[[registry]]
prefix = "docker.io"
location = "docker.io"
[[registry.mirror]]
location = "docker.m.daocloud.io"
EOF
    echo "  ✓ podman 阿里云镜像加速已配置"
else
    echo "  跳过容器镜像"
fi

### Phase 3: 配置 ###

### Step 4: credentials ###
log_step "4/${TOTAL_STEPS} 复制 credentials..."
read -p "  是否恢复 credentials（API Key）? [Y/n] " -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "  跳过"
else
mkdir -p "$OPENCLAW_HOME/credentials"
cred_count=0
if [ -d "$BACKUP/credentials" ]; then
    for f in "$BACKUP/credentials"/*.json; do
        [ -f "$f" ] || continue
        cp "$f" "$OPENCLAW_HOME/credentials/"
        cred_count=$((cred_count + 1))
    done
    chmod -f 600 "$OPENCLAW_HOME/credentials"/*.json 2>/dev/null || true
fi
echo "  → ${cred_count} 个 credential 文件已复制"
fi

### Phase 4: 插件 ###

### Step 5: 安装 Lossless-Claw（在合并 delta 前安装，避免被 doctor 当作 stale） ###
log_step "5/${TOTAL_STEPS} 安装 Lossless-Claw（contextEngine）..."
if command -v openclaw &>/dev/null; then
    if openclaw plugins list 2>/dev/null | grep -q "lossless-claw"; then
        echo "  ✓ 已安装"
    else
        openclaw plugins install @martian-engineering/lossless-claw
        echo "  ✓ 安装完成"
    fi
else
    echo "  ⚠ openclaw 不可用，稍后手动安装"
fi

# lossless-claw 安装完成后补回 plugins.allow + slots
openclaw config set plugins.allow '["lossless-claw"]' --strict-json --merge 2>/dev/null || true
openclaw config set plugins.slots.contextEngine '"lossless-claw"' --strict-json 2>/dev/null || true

### Phase 5: 合并 ###

### Step 6: 合并 delta ###
log_step "6/${TOTAL_STEPS} 合并用户增量..."
SYSTEM_CONFIG="$OPENCLAW_HOME/openclaw.json"

if [ -f "$SYSTEM_CONFIG" ]; then
    # 先替换 delta 中的占位符为当前机器实际值
    DELTA_RESOLVED=$(mktemp)
    cp "$DELTA_FILE" "$DELTA_RESOLVED"
    sed -i "s#<HOME_DIR>#$HOME#g" "$DELTA_RESOLVED"
    sed -i "s|<HOSTNAME>|$(hostname)|g" "$DELTA_RESOLVED"

    # 简单合并 + 移除 legacy keys
    jq -s '.[0] * .[1] | del(.agents.defaults.llm)' \
        "$SYSTEM_CONFIG" "$DELTA_RESOLVED" > "${SYSTEM_CONFIG}.merged"

    rm -f "$DELTA_RESOLVED"

    # 安全检查
    if jq empty "${SYSTEM_CONFIG}.merged" 2>/dev/null; then
        cp "$SYSTEM_CONFIG" "${SYSTEM_CONFIG}.bk.pre-restore"
        mv "${SYSTEM_CONFIG}.merged" "$SYSTEM_CONFIG"
        echo "  ✓ 用户增量已合并（旧配置备份为 .bk.pre-restore）"
        
        # 运行 doctor --fix 修复兼容性问题
        echo "  运行 doctor --fix..."
        openclaw doctor --fix 2>/dev/null || echo "  ⚠ doctor --fix 未完全修复，请检查日志"
    else
        rm -f "${SYSTEM_CONFIG}.merged"
        log_error "  合并结果无效 JSON，跳过。请手动合并。"
    fi
else
    # 新机器还没有系统配置，直接用 delta（但需要补充 models）
    cp "$DELTA_FILE" "$SYSTEM_CONFIG"
    sed -i "s#<HOME_DIR>#$HOME#g" "$SYSTEM_CONFIG"
    sed -i "s|<HOSTNAME>|$(hostname)|g" "$SYSTEM_CONFIG"
    echo "  ✓ 首次配置，用户增量已直接写入"
    echo "  ⚠ 需要运行 openclaw setup 补充 models 配置"
fi

### Phase 6: 数据 ###

### Step 7: Skills ###
log_step "7/${TOTAL_STEPS} 恢复自定义 Skill..."
read -p "  是否恢复 Skill? [Y/n] " -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "  跳过"
else
SKILLS_TARGET="$OPENCLAW_HOME/workspace/skills"
mkdir -p "$SKILLS_TARGET"
skill_count=0
if [ -d "$BACKUP/skills" ]; then
    # 先校验
    if [ -f "$BACKUP/skills/checksums.sha256" ]; then
        echo "  校验 SHA256..."
        (cd "$BACKUP/skills" && sha256sum -c checksums.sha256 2>/dev/null) || log_warn "  部分校验失败"
    fi

    for skill_file in "$BACKUP/skills"/*.skill; do
        [ -f "$skill_file" ] || continue
        name=$(basename "$skill_file" .skill)
        target="$SKILLS_TARGET/$name"
        mkdir -p "$target"
        unzip -o -q "$skill_file" -d "$target"
        skill_count=$((skill_count + 1))
    done
fi
echo "  → ${skill_count} 个 Skill 已恢复"

# minimax-office npm 依赖
MINIMAX_NPM="$SKILLS_TARGET/minimax-office"
if [ -d "$MINIMAX_NPM" ] && [ -f "$MINIMAX_NPM/package.json" ]; then
    echo "  安装 minimax-office npm 依赖..."
    (cd "$MINIMAX_NPM" && npm install --production 2>/dev/null) || log_warn "  npm install 失败"
fi
fi

### Step 8: workspace 文件 ###
log_step "8/${TOTAL_STEPS} 恢复 workspace 文件..."
read -p "  是否恢复 workspace 文件? [Y/n] " -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "  跳过"
else
WS_TARGET="$OPENCLAW_HOME/workspace"
mkdir -p "$WS_TARGET"
if [ -d "$BACKUP/workspace" ]; then
    cp -r "$BACKUP/workspace/"* "$WS_TARGET/" 2>/dev/null || true
    echo "  ✓ workspace 文件已恢复"

    # 替换占位符为当前机器实际值
    echo "  替换占位符..."
    find "$WS_TARGET" -name "*.md" -type f | while read -r f; do
        sed -i "s|<HOSTNAME>|$(hostname)|g" "$f"
        sed -i "s|\b<USER_NAME>\b|$(whoami)|g" "$f"
        sed -i "s#<HOME_DIR>#$HOME#g" "$f"
        sed -i "s#<OPENCLAW_WORKSPACE>#$HOME/.openclaw/workspace#g" "$f"
    done
    # scripts/ 中的文件也替换
    if [ -d "$WS_TARGET/scripts" ]; then
        find "$WS_TARGET/scripts" -type f | while read -r f; do
            sed -i "s|<HOSTNAME>|$(hostname)|g" "$f" 2>/dev/null || true
            sed -i "s#<HOME_DIR>#$HOME#g" "$f" 2>/dev/null || true
            sed -i "s#<OPENCLAW_WORKSPACE>#$HOME/.openclaw/workspace#g" "$f" 2>/dev/null || true
        done
    fi
    echo "  ✓ 占位符已替换"
fi
fi

### Phase 7: Gateway ###

### Step 9: 启动 Gateway + 开机自启 ###
log_step "9/${TOTAL_STEPS} 启动 Gateway..."
if command -v openclaw &>/dev/null; then
    # headless 服务器需要 XDG_RUNTIME_DIR
    if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
        export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    fi

    # 启用 memory-wiki（默认禁用）
    if ! openclaw plugins list 2>/dev/null | grep -q "memory-wiki"; then
        openclaw plugins enable memory-wiki 2>/dev/null || true
    fi

    echo "  安装 Gateway systemd 服务..."
    openclaw gateway install

    # 启用开机自启（linger）
    loginctl enable-linger 2>/dev/null || sudo loginctl enable-linger "$USER"

    # 启动并启用
    systemctl --user enable --now openclaw-gateway.service

    # 等待就绪
    for i in $(seq 1 30); do
        if openclaw gateway status 2>/dev/null | grep -q "running"; then
            echo "  ✓ Gateway 已就绪（开机自启已启用）"
            break
        fi
        sleep 1
    done

    # 生成 auth token
    read -p "  是否生成新的 Gateway auth token? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        TOKEN=$(openclaw gateway auth generate 2>/dev/null || echo "")
        if [ -n "$TOKEN" ]; then
            jq --arg t "$TOKEN" '.gateway.auth.token = $t' \
                "$OPENCLAW_HOME/openclaw.json" > "${OPENCLAW_HOME}/openclaw.json.tmp"
            mv "${OPENCLAW_HOME}/openclaw.json.tmp" "$OPENCLAW_HOME/openclaw.json"
            echo "  ✓ Gateway auth token 已更新"
        else
            log_warn "  Token 生成失败，请手动运行: openclaw gateway auth generate"
        fi
    fi
else
    echo "  ⚠ openclaw 不可用，跳过"
fi

### Step 10: Lark/WeChat ###
log_step "10/${TOTAL_STEPS} 安装 Lark/WeChat（需 Gateway 在线）..."
read -p "  是否安装第三方通讯插件? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if [ -f "$BACKUP/plugins/install.sh" ]; then
        bash "$BACKUP/plugins/install.sh"
    else
        echo "  手动安装命令:"
        echo "    npx -y @larksuite/openclaw-lark install"
        echo "    npx -y @tencent-weixin/openclaw-weixin-cli@latest install"
    fi

    # 恢复飞书 footer（可选）
    FOOTER_FILE="$BACKUP/config/feishu-footer.json"
    if [ -f "$FOOTER_FILE" ]; then
        read -p "  是否恢复飞书 footer 配置? [Y/n] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            jq --argjson footer "$(cat "$FOOTER_FILE")" \
                '.channels.feishu.footer = $footer' \
                "$OPENCLAW_HOME/openclaw.json" > "${OPENCLAW_HOME}/openclaw.json.tmp"
            mv "${OPENCLAW_HOME}/openclaw.json.tmp" "$OPENCLAW_HOME/openclaw.json"
            echo "  ✓ footer 已恢复"
        fi
    fi

    # lark/weixin 安装完成后补回 plugins.allow
    openclaw config set plugins.allow '["openclaw-weixin","openclaw-lark"]' --strict-json --merge 2>/dev/null || true
else
    echo "  跳过。稍后可运行: bash $BACKUP/plugins/install.sh"
fi

### Phase 7: 容器 ###

### Step 11: searxng ###
log_step "11/${TOTAL_STEPS} 启动 searxng 容器..."
if [ -f "$BACKUP/containers/searxng/podman-run.sh" ]; then
    if command -v podman &>/dev/null; then
        # 优先加载本地导出的镜像
        if [ -f "$BACKUP/containers/searxng/searxng.tar" ]; then
            echo "  加载本地 searxng 镜像..."
            podman load -i "$BACKUP/containers/searxng/searxng.tar"
            echo "  ✓ 镜像已加载"
        fi
        read -p "  是否启动 searxng 容器? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            bash "$BACKUP/containers/searxng/podman-run.sh" start
        fi
    else
        echo "  ⚠ podman 未安装，跳过"
    fi
else
    echo "  未找到容器配置，跳过"
fi

### Step 12: 重启 Gateway ###
log_step "12/${TOTAL_STEPS} 重启 Gateway..."
if command -v openclaw &>/dev/null; then
    read -p "  是否重启 Gateway 以加载所有配置? [Y/n] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        openclaw gateway restart
        echo "  ✓ Gateway 已重启"
    fi
fi

### Step 13: 恢复 memory 数据 ###
log_step "13/${TOTAL_STEPS} 恢复 memory 数据..."
read -p "  是否恢复 memory 数据（SQLite + wiki）? [Y/n] " -n 1 -r
echo
if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "  跳过"
else
MEMORY_BACKUP="$BACKUP/memory"

# 13a. SQLite 数据库
sqlite_count=0
if [ -f "$MEMORY_BACKUP/main.sqlite" ]; then
    mkdir -p "$OPENCLAW_HOME/memory"
    cp "$MEMORY_BACKUP/main.sqlite" "$OPENCLAW_HOME/memory/"
    sqlite_count=$((sqlite_count + 1))
    echo "  ✓ main.sqlite 已恢复"
fi
if [ -f "$MEMORY_BACKUP/lcm.db" ]; then
    cp "$MEMORY_BACKUP/lcm.db" "$OPENCLAW_HOME/"
    sqlite_count=$((sqlite_count + 1))
    echo "  ✓ lcm.db 已恢复"
fi
echo "  → ${sqlite_count} 个 SQLite 数据库"

# 13b. wiki 目录
if [ -d "$MEMORY_BACKUP/wiki" ]; then
    cp -r "$MEMORY_BACKUP/wiki" "$OPENCLAW_HOME/"
    echo "  ✓ wiki/ 已恢复"
fi

# workspace/memory/*.md 已在 Step 8 由 sanitize-md.py 处理恢复
fi

### Step 14: 完整验证 ###
log_step "14/${TOTAL_STEPS} 完整验证..."

# 14a. 基础验证
echo "  基础验证..."
if openclaw --version &>/dev/null; then
    echo "  ✓ 命令可用: $(openclaw --version 2>/dev/null || echo 'ok')"
else
    log_warn "  ⚠ openclaw 命令不可用"
fi

if openclaw gateway status 2>/dev/null | grep -q "running"; then
    echo "  ✓ Gateway 运行中"
else
    log_warn "  ⚠ Gateway 未运行"
fi

if jq empty "$OPENCLAW_HOME/openclaw.json" 2>/dev/null; then
    echo "  ✓ 配置 JSON 有效"
else
    log_error "  ✗ 配置 JSON 无效"
fi

# 14b. 插件验证
echo "  插件验证..."
plugins=$(openclaw plugins list 2>/dev/null || echo "")
if grep -q "lossless-claw" <<< "$plugins"; then
    echo "  ✓ Lossless-Claw 已加载"
else
    log_warn "  ⚠ Lossless-Claw 未加载"
fi
if grep -q "memory-wiki" <<< "$plugins"; then
    echo "  ✓ Memory-Wiki 已加载"
else
    log_warn "  ⚠ Memory-Wiki 未加载"
fi

# 14c. 记忆搜索验证（可选）
read -p "  是否测试记忆搜索? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    result=$(openclaw memory search "test" --limit 1 2>/dev/null || echo "")
    if [ -n "$result" ]; then
        echo "  ✓ 记忆搜索可用"
    else
        echo "  ⚠ 记忆搜索无结果（可能正常，数据需重建索引）"
    fi
fi

# 14d. 测试 query（可选）
read -p "  是否发送测试 query 到 Gateway? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    TOKEN=$(jq -r '.gateway.auth.token' "$OPENCLAW_HOME/openclaw.json" 2>/dev/null || echo "")
    if [ -n "$TOKEN" ]; then
        response=$(curl -s -X POST "http://localhost:18789/v1/chat" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            -d '{"message": "hello", "chat_id": "test"}' 2>/dev/null || echo "")
        if [ -n "$response" ]; then
            echo "  ✓ Gateway 响应正常"
        else
            log_warn "  ⚠ Gateway 无响应"
        fi
    else
        log_warn "  ⚠ 无 Gateway token，跳过测试"
    fi
fi

echo ""
log_info "=========================================="
log_info "恢复完成！"
log_info "=========================================="
echo ""
echo "  检查清单:"
echo "  [1] credentials:  $(ls "$OPENCLAW_HOME/credentials/"*.json 2>/dev/null | wc -l) 个文件"
echo "  [2] openclaw.json: $(wc -l < "$OPENCLAW_HOME/openclaw.json" 2>/dev/null || echo '?') 行"
echo "  [3] skills:       $(ls -d "$OPENCLAW_HOME/workspace/skills"/*/ 2>/dev/null | wc -l) 个"
echo "  [4] workspace:    $(ls "$OPENCLAW_HOME/workspace/"*.md 2>/dev/null | wc -l) 个 MD 文件"
echo "  [5] memory/sqlite: $(ls "$OPENCLAW_HOME/memory/main.sqlite" "$OPENCLAW_HOME/lcm.db" 2>/dev/null | wc -l) 个"
echo "  [6] wiki:         $(test -d $OPENCLAW_HOME/wiki && echo '已恢复' || echo '未恢复')"
echo ""
if [ -f "$OPENCLAW_HOME/openclaw.json.bk.pre-restore" ]; then
    echo "  原始配置备份: $OPENCLAW_HOME/openclaw.json.bk.pre-restore"
fi
echo ""
echo "  ⚠️  待手动完成："
echo "  - 飞书 channel: 扫码认证"
echo "  - 微信 channel: 扫码认证"
echo ""
echo "  如需重建记忆索引，运行:"
echo "  openclaw wiki compile"
echo ""
echo "  ⚠️  重要：请先执行以下命令使 openclaw 命令生效："
echo "  source ~/.bashrc"
echo ""