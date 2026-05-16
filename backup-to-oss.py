#!/usr/bin/env python3
"""
OpenClaw 备份 → 阿里云 OSS 一键脚本
1. 运行 backup.sh 生成增量备份
2. 打包为 tar.gz
3. 上传到阿里云 OSS
4. 清理 30 天前的旧备份

用法: python3 backup-to-oss.py
"""

import oss2
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

# ========== 配置 ==========
SCRIPT_DIR = Path(__file__).parent.resolve()
WORKSPACE = SCRIPT_DIR.parent  # ~/.openclaw/workspace
BACKUP_DIR = SCRIPT_DIR
OPENCLAW_HOME = Path.home() / ".openclaw"

# OSS 凭证
OSS_BUCKET_NAME = "ai-openclaw-backup"
OSS_ENDPOINT = "oss-cn-hongkong.aliyuncs.com"

# 保留天数
RETENTION_DAYS = 30

def get_oss_credentials():
    """从 credentials.json 读取 OSS 凭证"""
    cred_file = OPENCLAW_HOME / "credentials" / "credentials.json"
    if not cred_file.exists():
        print("❌ credentials.json 不存在")
        sys.exit(1)
    with open(cred_file) as f:
        creds = json.load(f)
    oss_cred = creds.get("阿里云 OSS 备份凭证", {})
    return {
        "access_key_id": oss_cred.get("oss_access_key_id", ""),
        "access_key_secret": oss_cred.get("oss_access_key_secret", ""),
    }

def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}")

def run_backup():
    """Step 1: 运行 backup.sh"""
    log("=" * 60)
    log("📦 Step 1/5: 运行 backup.sh...")
    log("=" * 60)
    
    backup_script = BACKUP_DIR / "backup.sh"
    if not backup_script.exists():
        print(f"❌ {backup_script} 不存在")
        sys.exit(1)
    
    result = subprocess.run(
        ["bash", str(backup_script)],
        capture_output=True, text=True, cwd=str(BACKUP_DIR)
    )
    print(result.stdout)
    if result.stderr:
        print(f"STDERR: {result.stderr}")
    if result.returncode != 0:
        log(f"❌ backup.sh 失败 (exit={result.returncode})")
        sys.exit(1)
    log("✅ backup.sh 完成")

def create_tarball():
    """Step 2: 打包 openclaw-backup 目录"""
    log("=" * 60)
    log("📦 Step 2/5: 打包备份...")
    log("=" * 60)
    
    # 打包路径: /tmp/openclaw-backup-YYYYMMDD_HHMMSS.tar.gz
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    import socket
    hostname = socket.gethostname()
    filename = f"openclaw-backup-{hostname}-{timestamp}.tar.gz"
    tarball_path = Path("/tmp") / filename
    
    log(f"  打包: {tarball_path}")
    
    # 用 tar 命令打包（比 Python tarfile 更可靠，保留权限等）
    result = subprocess.run(
        ["tar", "-czf", str(tarball_path),
         "-C", str(BACKUP_DIR.parent), "openclaw-backup"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        log(f"❌ 打包失败: {result.stderr}")
        sys.exit(1)
    
    size_mb = tarball_path.stat().st_size / 1024 / 1024
    log(f"✅ 打包完成: {size_mb:.2f} MB")
    return tarball_path, filename

def upload_to_oss(tarball_path, filename):
    """Step 3: 上传到 OSS"""
    log("=" * 60)
    log("☁️  Step 3/5: 上传到 OSS...")
    log("=" * 60)
    
    creds = get_oss_credentials()
    auth = oss2.Auth(creds["access_key_id"], creds["access_key_secret"])
    bucket = oss2.Bucket(auth, OSS_ENDPOINT, OSS_BUCKET_NAME)
    
    import socket
    hostname = socket.gethostname()
    oss_key = f"openclaw-home-{hostname}/backup-v7/{filename}"
    
    log(f"  上传: oss://{OSS_BUCKET_NAME}/{oss_key}")
    try:
        bucket.put_object_from_file(oss_key, str(tarball_path))
        log(f"✅ 上传成功")
        return bucket, oss_key
    except Exception as e:
        log(f"❌ 上传失败: {e}")
        sys.exit(1)

def cleanup_old_backups(bucket):
    """Step 4: 清理 30 天前的旧备份"""
    log("=" * 60)
    log(f"🧹 Step 4/5: 清理 {RETENTION_DAYS} 天前旧备份...")
    log("=" * 60)
    
    import socket
    hostname = socket.gethostname()
    prefix = f"openclaw-home-{hostname}/backup-v7/"
    cutoff = time.time() - RETENTION_DAYS * 86400
    
    deleted = 0
    for obj in oss2.ObjectIterator(bucket, prefix=prefix):
        if obj.last_modified < cutoff and obj.key.endswith(".tar.gz"):
            bucket.delete_object(obj.key)
            log(f"  🗑️  {obj.key.split('/')[-1]}")
            deleted += 1
    
    log(f"✅ 清理完成，删除 {deleted} 个")

def verify(bucket, oss_key, tarball_path):
    """Step 5: 验证上传结果"""
    log("=" * 60)
    log("✅ Step 5/5: 验证...")
    log("=" * 60)
    
    # 检查 OSS 上文件存在
    try:
        obj = bucket.get_object_meta(oss_key)
        oss_size = obj.content_length / 1024 / 1024
        local_size = tarball_path.stat().st_size / 1024 / 1024
        log(f"  📊 OSS 文件大小: {oss_size:.2f} MB")
        log(f"  📊 本地文件大小: {local_size:.2f} MB")
        if abs(oss_size - local_size) < 0.01:
            log(f"  ✅ 大小匹配，验证通过")
        else:
            log(f"  ⚠️  大小不匹配: OSS={oss_size:.2f}MB 本地={local_size:.2f}MB")
    except Exception as e:
        log(f"  ⚠️  验证异常: {e}")

def cleanup_local(tarball_path):
    """清理本地临时文件"""
    try:
        tarball_path.unlink()
        log(f"🧹 已清理本地临时文件")
    except Exception as e:
        log(f"⚠️  清理失败: {e}")

def main():
    log("🚀 OpenClaw 备份 → OSS 一键脚本")
    log("")
    
    # 1. 运行 backup.sh
    run_backup()
    
    # 2. 打包
    tarball_path, filename = create_tarball()
    
    # 3. 上传 OSS
    bucket, oss_key = upload_to_oss(tarball_path, filename)
    
    # 4. 清理 OSS 旧备份
    cleanup_old_backups(bucket)
    
    # 5. 验证
    verify(bucket, oss_key, tarball_path)
    
    # 6. 清理本地临时文件
    cleanup_local(tarball_path)
    
    log("")
    log("=" * 60)
    log("🎉 备份任务全部完成！")
    log(f"  文件: {filename}")
    log(f"  路径: oss://{OSS_BUCKET_NAME}/{oss_key}")
    log("=" * 60)

if __name__ == "__main__":
    main()
