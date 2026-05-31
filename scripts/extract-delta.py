#!/usr/bin/env python3
"""extract-delta.py — 从 openclaw.json 提取用户增量（delta）

只提取用户自定义的部分，丢弃系统自带的字段。
恢复时用 jq 合并到新系统配置上，而非全量覆盖。

产出:
  config/openclaw.json.delta  — 最小增量（用于 jq 合并）
  config/openclaw.json.full   — 完整配置参考（人可读，不用于恢复）
"""

import json
import os
import sys
import copy

OPENCLAW_HOME = os.path.expanduser("~/.openclaw")
SOURCE = os.path.join(OPENCLAW_HOME, "openclaw.json")
BACKUP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_DIR = os.path.join(BACKUP, "config")

CHANNELS_EXCLUDE = {"feishu", "openclaw-weixin", "openclaw-lark"}

SYSTEM_PLUGINS = {
    "tavily", "duckduckgo", "qwen", "feishu", "searxng", "memory-wiki",
    "openclaw-weixin", "openclaw-lark", "lossless-claw",
    "opencode-go", "deepseek",
}

# 非系统插件：不备份 plugin 条目和 allow/slots 引用，恢复时由安装流程补回
NON_SYSTEM_PLUGINS = {
    "openclaw-weixin", "openclaw-lark", "lossless-claw",
    "opencode-go", "deepseek",
}


def extract_delta(full):
    delta = {}

    # 1. agents.defaults — 用户模型偏好和运行参数
    defaults = full.get("agents", {}).get("defaults", {})
    agents_delta = {"defaults": {}}

    if "model" in defaults:
        agents_delta["defaults"]["model"] = defaults["model"]
    if "imageModel" in defaults:
        agents_delta["defaults"]["imageModel"] = defaults["imageModel"]
    if "models" in defaults:
        agents_delta["defaults"]["models"] = defaults["models"]
    if "memorySearch" in defaults:
        agents_delta["defaults"]["memorySearch"] = defaults["memorySearch"]
    if "compaction" in defaults:
        agents_delta["defaults"]["compaction"] = defaults["compaction"]
    if "maxConcurrent" in defaults:
        agents_delta["defaults"]["maxConcurrent"] = defaults["maxConcurrent"]
    if "subagents" in defaults:
        agents_delta["defaults"]["subagents"] = defaults["subagents"]
    if "bootstrapMaxChars" in defaults:
        agents_delta["defaults"]["bootstrapMaxChars"] = defaults["bootstrapMaxChars"]

    # workspace 路径用占位符
    if "workspace" in defaults:
        agents_delta["defaults"]["workspace"] = "<HOME_DIR>/.openclaw/workspace"

    delta["agents"] = agents_delta

    # 2. models.providers — 保留完整配置（包括 models 数组）
    # 自定义 provider（如 dashscope, arkcode, opencode-go）必须保留 models 数组
    # 只有内置 provider 可以使用系统 catalog，但用户的 provider id 通常与内置不匹配
    providers_full = full.get("models", {}).get("providers", {})
    providers_delta = {}
    for name, prov in providers_full.items():
        prov_delta = copy.deepcopy(prov)
        providers_delta[name] = prov_delta

    if providers_delta:
        delta["models"] = {
            "mode": full.get("models", {}).get("mode", "merge"),
            "providers": providers_delta,
        }

    # 3. secrets.providers — 保留结构，路径中的 /home/xxx 替换为占位符
    secrets_full = full.get("secrets", {}).get("providers", {})
    if secrets_full:
        secrets_delta = {}
        for name, entry in secrets_full.items():
            entry_copy = copy.deepcopy(entry)
            if "path" in entry_copy:
                entry_copy["path"] = entry_copy["path"].replace(
                    os.path.expanduser("~"), "<HOME_DIR>"
                ).replace(os.getenv("HOME", ""), "<HOME_DIR>")
            secrets_delta[name] = entry_copy
        delta["secrets"] = {"providers": secrets_delta}

    # 4. plugins — entries（含 config） + allow（白名单） + slots（槽位分配）
    entries_full = full.get("plugins", {}).get("entries", {})
    user_entries = {}
    for name, entry in entries_full.items():
        if name in SYSTEM_PLUGINS:
            continue
        entry_copy = copy.deepcopy(entry)
        if "config" in entry_copy:
            _sanitize_plugin_config(entry_copy["config"])
        user_entries[name] = entry_copy

    plugins_delta = {}
    if user_entries:
        plugins_delta["entries"] = user_entries
    if "allow" in full.get("plugins", {}):
        plugins_delta["allow"] = [p for p in full["plugins"]["allow"] if p not in NON_SYSTEM_PLUGINS]
    if "slots" in full.get("plugins", {}):
        raw_slots = full["plugins"]["slots"]
        plugins_delta["slots"] = {k: v for k, v in raw_slots.items() if v not in NON_SYSTEM_PLUGINS}
    if plugins_delta:
        delta["plugins"] = plugins_delta

    # 5. channels — 只保留用户自定义的 channel 框架（清空鉴权值）
    channels_full = full.get("channels", {})
    if channels_full:
        channels_delta = {}
        for name, ch in channels_full.items():
            if name in CHANNELS_EXCLUDE:
                continue
            ch_copy = copy.deepcopy(ch)
            # 删除所有鉴权相关字段
            for key in ["appSecret", "appId"]:
                ch_copy.pop(key, None)
            # v5.7: 将 channel 级旧字段移到 account 级，保持兼容
            _move_channel_to_account(ch_copy, [
                "domain", "connectionMode", "webhookPath",
                "dmPolicy", "groupPolicy",
                "reactionNotifications", "typingIndicator",
                "resolveSenderNames", "requireMention",
                "groups", "streaming", "footer",
                "blockStreaming", "blockStreamingBreak",
                "blockStreamingChunk", "blockStreamingCoalesce",
            ])
            if "accounts" in ch_copy:
                for acct_name, acct in ch_copy["accounts"].items():
                    for key in ["appSecret", "appId"]:
                        acct.pop(key, None)
                    if "allowFrom" in acct:
                        acct["allowFrom"] = []
            if "allowFrom" in ch_copy:
                ch_copy["allowFrom"] = []
            if "groupAllowFrom" in ch_copy:
                ch_copy["groupAllowFrom"] = []
            channels_delta[name] = ch_copy
        delta["channels"] = channels_delta

    # 6. tools — alsoAllow（自定义工具）+ web.search（搜索引擎）
    tools_delta = {}
    also_allow = full.get("tools", {}).get("alsoAllow", [])
    if also_allow:
        tools_delta["alsoAllow"] = also_allow
    if "web" in full.get("tools", {}):
        tools_delta["web"] = full["tools"]["web"]
    if tools_delta:
        delta["tools"] = tools_delta

    return delta


