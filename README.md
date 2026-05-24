# OpenClaw 备份与恢复方案 v7

> 核心原则：**只备份用户增量，不备份系统自带内容**
> 恢复方式：**增量合并而非全量覆盖**

---

## 概述

本方案将 OpenClaw 的**用户自定义部分**备份为透明目录结构，恢复时用 `jq` 合并到新系统配置上，避免全量覆盖导致新版系统配置丢失。

### v6 → v7 核心变化

| 方面 | v6 | v7 |
|------|----|----|
| Plugin 安装顺序 | 合并 delta 后装 lossless-claw → doctor 移除 stale | 先装 lossless-claw，再合并 delta |
| models.providers 备份 | ❌ 不含 models 数组（跨版本失败） | ✅ 完整备份 models 数组 |
| channels 备份 | feishu/weixin 含入 delta → v5.7 验证失败 | ✅ 排除（插件安装自动生成） |
| backup.sh 版本 | v4 | v5 |

### v5 → v6 核心变化

| 方面 | v5 | v6 |
|------|----|----|
| Step 2 初始化 | `openclaw setup`（不生成 models 数组） | `openclaw onboard --auth-choice skip`（生成完整配置） |
| 跨版本恢复 | ❌ v4.9 → v5.7 失败（models 数组缺失） | ✅ 正确合并（系统生成 models，delta 合并 baseUrl/apiKey） |

### v3 → v4/v5 核心变化

