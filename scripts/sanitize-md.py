#!/usr/bin/env python3
"""sanitize-md.py — 漂白 workspace 中的 MD 文件

替换本机/本用户信息为占位符。
顺序重要：精确模式在前，宽松模式在后。

恢复时用 sed 批量替换回实际值：
  sed -i "s|<HOSTNAME>|$(hostname)|g" ~/.openclaw/workspace/*.md
  sed -i "s|<USER_NAME>|$(whoami)|g" ~/.openclaw/workspace/*.md
  sed -i "s#<HOME_DIR>#$HOME#g" ~/.openclaw/workspace/*.md
  sed -i "s#<OPENCLAW_WORKSPACE>#$HOME/.openclaw/workspace#g" ~/.openclaw/workspace/*.md
"""

import os
import re
import shutil

WORKSPACE = os.path.expanduser("~/.openclaw/workspace")
SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
BACKUP = os.path.join(os.path.dirname(SCRIPTS_DIR), "workspace")

HOSTNAME = os.uname().nodename
HOME = os.path.expanduser("~")
USERNAME = os.getenv("USER", "alex")

REPLACEMENTS = [
    (re.compile(re.escape(HOSTNAME)), "<HOSTNAME>"),
    (re.compile(re.escape(os.path.join(HOME, ".openclaw/workspace")).replace("/", r"\/")), "<OPENCLAW_WORKSPACE>"),
    (re.compile(re.escape(HOME + "/").replace("/", r"\/")), "<HOME_DIR>/"),
    (re.compile(r"\b" + re.escape(USERNAME) + r"\b"), "<USER_NAME>"),
    (re.compile(r"ou_[a-f0-9]{32}"), "<OPEN_ID>"),
    (re.compile(r"cli_[a-f0-9]{26}"), "<FEISHU_CLI_ID>"),
]

SKIP_FILES = {"README.md"}
COPY_SUBDIRS = ["scripts", "memory"]


def sanitize_file(src, dst):
    with open(src, encoding="utf-8") as f:
        content = f.read()

    original = content
    for pattern, replacement in REPLACEMENTS:
        content = pattern.sub(replacement, content)

    changed = content != original
    with open(dst, "w", encoding="utf-8") as f:
        f.write(content)
    return changed


def main():
    os.makedirs(BACKUP, exist_ok=True)

    md_count = 0
    for fname in os.listdir(WORKSPACE):
        fpath = os.path.join(WORKSPACE, fname)
        if not os.path.isfile(fpath):
            continue
        if not fname.endswith(".md"):
            continue
        if fname in SKIP_FILES:
            continue

        dst = os.path.join(BACKUP, fname)
        if sanitize_file(fpath, dst):
            print(f"  ✓ {fname}: 已漂白")
        else:
            print(f"    {fname}: 无需修改")
        md_count += 1

    # 复制 scripts/ 子目录
    for subdir in COPY_SUBDIRS:
        src_dir = os.path.join(WORKSPACE, subdir)
        dst_dir = os.path.join(BACKUP, subdir)
        if os.path.isdir(src_dir):
            if os.path.exists(dst_dir):
                shutil.rmtree(dst_dir)
            shutil.copytree(src_dir, dst_dir)
            # 漂白 scripts 中的文件
            for root, dirs, files in os.walk(dst_dir):
                for f in files:
                    fp = os.path.join(root, f)
                    try:
                        with open(fp, encoding="utf-8") as fh:
                            content = fh.read()
                        original = content
                        for pattern, replacement in REPLACEMENTS:
                            content = pattern.sub(replacement, content)
                        if content != original:
                            with open(fp, "w", encoding="utf-8") as fh:
                                fh.write(content)
                    except (UnicodeDecodeError, PermissionError):
                        pass
            print(f"  ✓ {subdir}/: 已复制并漂白")

    print(f"\n  → 共处理 {md_count} 个 MD 文件")


if __name__ == "__main__":
    main()
