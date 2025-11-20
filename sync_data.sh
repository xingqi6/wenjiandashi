#!/bin/bash

# === 伪装配置 ===
APP_NAME="system-service"

# === 检查环境变量 ===
if [[ -z "$WEBDAV_URL" ]] || [[ -z "$WEBDAV_USERNAME" ]] || [[ -z "$WEBDAV_PASSWORD" ]]; then
    echo "⚠️ Missing WebDAV configuration. Starting service without backup..."
    ./$APP_NAME server --no-prefix
    exit 0
fi

# === 处理 WebDAV 路径 ===
# 去除 URL 末尾的斜杠
WEBDAV_URL=${WEBDAV_URL%/}
WEBDAV_BACKUP_PATH=${WEBDAV_BACKUP_PATH:-""}

if [ -n "$WEBDAV_BACKUP_PATH" ]; then
    FULL_WEBDAV_URL="${WEBDAV_URL}/${WEBDAV_BACKUP_PATH}"
else
    FULL_WEBDAV_URL="${WEBDAV_URL}"
fi

echo "🔗 WebDAV Target: $FULL_WEBDAV_URL"

# === 激活 Python 虚拟环境 ===
source $HOME/venv/bin/activate

# === 函数: 恢复备份 (Restore) ===
restore_backup() {
    echo "🔄 Checking for existing backups..."
    python3 -c "
import sys, os, tarfile, requests, shutil
from webdav3.client import Client

options = {
    'webdav_hostname': '$FULL_WEBDAV_URL',
    'webdav_login': '$WEBDAV_USERNAME',
    'webdav_password': '$WEBDAV_PASSWORD'
}
client = Client(options)

try:
    # 尝试创建目录 (如果不存在)
    if not client.check('.'):
        print('📂 Remote directory not found, creating...')
        client.mkdir('.')
except:
    pass

try:
    # 获取文件列表并筛选
    files = client.list()
    backups = [f for f in files if f.endswith('.tar.gz') and f.startswith('alist_backup_')]
    
    if not backups:
        print('✨ No remote backup found. Starting fresh.')
        sys.exit(0)

    # 找到最新的备份
    latest_backup = sorted(backups)[-1]
    print(f'📥 Found latest backup: {latest_backup}')
    
    # 下载
    download_url = f'$FULL_WEBDAV_URL/{latest_backup}'
    local_path = f'/tmp/{latest_backup}'
    
    with requests.get(download_url, auth=('$WEBDAV_USERNAME', '$WEBDAV_PASSWORD'), stream=True) as r:
        if r.status_code == 200:
            with open(local_path, 'wb') as f:
                for chunk in r.iter_content(chunk_size=8192):
                    f.write(chunk)
            print('✅ Download complete.')
            
            # 解压
            data_path = os.environ['HOME'] + '/data'
            if os.path.exists(data_path):
                shutil.rmtree(data_path)
            os.makedirs(data_path, exist_ok=True)
            
            try:
                with tarfile.open(local_path, 'r:gz') as tar:
                    tar.extractall(data_path)
                print('✅ Data restored successfully.')
            except Exception as e:
                print(f'❌ Extraction error: {e}')
            
            os.remove(local_path)
        else:
            print(f'❌ Download failed: {r.status_code}')

except Exception as e:
    print(f'⚠️ WebDAV Error: {e}')
"
}

# === 执行恢复 ===
restore_backup

# === 启动主程序 (后台运行) ===
echo "🚀 Starting application..."
./$APP_NAME server --no-prefix &
APP_PID=$!

# === 函数: 同步备份循环 (Sync Loop) ===
sync_data() {
    # 等待程序完全启动
    sleep 30
    
    while true; do
        # 获取间隔 (默认 600 秒)
        SYNC_INTERVAL=${SYNC_INTERVAL:-600}
        echo "⏳ Next sync in ${SYNC_INTERVAL}s..."
        sleep $SYNC_INTERVAL
        
        echo "🔄 Starting scheduled backup at $(date)..."
        
        if [ ! -d $HOME/data ]; then
            mkdir -p $HOME/data
        fi

        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_file="alist_backup_${timestamp}.tar.gz"
        local_path="/tmp/${backup_file}"

        # 1. 打包
        tar -czf "$local_path" -C $HOME/data .
        
        # 2. 上传
        curl -s -f -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" -T "$local_path" "$FULL_WEBDAV_URL/${backup_file}"
        
        if [ $? -eq 0 ]; then
            echo "✅ Upload success: ${backup_file}"
            
            # 3. 清理旧文件 (保留最近5份)
            python3 -c "
import sys
from webdav3.client import Client
options = {
    'webdav_hostname': '$FULL_WEBDAV_URL',
    'webdav_login': '$WEBDAV_USERNAME',
    'webdav_password': '$WEBDAV_PASSWORD'
}
try:
    client = Client(options)
    backups = [f for f in client.list() if f.endswith('.tar.gz') and f.startswith('alist_backup_')]
    backups.sort()
    
    if len(backups) > 5:
        to_delete = len(backups) - 5
        for f in backups[:to_delete]:
            client.clean(f)
            print(f'🗑️ Deleted old backup: {f}')
    else:
        print(f'Info: {len(backups)} backups exist.')
except:
    pass
"
        else
            echo "❌ Upload failed."
        fi
        
        rm -f "$local_path"
    done
}

# === 启动同步进程 ===
sync_data &

# === 挂起等待 ===
wait $APP_PID
