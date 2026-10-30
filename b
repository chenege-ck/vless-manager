#!/bin/bash
# VLESS / sing-box 轻量节点控制台 (Debian & Alpine 双支持版)
# 支持协议: Reality + Shadowsocks + WS(CF) + AnyTLS
# 支持功能: 节点搭建 / 增删协议 / 用户生命周期与到期管理

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============== 路径配置 ==============
SBOX_BIN="/usr/local/bin/sing-box"
SBOX_DIR="/etc/sing-box"
SBOX_CONFIG="${SBOX_DIR}/config.json"
USER_DB="${SBOX_DIR}/users.db"
META_REALITY="${SBOX_DIR}/meta-reality.conf"
META_SS="${SBOX_DIR}/meta-ss.conf"
META_WS="${SBOX_DIR}/meta-ws.conf"
META_ANYTLS="${SBOX_DIR}/meta-anytls.conf"
SERVICE_NAME="sing-box"

# ============== 默认端口 ==============
SS_PORT_DEFAULT=8668
ANYTLS_PORT_DEFAULT=8585

# ============== 基础提示 ==============
info()  { echo -e "${GREEN}  ✓${NC}  $1"; }
warn()  { echo -e "${YELLOW}  ⚠${NC}  $1"; }
error() { echo -e "${RED}  ✗${NC}  $1"; }
title() { echo -e "\n${BLUE}┌─${NC} ${CYAN}$1${NC}"; echo -e "${BLUE}└────────────────────────────${NC}"; }

# ============== 安全读取 key=value 配置 ==============
read_kv() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 1
    awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file"
}

