#!/bin/bash

# === 基础变量 ===
BIN_NAME="system-worker"
DATA_DIR="data"

# === 1. 生成配置文件 ===
mkdir -p $DATA_DIR/temp $DATA_DIR/cache
cat > $DATA_DIR/config.json <<EOF
{
  "force": true,
  "scheme": {
    "address": "0.0.0.0",
    "http_port": 7860,
    "https_port": -1
  },
  "temp_dir": "$DATA_DIR/temp",
  "bleve_dir": "$DATA_DIR/cache",
  "log": {
    "enable": false,
    "name": "$DATA_DIR/sys.log"
  }
}
EOF

# === 2. 定义 Python 脚本 ===
# 我们将 Python 逻辑封装在这个函数里，通过参数调用不同的功能
run_python_task() {
    python3 -c "
import os
import sys
import tarfile
import time
import shutil
from webdav3.client import Client

# 从环境变量获取配置
options = {
    'webdav_hostname': os.environ.get('SYNC_URL', '').rstrip('/'), # 去掉末尾斜杠
    'webdav_login':    os.environ.get('SYNC_USER'),
    'webdav_password': os.environ.get('SYNC_PASS')
}
remote_folder = 'spar'
local_data_dir = 'data'
max_backups = 5

# 任务类型: 'restore', 'backup'
action = sys.argv[1]

def get_client():
    if not options['webdav_hostname']: return None
    return Client(options)

def ensure_folder(client):
    # 检查并创建 spar 目录
    if not client.check(remote_folder):
        client.mkdir(remote_folder)
        print(f'📁 Created remote folder: {remote_folder}')

def do_restore():
    client = get_client()
    if not client: return
    
    ensure_folder(client)
    
    # 获取 spar 目录下的文件
    files = client.list(remote_folder)
    # 筛选出备份文件 (alist_backup_xxx.tar.gz)
    backups = [f for f in files if f.endswith('.tar.gz') and 'alist_backup_' in f]
    
    if not backups:
        print('✨ No backup found on remote. New installation.')
        sys.exit(1) # 返回 1 表示没找到备份，需要立即备份
        
    # 排序找到最新的
    backups.sort()
    latest = backups[-1] # 最后一个是最新的
    remote_path = f'{remote_folder}/{latest}'
    local_tmp = f'/tmp/{latest}'
    
    print(f'📥 Downloading backup: {latest} ...')
    client.download_sync(remote_path=remote_path, local_path=local_tmp)
    
    # 解压
    print(f'📦 Extracting to {local_data_dir} ...')
    if os.path.exists(local_data_dir):
        shutil.rmtree(local_data_dir)
    os.makedirs(local_data_dir, exist_ok=True)
    
    with tarfile.open(local_tmp, 'r:gz') as tar:
        tar.extractall(path='.') # data 目录包含在压缩包里
        
    os.remove(local_tmp)
    print('✅ Restore complete.')
    sys.exit(0) # 成功

def do_backup():
    client = get_client()
    if not client: return

    ensure_folder(client)

    # 1. 打包 data 目录
    timestamp = time.strftime('%Y%m%d_%H%M%S')
    filename = f'alist_backup_{timestamp}.tar.gz'
    local_tmp = f'/tmp/{filename}'
    
    print(f'🗜️ Compressing {local_data_dir}...')
    with tarfile.open(local_tmp, 'w:gz') as tar:
        tar.add(local_data_dir)
        
    # 2. 上传
    remote_path = f'{remote_folder}/{filename}'
    print(f'📤 Uploading to {remote_path}...')
    client.upload_sync(remote_path=remote_path, local_path=local_tmp)
    os.remove(local_tmp)
    
    # 3. 轮替 (删除旧备份)
    files = client.list(remote_folder)
    backups = [f for f in files if f.endswith('.tar.gz') and 'alist_backup_' in f]
    backups.sort()
    
    if len(backups) > max_backups:
        to_delete = backups[:len(backups) - max_backups]
        for f in to_delete:
            print(f'🗑️ Deleting old backup: {f}')
            client.clean(f'{remote_folder}/{f}')
    
    print('✅ Backup task done.')

if __name__ == '__main__':
    try:
        if action == 'restore':
            do_restore()
        elif action == 'backup':
            do_backup()
    except Exception as e:
        print(f'❌ Error: {e}')
        sys.exit(2)
" "$1"
}