| 方面 | v3 | v4/v5 |
|------|----|----|
| 恢复步骤 | 14 步（顺序有误） | 14 步（依赖优先 + Memory + 验证） |
| 检测安装 | 只检查是否安装 | 检测 + 询问恢复出厂 |
| jq 安装 | Step 1 单独装 + Step 4 重复 | Step 3a 统一装（无重复） |
| 依赖顺序 | Step 11 在 Skills 之后 ❌ | Step 3 在 Skills 之前 ✅ |
| 恢复出厂 | 手动命令 | 已安装时询问是否重置 |
| Memory 备份 | 仅 workspace/memory/*.md（空） | SQLite + wiki + lcm.db（完整） |
| 验证 | 无 | Step 14 完整验证 |
| 打包输出 | 无 | 自动生成 tar.gz + SHA256 |
| system-deps.sh | 包含 jq + playwright | 仅系统包 |

### v2 → v3 核心变化

| 方面 | v2 | v3 |
|------|----|----|
| 备份格式 | 3 个 tar.gz 包 | 透明目录结构 |
| 配置策略 | 全量覆盖（危险） | 增量合并（安全） |
| openclaw.json | 完整配置（626 行） | 用户增量 delta（~400 行，无 models 数组） |
| MD 文件 | 不漂白 | 自动替换主机名/路径/用户名 |
| Skill 备份 | rsync 整目录 | .skill 打包 + SHA256 校验 |
| 依赖管理 | 无 | pip/npm/系统依赖清单 |
| 容器配置 | 无 | searxng podman-run.sh |

---

## 备份内容

### 分类原则

| 类别 | 例子 | 处理方式 |
|------|------|----------|
| **用户创建** | 自定义 Skill (13 个) | ✅ 打包为 .skill |
| **用户创建** | credentials (API Key) | ✅ 完整备份 |
| **用户创建** | workspace MD 文件 | ✅ 漂白后备份 |
| **用户创建** | scripts/ 自定义脚本 | ✅ 漂白后备份 |
| **用户配置** | 模型偏好、provider 连接 | ✅ 提取为 delta（含 models 数组） |
| **用户配置** | 并发数、compaction 等 | ✅ 提取为 delta |
| **用户配置** | 第三方插件 config | ✅ 提取为 delta（不含内置插件） |
| **系统自带** | 内置 plugins (tavily 等) | ❌ 不备份 |
| **插件创建** | channels (feishu, weixin) | ❌ 不备份（插件安装自动生成） |
| **系统自带** | gateway 配置 | ❌ 不备份（新机器自己生成） |
| **系统自带** | meta/wizard 版本信息 | ❌ 不备份 |

### 备份目录结构

```
openclaw-backup/
├── backup.sh                         # 一键备份
├── restore.sh                        # 一键恢复（14 步）
├── README.md                         # 本文档
│
├── scripts/                          # 工具链
│   ├── extract-delta.py              # 从 openclaw.json 提取用户增量
│   ├── sanitize-md.py                # MD 文件漂白
│   ├── pack-skills.sh                # Skill 打包
│   └── export-deps.sh                # 依赖导出
│
├── plugins/
│   └── install.sh                    # 第三方插件安装脚本
│
├── containers/
│   └── searxng/
│       └── podman-run.sh             # 容器启动脚本
│
├── config/                           # ← backup.sh 生成
│   ├── openclaw.json.delta           # 用户增量（用于 jq 合并）
│   ├── openclaw.json.full            # 完整配置参考（人可读）
│   └── feishu-extra.json             # 飞书配置（footer + streaming）
│
├── credentials/                      # ← backup.sh 生成
│   └── *.json                        # API Key 完整备份
│
├── skills/                           # ← backup.sh 生成
│   ├── *.skill                       # 13 个打包文件
│   └── checksums.sha256              # 校验和
│
├── workspace/                        # ← backup.sh 生成
│   ├── *.md                          # 漂白后的 MD 文件
│   ├── memory/*.md                   # 每日记忆（漂白后）
│   └── scripts/                      # 漂白后的脚本
│
├── memory/                           # ← backup.sh Step 7
│   ├── main.sqlite                   # 记忆数据库 (71M)
│   ├── lcm.db                        # Lossless Context Memory (185M)
│   └── wiki/                         # Memory Wiki 编译输出
│
├── deps/                             # ← backup.sh 生成
│   ├── pip-requirements.txt
│   ├── npm-requirements.txt
│   └── system-deps.sh
│
└── containers/                       # ← backup.sh 生成
    └── searxng/
        ├── settings.yml              # 用户自定义配置
        └── podman-run.sh             # (已在版本控制中)
```

---

## 备份步骤

```bash
cd ~/.openclaw/workspace/openclaw-backup
chmod +x backup.sh
./backup.sh              # 常规备份
./backup.sh --with-memory  # 包含每日记忆
```

---

## 恢复步骤

```bash
# 将整个 openclaw-backup/ 目录复制到新机器
scp -r ~/.openclaw/workspace/openclaw-backup user@new-machine:~/

# 在新机器上
cd ~/openclaw-backup
chmod +x restore.sh
./restore.sh
```

恢复脚本会执行 **14 步**交互式流程：

| Phase | Step | 操作 | 说明 |
|-------|------|------|------|
| **准备** | 1 | 检测 + 安装/重置 | 未安装→全新安装；已安装→询问恢复出厂 |
| | 2 | 初始化 onboard | `openclaw onboard --auth-choice skip` 生成完整配置（含 models 数组） |
| **依赖** | 3 | 统一依赖 | 3a. jq（合并必需）<br>3b. 系统依赖（可选）<br>3c. pip/npm 应用依赖（可选）<br>3d. pip 镜像（可选） |
| **配置** | 4 | credentials | 复制 API Key 文件 |
| **插件** | 5 | Lossless-Claw | 先安装再合并，避免被 doctor 当作 stale |
| **合并** | 6 | 合并 delta | `jq -s '.[0] * .[1]'` 新版 + 用户增量 |
| **数据** | 7 | Skills | 解压 .skill + SHA256 校验 |
| | 8 | workspace 文件 | MD + scripts + memory/*.md + 替换占位符 |
| **Gateway** | 9 | 启动 Gateway | 生成 auth token |
| | 10 | Lark/WeChat | 需 Gateway 在线 |
| **容器** | 11 | searxng | 可选启动容器 |
| | 12 | 重启 Gateway | 加载所有配置 |
| **Memory** | 13 | 恢复 memory 数据 | main.sqlite + lcm.db + wiki/ |
| **验证** | 14 | 完整验证 | 命令 + Gateway + 插件 + 记忆搜索 + 测试 query |

---

## OpenClaw 安装（非 root）

### 基本安装

```bash
# 1. 配置 npm 全局目录（无需 sudo）
mkdir -p ~/.npm-global
npm config set prefix ~/.npm-global

# 2. 添加到 PATH
echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# 3. 安装 OpenClaw
npm install -g openclaw
```

### 大陆镜像设置

npm 和 pip 在大陆访问较慢，建议使用镜像源：

```bash
# npm — 淘宝镜像（二选一）
# 方式 A：临时指定
npm install -g openclaw --registry=https://registry.npmmirror.com

# 方式 B：全局设置（推荐，后续 npm install 都走镜像）
npm config set registry https://registry.npmmirror.com

# pip — 清华镜像
pip3 config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
```

restore.sh 在 Step 1 和 Step 3 会交互询问是否使用镜像。

### 安装后初始化

```bash
# 初始化配置和 workspace（自动生成完整配置，包括 models 数组）
openclaw onboard --non-interactive --auth-choice skip --mode local --accept-risk --skip-health

# 或交互式向导
openclaw onboard
```

---

## 恢复出厂设置

如果需要重置现有 OpenClaw（而非重装），使用 `openclaw reset`：

```bash
# 先备份！
openclaw backup create --output ~/openclaw-backup-before-reset

# 三种重置范围：

# 1. 只重置配置（保留 credentials 和 sessions）
openclaw reset --scope config --yes

# 2. 重置配置 + credentials + sessions
openclaw reset --scope config+creds+sessions --yes

# 3. 完全重置（恢复出厂，删除所有数据）
openclaw reset --scope full --yes

# 预览模式（不实际删除，只打印将要执行的操作）
openclaw reset --dry-run
```

### 重置后恢复用户增量

完全重置后，可以用我们的 restore.sh 将用户增量合并回来：

```bash
# 1. 完全重置
openclaw backup create --output ~/pre-reset
openclaw reset --scope full --yes

# 2. 重新初始化（生成完整配置）
openclaw onboard --non-interactive --auth-choice skip --mode local --accept-risk --skip-health

# 3. 用 restore.sh 合并用户增量
cd ~/openclaw-backup
./restore.sh
```

这样既能恢复出厂状态，又能保留用户自定义配置。

---

## openclaw.json.delta 说明

### 什么是 delta？

delta 是从完整 openclaw.json 中提取的**用户增量**，只包含用户自定义的部分。恢复时用 `jq` 合并到新系统配置上，而非全量覆盖。

### delta 包含什么？

```json
{
  "agents": {
    "defaults": {
      "model": { ... },           // 用户模型偏好
      "models": { ... },          // 用户模型别名
      "memorySearch": { ... },    // 记忆搜索配置
      "compaction": { ... },      // 压缩模式
      "maxConcurrent": 3,         // 并发数
      "workspace": "<HOME_DIR>/.openclaw/workspace"
    }
  },
  "models": {
    "mode": "merge",
    "providers": {
      "dashscope": {              // provider 连接信息
        "baseUrl": "...",
        "apiKey": { "source": "file", ... },
        "api": "openai-completions"
      }
    }
  },
  "secrets": { "providers": { ... } },  // credentials 引用
  "plugins": { "entries": { ... } },    // 仅第三方插件
  "channels": { ... },                  // 框架（清空鉴权值）
  "tools": { "alsoAllow": [ ... ] }     // 自定义工具授权
}
```

### delta 不包含什么？

| 字段 | 原因 |
|------|------|
| `gateway` | 新机器自己生成 token |
| `channels` | 飞书/微信由插件安装自动生成 |
| `plugins.entries` 中的内置插件 | 系统自带 (tavily, duckduckgo, qwen, feishu, searxng, memory-wiki) |
| `plugins.entries` 中需单独安装的插件 | openclaw-weixin, openclaw-lark, opencode-go, deepseek |
| `plugins.installs` | 安装元数据，重新安装后自动生成 |
| `plugins.allow` / `plugins.slots` | 由插件安装流程自动管理 |
| `channels.*.appSecret` / `appId` | 鉴权值需在新机器上重新配置 |
| `meta` / `wizard` | 版本特定信息 |

### 合并安全保证

```bash
jq -s '.[0] * .[1]' 新系统配置.json delta.json
```

- 对象：深度合并（用户的值覆盖系统默认值）
- 数组：整体替换（用户定义的 models 列表会覆盖系统默认）
- 新版新增的字段（delta 中没有的）完整保留

---

## MD 文件漂白

备份时自动将隐私信息替换为占位符：

| 占位符 | 替换内容 | 恢复时替换为 |
|--------|----------|-------------|
| `<HOSTNAME>` | 主机名 (alex-Thinkpad-X250) | `$(hostname)` |
| `<OPENCLAW_WORKSPACE>` | workspace 路径 | `$HOME/.openclaw/workspace` |
| `<HOME_DIR>` | 用户主目录 | `$HOME` |
| `<USER_NAME>` | 用户名 | `$(whoami)` |
| `<OPEN_ID>` | 飞书用户 ID (ou_xxx) | 自动替换为占位符（恢复时保留） |
| `<FEISHU_CLI_ID>` | 飞书应用 ID (cli_xxx) | 自动替换为占位符（恢复时保留） |

恢复时自动替换前 4 个。`<OPEN_ID>` 和 `<FEISHU_CLI_ID>` 仅用于 workspace MD 文件漂白，不影响 channels 配置。飞书/微信通过扫码认证自动配置。

---

## 第三方插件

| 插件 | 用途 | 安装命令 | 恢复后需操作 |
|------|------|----------|-------------|
| lossless-claw | 上下文引擎 | `openclaw plugins install @martian-engineering/lossless-claw` | 无 |
| openclaw-weixin | 微信渠道 | `npx -y @tencent-weixin/openclaw-weixin-cli@latest install` | 扫码认证 |
| openclaw-lark | 飞书渠道 | `npx -y @larksuite/openclaw-lark install` | 扫码认证 |

安装顺序：lossless-claw → (Gateway 启动) → weixin → lark

---

## 注意事项

1. **credentials 是最珍贵的备份** — 恢复后立即 `chmod 600`
2. **依赖在 Skills 前安装** — pip/npm 包在 Step 3，Skills 在 Step 7
3. **Lossless-Claw 需优先安装** — 在合并 delta 前装好（Step 5），避免 doctor 移除 stale config
4. **Lark/WeChat 需 Gateway 在线** — 安装后需重启 Gateway
5. **searxng volume 不备份** — 恢复后自动重建并生成新 secret key
6. **Gateway 停机** — 新增 Lark account 需重启 Gateway (~10 分钟)
7. **delta 合并需 jq** — restore.sh Step 3a 自动安装
8. **大陆镜像** — restore.sh 交互询问 npm/pip 镜像源
9. **恢复出厂** — 已安装时询问是否 `openclaw reset --scope full`
10. **Memory SQLite 不漂白** — 直接备份，恢复后路径可能需手动调整
11. **记忆索引需重建** — 恢复后运行 `openclaw wiki compile`
12. **验证可选测试** — Step 14 可跳过记忆搜索和 query 测试

---

## 故障排除

### 恢复后模型列表不完整

**原因**：delta 中的 models 数组来自 v4.9，可能与新版模型列表不同。

**解决**：运行 `openclaw doctor --fix` 自动补充。或手动在 openclaw.json 中添加缺失的模型定义。

### 合并失败

**原因**：jq 不存在或 delta 格式错误。

**解决**：
```bash
sudo apt-get install jq
# 手动合并
jq -s '.[0] * .[1]' ~/.openclaw/openclaw.json config/openclaw.json.delta > merged.json
```

### OpenClaw 安装失败（权限问题）

**原因**：全局 npm 安装默认需要 root。

**解决**：使用非 root 安装方式：
```bash
mkdir -p ~/.npm-global
npm config set prefix ~/.npm-global
echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
npm install -g openclaw
```

### npm/pip 下载太慢

**解决**：使用大陆镜像：
```bash
npm config set registry https://registry.npmmirror.com
pip3 config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
```

### 想恢复出厂设置

**解决**：
```bash
openclaw backup create --output ~/pre-reset
openclaw reset --scope full --yes
openclaw onboard --non-interactive --auth-choice skip --mode local --accept-risk --skip-health
./restore.sh
```

### Gateway 无法启动

**解决**：
```bash
openclaw gateway auth generate
# 将 token 填入 gateway.auth.token
openclaw gateway restart
```

---

*版本: 7.0*
*最后更新: 2026-05-16*
