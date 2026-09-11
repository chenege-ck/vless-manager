#!/bin/bash
# 多协议节点管理脚本 (sing-box) - Alpine Linux 专用 v1.4
# Reality + Shadowsocks + WS+TLS + Hysteria2 + AnyTLS + 用户管理（创建/到期/续期）

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============== 路径 ==============
SBOX_BIN="/usr/local/bin/sing-box"
SBOX_DIR="/etc/sing-box"
SBOX_CONFIG="${SBOX_DIR}/config.json"
USER_DB="${SBOX_DIR}/users.db"
META_REALITY="${SBOX_DIR}/meta-reality.conf"
META_SS="${SBOX_DIR}/meta-ss.conf"
META_WS="${SBOX_DIR}/meta-ws.conf"
META_HY2="${SBOX_DIR}/meta-hy2.conf"
META_ANYTLS="${SBOX_DIR}/meta-anytls.conf"
SBOX_INIT="/etc/init.d/sing-box"
CRON_JOB="/etc/periodic/15min/sbox-check-expire"
SELF_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0")"

# Hysteria2（独立官方二进制，独立 OpenRC 服务）
HY_BIN="/usr/local/bin/hysteria"
HY_DIR="/etc/hysteria"
HY_CONF="${HY_DIR}/config.yaml"
HY_CERT_F="${HY_DIR}/server.crt"
HY_KEY_F="${HY_DIR}/server.key"
HY_INIT="/etc/init.d/hysteria-server"

# ============== 默认端口 ==============
SS_PORT_DEFAULT=8668
HY2_PORT_DEFAULT=8999
ANYTLS_PORT_DEFAULT=8585

# ============== 工具函数 ==============
info()  { echo -e "${GREEN}  ✓${NC}  $1"; }
warn()  { echo -e "${YELLOW}  ⚠${NC}  $1"; }
error() { echo -e "${RED}  ✗${NC}  $1"; }
title() { echo -e "\n${BLUE}┌─${NC} ${CYAN}$1${NC}"; echo -e "${BLUE}└────────────────────────────${NC}"; }

read_kv() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 1
    awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file"
}

