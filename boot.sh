#!/bin/sh

# === 隐蔽配置 ===
BIN_NAME="system-worker"
DATA_DIR="data"
DB_FILE="$DATA_DIR/data.db"

# 云端混淆配置 (5个槽位轮替)
REMOTE_IDX_FILE="sys_ver.id" 
REMOTE_FILE_PREFIX="sys_core" 
REMOTE_FILE_EXT=".bin"
MAX_BACKUPS=5

# === 1. 动态生成配置 (端口 7860) ===
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

# === 辅助函数：获取当前云端版本号 ===
get_remote_version() {
    curl -s -f -u "$SYNC_USER:$SYNC_PASS" "${SYNC_URL}${REMOTE_IDX_FILE}" | tr -d -c 0-9
}

# === 2. 智能数据恢复 (Restore) ===
if [ -n "$SYNC_URL" ]; then
  echo "🔍 Checking remote storage for existing data..."
  LATEST_VER=$(get_remote_version)
  
  if [ -n "$LATEST_VER" ] && [ "$LATEST_VER" -gt 0 ]; then
    TARGET_FILE="${REMOTE_FILE_PREFIX}_${LATEST_VER}${REMOTE_FILE_EXT}"
    echo "📥 Found version $LATEST_VER. Downloading $TARGET_FILE..."
    curl -L -f -s -u "$SYNC_USER:$SYNC_PASS" "${SYNC_URL}${TARGET_FILE}" -o "$DB_FILE"
    
    if [ $? -eq 0 ]; then
      echo "✅ System restored successfully from slot $LATEST_VER."
    else
      echo "⚠️ Download failed. Starting with fresh database."
    fi
  else
    echo "✨ No remote backup found. Initializing fresh system."
  fi
fi

# === 3. 初始密码注入 ===
if [ -n "$SERVER_KEY" ]; then
  ./$BIN_NAME admin set "$SERVER_KEY" >/dev/null 2>&1
fi

# === 4. 循环轮替备份守护进程 (Rolling Backup Daemon) ===
if [ -n "$SYNC_URL" ]; then
  # --- 时间控制逻辑 ---
  # 如果设置了 SYNC_INTERVAL 变量，就用它，否则默认 10 (分钟)
  INTERVAL_MIN=${SYNC_INTERVAL:-10}
  # 将分钟转换为秒 (Alpine ash shell 支持这种运算)
  INTERVAL_SEC=$(($INTERVAL_MIN * 60))
  
  echo "🔄 Rolling backup service started. Interval: ${INTERVAL_MIN} min(s)."

  (
    while true; do
      # 等待指定的时间
      sleep $INTERVAL_SEC
      
      # 1. 获取当前版本
      CUR_VER=$(get_remote_version)
      if [ -z "$CUR_VER" ]; then CUR_VER=0; fi
      
      # 2. 计算下一版本 (环形: 1-2-3-4-5-1...)
      NEXT_VER=$(( (CUR_VER % MAX_BACKUPS) + 1 ))
      NEXT_FILENAME="${REMOTE_FILE_PREFIX}_${NEXT_VER}${REMOTE_FILE_EXT}"
      
      # 3. 上传覆盖
      curl -L -f -s -u "$SYNC_USER:$SYNC_PASS" -T "$DB_FILE" "${SYNC_URL}${NEXT_FILENAME}"
      
      # 4. 更新指针
      if [ $? -eq 0 ]; then
        echo "$NEXT_VER" > ver.tmp
        curl -L -f -s -u "$SYNC_USER:$SYNC_PASS" -T ver.tmp "${SYNC_URL}${REMOTE_IDX_FILE}"
        rm ver.tmp
      fi
    done
  ) &
fi

# === 5. 启动主程序 ===
echo "🚀 System service running..."
exec ./$BIN_NAME server --no-prefix