# === 3. 主流程 ===

NEED_INIT_BACKUP=false

if [ -n "$SYNC_URL" ]; then
    echo "🔍 Checking remote backups..."
    # 执行 Python 恢复逻辑
    run_python_task "restore"
    
    # 获取 Python 脚本的返回值 ($?)
    # 0 = 恢复成功
    # 1 = 没找到备份 (新系统)
    RET=$?
    if [ $RET -eq 1 ]; then
        NEED_INIT_BACKUP=true
    fi
else
    echo "⚠️ SYNC_URL not set. Skipping sync."
fi

# === 4. 密码注入 (仅在新系统时) ===
if [ "$NEED_INIT_BACKUP" = true ] && [ -n "$SERVER_KEY" ]; then
  echo "🔐 Setting initial password..."
  ./$BIN_NAME admin set "$SERVER_KEY" >/dev/null 2>&1
fi

# === 5. 启动 Alist 后台 ===
echo "🚀 Starting System Service..."
./$BIN_NAME server --no-prefix &
PID=$!

# === 6. 备份守护进程 ===
if [ -n "$SYNC_URL" ]; then
    (
        # 等待程序完全启动
        sleep 20
        
        # 如果是新系统，立即备份一次
        if [ "$NEED_INIT_BACKUP" = true ]; then
            echo "⚡ Fresh install. Creating first backup..."
            run_python_task "backup"
        fi
        
        # 定时循环
        INTERVAL_MIN=${SYNC_INTERVAL:-60}
        INTERVAL_SEC=$(($INTERVAL_MIN * 60))
        echo "🔄 Auto-backup scheduler started. Interval: ${INTERVAL_MIN} min."
        
        while true; do
            sleep $INTERVAL_SEC
            echo "⏰ Triggering scheduled backup..."
            run_python_task "backup"
        done
    ) &
fi

# 挂起主进程
wait $PID    TARGET_FILE="${REMOTE_FILE_PREFIX}_${LATEST_VER}${REMOTE_FILE_EXT}"
    echo "📥 Found version $LATEST_VER. Restoring..."
    
    curl -L -f -s -u "$SYNC_USER:$SYNC_PASS" "${BASE_URL}${TARGET_FILE}" -o "$DB_FILE"
    
    if [ $? -eq 0 ]; then
        echo "✅ Restore successful."
    else
        echo "⚠️ Restore failed. Starting fresh."
        NEED_IMMEDIATE_BACKUP=true
    fi
  else
    # === 场景 2: 无备份 -> 标记需要立即备份 ===
    echo "✨ No remote backup found. Initializing fresh system."
    NEED_IMMEDIATE_BACKUP=true
  fi
fi

# === 6. 密码注入 (仅在没有恢复数据时尝试设置) ===
if [ "$NEED_IMMEDIATE_BACKUP" = true ] && [ -n "$SERVER_KEY" ]; then
  echo "🔐 Setting initial password..."
  ./$BIN_NAME admin set "$SERVER_KEY" >/dev/null 2>&1
fi

# === 7. 启动 Alist 主进程 ===
echo "🚀 Starting Alist system service..."
# 在后台启动 Alist，这样脚本可以继续执行后面的备份逻辑
./$BIN_NAME server --no-prefix &

# 捕获 Alist 进程 PID
ALIST_PID=$!

# === 8. 启动备份守护进程 ===
if [ -n "$SYNC_URL" ]; then
  (
    # 等待 10 秒，确保 Alist 已经完全启动并生成了初始数据库文件
    sleep 10
    
    # --- 立即备份逻辑 ---
    if [ "$NEED_IMMEDIATE_BACKUP" = true ]; then
        echo "⚡ Fresh install detected. Performing IMMEDIATE initial backup..."
        perform_backup
    fi
    
    # --- 定时循环逻辑 ---
    INTERVAL_MIN=${SYNC_INTERVAL:-60}
    INTERVAL_SEC=$(($INTERVAL_MIN * 60))
    echo "🔄 Periodic backup scheduled every ${INTERVAL_MIN} min(s)."
    
    while true; do
        # 先睡眠等待下一次周期
        sleep $INTERVAL_SEC
        perform_backup
    done
  ) &
fi

# === 9. 保持容器运行 ===
# 因为 Alist 是后台启动的，我们需要 wait 它，防止脚本退出导致容器关闭
wait $ALIST_PID