validate_username() {
    local value="$1"
    [[ -z "$value" ]] && { error "用户名不能为空"; return 1; }
    [[ "$value" == *:* ]] && { error "用户名不能包含冒号"; return 1; }
    [[ "$value" == *[[:space:]]* ]] && { error "用户名不能包含空格或换行"; return 1; }
    if (( ${#value} > 20 )); then
        error "用户名过长（最多 20 个字符）"
        return 1
    fi
    return 0
}

validate_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || {
        error "UUID 格式异常"
        return 1
    }
}

user_exists() {
    awk -F: -v n="$1" '$1==n {found=1; exit} END {exit !found}' "$USER_DB" 2>/dev/null
}

get_user_field() {
    awk -F: -v n="$1" -v f="$2" '$1==n {print $f; exit}' "$USER_DB" 2>/dev/null
}

# ============== 自下载修复（防止 bash <(curl) 管道运行 $0 是管道） ==============
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
[[ $EUID -ne 0 ]] && error "请用 root 运行此脚本" && exit 1

# ============== 系统检查（仅 Alpine） ==============
check_system() {
    local OS_ID
    OS_ID=$(awk -F= '/^ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null)
    if [[ "$OS_ID" != "alpine" ]]; then
        error "本脚本仅支持 Alpine Linux"
        exit 1
    fi
}

# ============== 时区 ==============
set_shanghai_timezone() {
    apk add --no-cache tzdata >/dev/null 2>&1
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    echo "Asia/Shanghai" > /etc/timezone
    info "系统时区已设置为 Asia/Shanghai"
}

# ============== 上海时间工具 ==============
now_shanghai_ts() { TZ=Asia/Shanghai date +%s; }

expire_noon_str() {
    local days="$1"
    TZ=Asia/Shanghai date -d "+${days} days 12:00:00" "+%Y-%m-%d_%H-%M-%S" 2>/dev/null
}

expire_to_ts() {
    local expire="$1"
    if [[ "$expire" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
        local d="${expire%%_*}" t="${expire#*_}"
        TZ=Asia/Shanghai date -d "${d} ${t//-/:}" +%s 2>/dev/null; return
    fi
    TZ=Asia/Shanghai date -d "$expire" +%s 2>/dev/null
}

expire_display() {
    local expire="$1"
    if [[ "$expire" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
        local d="${expire%%_*}" t="${expire#*_}"; echo "${d} ${t//-/:}"
    else
        echo "$expire"
    fi
}

# ============== 获取公网 IP ==============
get_public_ip() {
    local ip=""
    ip=$(curl -s4 --max-time 5 ip.sb 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s4 --max-time 5 api.ipify.org 2>/dev/null)
    echo "${ip:-<请手动填写服务器IP>}"
}

# ============== 端口检查 ==============
check_port()     { ss -tlnp 2>/dev/null | grep -q ":${1} " && return 1 || return 0; }
check_port_udp() { ss -ulnp 2>/dev/null | grep -q ":${1} " && return 1 || return 0; }

# ============== 用户数据库格式化 ==============
# 格式: NAME:UUID:EXPIRE:STATUS:NODE  (NODE 仅用于 reality/ws/both)
normalize_user_db() {
    [[ ! -f "$USER_DB" ]] && return 0
    python3 - <<PYEOF
from pathlib import Path
import re

p = Path("$USER_DB")
lines = p.read_text(encoding="utf-8", errors="ignore").splitlines()
out = []
changed = False

def normalize_expire(exp):
    exp = exp.strip()
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", exp):
        return exp + "_12-00-00"
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}", exp):
        return exp
    return exp

for line in lines:
    if not line.strip():
        continue
    parts = line.rstrip("\n").split(":")
    if len(parts) == 4:
        name, uuid, expire, status = parts
        node = "both"
        changed = True
    elif len(parts) >= 5:
        name, uuid, expire, status, node = parts[0], parts[1], parts[2], parts[3], parts[4] or "both"
    else:
        continue
    expire2 = normalize_expire(expire)
    if expire2 != expire:
        changed = True
    out.append(":".join([name, uuid, expire2, status, node]))

if changed:
    p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
}

# ============== 加载元数据 ==============
load_meta() {
    REALITY_PRIVATE_KEY="" REALITY_PUBLIC_KEY="" REALITY_SNI=""
    REALITY_PORT="" REALITY_SHORTID=""
    SS_PORT="" SS_METHOD="" SS_PASSWORD=""
    WS_PORT="" WS_PATH="" WS_DOMAIN="" WS_TLS="" CERT_DIR=""
    HY2_PORT="" HY2_PASSWORD="" HY2_SNI=""
    ANYTLS_PORT="" ANYTLS_PASSWORD="" ANYTLS_SNI=""
    ANYTLS_PRIVATE_KEY="" ANYTLS_PUBLIC_KEY="" ANYTLS_SHORTID=""

    if [[ -f "$META_REALITY" ]]; then
        REALITY_PRIVATE_KEY=$(read_kv "$META_REALITY" "REALITY_PRIVATE_KEY")
        REALITY_PUBLIC_KEY=$(read_kv "$META_REALITY" "REALITY_PUBLIC_KEY")
        REALITY_SNI=$(read_kv "$META_REALITY" "REALITY_SNI")
        REALITY_PORT=$(read_kv "$META_REALITY" "REALITY_PORT")
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
        WS_TLS=$(read_kv "$META_WS" "WS_TLS")
        CERT_DIR=$(read_kv "$META_WS" "CERT_DIR")
        CERT_DIR=${CERT_DIR:-/etc/sing-box/ssl}
    fi
    if [[ -f "$META_HY2" ]]; then
        HY2_PORT=$(read_kv "$META_HY2" "HY2_PORT")
        HY2_PASSWORD=$(read_kv "$META_HY2" "HY2_PASSWORD")
        HY2_SNI=$(read_kv "$META_HY2" "HY2_SNI")
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

# ============== 节点存在检查 ==============
has_reality()     { [[ -f "$META_REALITY" ]]; }
has_shadowsocks() { [[ -f "$META_SS" ]]; }
has_ws()          { [[ -f "$META_WS" ]]; }
has_hy2()         { [[ -f "$META_HY2" ]]; }
has_anytls()      { [[ -f "$META_ANYTLS" ]]; }

# ============== sing-box 配置校验 ==============
validate_sbox_config() {
    [[ ! -f "$SBOX_CONFIG" ]] && error "配置文件不存在: $SBOX_CONFIG" && return 1
    python3 -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8'))" "$SBOX_CONFIG" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        error "config.json 不是合法 JSON"; return 1
    fi
    local VALIDATE_OUTPUT
    VALIDATE_OUTPUT=$("$SBOX_BIN" check -c "$SBOX_CONFIG" 2>&1)
    if [[ $? -ne 0 ]]; then
        error "sing-box 配置校验失败:"
        echo "$VALIDATE_OUTPUT" | while IFS= read -r line; do
            echo -e "  ${RED}${line}${NC}"
        done
        return 1
    fi
    return 0
}

# ============== 启动 sing-box（OpenRC） ==============
_start_sbox() {
    validate_sbox_config || return 1
    rc-update add sing-box default >/dev/null 2>&1
    rc-service sing-box restart >/dev/null 2>&1
    sleep 1
    if rc-service sing-box status 2>/dev/null | grep -q started; then
        info "sing-box 已启动"; return 0
    else
        error "sing-box 启动失败，运行 cat /var/log/sing-box.log 查看日志"
        return 1
    fi
}

# ============================================================
# 安装依赖
# ============================================================
install_deps() {
    title "安装依赖..."
    apk update -q
    apk add --no-cache curl openssl python3 bash coreutils iproute2 ca-certificates >/dev/null 2>&1
    [[ $? -ne 0 ]] && error "依赖安装失败" && return 1
    info "依赖安装完成"
}

# ============================================================
# 安装 sing-box（从 GitHub Releases 下载静态二进制）
# ============================================================
install_sbox() {
    title "安装 sing-box..."
    if [[ -x "$SBOX_BIN" ]]; then
        if "$SBOX_BIN" version >/dev/null 2>&1; then
            warn "sing-box 已安装，跳过安装步骤"
            return 0
        else
            warn "检测到已安装的 sing-box 无法执行（常见于误装 glibc 版本，Alpine 需要 musl 版），将重新安装"
            rm -f "$SBOX_BIN"
        fi
    fi
    install_deps || return 1

    local ARCH
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l)  ARCH="armv7" ;;
        *) error "不支持的架构: $ARCH"; return 1 ;;
    esac

    info "获取 sing-box 最新版本..."
    local VER
    VER=$(curl -fsSL -H "User-Agent: Mozilla/5.0" "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
          | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name','').lstrip('v'))" 2>/dev/null)
    [[ -z "$VER" ]] && { error "无法获取 sing-box 最新版本"; return 1; }

    # 注意：Alpine 是 musl libc，必须下载 -musl 后缀的静态二进制，
    # 普通版本是动态链接 glibc 的，在 Alpine 上会静默执行失败
    local URL="https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${ARCH}-musl.tar.gz"
    info "下载: ${URL}"
    curl -fsSL -H "User-Agent: Mozilla/5.0" "$URL" -o /tmp/sing-box.tar.gz || { error "下载失败"; return 1; }
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/
    local DIR_NAME="sing-box-${VER}-linux-${ARCH}-musl"
    cp "/tmp/${DIR_NAME}/sing-box" "$SBOX_BIN"
    chmod +x "$SBOX_BIN"
    rm -rf /tmp/sing-box.tar.gz "/tmp/${DIR_NAME}"

    [[ -x "$SBOX_BIN" ]] || { error "sing-box 安装失败"; return 1; }
    mkdir -p "$SBOX_DIR"
    touch "$USER_DB" && chmod 600 "$USER_DB"

    cat > "$SBOX_INIT" <<'EOF'
#!/sbin/openrc-run
name="sing-box"
description="sing-box service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"

depend() {
    need net
    after firewall
}
EOF
    chmod +x "$SBOX_INIT"

    info "sing-box 安装成功: $($SBOX_BIN version 2>/dev/null | head -1)"
}

# ============================================================
# 卸载
# ============================================================
uninstall_sbox() {
    title "卸载所有节点..."
    read -rp "确认卸载？将删除所有配置、证书和用户数据 [y/N]: " CONFIRM
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && warn "已取消" && return

    rc-service sing-box stop 2>/dev/null
    rc-update del sing-box default 2>/dev/null
    rc-service hysteria-server stop 2>/dev/null
    rc-update del hysteria-server default 2>/dev/null

    rm -f "$SBOX_BIN" "$SBOX_INIT" "$HY_BIN" "$HY_INIT" "$CRON_JOB"
    rm -rf "$SBOX_DIR" "$HY_DIR"
    info "已完全卸载"
    exit 0
}

# ============================================================
# 生成 Reality 密钥对
# ============================================================
gen_keypair() {
    local OUTPUT
    OUTPUT=$("$SBOX_BIN" generate reality-keypair 2>&1)
    if [[ $? -ne 0 ]]; then
        error "sing-box generate reality-keypair 执行失败:"
        echo "$OUTPUT"
    fi
    PRIVATE_KEY=$(echo "$OUTPUT" | grep -i "PrivateKey" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$OUTPUT" | grep -i "PublicKey" | awk '{print $NF}')
}

# ============================================================
# 根据已有 meta 重建 sing-box config.json
# ============================================================
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

    python3 - <<PYEOF
import json, os

cfg = {"log": {"level": "warn", "timestamp": True}, "inbounds": [], "outbounds": []}

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
        "method": os.environ["SS_METHOD"], "password": os.environ["SS_PASSWORD"]
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

cfg["outbounds"] = [{"type": "direct", "tag": "direct"}, {"type": "block", "tag": "block"}]
cfg["route"] = {
    "rules": [
        {"protocol": "dns", "action": "hijack-dns"},
        {"action": "sniff"}
    ],
    "final": "direct"
}

with open(os.environ["SBOX_CONFIG"], "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF
    # 重建配置后，自动把 DB 里所有 active 用户重新注入，避免 users 为空导致节点无法连接
    _inject_all_users
}

# ============================================================
# 注入用户到 config.json（Reality 和 WS，按 UUID 区分）
# ============================================================
_inject_user() {
    local UUID=$1 NAME=$2 NODE=$3

    INJECT_UUID="$UUID" INJECT_NAME="$NAME" INJECT_NODE="$NODE" \
    INJECT_CONFIG="$SBOX_CONFIG" python3 - <<'PYEOF'
import json, os
uuid = os.environ["INJECT_UUID"]
name = os.environ["INJECT_NAME"]
node = os.environ["INJECT_NODE"]
cfg_path = os.environ["INJECT_CONFIG"]

with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

VLESS_TAGS = {"inbound-reality", "inbound-ws"}

for inbound in cfg.get("inbounds", []):
    tag = inbound.get("tag", "")
    users = inbound.get("users")
    if users is None or tag not in VLESS_TAGS:
        continue
    inbound["users"] = [u for u in users if u.get("uuid") != uuid]
    should_add = node == "both" or (node == "reality" and tag == "inbound-reality") or (node == "ws" and tag == "inbound-ws")
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
    while IFS=: read -r NAME UUID EXPIRE STATUS NODE; do
        [[ "$STATUS" != "active" ]] && continue
        NODE=${NODE:-both}
        _inject_user "$UUID" "$NAME" "$NODE"
    done < "$USER_DB"
}

# ============================================================
# 初始化 Reality 节点
# ============================================================
init_reality() {
    title "配置 VLESS + Reality"
    if has_reality; then
        warn "Reality 已存在，重新配置会生成新密钥，现有用户链接将失效"
        read -rp "确认继续？[y/N]: " C
        [[ "$C" != "y" && "$C" != "Y" ]] && return
    fi

    gen_keypair
    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        error "密钥生成失败"; return 1
    fi

    while true; do
        read -rp "监听端口 [默认 8443]: " REALITY_PORT
        REALITY_PORT=${REALITY_PORT:-8443}
        if ! [[ "$REALITY_PORT" =~ ^[0-9]+$ ]] || (( REALITY_PORT < 1 || REALITY_PORT > 65535 )); then
            error "端口必须是 1-65535"; continue
        fi
        check_port "$REALITY_PORT" && break || warn "端口 ${REALITY_PORT} 已被占用"
    done

    read -rp "伪装域名 [默认 www.microsoft.com]: " REALITY_SNI
    REALITY_SNI=${REALITY_SNI:-www.microsoft.com}
    local REALITY_SHORTID
    REALITY_SHORTID=$(openssl rand -hex 8)

    mkdir -p "$SBOX_DIR"
    cat > "$META_REALITY" <<EOF
REALITY_PRIVATE_KEY=${PRIVATE_KEY}
REALITY_PUBLIC_KEY=${PUBLIC_KEY}
REALITY_SNI=${REALITY_SNI}
REALITY_PORT=${REALITY_PORT}
REALITY_SHORTID=${REALITY_SHORTID}
EOF
    chmod 600 "$META_REALITY"

    rebuild_config
    _inject_all_users
    _start_sbox
    info "Reality 节点配置完成"
    info "公钥: ${PUBLIC_KEY}"
}

# ============================================================
# 单独修改 Reality 监听端口（不改密钥，不影响已有用户）
# ============================================================
change_reality_port() {
    title "修改 Reality 监听端口"
    has_reality || { error "尚未配置 Reality 节点"; return; }
    load_meta
    echo -e "当前端口: ${CYAN}${REALITY_PORT}${NC}"
    local NEW_PORT
    while true; do
        read -rp "新端口: " NEW_PORT
        [[ -z "$NEW_PORT" ]] && { warn "已取消"; return; }
        if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || (( NEW_PORT < 1 || NEW_PORT > 65535 )); then
            error "端口必须是 1-65535 的数字"; continue
        fi
        [[ "$NEW_PORT" == "$REALITY_PORT" ]] && { warn "与当前端口相同"; return; }
        check_port "$NEW_PORT" && break || warn "端口 ${NEW_PORT} 已被占用，请换一个"
    done
    sed -i "s|^REALITY_PORT=.*|REALITY_PORT=${NEW_PORT}|" "$META_REALITY"
    rebuild_config
    _inject_all_users
    _start_sbox
    info "端口已修改为 ${NEW_PORT}，请重新获取分享链接"
}

# ============================================================
# 初始化 Shadowsocks 节点
# ============================================================
init_shadowsocks() {
    title "配置 Shadowsocks"
    if has_shadowsocks; then
        warn "Shadowsocks 已存在，重新配置会生成新密码"
        read -rp "确认继续？[y/N]: " C
        [[ "$C" != "y" && "$C" != "Y" ]] && return
    fi
    local PORT=${SS_PORT_DEFAULT}
    while true; do
        read -rp "监听端口 [默认 ${PORT}]: " PORT
        PORT=${PORT:-$SS_PORT_DEFAULT}
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
            error "端口必须是 1-65535"; continue
        fi
        check_port "$PORT" && break || warn "端口 ${PORT} 已被占用"
    done

    SS_PORT=$PORT
    SS_METHOD="2022-blake3-aes-128-gcm"
    SS_PASSWORD=$(openssl rand -base64 16)
    [[ -n "$SS_PASSWORD" ]] || { error "密码生成失败"; return 1; }

    mkdir -p "$SBOX_DIR"
    cat > "$META_SS" <<EOF
SS_PORT=${SS_PORT}
SS_METHOD=${SS_METHOD}
SS_PASSWORD=${SS_PASSWORD}
EOF
    chmod 600 "$META_SS"

    rebuild_config || return 1
    _start_sbox || return 1
    info "Shadowsocks 配置完成"
    _print_ss_link
}

_print_ss_link() {
    load_meta
    [[ -z "$SS_PASSWORD" ]] && return
    local SERVER_IP USERINFO
    SERVER_IP=$(get_public_ip)
    USERINFO=$(printf '%s' "${SS_METHOD}:${SS_PASSWORD}" | base64 -w0)
    echo ""
    echo -e "${GREEN}===== Shadowsocks 信息 =====${NC}"
    echo -e "地址   : ${SERVER_IP}"
    echo -e "端口   : ${SS_PORT}"
    echo -e "加密   : ${SS_METHOD}"
    echo -e "密码   : ${SS_PASSWORD}"
    echo -e "${CYAN}分享链接:${NC}"
    echo "ss://${USERINFO}@${SERVER_IP}:${SS_PORT}#Shadowsocks-${SS_PORT}"
    echo ""
}

# ============================================================
# 初始化 WS+TLS 节点（自签证书，配合 CF 等前置代理使用）
# ============================================================
init_ws_cf() {
    title "配置 VLESS + WS + TLS"
    while true; do
        read -rp "监听端口 [默认 8445]: " WS_PORT
        WS_PORT=${WS_PORT:-8445}
        if ! [[ "$WS_PORT" =~ ^[0-9]+$ ]] || (( WS_PORT < 1 || WS_PORT > 65535 )); then
            error "端口必须是 1-65535"; continue
        fi
        check_port "$WS_PORT" && break || warn "端口 ${WS_PORT} 已被占用"
    done
    read -rp "WS 路径 [默认 /vless]: " WS_PATH
    WS_PATH=${WS_PATH:-/vless}
    read -rp "你的域名（已在 CF 等前置解析）: " WS_DOMAIN
    [[ -z "$WS_DOMAIN" ]] && error "域名不能为空" && return 1

    CERT_DIR="/etc/sing-box/ssl"
    mkdir -p "$CERT_DIR"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "${CERT_DIR}/ws.key" -out "${CERT_DIR}/ws.crt" \
        -days 3650 -subj "/CN=${WS_DOMAIN}" \
        -addext "subjectAltName=DNS:${WS_DOMAIN}" 2>/dev/null || {
        error "自签证书生成失败"; return 1
    }
    chmod 640 "${CERT_DIR}/ws.key"
    chmod 644 "${CERT_DIR}/ws.crt"

    cat > "$META_WS" <<EOF
WS_PORT=${WS_PORT}
WS_PATH=${WS_PATH}
WS_DOMAIN=${WS_DOMAIN}
WS_TLS=tls
CERT_DIR=${CERT_DIR}
EOF
    chmod 600 "$META_WS"

    rebuild_config || return 1
    _inject_all_users
    _start_sbox || return 1
    info "WS+TLS 节点配置完成"
    echo -e "${YELLOW}提示：${NC}${WS_DOMAIN} 需解析到本机，并在前置代理（如 CF）开启 TLS（完全/Full 模式）"
}

# ============================================================
# Hysteria2（独立官方 hysteria 二进制，独立 OpenRC 服务）
# ============================================================
detect_hyst_arch(){
    case "$(uname -m)" in
        x86_64|amd64)  echo "hysteria-linux-amd64" ;;
        aarch64|arm64) echo "hysteria-linux-arm64" ;;
        armv7l|armv6l) echo "hysteria-linux-arm" ;;
        *) return 1 ;;
    esac
}

hy_installed_ver(){
    [[ -x "$HY_BIN" ]] || return 1
    "$HY_BIN" version 2>/dev/null | head -1 | sed -E 's/.*v([0-9]+\.[0-9]+\.[0-9]+).*/\1/'
}

install_hysteria(){
    title "安装官方 Hysteria"
    if [[ -x "$HY_BIN" ]]; then
        info "已安装 Hysteria: $(hy_installed_ver || echo 未知)"
        return 0
    fi
    local FN DOWNLOAD
    FN=$(detect_hyst_arch) || { error "不支持的架构: $(uname -m)"; return 1; }
    DOWNLOAD="https://download.hysteria.network/app/latest/${FN}"
    info "下载: ${DOWNLOAD}"
    curl -fsSL --max-time 120 "$DOWNLOAD" -o "$HY_BIN" || { error "下载失败"; return 1; }
    chmod +x "$HY_BIN"
    [[ -x "$HY_BIN" ]] || { error "安装失败"; return 1; }
    info "hysteria 安装成功: $("$HY_BIN" version | head -1)"
}

_gen_hy2_cert(){
    local SNI="$1"
    mkdir -p "$HY_DIR"
    if [[ -s "$HY_CERT_F" && -s "$HY_KEY_F" ]]; then
        warn "证书已存在，保留现有证书"
        return 0
    fi
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$HY_KEY_F" -out "$HY_CERT_F" \
        -days 3650 -subj "/CN=${SNI}" \
        -addext "subjectAltName=DNS:${SNI}" >/dev/null 2>&1
    [[ -s "$HY_CERT_F" && -s "$HY_KEY_F" ]] || { error "证书生成失败"; return 1; }
    chmod 644 "$HY_CERT_F"; chmod 600 "$HY_KEY_F"
    return 0
}

_setup_hy2_service(){
    cat > "$HY_INIT" <<EOF
#!/sbin/openrc-run
name="hysteria-server"
description="Hysteria2 server (official)"
command="${HY_BIN}"
command_args="server -c ${HY_CONF}"
command_background=true
pidfile="/run/hysteria-server.pid"
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.log"

depend() {
    need net
    after firewall
}
EOF
    chmod +x "$HY_INIT"
}

_start_hy2_service(){
    rc-update add hysteria-server default >/dev/null 2>&1
    rc-service hysteria-server restart >/dev/null 2>&1
    sleep 1
    if rc-service hysteria-server status 2>/dev/null | grep -q started; then
        info "hysteria 服务运行中"; return 0
    else
        error "hysteria 启动失败，运行 cat /var/log/hysteria.log 查看日志"
        return 1
    fi
}

init_hy2() {
    title "配置 Hysteria2（独立官方 hysteria）"

    if has_hy2; then
        warn "Hysteria2 已存在，重新配置将覆盖并重启服务"
        read -rp "确认继续？[y/N]: " C
        [[ "$C" != "y" && "$C" != "Y" ]] && warn "已取消" && return
    fi

    local PORT SNI UP DOWN PASS
    read -rp "监听端口 [默认 ${HY2_PORT_DEFAULT}]: " PORT
    PORT=${PORT:-$HY2_PORT_DEFAULT}
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
        error "端口必须是 1-65535"; return 1
    fi
    check_port_udp "$PORT" || { error "UDP 端口 ${PORT} 已被占用"; return 1; }

    read -rp "伪装域名（SNI）[默认 www.bing.com]: " SNI
    SNI=${SNI:-www.bing.com}

    read -rp "服务器上行带宽 Mbps（填整数，启用 brutal 拥塞控制）[如 100]: " UP
    read -rp "服务器下行带宽 Mbps（填整数，启用 brutal 拥塞控制）[如 100]: " DOWN
    UP=${UP:-0}; DOWN=${DOWN:-0}
    if (( UP <= 0 )) || (( DOWN <= 0 )); then
        warn "带宽未填或为 0，将不启用 brutal（用默认 BBR，带宽不受限）"
    fi

    PASS=$(openssl rand -hex 16)
    [[ -n "$PASS" ]] || { error "密码生成失败"; return 1; }

    _gen_hy2_cert "$SNI" || return 1

    mkdir -p "$HY_DIR"
    cat > "$HY_CONF" <<EOF2
listen: :${PORT}
obfs:
  type: salamander
  salamander:
    password: ${PASS}
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 30s
  maxIncomingStreams: 1024
auth:
  type: password
  password: ${PASS}
masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
bandwidth:
  up: ${UP} mbps
  down: ${DOWN} mbps
tls:
  cert: ${HY_CERT_F}
  key: ${HY_KEY_F}
EOF2

    cat > "$META_HY2" <<EOF
HY2_PORT=${PORT}
HY2_SNI=${SNI}
HY2_PASSWORD=${PASS}
HY2_UP=${UP}
HY2_DOWN=${DOWN}
EOF
    chmod 600 "$META_HY2" "$HY_CONF"

    install_hysteria || return 1
    _setup_hy2_service || return 1
    _start_hy2_service || return 1
    info "Hysteria2 配置完成（端口 ${PORT}/UDP，带宽 up=${UP} down=${DOWN} Mbps）"
    _print_hy2_link
}

remove_hy2() {
    has_hy2 || { error "Hysteria2 未启用"; return 1; }
    read -rp "确认移除 Hysteria2（停止并删除服务/配置/证书）？[y/N]: " C
    [[ "$C" != "y" && "$C" != "Y" ]] && warn "已取消" && return
    rc-service hysteria-server stop 2>/dev/null
    rc-update del hysteria-server default 2>/dev/null
    rm -f "$HY_INIT"
    rm -rf "$HY_DIR"
    rm -f "$META_HY2"
    info "Hysteria2 已移除（二进制保留，可用菜单重装）"
}

_print_hy2_link() {
    has_hy2 || return 1
    local PORT PASS SNI SERVER_IP UP DOWN
    PORT=$(read_kv "$META_HY2" HY2_PORT); PASS=$(read_kv "$META_HY2" HY2_PASSWORD)
    SNI=$(read_kv "$META_HY2" HY2_SNI); SERVER_IP=$(get_public_ip)
    UP=$(read_kv "$META_HY2" HY2_UP); DOWN=$(read_kv "$META_HY2" HY2_DOWN)
    echo ""
    echo -e "${GREEN}===== Hysteria2 信息 =====${NC}"
    echo -e "地址   : ${SERVER_IP}"
    echo -e "端口   : ${PORT} (UDP)"
    echo -e "密码   : ${PASS}"
    echo -e "SNI    : ${SNI}"
    echo -e "证书   : 自签名，客户端需 insecure=1"
    echo -e "混淆   : Salamander（密码同值）"
    echo -e "带宽   : 上行 ${UP:-0} / 下行 ${DOWN:-0} Mbps (brutal)"
    echo -e "${CYAN}分享链接:${NC}"
    echo "hy2://${PASS}@${SERVER_IP}:${PORT}/?sni=${SNI}&insecure=1&obfs=salamander&obfs-password=${PASS}#Hysteria2-${PORT}"
    echo ""
}

show_hy2_link() {
    has_hy2 || { error "Hysteria2 尚未配置"; return 1; }
    _print_hy2_link
}

# ============================================================
# AnyTLS（Reality 伪装）
# ============================================================
init_anytls() {
    title "配置 AnyTLS + Reality"
    if has_anytls; then
        warn "AnyTLS 已存在，重新配置将生成新密码/密钥"
        read -rp "确认继续？[y/N]: " C
        [[ "$C" != "y" && "$C" != "Y" ]] && warn "已取消" && return
    fi

    local PORT SNI
    read -rp "监听端口 [默认 ${ANYTLS_PORT_DEFAULT}]: " PORT
    PORT=${PORT:-$ANYTLS_PORT_DEFAULT}
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
        error "端口必须是 1-65535"; return 1
    fi
    check_port "$PORT" || { error "端口 ${PORT} 已被占用"; return 1; }

    read -rp "伪装域名 [默认 www.microsoft.com]: " SNI
    SNI=${SNI:-www.microsoft.com}

    gen_keypair
    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        error "密钥生成失败"; return 1
    fi

    ANYTLS_PORT=$PORT
    ANYTLS_PASSWORD=$(openssl rand -hex 16)
    [[ -n "$ANYTLS_PASSWORD" ]] || { error "密码生成失败"; return 1; }
    local ANYTLS_SHORTID
    ANYTLS_SHORTID=$(openssl rand -hex 8)

    cat > "$META_ANYTLS" <<EOF
ANYTLS_PORT=${ANYTLS_PORT}
ANYTLS_PASSWORD=${ANYTLS_PASSWORD}
ANYTLS_SNI=${SNI}
ANYTLS_PRIVATE_KEY=${PRIVATE_KEY}
ANYTLS_PUBLIC_KEY=${PUBLIC_KEY}
ANYTLS_SHORTID=${ANYTLS_SHORTID}
EOF
    chmod 600 "$META_ANYTLS"

    rebuild_config || return 1
    _start_sbox || return 1
    info "AnyTLS 配置完成（端口 ${ANYTLS_PORT}，Reality 伪装）"
    _print_anytls_link
}

remove_anytls() {
    has_anytls || { error "AnyTLS 未启用"; return 1; }
    read -rp "确认移除 AnyTLS？[y/N]: " C
    [[ "$C" != "y" && "$C" != "Y" ]] && warn "已取消" && return
    rm -f "$META_ANYTLS"
    rebuild_config
    _inject_all_users
    _start_sbox
    info "AnyTLS 已移除"
}

_print_anytls_link() {
    has_anytls || return 1
    local AT_PORT AT_PASSWORD AT_SNI AT_PUBKEY AT_SHORTID SERVER_IP
    AT_PORT=$(read_kv "$META_ANYTLS" "ANYTLS_PORT")
    AT_PASSWORD=$(read_kv "$META_ANYTLS" "ANYTLS_PASSWORD")
    AT_SNI=$(read_kv "$META_ANYTLS" "ANYTLS_SNI")
    AT_PUBKEY=$(read_kv "$META_ANYTLS" "ANYTLS_PUBLIC_KEY")
    AT_SHORTID=$(read_kv "$META_ANYTLS" "ANYTLS_SHORTID")
    SERVER_IP=$(get_public_ip)
    echo ""
    echo -e "${GREEN}===== AnyTLS 信息 =====${NC}"
    echo -e "地址   : ${SERVER_IP}"
    echo -e "端口   : ${AT_PORT}"
    echo -e "密码   : ${AT_PASSWORD}"
    echo -e "SNI    : ${AT_SNI}"
    echo -e "公钥   : ${AT_PUBKEY}"
    echo -e "ShortID: ${AT_SHORTID}"
    echo -e "伪装   : Reality"
    echo ""
    echo -e "${CYAN}客户端配置示例:${NC}"
    echo "anytls://${AT_PASSWORD}@${SERVER_IP}:${AT_PORT}/?sni=${AT_SNI}&pbk=${AT_PUBKEY}&sid=${AT_SHORTID}&fp=chrome&security=reality#AnyTLS-${AT_PORT}"
    echo ""
}

show_anytls_link() {
    has_anytls || { error "AnyTLS 尚未配置"; return 1; }
    _print_anytls_link
}

# ============================================================
# 节点配置菜单（安装/移除各协议）
# ============================================================
node_menu() {
    title "节点配置"
    mkdir -p "$SBOX_DIR"
    touch "$USER_DB" && chmod 600 "$USER_DB"
    load_meta

    echo ""
    echo "当前节点状态："
    has_reality     && echo -e "  ${GREEN}✓${NC} Reality 已启用（端口 ${REALITY_PORT}）"     || echo -e "  ${RED}✗${NC} Reality 未启用"
    has_shadowsocks && echo -e "  ${GREEN}✓${NC} Shadowsocks 已启用（端口 ${SS_PORT}）"       || echo -e "  ${RED}✗${NC} Shadowsocks 未启用"
    has_ws          && echo -e "  ${GREEN}✓${NC} WS+TLS 已启用（端口 ${WS_PORT}）"            || echo -e "  ${RED}✗${NC} WS+TLS 未启用"
    has_hy2         && echo -e "  ${GREEN}✓${NC} Hysteria2 已启用（端口 ${HY2_PORT}）"        || echo -e "  ${RED}✗${NC} Hysteria2 未启用"
    has_anytls      && echo -e "  ${GREEN}✓${NC} AnyTLS 已启用（端口 ${ANYTLS_PORT}）"        || echo -e "  ${RED}✗${NC} AnyTLS 未启用"
    echo ""
    echo -e "  ${GREEN}1.${NC} 配置 VLESS + Reality"
    echo -e "  ${GREEN}2.${NC} 配置 Shadowsocks"
    echo -e "  ${GREEN}3.${NC} 配置 VLESS + WS + TLS"
    echo -e "  ${GREEN}4.${NC} 配置 Hysteria2"
    echo -e "  ${GREEN}5.${NC} 配置 AnyTLS"
    echo -e "  ${GREEN}6.${NC} 修改 Reality 端口"
    has_reality     && echo -e "  ${RED}10.${NC} 移除 Reality"
    has_shadowsocks && echo -e "  ${RED}11.${NC} 移除 Shadowsocks"
    has_ws          && echo -e "  ${RED}12.${NC} 移除 WS+TLS"
    has_hy2         && echo -e "  ${RED}13.${NC} 移除 Hysteria2"
    has_anytls      && echo -e "  ${RED}14.${NC} 移除 AnyTLS"
    echo -e "  ${GREEN}0.${NC} 返回"
    echo ""
    read -rp "选择: " MODE_SEL
    case $MODE_SEL in
        1) init_reality ;;
        2) init_shadowsocks ;;
        3) init_ws_cf ;;
        4) init_hy2 ;;
        5) init_anytls ;;
        6) change_reality_port ;;
        10)
            has_reality || { error "Reality 未启用"; return; }
            read -rp "确认移除 Reality？[y/N]: " C
            [[ "$C" != "y" && "$C" != "Y" ]] && return
            rm -f "$META_REALITY"
            rebuild_config; _inject_all_users; _start_sbox
            info "Reality 已移除" ;;
        11)
            has_shadowsocks || { error "SS 未启用"; return; }
            read -rp "确认移除 Shadowsocks？[y/N]: " C
            [[ "$C" != "y" && "$C" != "Y" ]] && return
            rm -f "$META_SS"
            rebuild_config; _inject_all_users; _start_sbox
            info "Shadowsocks 已移除" ;;
        12)
            has_ws || { error "WS 未启用"; return; }
            read -rp "确认移除 WS+TLS？[y/N]: " C
            [[ "$C" != "y" && "$C" != "Y" ]] && return
            rm -f "$META_WS"
            rebuild_config; _inject_all_users; _start_sbox
            info "WS+TLS 已移除" ;;
        13) remove_hy2 ;;
        14) remove_anytls ;;
        0) return ;;
        *) error "无效选择" ;;
    esac
}

