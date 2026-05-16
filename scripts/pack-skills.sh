#!/bin/bash
set -euo pipefail
# pack-skills.sh — 打包 workspace/skills/ 下所有自定义 Skill 为 .skill 文件
# 排除 dist/ 和 node_modules/

OPENCLAW_HOME="$HOME/.openclaw"
SKILLS_DIR="$OPENCLAW_HOME/workspace/skills"
BACKUP="$OPENCLAW_HOME/workspace/openclaw-backup/skills"

mkdir -p "$BACKUP"

# 清理旧备份
rm -f "$BACKUP"/*.skill "$BACKUP"/checksums.sha256

count=0
if [ -d "$SKILLS_DIR" ]; then
    for skill_dir in "$SKILLS_DIR"/*/; do
        [ -d "$skill_dir" ] || continue
        name=$(basename "$skill_dir")

        # 跳过 dist 目录（编译产物，非自定义 skill）
        [ "$name" = "dist" ] && continue

        skill_file="$BACKUP/${name}.skill"

        # 打包，排除 node_modules 和 dist
        (cd "$skill_dir" && zip -r -q "$skill_file" . \
            -x "node_modules/*" \
            -x "dist/*" \
            -x ".git/*" \
            -x "__pycache__/*" \
            -x "*.pyc")

        count=$((count + 1))
        size=$(du -h "$skill_file" | cut -f1)
        echo "  ✓ ${name}.skill ($size)"
    done
fi

# 生成校验和
if [ "$count" -gt 0 ]; then
    (cd "$BACKUP" && sha256sum *.skill > checksums.sha256)
    echo "  → 共打包 ${count} 个 Skill，校验和已生成"
else
    echo "  ⚠ 未找到自定义 Skill"
fi
