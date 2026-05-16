#!/bin/bash
set -euo pipefail
# export-deps.sh — 导出外部依赖清单

OPENCLAW_HOME="$HOME/.openclaw"
BACKUP="$OPENCLAW_HOME/workspace/openclaw-backup/deps"
mkdir -p "$BACKUP"

# 1. pip 依赖
echo "[1/3] 导出 pip 依赖..."
pip3 freeze --path ~/.local/lib 2>/dev/null | grep -v "^openclaw" > "$BACKUP/pip-requirements.txt" 2>/dev/null || true

# 只保留 skill 相关的包
SKILL_PIPS=(
    markitdown
    markitdown-ocr
    python-docx
    lxml
    openpyxl
    xlsxwriter
    reportlab
    pandas
    PyMuPDF
    Pillow
    oss2
    dashscope
    playwright
    graphify
)

pip_deps="$BACKUP/pip-requirements.txt"
> "$pip_deps"
for pkg in "${SKILL_PIPS[@]}"; do
    installed=$(pip3 show "$pkg" 2>/dev/null | grep "^Version:" | awk '{print $2}' || true)
    if [ -n "$installed" ]; then
        echo "${pkg}>=${installed}" >> "$pip_deps"
    fi
done
echo "  → $(wc -l < "$pip_deps") 个 pip 包"

# 2. npm 依赖（仅 minimax-office 有 npm 依赖）
echo "[2/3] 导出 npm 依赖..."
npm_deps="$BACKUP/npm-requirements.txt"
> "$npm_deps"
minimax_dir="$OPENCLAW_HOME/workspace/skills/minimax-office"
if [ -d "$minimax_dir" ] && [ -f "$minimax_dir/package.json" ]; then
    # 提取 dependencies
    python3 -c "
import json
with open('$minimax_dir/package.json') as f:
    pkg = json.load(f)
for name, ver in pkg.get('dependencies', {}).items():
    print(f'{name}@{ver.lstrip(\"^\")}')" >> "$npm_deps" 2>/dev/null || true
fi
echo "  → $(wc -l < "$npm_deps") 个 npm 包"

# 3. 系统依赖
echo "[3/3] 生成系统依赖脚本..."
cat > "$BACKUP/system-deps.sh" << 'SYSEOF'
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
SYSEOF
chmod +x "$BACKUP/system-deps.sh"
echo "  ✓ system-deps.sh 已生成"