# ============================================================
# 打印用户分享链接（Reality / WS，按用户 NODE 权限）
# ============================================================
_print_link() {
    local USERNAME=$1 UUID=$2 EXPIRE=$3 NODE=${4:-both}
    load_meta
    local EXPIRE_SHOW
    EXPIRE_SHOW=$(expire_display "$EXPIRE")

    echo ""
    echo -e "${GREEN}===== 用户信息 =====${NC}"
    echo -e "用户名 : ${USERNAME}"
    echo -e "UUID   : ${UUID}"
    echo -e "到期   : ${EXPIRE_SHOW}"
    echo -e "节点   : ${NODE}"

    if [[ "$NODE" == "reality" || "$NODE" == "both" ]] && has_reality; then
        local SERVER_IP
        SERVER_IP=$(get_public_ip)
        echo ""
        echo -e "${CYAN}── Reality 节点 ──${NC}"
        echo -e "地址   : ${SERVER_IP}"
        echo -e "端口   : ${REALITY_PORT}"
        echo -e "公钥   : ${REALITY_PUBLIC_KEY}"
        echo -e "SNI    : ${REALITY_SNI}"
        echo -e "ShortID: ${REALITY_SHORTID}"
        local LINK="vless://${UUID}@${SERVER_IP}:${REALITY_PORT}/?type=tcp&encryption=none&flow=xtls-rprx-vision&sni=${REALITY_SNI}&fp=chrome&security=reality&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORTID}#${USERNAME}-reality"
        echo -e "${CYAN}分享链接:${NC}"
        echo "$LINK"
    fi

    if [[ "$NODE" == "ws" || "$NODE" == "both" ]] && has_ws; then
        local ENCODED_PATH ENCODED_NAME
        ENCODED_PATH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${WS_PATH}'))")
        ENCODED_NAME=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${USERNAME}-ws'))")
        echo ""
        echo -e "${CYAN}── WS+TLS 节点 ──${NC}"
        echo -e "域名   : ${WS_DOMAIN}"
        echo -e "端口   : ${WS_PORT}"
        echo -e "WS路径 : ${WS_PATH}"
        echo -e "SNI    : ${WS_DOMAIN}"
        local WS_LINK="vless://${UUID}@${WS_DOMAIN}:${WS_PORT}/?type=ws&encryption=none&host=${WS_DOMAIN}&path=${ENCODED_PATH}&security=tls&sni=${WS_DOMAIN}#${ENCODED_NAME}"
        echo -e "${CYAN}分享链接:${NC}"
        echo "$WS_LINK"
    fi
    echo ""
}