# ============== 自下载修复（保持管道与本地执行一致） ==============
_SBOX_SCRIPT_URL="https://raw.githubusercontent.com/chenege-ck/vless-manager/main/b"
_SBOX_REAL="/usr/local/bin/singbox_manager.sh"
if [[ ! -f "$0" || "$0" == /proc/* || "$0" == /dev/fd/* ]]; then
    mkdir -p "$(dirname "$_SBOX_REAL")" 2>/dev/null
    if curl -fsSL "$_SBOX_SCRIPT_URL" -o "$_SBOX_REAL" 2>/dev/null && [[ -s "$_SBOX_REAL" ]]; then
        chmod +x "$_SBOX_REAL"
        exec bash "$_SBOX_REAL" "$@"
    fi
fi

# ============== 权限检查 ==============
[[ $EUID -ne 0 ]] && error "请使用 root 权限运行此脚本" && exit 1

# ============== 系统识别 ==============
detect_os() {
    if [[ -f /etc/alpine-release ]] || grep -qi "alpine" /etc/os-release 2>/dev/null; then
        OS_TYPE="alpine"
    elif grep -qi -E "debian|ubuntu" /etc/os-release 2>/dev/null; then
        OS_TYPE="debian"
    else
        error "仅支持 Debian 系列或 Alpine Linux 系统"
        exit 1
    fi
}
detect_os

# ============== 服务控制抽象（适配 systemd 与 OpenRC） ==============
sbox_service_ctrl() {
    local action="$1"
    if [[ "$OS_TYPE" == "alpine" ]]; then
        case "$action" in
            start)   rc-service "$SERVICE_NAME" start ;;
            stop)    rc-service "$SERVICE_NAME" stop 2>/dev/null ;;
            restart) rc-service "$SERVICE_NAME" restart ;;
            enable)  rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 ;;
            disable) rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 ;;
            status)  rc-service "$SERVICE_NAME" status 2>/dev/null | grep -qi "started" ;;
        esac
    else
        case "$action" in
            start)   systemctl start "$SERVICE_NAME" ;;
            stop)    systemctl stop "$SERVICE_NAME" 2>/dev/null ;;
            restart) systemctl restart "$SERVICE_NAME" ;;
            enable)  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 ;;
            disable) systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 ;;
            status)  systemctl is-active --quiet "$SERVICE_NAME" ;;
        esac
    fi
}

# ============== 时区与时间工具（Python 跨平台处理） ==============
set_shanghai_timezone() {
    title "设置系统时区"
    if [[ "$OS_TYPE" == "alpine" ]]; then
        apk add --no-cache tzdata >/dev/null 2>&1
    fi
    if [[ -f /usr/share/zoneinfo/Asia/Shanghai ]]; then
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        echo "Asia/Shanghai" > /etc/timezone
        info "时区已设置为 Asia/Shanghai"
    else
        warn "未找到 tzdata，跳过时区强制变更"
    fi
}

now_shanghai_ts() {
    python3 -c "import time; print(int(time.time()))"
}

expire_noon_str() {
    local days="$1"
    python3 -c "import datetime; print((datetime.datetime.now() + datetime.timedelta(days=int('$days'))).strftime('%Y-%m-%d_12-00-00'))" 2>/dev/null
}

expire_to_ts() {
    local expire="$1"
    python3 -c "
import datetime, sys
exp = sys.argv[1].strip()
for fmt in ('%Y-%m-%d_%H-%M-%S', '%Y-%m-%dT%H:%M:%S', '%Y-%m-%d %H:%M:%S', '%Y-%m-%d'):
    try:
        dt = datetime.datetime.strptime(exp, fmt)
        if fmt == '%Y-%m-%d':
            dt = dt.replace(hour=12, minute=0, second=0)
        print(int(dt.timestamp()))
        sys.exit(0)
    except:
        pass
print(0)
" "$expire" 2>/dev/null
}

expire_display() {
    local expire="$1"
    if [[ "$expire" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
        local d="${expire%%_*}" t="${expire#*_}"; echo "${d} ${t//-/:}"
    else
        echo "$expire"
    fi
}

# ============== 端口探测工具（基于 Python，不依赖系统工具） ==============
check_port() {
    python3 -c "
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    s.bind(('0.0.0.0', int(sys.argv[1])))
    s.close()
    sys.exit(0)
except:
    sys.exit(1)
" "$1"
}

# ============== 公网 IP 获取 ==============
get_public_ip() {
    local ip=""
    ip=$(curl -s4 --max-time 5 ip.sb 2>/dev/null || curl -s4 --max-time 5 ifconfig.me 2>/dev/null || curl -s4 --max-time 5 api.ipify.org 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s6 --max-time 5 ip.sb 2>/dev/null || curl -s6 --max-time 5 ifconfig.me 2>/dev/null)
    echo "${ip:-<请填写服务器IP>}"
}

# ============== 用户名与 UUID 校验 ==============
validate_username() {
    local value="$1"
    [[ -z "$value" ]] && { error "用户名不能为空"; return 1; }
    [[ "$value" == *:* ]] && { error "用户名不能包含冒号"; return 1; }
    [[ "$value" == *[[:space:]]* ]] && { error "用户名不能包含空格或换行"; return 1; }
    local N
    N=$(printf '%s' "$value" | python3 -c 'import sys; sys.stdout.write(str(len(sys.stdin.read())))')
    if (( N > 20 )); then
        error "用户名过长（最多 20 个字符）"
        return 1
    fi
    return 0
}

validate_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || {
        error "UUID 格式不正确"
        return 1
    }
}

user_exists() {
    awk -F: -v n="$1" '$1==n {found=1; exit} END {exit !found}' "$USER_DB" 2>/dev/null
}

get_user_field() {
    awk -F: -v n="$1" -v f="$2" '$1==n {print $f; exit}' "$USER_DB" 2>/dev/null
}

# ============== 用户数据库标准化 ==============
# 格式: NAME:UUID:EXPIRE:STATUS:NODE:SSPASS
normalize_user_db() {
    [[ ! -f "$USER_DB" ]] && return 0
    python3 - <<PYEOF
from pathlib import Path
import re
p = Path("$USER_DB")
raw = p.read_text(encoding="utf-8", errors="ignore")
lines = raw.splitlines()
out = []
changed = False

def normalize_expire(exp):
    exp = exp.strip()
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", exp):
        return exp + "_12-00-00"
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}", exp):
        d, t = re.split(r"[T ]", exp, 1)
        return d + "_" + t.replace(":", "-")
    return exp

for line in lines:
    if not line.strip():
        changed = True; continue
    parts = line.rstrip("\n").split(":")
    if len(parts) < 4:
        changed = True; continue
    name, uuid, expire, status = parts[0], parts[1], parts[2], parts[3]
    node = (parts[4] if len(parts) > 4 else "") or "both"
    sspass = parts[5] if len(parts) > 5 else ""
    row = ":".join([name, uuid, normalize_expire(expire), status, node, sspass])
    if row != line:
        changed = True
    out.append(row)

if changed:
    p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
}

# ============== 加载元数据 ==============
load_meta() {
    REALITY_PORT="" REALITY_SNI="" REALITY_PRIVATE_KEY="" REALITY_PUBLIC_KEY="" REALITY_SHORTID=""
    SS_PORT="" SS_METHOD="" SS_PASSWORD=""
    WS_PORT="" WS_PATH="" WS_DOMAIN="" WS_CF_PORT="" CERT_DIR=""
    ANYTLS_PORT="" ANYTLS_PASSWORD="" ANYTLS_SNI="" ANYTLS_PRIVATE_KEY="" ANYTLS_PUBLIC_KEY="" ANYTLS_SHORTID=""

    if [[ -f "$META_REALITY" ]]; then
        REALITY_PORT=$(read_kv "$META_REALITY" "REALITY_PORT")
        REALITY_SNI=$(read_kv "$META_REALITY" "REALITY_SNI")
        REALITY_PRIVATE_KEY=$(read_kv "$META_REALITY" "REALITY_PRIVATE_KEY")
        REALITY_PUBLIC_KEY=$(read_kv "$META_REALITY" "REALITY_PUBLIC_KEY")
        REALITY_SHORTID=$(read_kv "$META_REALITY" "REALITY_SHORTID")
    fi
    if [[ -f "$META_SS" ]]; then
        SS_PORT=$(read_kv "$META_SS" "SS_PORT")
        SS_METHOD=$(read_kv "$META_SS" "SS_METHOD")
        SS_PASSWORD=$(read_kv "$META_SS" "SS_PASSWORD")
    fi
    if [[ -f "$META_WS" ]]; then
        WS_PORT=$(read_kv "$META_WS" "WS_PORT")
        WS_PATH=$(read_kv "$META_WS" "WS_PATH")
        WS_DOMAIN=$(read_kv "$META_WS" "WS_DOMAIN")
        WS_CF_PORT=$(read_kv "$META_WS" "WS_CF_PORT")
        CERT_DIR=$(read_kv "$META_WS" "CERT_DIR")
        CERT_DIR=${CERT_DIR:-/etc/sing-box/ssl}
    fi
    if [[ -f "$META_ANYTLS" ]]; then
        ANYTLS_PORT=$(read_kv "$META_ANYTLS" "ANYTLS_PORT")
        ANYTLS_PASSWORD=$(read_kv "$META_ANYTLS" "ANYTLS_PASSWORD")
        ANYTLS_SNI=$(read_kv "$META_ANYTLS" "ANYTLS_SNI")
        ANYTLS_PRIVATE_KEY=$(read_kv "$META_ANYTLS" "ANYTLS_PRIVATE_KEY")
        ANYTLS_PUBLIC_KEY=$(read_kv "$META_ANYTLS" "ANYTLS_PUBLIC_KEY")
        ANYTLS_SHORTID=$(read_kv "$META_ANYTLS" "ANYTLS_SHORTID")
    fi
}

has_reality()     { [[ -f "$META_REALITY" ]]; }
has_shadowsocks() { [[ -f "$META_SS" ]]; }
has_ws()          { [[ -f "$META_WS" ]]; }
has_anytls()      { [[ -f "$META_ANYTLS" ]]; }

# ============== sing-box 二进制查找 ==============
detect_sbox_bin() {
    local candidate
    for candidate in /usr/local/bin/sing-box /usr/bin/sing-box "$(command -v sing-box 2>/dev/null)"; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        if "$candidate" version >/dev/null 2>&1; then
            SBOX_BIN="$candidate"
            return 0
        fi
    done
    return 1
}

# ============== 验证配置 ==============
validate_sbox_config() {
    [[ ! -f "$SBOX_CONFIG" ]] && error "配置文件不存在: $SBOX_CONFIG" && return 1
    python3 -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8'))" "$SBOX_CONFIG" >/dev/null 2>&1 || {
        error "config.json 格式有误"
        return 1
    }
    detect_sbox_bin || { error "未找到 sing-box 可执行程序"; return 1; }
    local OUT
    OUT=$("$SBOX_BIN" check -c "$SBOX_CONFIG" 2>&1)
    if [[ $? -ne 0 ]]; then
        error "sing-box 校验失败: $OUT"
        return 1
    fi
    return 0
}

_start_sbox() {
    validate_sbox_config || return 1
    sbox_service_ctrl enable
    sbox_service_ctrl restart
    sleep 1
    if sbox_service_ctrl status; then
        info "sing-box 运行中"
        return 0
    else
        error "sing-box 启动失败"
        return 1
    fi
}

# ============== 依赖安装 ==============
install_deps() {
    title "安装基础依赖..."
    if [[ "$OS_TYPE" == "alpine" ]]; then
        apk update
        apk add --no-cache curl openssl python3 bash tzdata ca-certificates
    else
        apt-get update -qq
        apt-get install -y -qq curl openssl python3 tzdata ca-certificates
    fi
    info "依赖安装完成"
}

# ============== sing-box 安装与服务生成 ==============
install_sbox() {
    title "安装 sing-box..."
    if detect_sbox_bin; then
        warn "sing-box 已安装，跳过下载"
        return 0
    fi
    install_deps || return 1

    local ARCH
    case "$(uname -m)" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l)  ARCH="armv7" ;;
        *) error "不支持的 CPU 架构: $(uname -m)"; return 1 ;;
    esac

    info "正在拉取最新静态编译二进制..."
    local VER
    VER=$(curl -fsSL --max-time 15 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
          | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name","").lstrip("v"))' 2>/dev/null)

    if [[ ! "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        VER="1.11.4" # 回退兜底稳定版本
    fi

    local URL="https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${ARCH}.tar.gz"
    info "下载: $URL"
    curl -fsSL "$URL" -o /tmp/sing-box.tar.gz || { error "下载失败，请检查网络"; return 1; }
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/
    mkdir -p /usr/local/bin "$SBOX_DIR"
    cp "/tmp/sing-box-${VER}-linux-${ARCH}/sing-box" "$SBOX_BIN"
    chmod +x "$SBOX_BIN"
    rm -rf /tmp/sing-box.tar.gz "/tmp/sing-box-${VER}-linux-${ARCH}"

    # 安装系统守护服务
    if [[ "$OS_TYPE" == "alpine" ]]; then
        cat > /etc/init.d/sing-box <<'EOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background="yes"
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/sing-box
    else
        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${SBOX_BIN} run -c ${SBOX_CONFIG}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi

    detect_sbox_bin || { error "安装校验失败"; return 1; }
    info "sing-box 安装成功: $("$SBOX_BIN" version | head -n1)"
}

# ============== 生成 Reality 密钥对 ==============
gen_keypair() {
    PRIVATE_KEY=""
    PUBLIC_KEY=""
    detect_sbox_bin || { error "未找到 sing-box 可执行文件"; return 1; }
    local OUT
    OUT=$("$SBOX_BIN" generate reality-keypair 2>&1)
    PRIVATE_KEY=$(echo "$OUT" | awk -F': ' '/PrivateKey/I {print $2}' | tr -d ' \r\n')
    PUBLIC_KEY=$(echo "$OUT" | awk -F': ' '/PublicKey/I {print $2}' | tr -d ' \r\n')
    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        error "Reality 密钥生成失败"
        return 1
    fi
}

# ============== 重建 config.json ==============
rebuild_config() {
    load_meta
    HAS_REALITY=0; has_reality && HAS_REALITY=1
    HAS_SS=0; has_shadowsocks && HAS_SS=1
    HAS_WS=0; has_ws && HAS_WS=1
    HAS_ANYTLS=0; has_anytls && HAS_ANYTLS=1

    export SBOX_CONFIG HAS_REALITY HAS_SS HAS_WS HAS_ANYTLS
    export REALITY_PORT REALITY_SNI REALITY_PRIVATE_KEY REALITY_SHORTID
    export SS_PORT SS_METHOD SS_PASSWORD
    export WS_PORT WS_PATH CERT_DIR
    export ANYTLS_PORT ANYTLS_PASSWORD ANYTLS_SNI ANYTLS_PRIVATE_KEY ANYTLS_SHORTID

    python3 - <<'PYEOF'
import json, os

cfg = {
    "log": {"level": "warn", "timestamp": True},
    "inbounds": [],
    "outbounds": [
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"}
    ],
    "route": {
        "rules": [
            {"protocol": "dns", "action": "hijack-dns"},
            {"action": "sniff"}
        ],
        "final": "direct"
    }
}

if os.environ.get("HAS_REALITY") == "1":
    cfg["inbounds"].append({
        "type": "vless", "tag": "inbound-reality",
        "listen": "::", "listen_port": int(os.environ["REALITY_PORT"]),
        "users": [],
        "tls": {
            "enabled": True, "server_name": os.environ["REALITY_SNI"],
            "reality": {
                "enabled": True,
                "handshake": {"server": os.environ["REALITY_SNI"], "server_port": 443},
                "private_key": os.environ["REALITY_PRIVATE_KEY"],
                "short_id": [os.environ["REALITY_SHORTID"]]
            }
        }
    })

if os.environ.get("HAS_SS") == "1":
    cfg["inbounds"].append({
        "type": "shadowsocks", "tag": "inbound-shadowsocks",
        "listen": "::", "listen_port": int(os.environ["SS_PORT"]),
        "method": os.environ["SS_METHOD"], "password": os.environ["SS_PASSWORD"],
        "users": []
    })

if os.environ.get("HAS_WS") == "1":
    cfg["inbounds"].append({
        "type": "vless", "tag": "inbound-ws",
        "listen": "::", "listen_port": int(os.environ["WS_PORT"]),
        "users": [],
        "tls": {
            "enabled": True,
            "certificate_path": os.environ["CERT_DIR"] + "/ws.crt",
            "key_path": os.environ["CERT_DIR"] + "/ws.key"
        },
        "transport": {
            "type": "ws", "path": os.environ["WS_PATH"],
            "max_early_data": 2048,
            "early_data_header_name": "Sec-WebSocket-Protocol"
        }
    })

if os.environ.get("HAS_ANYTLS") == "1":
    cfg["inbounds"].append({
        "type": "anytls", "tag": "inbound-anytls",
        "listen": "::", "listen_port": int(os.environ["ANYTLS_PORT"]),
        "users": [{"name": "shared", "password": os.environ["ANYTLS_PASSWORD"]}],
        "tls": {
            "enabled": True,
            "server_name": os.environ["ANYTLS_SNI"],
            "reality": {
                "enabled": True,
                "handshake": {"server": os.environ["ANYTLS_SNI"], "server_port": 443},
                "private_key": os.environ["ANYTLS_PRIVATE_KEY"],
                "short_id": [os.environ["ANYTLS_SHORTID"]]
            }
        }
    })

with open(os.environ["SBOX_CONFIG"], "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF

    _inject_all_users
}

# ============== 用户注入逻辑 ==============
_inject_user() {
    local UUID=$1 NAME=$2 EXPIRE=$3 NODE=$4 SSPASS=${5:-}
    INJECT_UUID="$UUID" INJECT_NAME="$NAME" INJECT_NODE="$NODE" \
    INJECT_CONFIG="$SBOX_CONFIG" python3 - <<'PYEOF'
import json, os
uuid = os.environ["INJECT_UUID"]
name = os.environ["INJECT_NAME"]
node = os.environ["INJECT_NODE"]
cfg_path = os.environ["INJECT_CONFIG"]

with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

for inbound in cfg.get("inbounds", []):
    tag = inbound.get("tag", "")
    if tag not in ("inbound-reality", "inbound-ws"):
        continue
    users = inbound.get("users", [])
    inbound["users"] = [u for u in users if u.get("uuid") != uuid]
    should_add = (node == "both") or (node == "reality" and tag == "inbound-reality") or (node == "ws" and tag == "inbound-ws")
    if should_add:
        user_entry = {"name": name, "uuid": uuid}
        if tag == "inbound-reality":
            user_entry["flow"] = "xtls-rprx-vision"
        inbound["users"].append(user_entry)

with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF
}

_inject_all_users() {
    [[ ! -f "$USER_DB" ]] && return
    normalize_user_db
    while IFS=: read -r NAME UUID EXPIRE STATUS NODE SSPASS _REST; do
        [[ "$STATUS" != "active" ]] && continue
        NODE=${NODE:-both}
        _inject_user "$UUID" "$NAME" "$EXPIRE" "$NODE" "$SSPASS"
    done < "$USER_DB"
}

# ============== 协议配置模块 ==============
init_reality() {
    title "配置 VLESS + Reality"
    gen_keypair || return 1
    local PORT SNI SHORTID
    while true; do
        read -rp "监听端口 [默认 8443]: " PORT
        PORT=${PORT:-8443}
        check_port "$PORT" && break || warn "端口 ${PORT} 已被占用，请更换"
    done
    read -rp "伪装域名 [默认 www.apple.com]: " SNI
    SNI=${SNI:-www.apple.com}
    SHORTID=$(openssl rand -hex 8)

    cat > "$META_REALITY" <<EOF
REALITY_PRIVATE_KEY=${PRIVATE_KEY}
REALITY_PUBLIC_KEY=${PUBLIC_KEY}
REALITY_SNI=${SNI}
REALITY_PORT=${PORT}
REALITY_SHORTID=${SHORTID}
EOF
    rebuild_config && _start_sbox
    info "Reality 配置完成！端口: ${PORT}, SNI: ${SNI}"
}

init_shadowsocks() {
    title "配置 Shadowsocks"
    local PORT
    while true; do
        read -rp "监听端口 [默认 ${SS_PORT_DEFAULT}]: " PORT
        PORT=${PORT:-$SS_PORT_DEFAULT}
        check_port "$PORT" && break || warn "端口 ${PORT} 已被占用，请更换"
    done
    local METHOD="2022-blake3-aes-128-gcm"
    local PASS
    PASS=$(openssl rand -base64 16)

    cat > "$META_SS" <<EOF
SS_PORT=${PORT}
SS_METHOD=${METHOD}
SS_PASSWORD=${PASS}
EOF
    rebuild_config && _start_sbox
    info "Shadowsocks 配置完成！"
}

init_ws_cf() {
    title "配置 VLESS + WS + TLS"
    local PORT PATH DOMAIN
    while true; do
        read -rp "监听端口 [默认 8445]: " PORT
        PORT=${PORT:-8445}
        check_port "$PORT" && break || warn "端口 ${PORT} 已被占用，请更换"
    done
    read -rp "WS 路径 [默认 /vless]: " PATH
    PATH=${PATH:-/vless}
    read -rp "已解析到本机的域名: " DOMAIN
    [[ -z "$DOMAIN" ]] && error "域名不能为空" && return 1

    CERT_DIR="${SBOX_DIR}/ssl"
    mkdir -p "$CERT_DIR"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "${CERT_DIR}/ws.key" -out "${CERT_DIR}/ws.crt" \
        -days 3650 -subj "/CN=${DOMAIN}" >/dev/null 2>&1 || {
        error "自签证书生成失败"; return 1
    }

    cat > "$META_WS" <<EOF
WS_PORT=${PORT}
WS_PATH=${PATH}
WS_DOMAIN=${DOMAIN}
WS_CF_PORT=${PORT}
CERT_DIR=${CERT_DIR}
EOF
    rebuild_config && _start_sbox
    info "WS+TLS 节点配置完成"
}

init_anytls() {
    title "配置 AnyTLS + Reality"
    local PORT SNI SHORTID PASS
    while true; do
        read -rp "监听端口 [默认 ${ANYTLS_PORT_DEFAULT}]: " PORT
        PORT=${PORT:-$ANYTLS_PORT_DEFAULT}
        check_port "$PORT" && break || warn "端口 ${PORT} 已被占用，请更换"
    done
    read -rp "伪装域名 [默认 www.apple.com]: " SNI
    SNI=${SNI:-www.apple.com}
    gen_keypair || return 1
    SHORTID=$(openssl rand -hex 8)
    PASS=$(openssl rand -hex 16)

    cat > "$META_ANYTLS" <<EOF
ANYTLS_PORT=${PORT}
ANYTLS_PASSWORD=${PASS}
ANYTLS_SNI=${SNI}
ANYTLS_PRIVATE_KEY=${PRIVATE_KEY}
ANYTLS_PUBLIC_KEY=${PUBLIC_KEY}
ANYTLS_SHORTID=${SHORTID}
EOF
    rebuild_config && _start_sbox
    info "AnyTLS 配置完成！"
}

# ============== 节点管理总菜单 ==============
init_config() {
    title "节点协议管理"
    mkdir -p "$SBOX_DIR"
    touch "$USER_DB" && chmod 600 "$USER_DB"
    normalize_user_db
    load_meta

    echo ""
    echo "当前协议状态："
    has_reality     && echo -e "  ${GREEN}✓${NC} Reality 已配置"     || echo -e "  ${RED}✗${NC} Reality 未配置"
    has_shadowsocks && echo -e "  ${GREEN}✓${NC} Shadowsocks 已配置" || echo -e "  ${RED}✗${NC} Shadowsocks 未配置"
    has_ws          && echo -e "  ${GREEN}✓${NC} WS+CF 已配置"       || echo -e "  ${RED}✗${NC} WS+CF 未配置"
    has_anytls      && echo -e "  ${GREEN}✓${NC} AnyTLS 已配置"      || echo -e "  ${RED}✗${NC} AnyTLS 未配置"
    echo ""
    echo -e "  ${GREEN}1.${NC} 配置 VLESS + Reality"
    echo -e "  ${GREEN}2.${NC} 配置 Shadowsocks"
    echo -e "  ${GREEN}3.${NC} 配置 VLESS + WS + TLS"
    echo -e "  ${GREEN}4.${NC} 配置 AnyTLS"
    echo ""
    echo -e "  ${RED}5.${NC} 移除 Reality"
    echo -e "  ${RED}6.${NC} 移除 Shadowsocks"
    echo -e "  ${RED}7.${NC} 移除 WS+CF"
    echo -e "  ${RED}8.${NC} 移除 AnyTLS"
    echo -e "  ${GREEN}0.${NC} 返回主菜单"
    echo ""
    read -rp "请选择: " SEL
    case $SEL in
        1) init_reality ;;
        2) init_shadowsocks ;;
        3) init_ws_cf ;;
        4) init_anytls ;;
        5) rm -f "$META_REALITY"; rebuild_config; _start_sbox; info "Reality 已移除" ;;
        6) rm -f "$META_SS"; rebuild_config; _start_sbox; info "Shadowsocks 已移除" ;;
        7) rm -f "$META_WS"; rebuild_config; _start_sbox; info "WS+CF 已移除" ;;
        8) rm -f "$META_ANYTLS"; rebuild_config; _start_sbox; info "AnyTLS 已移除" ;;
        0) return ;;
        *) warn "无效选项" ;;
    esac
}

# ============== 用户管理 ==============
_print_link() {
    local USERNAME=$1 UUID=$2 EXPIRE=$3 NODE=${4:-both}
    load_meta
    local SERVER_IP
    SERVER_IP=$(get_public_ip)
    local EXPIRE_SHOW
    EXPIRE_SHOW=$(expire_display "$EXPIRE")

    echo ""
    echo -e "${GREEN}===== 节点分享信息 =====${NC}"
    echo -e "用户名称 : ${CYAN}${USERNAME}${NC}"
    echo -e "用户UUID : ${UUID}"
    echo -e "到期时间 : ${EXPIRE_SHOW}"

    if [[ "$NODE" == "reality" || "$NODE" == "both" ]] && has_reality; then
        local LINK="vless://${UUID}@${SERVER_IP}:${REALITY_PORT}/?type=tcp&encryption=none&flow=xtls-rprx-vision&sni=${REALITY_SNI}&fp=chrome&security=reality&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORTID}#${USERNAME}-Reality"
        echo ""
        echo -e "${CYAN}── Reality 节点 ──${NC}"
        echo -e "链接: $LINK"
    fi

    if [[ "$NODE" == "ws" || "$NODE" == "both" ]] && has_ws; then
        local WS_LINK="vless://${UUID}@${WS_DOMAIN}:${WS_CF_PORT:-443}/?type=ws&encryption=none&host=${WS_DOMAIN}&path=${WS_PATH}&security=tls&sni=${WS_DOMAIN}#${USERNAME}-WS"
        echo ""
        echo -e "${CYAN}── WS+TLS 节点 ──${NC}"
        echo -e "链接: $WS_LINK"
    fi

    if has_shadowsocks; then
        local USERINFO
        USERINFO=$(printf '%s' "${SS_METHOD}:${SS_PASSWORD}" | base64 | tr -d '\r\n')
        echo ""
        echo -e "${CYAN}── Shadowsocks 节点 (共享公共密码) ──${NC}"
        echo -e "链接: ss://${USERINFO}@${SERVER_IP}:${SS_PORT}#Shadowsocks"
    fi

    if has_anytls; then
        local AT_LINK="anytls://${ANYTLS_PASSWORD}@${SERVER_IP}:${ANYTLS_PORT}/?sni=${ANYTLS_SNI}&pbk=${ANYTLS_PUBLIC_KEY}&sid=${ANYTLS_SHORTID}&fp=chrome&security=reality#${USERNAME}-AnyTLS"
        echo ""
        echo -e "${CYAN}── AnyTLS 节点 ──${NC}"
        echo -e "链接: $AT_LINK"
    fi
    echo ""
}

add_user() {
    title "新建用户"
    normalize_user_db
    read -rp "输入用户名: " USERNAME
    validate_username "$USERNAME" || return
    if user_exists "$USERNAME"; then
        error "用户 ${USERNAME} 已存在"; return
    fi

    local NODE="both"
    if has_reality && has_ws; then
        echo "分配节点权限: 1. Reality+WS (默认) | 2. 仅 Reality | 3. 仅 WS"
        read -rp "选择 [1/2/3]: " N_OPT
        case $N_OPT in 2) NODE="reality" ;; 3) NODE="ws" ;; *) NODE="both" ;; esac
    elif has_reality; then
        NODE="reality"
    elif has_ws; then
        NODE="ws"
    fi

    read -rp "有效天数 [默认 999]: " DAYS
    DAYS=${DAYS:-999}
    [[ ! "$DAYS" =~ ^[0-9]+$ ]] && error "请输入纯数字" && return

    local EXPIRE UUID
    EXPIRE=$(expire_noon_str "$DAYS")
    UUID=$(python3 -c "import uuid; print(str(uuid.uuid4()))")

    echo "${USERNAME}:${UUID}:${EXPIRE}:active:${NODE}:" >> "$USER_DB"
    _inject_user "$UUID" "$USERNAME" "$EXPIRE" "$NODE"
    validate_sbox_config && sbox_service_ctrl restart
    _print_link "$USERNAME" "$UUID" "$EXPIRE" "$NODE"
}

delete_user() {
    title "删除用户"
    list_users_brief
    read -rp "请输入要删除的用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return
    if ! user_exists "$USERNAME"; then error "用户不存在"; return; fi

    UUID=$(get_user_field "$USERNAME" 2)
    # 从配置文件中删除
    python3 - <<PYEOF
import json
with open("$SBOX_CONFIG", "r", encoding="utf-8") as f:
    cfg = json.load(f)
for inbound in cfg.get("inbounds", []):
    if "users" in inbound:
        inbound["users"] = [u for u in inbound["users"] if u.get("uuid") != "$UUID"]
with open("$SBOX_CONFIG", "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF
    # 从数据库中剔除
    python3 - <<PYEOF
from pathlib import Path
p = Path("$USER_DB")
lines = [l for l in p.read_text().splitlines() if not l.startswith("$USERNAME:")]
p.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
PYEOF
    sbox_service_ctrl restart
    info "用户 ${USERNAME} 已完全删除"
}

toggle_user() {
    local ACTION="$1"
    title "${ACTION}用户"
    list_users_brief
    read -rp "输入用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return
    if ! user_exists "$USERNAME"; then error "用户不存在"; return; fi

    local UUID EXPIRE NODE
    UUID=$(get_user_field "$USERNAME" 2)
    EXPIRE=$(get_user_field "$USERNAME" 3)
    NODE=$(get_user_field "$USERNAME" 5)

    if [[ "$ACTION" == "disable" ]]; then
        # 从配置中摘掉
        python3 - <<PYEOF
import json
with open("$SBOX_CONFIG", "r", encoding="utf-8") as f:
    cfg = json.load(f)
for inbound in cfg.get("inbounds", []):
    if "users" in inbound:
        inbound["users"] = [u for u in inbound["users"] if u.get("uuid") != "$UUID"]
with open("$SBOX_CONFIG", "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF
        python3 - <<PYEOF
from pathlib import Path
p = Path("$USER_DB")
lines = [l.replace(":active:", ":disabled:") if l.startswith("$USERNAME:") else l for l in p.read_text().splitlines()]
p.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
PYEOF
        sbox_service_ctrl restart
        info "用户 ${USERNAME} 已禁用"
    else
        # 启用
        local NOW_TS EXP_TS
        NOW_TS=$(now_shanghai_ts)
        EXP_TS=$(expire_to_ts "$EXPIRE")
        if (( EXP_TS > 0 && NOW_TS >= EXP_TS )); then
            warn "用户已到期，请先续期后再启用"
            return
        fi
        _inject_user "$UUID" "$USERNAME" "$EXPIRE" "$NODE"
        python3 - <<PYEOF
from pathlib import Path
p = Path("$USER_DB")
lines = [l.replace(":disabled:", ":active:") if l.startswith("$USERNAME:") else l for l in p.read_text().splitlines()]
p.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
PYEOF
        validate_sbox_config && sbox_service_ctrl restart
        info "用户 ${USERNAME} 已启用"
    fi
}

renew_user() {
    title "用户续期"
    list_users_brief
    read -rp "输入用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return
    if ! user_exists "$USERNAME"; then error "用户不存在"; return; fi

    read -rp "从当前起续期天数 [默认 999]: " DAYS
    DAYS=${DAYS:-999}
    local NEW_EXPIRE UUID NODE
    NEW_EXPIRE=$(expire_noon_str "$DAYS")
    UUID=$(get_user_field "$USERNAME" 2)
    NODE=$(get_user_field "$USERNAME" 5)

    python3 - <<PYEOF
from pathlib import Path
p = Path("$USER_DB")
out = []
for l in p.read_text().splitlines():
    parts = l.split(":")
    if parts[0] == "$USERNAME":
        parts[2] = "$NEW_EXPIRE"
        parts[3] = "active"
        out.append(":".join(parts))
    else:
        out.append(l)
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
    _inject_user "$UUID" "$USERNAME" "$NEW_EXPIRE" "$NODE"
    validate_sbox_config && sbox_service_ctrl restart
    info "用户 ${USERNAME} 已续期至 $(expire_display "$NEW_EXPIRE")，已恢复活跃"
}

list_users() {
    title "用户列表"
    normalize_user_db
    [[ ! -s "$USER_DB" ]] && warn "暂无任何用户" && return
    echo -e "  ${YELLOW}用户名           到期时间             状态       权限${NC}"
    echo -e "  ──────────────────────────────────────────────────────────"
    while IFS=: read -r NAME UUID EXPIRE STATUS NODE _REST; do
        local COLOR=$GREEN
        [[ "$STATUS" != "active" ]] && COLOR=$RED
        printf "  ${COLOR}%-16s %-20s %-10s %s${NC}\n" "$NAME" "$(expire_display "$EXPIRE")" "$STATUS" "${NODE:-both}"
    done < "$USER_DB"
    echo ""
}

list_users_brief() {
    normalize_user_db
    [[ ! -s "$USER_DB" ]] && echo "  (暂无用户)" && return
    while IFS=: read -r NAME UUID EXPIRE STATUS NODE _REST; do
        printf "  - %-15s [%s | %s]\n" "$NAME" "$STATUS" "$(expire_display "$EXPIRE")"
    done < "$USER_DB"
}

show_user_link() {
    title "查看分享链接"
    list_users_brief
    read -rp "输入用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return
    if ! user_exists "$USERNAME"; then error "用户不存在"; return; fi

    local UUID EXPIRE NODE
    UUID=$(get_user_field "$USERNAME" 2)
    EXPIRE=$(get_user_field "$USERNAME" 3)
    NODE=$(get_user_field "$USERNAME" 5)
    _print_link "$USERNAME" "$UUID" "$EXPIRE" "$NODE"
}

# ============== 到期检测（定时任务执行） ==============
check_expire() {
    normalize_user_db
    local NOW_TS
    NOW_TS=$(now_shanghai_ts)
    local CHANGED=0
    [[ ! -f "$USER_DB" ]] && return

    while IFS=: read -r NAME UUID EXPIRE STATUS NODE _REST; do
        [[ "$STATUS" != "active" ]] && continue
        local EXP_TS
        EXP_TS=$(expire_to_ts "$EXPIRE")
        if (( EXP_TS > 0 && NOW_TS >= EXP_TS )); then
            warn "用户 [${NAME}] 已到期，自动停用"
            CHANGED=1
        fi
    done < "$USER_DB"

    if [[ $CHANGED -eq 1 ]]; then
        python3 - <<PYEOF
import time, json
from pathlib import Path

p = Path("$USER_DB")
lines = p.read_text().splitlines()
now = int(time.time())
expired_uuids = set()
out = []

for l in lines:
    parts = l.split(":")
    if len(parts) >= 4 and parts[3] == "active":
        # 解析时间
        import datetime
        exp = parts[2]
        ts = 0
        for fmt in ('%Y-%m-%d_%H-%M-%S', '%Y-%m-%d'):
            try:
                dt = datetime.datetime.strptime(exp, fmt)
                ts = int(dt.timestamp())
                break
            except: pass
        if ts > 0 and now >= ts:
            parts[3] = "disabled"
            expired_uuids.add(parts[1])
    out.append(":".join(parts))
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")

if expired_uuids:
    cfg_p = Path("$SBOX_CONFIG")
    cfg = json.loads(cfg_p.read_text())
    for inbound in cfg.get("inbounds", []):
        if "users" in inbound:
            inbound["users"] = [u for u in inbound["users"] if u.get("uuid") not in expired_uuids]
    cfg_p.write_text(json.dumps(cfg, indent=2))
PYEOF
        sbox_service_ctrl restart
    fi
}

# ============== 定时任务自动挂载 ==============
setup_cron() {
    local CRON_CMD="*/10 * * * * /usr/local/bin/singbox_manager.sh --check-expire >/dev/null 2>&1"
    (crontab -l 2>/dev/null | grep -v "check-expire"; echo "$CRON_CMD") | crontab -
    if [[ "$OS_TYPE" == "alpine" ]]; then
        rc-service crond start >/dev/null 2>&1
        rc-update add crond default >/dev/null 2>&1
    fi
    info "到期自动检查计划已配置 (每10分钟自动扫描)"
}

# ============== 快捷命令 c 安装 ==============
install_shortcut() {
    local TARGET="/usr/local/bin/singbox_manager.sh"
    if [[ "$0" != "$TARGET" && "$0" != "/usr/local/bin/c" ]]; then
        cat "$0" > "$TARGET" 2>/dev/null
        chmod +x "$TARGET"
    fi
    cp -f "$TARGET" /usr/local/bin/c 2>/dev/null
    chmod +x /usr/local/bin/c 2>/dev/null
}

# ============== 节点运行状态 ==============
show_info() {
    title "服务与节点状态"
    local S_STATUS
    if sbox_service_ctrl status; then
        S_STATUS="${GREEN}运行中${NC}"
    else
        S_STATUS="${RED}已停止${NC}"
    fi
    local U_COUNT=0 A_COUNT=0
    [[ -f "$USER_DB" ]] && U_COUNT=$(wc -l < "$USER_DB")
    [[ -f "$USER_DB" ]] && A_COUNT=$(grep -c ":active:" "$USER_DB" 2>/dev/null || echo 0)

    echo -e "  系统环境 : ${CYAN}${OS_TYPE}${NC}"
    echo -e "  服务状态 : ${S_STATUS}"
    echo -e "  用户统计 : 共 ${U_COUNT} 个 (活跃: ${A_COUNT})"
    echo -e "  公网 IP  : $(get_public_ip)"
    echo ""
    load_meta
    has_reality     && echo -e "  ${GREEN}✓${NC} Reality 端口: ${REALITY_PORT} | SNI: ${REALITY_SNI}"
    has_shadowsocks && echo -e "  ${GREEN}✓${NC} Shadowsocks 端口: ${SS_PORT} | 加密: ${SS_METHOD}"
    has_ws          && echo -e "  ${GREEN}✓${NC} WS+TLS 端口: ${WS_PORT} | 域名: ${WS_DOMAIN}"
    has_anytls      && echo -e "  ${GREEN}✓${NC} AnyTLS 端口: ${ANYTLS_PORT} | SNI: ${ANYTLS_SNI}"
    echo ""
}

# ============== 在线更新管理脚本 ==============
update_script() {
    title "更新控制台管理脚本"
    local SCRIPT_URL="https://raw.githubusercontent.com/chenege-ck/vless-manager/main/b"
    info "正在从 GitHub 下载最新版本..."
    local TMP_F="/tmp/sbox_mgr_new.sh"
    rm -f "$TMP_F"
    if curl -fsSL "$SCRIPT_URL" -o "$TMP_F" && [[ -s "$TMP_F" ]]; then
        if ! head -n 5 "$TMP_F" | grep -q "sing-box"; then
            error "拉取的内容非合法脚本，更新取消"
            rm -f "$TMP_F"; return
        fi
        cp -f "$TMP_F" /usr/local/bin/singbox_manager.sh
        cp -f "$TMP_F" /usr/local/bin/c
        chmod +x /usr/local/bin/singbox_manager.sh /usr/local/bin/c
        rm -f "$TMP_F"
        info "脚本更新成功，正在重启进入新版..."
        sleep 1
        exec /usr/local/bin/c
    else
        error "下载失败，请检查网络是否通畅"
    fi
}

# ============== 卸载清理 ==============
uninstall_all() {
    title "卸载服务与清理"
    read -rp "确定彻底卸载 sing-box 及其所有用户配置？[y/N]: " CONFIRM
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && warn "取消操作" && return
    sbox_service_ctrl stop
    sbox_service_ctrl disable
    if [[ "$OS_TYPE" == "alpine" ]]; then
        rm -f /etc/init.d/sing-box
    else
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload 2>/dev/null
    fi
    crontab -l 2>/dev/null | grep -v "check-expire" | crontab - 2>/dev/null
    rm -rf "$SBOX_DIR" "$SBOX_BIN" /usr/local/bin/singbox_manager.sh /usr/local/bin/c
    info "卸载清理完毕！"
    exit 0
}

# ============== 外部 CLI 参数调用 ==============
if [[ "$1" == "--check-expire" ]]; then
    check_expire
    exit 0
fi

# ============== 主控制菜单 ==============
main_menu() {
    install_shortcut
    while true; do
        clear
        normalize_user_db
        load_meta
        local S_STATUS="${RED}● 已停止${NC}"
        sbox_service_ctrl status && S_STATUS="${GREEN}● 运行中${NC}"

        local PROTO_LIST=""
        has_reality     && PROTO_LIST="Reality"
        has_shadowsocks && PROTO_LIST="${PROTO_LIST:+$PROTO_LIST+}SS"
        has_ws          && PROTO_LIST="${PROTO_LIST:+$PROTO_LIST+}WS"
        has_anytls      && PROTO_LIST="${PROTO_LIST:+$PROTO_LIST+}AnyTLS"
        [[ -z "$PROTO_LIST" ]] && PROTO_LIST="未搭建节点"

        local U_TOTAL=0 U_ACT=0
        [[ -f "$USER_DB" ]] && U_TOTAL=$(wc -l < "$USER_DB")
        [[ -f "$USER_DB" ]] && U_ACT=$(grep -c ":active:" "$USER_DB" 2>/dev/null || echo 0)

        echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║${NC}   ${CYAN}sing-box 极简控制台 (Debian/Alpine)${NC}        ${BLUE}║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}   系统: ${GREEN}${OS_TYPE}${NC}  状态: ${S_STATUS}               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   节点: ${YELLOW}${PROTO_LIST}${NC}                          ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   用户: ${GREEN}${U_ACT}${NC} 活跃 / ${U_TOTAL} 总数                   ${BLUE}║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}[节点搭建]${NC}                                   ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}1.${NC} 一键安装并配置节点                         ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}2.${NC} 节点协议管理 (添加 / 移除)                ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}3.${NC} 查看节点运行状态与配置                     ${BLUE}║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}[用户管理]${NC}                                   ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}4.${NC} 新建用户          ${GREEN}5.${NC} 删除用户            ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}6.${NC} 禁用用户          ${GREEN}7.${NC} 启用用户            ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}8.${NC} 用户续期          ${GREEN}9.${NC} 用户列表            ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}10.${NC} 查看分享链接                              ${BLUE}║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}[系统维护]${NC}                                   ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}11.${NC} 更新控制台脚本   ${RED}12.${NC} 卸载 sing-box         ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}0.${NC} 退出控制台                                 ${BLUE}║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
        echo -ne " 请输入选项编号 » "
        read -r CHOICE

        case $CHOICE in
            1)  set_shanghai_timezone; install_sbox; init_config; setup_cron ;;
            2)  init_config ;;
            3)  show_info ;;
            4)  add_user ;;
            5)  delete_user ;;
            6)  toggle_user disable ;;
            7)  toggle_user enable ;;
            8)  renew_user ;;
            9)  list_users ;;
            10) show_user_link ;;
            11) update_script ;;
            12) uninstall_all ;;
            0)  echo -e "\n${GREEN}已退出控制台。快捷命令随时输入 c 即可唤起。${NC}\n"; exit 0 ;;
            *)  warn "无效输入，请重新选择" ;;
        esac

        echo ""
        echo -ne "${BLUE}按回车键返回主菜单...${NC}"
        read -r _
    done
}

# 脚本入口
main_menu
