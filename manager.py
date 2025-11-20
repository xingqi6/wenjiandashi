import os
import sys
import time
import tarfile
import shutil
import subprocess
import requests
from webdav3.client import Client

# === 🎭 深度伪装配置 ===
CORE_BIN = "./sys-kernel"
DATA_PATH = os.path.join(os.getcwd(), "data")
SNAPSHOT_PREFIX = "snap_core_"

# === 🕵️ 环境变量 ===
R_URL = os.environ.get("REMOTE_URL", "")
R_USER = os.environ.get("REMOTE_USER", "")
R_PASS = os.environ.get("REMOTE_PASS", "")
R_DIR = os.environ.get("REMOTE_DIR", "storage")
CYCLE = int(os.environ.get("CYCLE_PERIOD", 600))

def log(msg):
    print(f"[SystemAgent] {msg}", flush=True)

def get_client():
    if not R_URL or not R_USER:
        log("⚠️ Remote config missing. Standalone mode.")
        return None, None
    base = R_URL.rstrip('/')
    target_url = f"{base}/{R_DIR}/"
    options = {
        'webdav_hostname': target_url,
        'webdav_login': R_USER,
        'webdav_password': R_PASS,
        'disable_check_certificate_hostname_check': True
    }
    return Client(options), target_url

def check_remote_env(client):
    """修复：如果目录不存在，强制创建"""
    try:
        client.list()
    except:
        log(f"📂 Target directory '{R_DIR}' missing. Creating...")
        try:
            # 尝试创建当前目录 (.)
            client.mkdir('.')
        except Exception as e:
            log(f"⚠️ Create dir failed: {e}. Please create '{R_DIR}' manually in your cloud disk.")

def restore_snapshot(client, full_url):
    log("🔄 Scanning snapshots...")
    try:
        files = client.list()
        snaps = [f for f in files if f.startswith(SNAPSHOT_PREFIX) and f.endswith(".tar.gz")]
        if not snaps:
            log("✨ No snapshot found. Fresh start.")
            return
        snaps.sort()
        latest = snaps[-1]
        log(f"📥 Pulling: {latest}")
        local_tmp = f"/tmp/{latest}"
        d_link = f"{full_url}{latest}"
        with requests.get(d_link, auth=(R_USER, R_PASS), stream=True) as r:
            if r.status_code == 200:
                with open(local_tmp, 'wb') as f:
                    for chunk in r.iter_content(chunk_size=8192):
                        f.write(chunk)
                if os.path.exists(DATA_PATH):
                    shutil.rmtree(DATA_PATH)
                os.makedirs(DATA_PATH, exist_ok=True)
                with tarfile.open(local_tmp, "r:gz") as tar:
                    tar.extractall(DATA_PATH)
                log("✅ State restored.")
                os.remove(local_tmp)
    except Exception as e:
        log(f"❌ Restore Error: {str(e)}")

def create_snapshot(client):
    if not os.path.exists(DATA_PATH):
        return
    ts = time.strftime("%Y%m%d_%H%M%S")
    name = f"{SNAPSHOT_PREFIX}{ts}.tar.gz"
    local_tmp = f"/tmp/{name}"
    try:
        with tarfile.open(local_tmp, "w:gz") as tar:
            tar.add(DATA_PATH, arcname=".")
        log(f"📤 Syncing: {name}...")
        client.upload_sync(remote_path=name, local_path=local_tmp)
        os.remove(local_tmp)
        
        # 清理旧备份
        all_files = client.list()
        snaps = [f for f in all_files if f.startswith(SNAPSHOT_PREFIX) and f.endswith(".tar.gz")]
        snaps.sort()
        if len(snaps) > 5:
            for g in snaps[:len(snaps)-5]:
                client.clean(g)
                log(f"🗑️ Pruned: {g}")
    except Exception as e:
        log(f"❌ Sync Error: {str(e)}")

def main():
    client, full_url = get_client()
    if client:
        check_remote_env(client)
        restore_snapshot(client, full_url)
    
    log("🚀 Init Kernel...")
    proc = subprocess.Popen([CORE_BIN, "server", "--no-prefix"])
    
    while True:
        try:
            if proc.poll() is not None:
                break
            time.sleep(CYCLE)
            if client:
                create_snapshot(client)
        except:
            break

if __name__ == "__main__":
    main()            if client:
                create_snapshot(client)
        except:
            break

if __name__ == "__main__":
    main()
