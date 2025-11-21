# 定义 README.md 内容
readme_content = """# Stealth-Service-Deploy (隐匿云服务部署指南)

本项目提供一种在 PaaS 平台（如 Hugging Face）上部署高度隐匿的文件管理服务的方案。核心特点：**去名化**、**进程伪装**、**WebDAV 自动同步**、**断电数据恢复**。

> **免责声明**：本项目仅用于技术研究与数据备份测试，请勿用于违反平台服务条款的用途。

---

## 📋 准备工作
1. **GitHub 账号**：用于构建干净的基础镜像。
2. **Hugging Face 账号**：用于部署运行环境。
3. **WebDAV 网盘**：用于数据持久化备份（推荐 TeraCloud, InfiniCloud 等）。

---

## 🛠 第一阶段：构建伪装镜像 (GitHub)
### 步骤 1：创建 GitHub 仓库
新建公开仓库（如命名为 `server-base`）。

### 步骤 2：创建镜像构建文件
在仓库根目录创建以下两个文件：

#### 1. Dockerfile
```dockerfile
FROM alpine:latest

# 下载核心文件 -> 解压 -> 重命名为 wenjiandashi -> 销毁压缩包
RUN apk add --no-cache curl tar && \
    curl -L https://github.com/AlistGo/alist/releases/latest/download/alist-linux-musl-amd64.tar.gz -o core.tar.gz && \
    tar -zxvf core.tar.gz && \
    mv alist /usr/local/bin/wenjiandashi && \
    chmod +x /usr/local/bin/wenjiandashi && \
    rm core.tar.gz && \
    apk del curl tar

# 设置默认入口
ENTRYPOINT [ "wenjiandashi" ]
```
2. .github/workflows/build.yml
```yml

name: Build Stealth Image

on:
  workflow_dispatch:
  push:
    branches: [ "main" ]

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository_owner }}/wenjiandashi

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      
      - name: Extract metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}

      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}
```
步骤 3：构建并发布镜像
 
1. 提交代码后，进入仓库 Actions 页面等待构建完成。
​
2. 构建成功后，进入仓库右侧 Packages → 点击镜像名 → Package Settings → 将权限修改为 Public。
 
 
 
🚀 第二阶段：部署运行环境 (Hugging Face)
 
步骤 1：创建 Hugging Face Space
 
1. 新建 Space，SDK 选择 Docker，模板选择 Blank。
​
2. 在 Space 中创建以下三个文件：
 
1. boot.sh（核心启动脚本）
```
#!/bin/bash

# ==========================================
# Kernel Log Sync Daemon (Stealth Mode)
# ==========================================

if [[ -z "$WEBDAV_URL" ]] || [[ -z "$WEBDAV_USERNAME" ]] || [[ -z "$WEBDAV_PASSWORD" ]]; then
    echo "[System] Remote config missing. Starting local kernel only."
    ./kernel_daemon server
    exit 0
fi

# 变量处理
WEBDAV_BACKUP_PATH=${WEBDAV_BACKUP_PATH:-""}
WEBDAV_URL=${WEBDAV_URL%/}
FULL_WEBDAV_URL="${WEBDAV_URL}"

if [ -n "$WEBDAV_BACKUP_PATH" ]; then
    FULL_WEBDAV_URL="${WEBDAV_URL}/${WEBDAV_BACKUP_PATH}"
fi

source $HOME/env_core/bin/activate
DATA_DIR="$HOME/runtime/data"
BACKUP_PREFIX="sys_snapshot_"

# 自动初始化远程目录
init_remote_dir() {
    if [ -n "$WEBDAV_BACKUP_PATH" ]; then
        echo "[System] Checking remote storage..."
        curl -s -X MKCOL -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" "${FULL_WEBDAV_URL}" > /dev/null
    fi
}

# 恢复数据
restore_snapshot() {
    echo "[System] Syncing remote state..."
    python3 -c "
import sys, os, tarfile, requests, shutil
from webdav3.client import Client

opts = {
    'webdav_hostname': '$FULL_WEBDAV_URL',
    'webdav_login': '$WEBDAV_USERNAME',
    'webdav_password': '$WEBDAV_PASSWORD',
    'disable_check': True
}
try:
    client = Client(opts)
    backups = [f for f in client.list() if f.endswith('.tar.gz') and f.startswith('$BACKUP_PREFIX')]
    
    if not backups:
        print('[System] No previous state found. Clean boot.')
        sys.exit()
        
    latest = sorted(backups)[-1]
    print(f'[System] Restoring from: {latest}')
    
    local_tmp = f'/tmp/{latest}'
    with requests.get(f'$FULL_WEBDAV_URL/{latest}', auth=('$WEBDAV_USERNAME', '$WEBDAV_PASSWORD'), stream=True) as r:
        if r.status_code == 200:
            with open(local_tmp, 'wb') as f:
                for chunk in r.iter_content(8192): f.write(chunk)
            
            if os.path.exists('$DATA_DIR'): shutil.rmtree('$DATA_DIR')
            os.makedirs('$DATA_DIR', exist_ok=True)
            with tarfile.open(local_tmp, 'r:gz') as tar: tar.extractall('$DATA_DIR')
            print('[System] State restored.')
            os.remove(local_tmp)
except Exception as e:
    print(f'[System] Init notice: {str(e)}')
"
}

# 守护进程
sync_loop() {
    init_remote_dir
    while true; do
        INTERVAL=${SYNC_INTERVAL:-3600}
        echo "[System] Daemon sleeping for ${INTERVAL}s..."
        sleep $INTERVAL
        
        if [ -d "$DATA_DIR" ]; then
            TS=$(date +%Y%m%d_%H%M%S)
            FNAME="${BACKUP_PREFIX}${TS}.tar.gz"
            TMP_FILE="/tmp/$FNAME"
            
            tar -czf "$TMP_FILE" -C "$DATA_DIR" .
            
            # 尝试上传
            curl -f -s -u "$WEBDAV_USERNAME:$WEBDAV_PASSWORD" -T "$TMP_FILE" "$FULL_WEBDAV_URL/$FNAME"
            
            if [ $? -eq 0 ]; then
                echo "[System] Snapshot created: $FNAME"
                python3 -c "
from webdav3.client import Client
opts = {
    'webdav_hostname': '$FULL_WEBDAV_URL',
    'webdav_login': '$WEBDAV_USERNAME',
    'webdav_password': '$WEBDAV_PASSWORD'
}
try:
    c = Client(opts)
    files = sorted([f for f in c.list() if f.startswith('$BACKUP_PREFIX')])
    if len(files) > 5:
        for f in files[:-5]:
            c.clean(f)
except: pass
"
            else
                init_remote_dir 
            fi
            rm -f "$TMP_FILE"
        fi
    done
}

restore_snapshot
sync_loop &
echo "[System] Kernel Daemon launched."
./kernel_daemon server
```
2. Dockerfile（运行环境构建）
 
⚠️ 注意：将  <你的GitHub用户名>  替换为真实 GitHub 用户名（全小写）。
```
FROM ghcr.io/<你的GitHub用户名>/wenjiandashi:latest

# 1. 安装运行依赖
RUN apk add --no-cache python3 py3-pip bash jq curl && \
    python3 -m venv /home/user/env_core && \
    /home/user/env_core/bin/pip install --no-cache-dir requests webdavclient3

# 2. 创建安全用户
RUN adduser -D -u 1000 user
ENV HOME=/home/user \
    PATH=/home/user/.local/bin:$PATH

WORKDIR /home/user/runtime

# 3. 二次混淆：wenjiandashi -> kernel_daemon
RUN mv /usr/local/bin/wenjiandashi /home/user/runtime/kernel_daemon

# 4. 部署脚本
COPY --chown=user boot.sh /home/user/runtime/

# 5. 赋权
RUN chmod +x /home/user/runtime/kernel_daemon && \
    chmod +x /home/user/runtime/boot.sh

RUN chown -R user:user /home/user
USER user

# 6. 强制入口
ENTRYPOINT ["/bin/bash", "/home/user/runtime/boot.sh"]
```
3. README.md（Space 说明文件）
 
在文件开头添加端口配置：
```
app_port: 5244
```
步骤 2：配置环境变量
 
1. 进入 Hugging Face Space 的 Settings → Variables and Secrets。
​
2. 添加以下变量（建议使用 Secret）：
 
表格
   

变量名 (Key) 示例值 (Value) 说明 
WEBDAV_URL https://jike.teracloud.jp/dav WebDAV 服务器地址 
WEBDAV_USERNAME myuser WebDAV 用户名 
WEBDAV_PASSWORD mypassword WebDAV 密码/应用密码 
WEBDAV_BACKUP_PATH sys_backup 备份文件夹名称（程序会自动创建） 
SYNC_INTERVAL 3600 备份间隔时间（秒），建议 1 小时以上
📝 运行与维护
 
首次启动
 
1. 等待 Space 构建完成并显示 Running。
​
2. 查看 Logs，搜索  initial password  获取初始密码。
​
3. 打开网页，使用  admin  和初始密码登录。
 
数据持久化
 
1. 登录后立即修改密码，并进行个性化设置。
​
2. 等待第一次备份完成（日志显示  Snapshot created ）。
​
3. 后续重启或更新时，配置会自动从 WebDAV 恢复。
 
更新版本
 
1. 在 GitHub 仓库中重新运行 Action 构建镜像。
​
2. 在 Hugging Face 中点击 Factory Reboot 拉取最新核心。
 
隐匿性检查
 
- 构建日志：无原程序下载记录（GitHub 侧完成）。
​
- 进程列表：显示为  kernel_daemon 。
​
- 网盘文件：显示为  sys_snapshot_xxx.tar.gz 。
​
- 运行日志：全部伪装为 System Kernel 日志。
