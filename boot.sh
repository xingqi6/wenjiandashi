#!/bin/sh

# === 1. 基础配置 ===
BIN_NAME="system-worker"
DATA_DIR="data"
DB_FILE="$DATA_DIR/data.db"

# === 2. 云端存储配置 (spar 文件夹) ===
# 远程文件夹名称
REMOTE_FOLDER="spar"
# 索引文件 (记录当前版本)
REMOTE_IDX_FILE="sys_ver.id"
# 备份文件前缀
REMOTE_FILE_PREFIX="sys_core"
# 备份文件后缀
REMOTE_FILE_EXT=".bin"
# 保留备份数量
MAX_BACKUPS=5

# === 3. 生成配置文件 (锁定端口 7860) ===
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

# === 4. 工具函数 ===

# 构建完整的远程基础 URL (确保以 / 结尾)
# 逻辑：SYNC_URL + spar/
# 例如: https://dav.jianguoyun.com/dav/ + spar/
getFullRemotePath() {
    echo "${SYNC_URL}${REMOTE_FOLDER}/"
}

# 获取云端版本号
get_remote_version() {
    BASE_URL=$(getFullRemotePath)
    curl -s -f -u "$SYNC_USER:$SYNC_PASS" "${BASE_URL}${REMOTE_IDX_FILE}" | tr -d -c 0-9
}

# 确保云端文件夹存在
ensure_remote_folder() {
    if [ -n "$SYNC_URL" ]; then
        FULL_URL=$(getFullRemotePath)
        echo "📂 Checking/Creating remote folder: ${REMOTE_FOLDER} ..."
        # 发送 MKCOL 请求创建目录 (如果目录已存在会返回错误，我们忽略错误)
        curl -s -X MKCOL -u "$SYNC_USER:$SYNC_PASS" "$FULL_URL" >/dev/null 2>&1
    fi
}

# 执行单次备份逻辑
perform_backup() {
    # 获取当前版本
    CUR_VER=$(get_remote_version)
    [ -z "$CUR_VER" ] && CUR_VER=0
    
    # 计算下一个版本 (1-5 循环)
    NEXT_VER=$(( (CUR_VER % MAX_BACKUPS) + 1 ))
    
    NEXT_FILE="${REMOTE_FILE_PREFIX}_${NEXT_VER}${REMOTE_FILE_EXT}"
    BASE_URL=$(getFullRemotePath)
    
    echo "📤 Uploading backup to slot ${NEXT_VER} (${REMOTE_FOLDER}/${NEXT_FILE})..."
    
    curl -L -f -s -u "$SYNC_USER:$SYNC_PASS" -T "$DB_FILE" "${BASE_URL}${NEXT_FILE}"
    
    if [ $? -eq 0 ]; then
        # 上传索引
        echo "$NEXT_VER" > ver.tmp
        curl -L -f -s -u "$SYNC_USER:$SYNC_PASS" -T ver.tmp "${BASE_URL}${REMOTE_IDX_FILE}"
        rm ver.tmp
        echo "✅ Backup success at $(date)"
    else
        echo "❌ Backup failed at $(date)"
    fi
}

# === 5. 主逻辑开始 ===

# 标记：是否需要立即备份 (默认为 false)
NEED_IMMEDIATE_BACKUP=false

if [ -n "$SYNC_URL" ]; then
  # 步骤 A: 确保 spar 文件夹存在
  ensure_remote_folder
  
  BASE_URL=$(getFullRemotePath)
  echo "🔍 Checking remote data in ${REMOTE_FOLDER}..."
  
  LATEST_VER=$(get_remote_version)
  
  if [ -n "$LATEST_VER" ] && [ "$LATEST_VER" -gt 0 ]; then
    # === 场景 1: 发现备份 -> 恢复 ===
    TARGET_FILE="${REMOTE_FILE_PREFIX}_${LATEST_VER}${REMOTE_FILE_EXT}"
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