# ============================================================
# 创建用户（用户仅归属 Reality / WS，SS·HY2·AnyTLS 为共享单节点）
# ============================================================
add_user() {
    title "创建用户"
    load_meta
    normalize_user_db

    read -rp "用户名（备注用）: " USERNAME
    validate_username "$USERNAME" || return
    if user_exists "$USERNAME"; then
        error "用户 ${USERNAME} 已存在"; return
    fi

    local NODE="both"
    local AVAIL_NODES=()
    has_reality && AVAIL_NODES+=("reality")
    has_ws && AVAIL_NODES+=("ws")

    if [[ ${#AVAIL_NODES[@]} -eq 0 ]]; then
        error "尚未配置 Reality 或 WS 节点，请先在「节点配置」中初始化"
        return
    fi

    if [[ ${#AVAIL_NODES[@]} -eq 1 ]]; then
        NODE="${AVAIL_NODES[0]}"
        local NODE_DESC="Reality"
        [[ "$NODE" == "ws" ]] && NODE_DESC="WS+TLS"
        info "当前仅有 ${NODE_DESC} 节点，用户将加入该节点"
    else
        echo ""
        echo "请选择加入的节点："
        echo -e "  ${GREEN}1.${NC} Reality + WS"
        echo -e "  ${GREEN}2.${NC} 仅 Reality"
        echo -e "  ${GREEN}3.${NC} 仅 WS"
        read -rp "选择 [1/2/3，默认1]: " NODE_SEL
        case ${NODE_SEL:-1} in
            2) NODE="reality" ;;
            3) NODE="ws" ;;
            *) NODE="both" ;;
        esac
    fi

    read -rp "到期天数 [默认 30 天]: " DAYS
    DAYS=${DAYS:-30}
    if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
        error "天数必须是纯数字"; return
    fi

    local EXPIRE UUID
    EXPIRE=$(expire_noon_str "$DAYS")
    [[ -z "$EXPIRE" ]] && { error "到期时间计算失败"; return; }
    UUID=$(cat /proc/sys/kernel/random/uuid)

    echo "${USERNAME}:${UUID}:${EXPIRE}:active:${NODE}" >> "$USER_DB"
    _inject_user "$UUID" "$USERNAME" "$NODE"

    validate_sbox_config || {
        sed -i "/^${USERNAME}:${UUID}:/d" "$USER_DB"
        rebuild_config; _inject_all_users
        error "配置校验失败，已回滚本次添加"; return 1
    }

    _start_sbox || {
        sed -i "/^${USERNAME}:${UUID}:/d" "$USER_DB"
        rebuild_config; _inject_all_users
        error "启动失败，已回滚本次添加"; return 1
    }

    _print_link "$USERNAME" "$UUID" "$EXPIRE" "$NODE"
}

# ============================================================
# 删除用户
# ============================================================
delete_user() {
    title "删除用户"
    normalize_user_db
    list_users_brief

    read -rp "输入用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return
    if ! user_exists "$USERNAME"; then
        error "用户不存在"; return
    fi

    sed -i "/^${USERNAME}:/d" "$USER_DB"
    rebuild_config
    _inject_all_users
    _start_sbox
    info "用户 ${USERNAME} 已删除"
}

# ============================================================
# 启用 / 禁用用户
# ============================================================
toggle_user() {
    local ACTION=$1
    title "${ACTION} 用户"
    normalize_user_db
    list_users_brief

    read -rp "输入用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return
    if ! user_exists "$USERNAME"; then
        error "用户不存在"; return
    fi

    local UUID NODE
    UUID=$(get_user_field "$USERNAME" 2)
    validate_uuid "$UUID" || return
    NODE=$(get_user_field "$USERNAME" 5)
    NODE=${NODE:-both}

    if [[ "$ACTION" == "禁用" ]]; then
        DB_PATH="$USER_DB" TARGET="$USERNAME" python3 - <<'PYEOF'
import os
from pathlib import Path
p = Path(os.environ["DB_PATH"])
out = []
for line in p.read_text(encoding="utf-8", errors="ignore").splitlines():
    parts = line.split(":")
    if parts and parts[0] == os.environ["TARGET"] and len(parts) >= 4:
        parts[3] = "disabled"
    out.append(":".join(parts))
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
        rebuild_config
        _inject_all_users
        _start_sbox
        info "用户 ${USERNAME} 已禁用"
    else
        local EXPIRE EXPIRE_TS NOW_TS
        EXPIRE=$(get_user_field "$USERNAME" 3)
        EXPIRE_TS=$(expire_to_ts "$EXPIRE")
        NOW_TS=$(now_shanghai_ts)
        if [[ -n "$EXPIRE_TS" ]] && (( NOW_TS >= EXPIRE_TS )); then
            warn "用户 ${USERNAME} 已过期，请先续期再启用"
            return
        fi
        DB_PATH="$USER_DB" TARGET="$USERNAME" python3 - <<'PYEOF'
import os
from pathlib import Path
p = Path(os.environ["DB_PATH"])
out = []
for line in p.read_text(encoding="utf-8", errors="ignore").splitlines():
    parts = line.split(":")
    if parts and parts[0] == os.environ["TARGET"] and len(parts) >= 4:
        parts[3] = "active"
    out.append(":".join(parts))
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
        _inject_user "$UUID" "$USERNAME" "$NODE"
        _start_sbox
        info "用户 ${USERNAME} 已启用"
    fi
}

# ============================================================
# 续期用户
# ============================================================
renew_user() {
    title "续期用户"
    normalize_user_db
    list_users_brief

    read -rp "输入用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return
    if ! user_exists "$USERNAME"; then
        error "用户不存在"; return
    fi

    read -rp "续期天数 [默认 30 天]: " DAYS
    DAYS=${DAYS:-30}
    if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
        error "天数必须是纯数字"; return
    fi

    local UUID NODE NEW_EXPIRE
    UUID=$(get_user_field "$USERNAME" 2)
    validate_uuid "$UUID" || return
    NODE=$(get_user_field "$USERNAME" 5)
    NODE=${NODE:-both}
    NEW_EXPIRE=$(expire_noon_str "$DAYS")

    sed -i "s|^${USERNAME}:${UUID}:.*|${USERNAME}:${UUID}:${NEW_EXPIRE}:active:${NODE}|" "$USER_DB"
    _inject_user "$UUID" "$USERNAME" "$NODE"
    _start_sbox
    info "用户 ${USERNAME} 到期时间已更新为 $(expire_display "$NEW_EXPIRE")（已自动启用）"
}

# ============================================================
# 用户列表
# ============================================================
list_users() {
    title "用户列表"
    normalize_user_db
    [[ ! -s "$USER_DB" ]] && warn "暂无用户" && return

    printf "  %-15s %-38s %-20s %-8s %-8s\n" "用户名" "UUID" "到期时间" "状态" "节点"
    echo "  ────────────────────────────────────────────────────────────────────────────────"
    while IFS=: read -r NAME UUID EXPIRE STATUS NODE; do
        NODE=${NODE:-both}
        local COLOR=$NC
        [[ "$STATUS" == "active" ]] && COLOR=$GREEN || COLOR=$RED
        printf "  ${COLOR}%-15s %-38s %-20s %-8s %-8s${NC}\n" "$NAME" "$UUID" "$(expire_display "$EXPIRE")" "$STATUS" "$NODE"
    done < "$USER_DB"
    echo ""
}

list_users_brief() {
    normalize_user_db
    echo ""
    [[ ! -s "$USER_DB" ]] && echo "  （暂无用户）" && echo "" && return
    while IFS=: read -r NAME UUID EXPIRE STATUS NODE; do
        NODE=${NODE:-both}
        printf "  %-15s %s  [%s | %s]\n" "$NAME" "$(expire_display "$EXPIRE")" "$STATUS" "$NODE"
    done < "$USER_DB"
    echo ""
}

show_user_link() {
    title "查看用户分享链接"
    normalize_user_db
    list_users_brief
    read -rp "输入用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return
    if ! user_exists "$USERNAME"; then
        error "用户不存在"; return
    fi
    local UUID EXPIRE NODE STATUS
    UUID=$(get_user_field "$USERNAME" 2)
    EXPIRE=$(get_user_field "$USERNAME" 3)
    STATUS=$(get_user_field "$USERNAME" 4)
    NODE=$(get_user_field "$USERNAME" 5)
    NODE=${NODE:-both}
    [[ "$STATUS" == "disabled" ]] && warn "用户 ${USERNAME} 当前已禁用"
    _print_link "$USERNAME" "$UUID" "$EXPIRE" "$NODE"
}

# ============================================================
# 到期检查（供 crond 调用）
# ============================================================
check_expire() {
    [[ ! -f "$USER_DB" ]] && exit 0
    normalize_user_db
    local NOW_TS CHANGED=0 EXPIRED_UUIDS=""
    NOW_TS=$(now_shanghai_ts)

    while IFS=: read -r NAME UUID EXPIRE STATUS NODE; do
        [[ "$STATUS" != "active" ]] && continue
        local EXPIRE_TS
        EXPIRE_TS=$(expire_to_ts "$EXPIRE")
        [[ -z "$EXPIRE_TS" ]] && continue
        if (( NOW_TS >= EXPIRE_TS )); then
            EXPIRED_UUIDS="${EXPIRED_UUIDS} ${UUID}"
            CHANGED=1
        fi
    done < "$USER_DB"

    if [[ $CHANGED -eq 1 ]]; then
        BATCH_UUIDS="$EXPIRED_UUIDS" DB_PATH="$USER_DB" python3 - <<'PYEOF'
import os
from pathlib import Path
uuids = set(os.environ["BATCH_UUIDS"].split())
p = Path(os.environ["DB_PATH"])
out = []
for line in p.read_text(encoding="utf-8", errors="ignore").splitlines():
    parts = line.split(":")
    if len(parts) >= 2 and parts[1] in uuids:
        if len(parts) < 5:
            parts += ["both"] * (5 - len(parts))
        parts[3] = "disabled"
    out.append(":".join(parts))
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
        rebuild_config
        _inject_all_users
        validate_sbox_config && rc-service sing-box restart >/dev/null 2>&1
    fi
}

setup_cron() {
    mkdir -p /etc/periodic/15min
    cat > "$CRON_JOB" <<EOF
#!/bin/sh
${SELF_PATH} check-expire
EOF
    chmod +x "$CRON_JOB"
    rc-update add crond default >/dev/null 2>&1
    rc-service crond start >/dev/null 2>&1 || rc-service crond restart >/dev/null 2>&1
}

# ============================================================
# 节点信息总览
# ============================================================
show_info() {
    title "节点信息"
    load_meta
    normalize_user_db

    local SBOX_STATUS USER_COUNT ACTIVE_COUNT PUBLIC_IP
    SBOX_STATUS=$(rc-service sing-box status 2>/dev/null | grep -q started && echo active || echo inactive)
    USER_COUNT=0; [[ -f "$USER_DB" ]] && USER_COUNT=$(wc -l < "$USER_DB")
    ACTIVE_COUNT=0; [[ -f "$USER_DB" ]] && ACTIVE_COUNT=$(grep -c ":active:" "$USER_DB" 2>/dev/null || echo 0)
    PUBLIC_IP=$(get_public_ip)

    echo -e "sing-box: $( [[ "$SBOX_STATUS" == "active" ]] && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}已停止${NC}" )"
    echo -e "用户数  : 共 ${USER_COUNT} 个，活跃 ${ACTIVE_COUNT} 个"
    echo -e "公网IP  : ${PUBLIC_IP}"
    echo ""

    has_reality && { echo -e "${CYAN}Reality${NC} 端口 ${REALITY_PORT}  SNI ${REALITY_SNI}"; }
    has_shadowsocks && { echo -e "${CYAN}Shadowsocks${NC} 端口 ${SS_PORT}"; }
    has_ws && { echo -e "${CYAN}WS+TLS${NC} 端口 ${WS_PORT}  域名 ${WS_DOMAIN}"; }
    has_hy2 && { echo -e "${CYAN}Hysteria2${NC} 端口 ${HY2_PORT}/UDP"; }
    has_anytls && { echo -e "${CYAN}AnyTLS${NC} 端口 ${ANYTLS_PORT}"; }
    echo ""
}

# ============================================================
# 一键安装（首次使用）
# ============================================================
full_install() {
    check_system
    set_shanghai_timezone
    install_sbox || return 1
    init_reality || return 1
    setup_cron
    info "安装完成，可继续在「节点配置」中添加更多协议，或直接「创建用户」"
}

# ============================================================
# 主菜单
# ============================================================
main_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}========== 多协议节点管理（Alpine）==========${NC}"
        echo -e "  ${GREEN}1.${NC} 一键安装（首次使用，先装 Reality）"
        echo -e "  ${GREEN}2.${NC} 节点配置（增删 Reality/SS/WS/Hy2/AnyTLS，改端口）"
        echo -e "  ${GREEN}3.${NC} 创建用户"
        echo -e "  ${GREEN}4.${NC} 删除用户"
        echo -e "  ${GREEN}5.${NC} 续期用户"
        echo -e "  ${GREEN}6.${NC} 禁用用户"
        echo -e "  ${GREEN}7.${NC} 启用用户"
        echo -e "  ${GREEN}8.${NC} 用户列表"
        echo -e "  ${GREEN}9.${NC} 查看用户分享链接"
        echo -e "  ${GREEN}10.${NC} 查看 SS / Hysteria2 / AnyTLS 链接"
        echo -e "  ${GREEN}11.${NC} 节点信息总览"
        echo -e "  ${GREEN}12.${NC} 手动执行到期检查"
        echo -e "  ${GREEN}13.${NC} 卸载全部"
        echo -e "  ${GREEN}0.${NC} 退出"
        echo -e "${CYAN}==============================================${NC}"
        read -rp "选择: " CHOICE
        case "$CHOICE" in
            1) full_install ;;
            2) node_menu ;;
            3) add_user ;;
            4) delete_user ;;
            5) renew_user ;;
            6) toggle_user "禁用" ;;
            7) toggle_user "启用" ;;
            8) list_users ;;
            9) show_user_link ;;
            10)
                echo -e "  1) Shadowsocks  2) Hysteria2  3) AnyTLS"
                read -rp "选择: " S
                case "$S" in
                    1) show_ss_link 2>/dev/null || _print_ss_link ;;
                    2) show_hy2_link ;;
                    3) show_anytls_link ;;
                    *) error "无效选择" ;;
                esac ;;
            11) show_info ;;
            12) check_expire; info "到期检查已执行" ;;
            13) uninstall_sbox ;;
            0) exit 0 ;;
            *) error "无效选择" ;;
        esac
    done
}

show_ss_link() { has_shadowsocks || { error "Shadowsocks 尚未配置"; return 1; }; load_meta; _print_ss_link; }

# ============== 入口 ==============
if [[ "$1" == "check-expire" ]]; then
    check_expire
    exit 0
fi

check_system
main_menu