def _sanitize_plugin_config(config):
    """递归清理插件配置中的路径信息"""
    if isinstance(config, dict):
        for key in list(config.keys()):
            val = config[key]
            if isinstance(val, str) and "/home/" in val:
                config[key] = val.replace(
                    os.path.expanduser("~"), "<HOME_DIR>"
                )
            elif isinstance(val, dict):
                _sanitize_plugin_config(val)


def _move_channel_to_account(ch, keys):
    """将 channel 级旧字段移到 accounts.default 级（v4.x → v5.7 兼容）"""
    accounts = ch.setdefault("accounts", {})
    default = accounts.setdefault("default", {})
    for key in keys:
        if key in ch:
            val = ch.pop(key)
            if key not in default:
                default[key] = val
            elif key in ch.get("accounts", {}):
                accounts.get("default", {})[key] = val


def clean_full(full):
    """清洗完整配置：清空敏感值，用于人可读参考"""
    cleaned = copy.deepcopy(full)

    # gateway.auth.token
    if "gateway" in cleaned:
        cleaned["gateway"].setdefault("auth", {})["token"] = "REPLACE_ON_NEW_MACHINE"

    # plugins.installs — 删除安装元数据
    if "plugins" in cleaned:
        cleaned["plugins"].pop("installs", None)

    # meta / wizard — 删除版本特定信息
    cleaned.pop("meta", None)
    cleaned.pop("wizard", None)

    # channels — 清空鉴权
    for ch_name, ch in cleaned.get("channels", {}).items():
        ch.pop("appSecret", None)
        ch.pop("appId", None)
        if "accounts" in ch:
            for acct in ch["accounts"].values():
                acct.pop("appSecret", None)
                acct.pop("appId", None)
                if "allowFrom" in acct:
                    acct["allowFrom"] = []
        if "allowFrom" in ch:
            ch["allowFrom"] = []
        if "groupAllowFrom" in ch:
            ch["groupAllowFrom"] = []

    # secrets — 清空路径值
    for entry in cleaned.get("secrets", {}).get("providers", {}).values():
        if "path" in entry:
            entry["path"] = ""

    return cleaned


def main():
    if not os.path.isfile(SOURCE):
        print(f"错误: {SOURCE} 不存在", file=sys.stderr)
        sys.exit(1)

    with open(SOURCE, encoding="utf-8") as f:
        full = json.load(f)

    os.makedirs(CONFIG_DIR, exist_ok=True)

    # 提取 delta
    delta = extract_delta(full)
    delta_path = os.path.join(CONFIG_DIR, "openclaw.json.delta")
    with open(delta_path, "w", encoding="utf-8") as f:
        json.dump(delta, f, indent=2, ensure_ascii=False)
    print(f"✓ 用户增量: {delta_path} ({len(json.dumps(delta))} bytes)")

    # 清洗完整配置（人可读参考）
    cleaned = clean_full(full)
    full_path = os.path.join(CONFIG_DIR, "openclaw.json.full")
    with open(full_path, "w", encoding="utf-8") as f:
        json.dump(cleaned, f, indent=2, ensure_ascii=False)
    print(f"✓ 完整参考: {full_path} ({len(json.dumps(cleaned))} bytes)")

    # 导出飞书配置（feishu channel 已被排除出 delta，完整配置单独保存）
    if "channels" in full and "feishu" in full["channels"]:
        feishu = full["channels"]["feishu"]
        feishu_extra = {}
        # 通道级配置
        for key in ["dmPolicy", "groupPolicy", "reactionNotifications",
                     "typingIndicator", "resolveSenderNames", "streaming", "footer"]:
            if key in feishu:
                feishu_extra[key] = feishu[key]
        # allowFrom 清空（恢复后需重新配对）
        feishu_extra["allowFrom"] = []
        feishu_extra["groupAllowFrom"] = []
        # accounts.lark 配置
        if "accounts" in feishu and "lark" in feishu["accounts"]:
            lark = feishu["accounts"]["lark"]
            lark_extra = {}
            for key in ["dmPolicy", "groupPolicy"]:
                if key in lark:
                    lark_extra[key] = lark[key]
            lark_extra["allowFrom"] = []
            lark_extra["groupAllowFrom"] = []
            feishu_extra["accounts"] = {"lark": lark_extra}
        if feishu_extra:
            path = os.path.join(CONFIG_DIR, "feishu-extra.json")
            with open(path, "w", encoding="utf-8") as f:
                json.dump(feishu_extra, f, indent=2, ensure_ascii=False)
            print(f"✓ 飞书配置: {path}")


if __name__ == "__main__":
    main()
