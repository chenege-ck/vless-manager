#!/bin/bash
# VLESS 智能节点控制台 (sing-box) v1.0
# Reality + SS + WS + Hysteria2 + 用户管理 + Telegram

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============== 路径 ==============
SBOX_BIN="/usr/local/bin/sing-box"
SBOX_CONFIG="/etc/sing-box/config.json"
SBOX_DIR="/etc/sing-box"
USER_DB="${SBOX_DIR}/users.db"
META_REALITY="${SBOX_DIR}/meta-reality.conf"
META_SS="${SBOX_DIR}/meta-ss.conf"
META_WS="${SBOX_DIR}/meta-ws.conf"
META_HY2="${SBOX_DIR}/meta-hy2.conf"
META="${SBOX_DIR}/meta.conf"
SERVICE_NAME="sing-box"

# ============== 默认端口 ==============
SS_PORT_DEFAULT=8668
HY2_PORT_DEFAULT=8999

# ============== 工具函数 ==============
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

# ============== 用户名校验 ==============
validate_username() {
    local value="$1"
    [[ -z "$value" ]] && { error "用户名不能为空"; return 1; }
    [[ "$value" == *:* ]] && { error "用户名不能包含冒号"; return 1; }
    [[ "$value" == *[[:space:]]* ]] && { error "用户名不能包含空格或换行"; return 1; }
    local N
    N=$(printf '%s' "$value" | python3 -c 'import sys; sys.stdout.write(str(len(sys.stdin.read())))')
    if (( N > 20 )); then
        error "用户名过长（最多 20 个字符，约 10 个汉字）"
        return 1
    fi
    return 0
}

# ============== UUID 校验 ==============
validate_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || {
        error "UUID 格式异常"
        return 1
    }
}

# ============== 用户数据库操作 ==============
user_exists() {
    awk -F: -v n="$1" '$1==n {found=1; exit} END {exit !found}' "$USER_DB" 2>/dev/null
}

get_user_field() {
    awk -F: -v n="$1" -v f="$2" '$1==n {print $f; exit}' "$USER_DB" 2>/dev/null
}

# ============== 权限检查 ==============
[[ $EUID -ne 0 ]] && error "请用 root 运行此脚本" && exit 1

# ============== 系统检查（仅 Debian） ==============
check_system() {
    local OS_ID CODENAME
    OS_ID=$(awk -F= '/^ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null)
    CODENAME=$(awk -F= '/^VERSION_CODENAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null)
    if [[ "$OS_ID" != "debian" ]]; then
        error "本脚本仅支持 Debian 11/12/13，不支持当前系统"
        exit 1
    fi
    case "$CODENAME" in
        bullseye|bookworm|trixie) ;;
        *) error "仅支持 Debian 11/12/13，当前: ${CODENAME:-unknown}"; exit 1 ;;
    esac
}

# ============== 设置上海时区 ==============
set_shanghai_timezone() {
    title "设置系统时区"
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-timezone Asia/Shanghai 2>/dev/null
    else
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        echo "Asia/Shanghai" > /etc/timezone
    fi
    if [[ "$(readlink -f /etc/localtime 2>/dev/null)" == "/usr/share/zoneinfo/Asia/Shanghai" ]]; then
        info "系统时区已设置为 Asia/Shanghai"
    else
        warn "时区设置可能未生效，请手动执行: timedatectl set-timezone Asia/Shanghai"
    fi
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
    if [[ "$expire" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        TZ=Asia/Shanghai date -d "${expire} 12:00:00" +%s 2>/dev/null; return
    fi
    local normalized="${expire/T/ }"
    TZ=Asia/Shanghai date -d "$normalized" +%s 2>/dev/null
}

expire_display() {
    local expire="$1"
    if [[ "$expire" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
        local d="${expire%%_*}" t="${expire#*_}"; echo "${d} ${t//-/:}"
    elif [[ "$expire" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        echo "${expire/T/ }"
    elif [[ "$expire" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "${expire} 12:00:00"
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
    if [[ -z "$ip" ]]; then
        ip=$(curl -s6 --max-time 5 ip.sb 2>/dev/null)
        [[ -z "$ip" ]] && ip=$(curl -s6 --max-time 5 ifconfig.me 2>/dev/null)
    fi
    echo "${ip:-<请手动填写服务器IP>}"
}

# ============== 端口检查 ==============
check_port()     { ss -tlnp | grep -q ":${1} " && return 1 || return 0; }
check_port_udp() { ss -ulnp | grep -q ":${1} " && return 1 || return 0; }

# ============== 用户数据库格式化 ==============
# 格式: NAME:UUID:EXPIRE:STATUS:NODE
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
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}", exp):
        d, t = exp.split("T", 1)
        return d + "_" + t.replace(":", "-")
    if re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", exp):
        d, t = exp.split(" ", 1)
        return d + "_" + t.replace(":", "-")
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
        name = parts[0]
        uuid = parts[1]
        status = parts[-2]
        node = parts[-1] or "both"
        expire = ":".join(parts[2:-2])
        if len(parts) != 5:
            changed = True
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
    REALITY_PRIVATE_KEY=""  REALITY_PUBLIC_KEY=""  REALITY_SNI=""
    REALITY_PORT=""  REALITY_SHORTID=""
    SS_PORT=""  SS_METHOD=""  SS_PASSWORD=""
    WS_PORT=""  WS_PATH=""  WS_DOMAIN=""  WS_CF_PORT=""  WS_TLS=""  CERT_DIR=""
    HY2_PORT=""  HY2_PASSWORD=""  HY2_SNI=""

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
        WS_CF_PORT=$(read_kv "$META_WS" "WS_CF_PORT")
        WS_TLS=$(read_kv "$META_WS" "WS_TLS")
        CERT_DIR=$(read_kv "$META_WS" "CERT_DIR")
        CERT_DIR=${CERT_DIR:-/etc/sing-box/ssl}
    fi
    if [[ -f "$META_HY2" ]]; then
        HY2_PORT=$(read_kv "$META_HY2" "HY2_PORT")
        HY2_PASSWORD=$(read_kv "$META_HY2" "HY2_PASSWORD")
        HY2_SNI=$(read_kv "$META_HY2" "HY2_SNI")
    fi
}

# ============== 节点存在检查 ==============
has_reality()     { [[ -f "$META_REALITY" ]]; }
has_shadowsocks() { [[ -f "$META_SS" ]]; }
has_ws()          { [[ -f "$META_WS" ]]; }
has_hy2()         { [[ -f "$META_HY2" ]]; }

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

# ============== 启动 sing-box ==============
_start_sbox() {
    validate_sbox_config || return 1
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"
    sleep 1
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        info "sing-box 已启动"; return 0
    else
        error "sing-box 启动失败，运行 journalctl -u $SERVICE_NAME -n 20 查看日志"
        return 1
    fi
}

# ============== 分割线 ==============
# ============================================================
# 安装依赖
# ============================================================
install_deps() {
    title "安装依赖..."
    info "正在更新 apt 索引..."
    if ! apt-get update -qq; then
        warn "apt 更新失败，尝试自动修复软件源..."
        fix_apt || return 1
    fi
    apt-get install -y -qq curl openssl python3
    [[ $? -ne 0 ]] && error "依赖安装失败" && return 1
    info "依赖安装完成"
}

# ============================================================
# 修复 apt 源（仅 Debian 11/12/13）
# ============================================================
fix_apt() {
    local CODENAME
    CODENAME=$(awk -F= '/^VERSION_CODENAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null)
    [[ -z "$CODENAME" ]] && error "无法识别 Debian 版本" && return 1
    cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%s) 2>/dev/null
    case "$CODENAME" in
        bullseye)
            cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian bullseye main contrib non-free
deb-src http://deb.debian.org/debian bullseye main contrib non-free
deb http://deb.debian.org/debian bullseye-updates main contrib non-free
deb-src http://deb.debian.org/debian bullseye-updates main contrib non-free
deb http://security.debian.org/debian-security bullseye-security main contrib non-free
deb-src http://security.debian.org/debian-security bullseye-security main contrib non-free
EOF
            ;;
        bookworm)
            cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF
            ;;
        trixie)
            cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF
            ;;
        *) error "不支持的版本: $CODENAME"; return 1 ;;
    esac
    apt-get update -qq
    [[ $? -ne 0 ]] && error "apt 源修复后仍然失败" && return 1
    info "apt 源已修复: ${CODENAME}"
    return 0
}

# ============================================================
# 安装 sing-box
# ============================================================
install_sbox() {
    title "安装 sing-box..."
    if [[ -f "$SBOX_BIN" ]]; then
        warn "sing-box 已安装，跳过安装步骤"
        return 0
    fi
    install_deps || return 1

    info "正在下载 sing-box..."
    bash <(curl -fsSL https://sing-box.app/deb-install.sh) 2>/dev/null
    if [[ ! -f "$SBOX_BIN" ]]; then
        # 备用：从 GitHub releases 手动安装
        info "官方脚本安装失败，尝试从 GitHub releases 安装..."
        local ARCH
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64)  ARCH="amd64" ;;
            aarch64) ARCH="arm64" ;;
            armv7l)  ARCH="armv7" ;;
            *) error "不支持的架构: $ARCH"; return 1 ;;
        esac
        local VER
        VER=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
              | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name','').lstrip('v'))" 2>/dev/null)
        [[ -z "$VER" ]] && error "无法获取 sing-box 最新版本" && return 1
        local URL="https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${ARCH}.tar.gz"
        curl -fsSL "$URL" -o /tmp/sing-box.tar.gz || { error "下载失败"; return 1; }
        tar -xzf /tmp/sing-box.tar.gz -C /tmp/
        local DIR_NAME="sing-box-${VER}-linux-${ARCH}"
        cp "/tmp/${DIR_NAME}/sing-box" "$SBOX_BIN"
        chmod +x "$SBOX_BIN"
        rm -rf /tmp/sing-box.tar.gz "/tmp/${DIR_NAME}"

        # 创建 systemd 服务
        printf '%s\n' \
            "[Unit]" \
            "Description=sing-box service" \
            "Documentation=https://sing-box.sagernet.org" \
            "After=network.target nss-lookup.target" \
            "" \
            "[Service]" \
            "Type=simple" \
            "ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json" \
            "Restart=on-failure" \
            "RestartSec=10" \
            "LimitNOFILE=infinity" \
            "" \
            "[Install]" \
            "WantedBy=multi-user.target" \
            > /etc/systemd/system/sing-box.service
        systemctl daemon-reload
    fi

    [[ -x "$SBOX_BIN" ]] || { error "sing-box 安装失败"; return 1; }
    mkdir -p "$SBOX_DIR"
    info "sing-box 安装成功: $($SBOX_BIN version 2>/dev/null | head -1)"
}

# ============================================================
# 卸载 sing-box
# ============================================================
uninstall_sbox() {
    title "卸载 sing-box..."
    read -rp "确认卸载？将删除所有配置和用户数据 [y/N]: " CONFIRM
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && warn "已取消" && return

    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    rm -f "$SBOX_BIN"
    rm -f /etc/systemd/system/sing-box.service
    rm -rf "$SBOX_DIR"
    crontab -l 2>/dev/null | grep -v "check-expire" | crontab -
    systemctl daemon-reload
    info "sing-box 已完全卸载"
    exit 0
}

# ============================================================
# 生成 Reality 密钥对
# ============================================================
gen_keypair() {
    local OUTPUT
    OUTPUT=$("$SBOX_BIN" generate reality-keypair 2>/dev/null)
    PRIVATE_KEY=$(echo "$OUTPUT" | grep -i "PrivateKey" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$OUTPUT" | grep -i "PublicKey" | awk '{print $NF}')
}

# ============================================================
# IP 优先级设置
# ============================================================
_read_ip_priority() {
    local ds=""
    [[ -f "$META" ]] && ds=$(read_kv "$META" "IP_PRIORITY")
    echo "$ds"
}

_get_ip_priority_desc() {
    local ds
    ds=$(_read_ip_priority)
    case "$ds" in
        prefer_ipv4) echo "IPv4 优先（v4失败自动切v6）" ;;
        prefer_ipv6) echo "IPv6 优先（v6失败自动切v4）" ;;
        ipv4_only)   echo "仅 IPv4" ;;
        ipv6_only)   echo "仅 IPv6" ;;
        *)           echo "系统默认" ;;
    esac
}

_save_ip_priority() {
    local ds="$1"
    mkdir -p "$(dirname "$META")"
    touch "$META"
    if grep -q "^IP_PRIORITY=" "$META" 2>/dev/null; then
        sed -i "s|^IP_PRIORITY=.*|IP_PRIORITY=${ds}|" "$META"
    else
        echo "IP_PRIORITY=${ds}" >> "$META"
    fi
}

ip_priority_menu() {
    title "网络优先级（IPv4/IPv6）"
    load_meta
    local CURRENT_DESC
    CURRENT_DESC=$(_get_ip_priority_desc)
    echo ""
    echo -e "当前模式：${CYAN}${CURRENT_DESC}${NC}"
    echo -e "${YELLOW}（Reality / SS / WS / Hysteria2 统一生效）${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} IPv4 优先   — 优先走 v4，v4 不通自动切 v6"
    echo -e "  ${GREEN}2.${NC} IPv6 优先   — 优先走 v6，v6 不通自动切 v4"
    echo -e "  ${GREEN}3.${NC} 仅 IPv4     — 强制只走 v4"
    echo -e "  ${GREEN}4.${NC} 仅 IPv6     — 强制只走 v6"
    echo -e "  ${GREEN}5.${NC} 系统默认"
    echo -e "  ${GREEN}0.${NC} 返回"
    echo ""
    read -rp "选择: " OPT
    local DS=""
    local DESC=""
    case "$OPT" in
        1) DS="prefer_ipv4"; DESC="IPv4 优先" ;;
        2) DS="prefer_ipv6"; DESC="IPv6 优先" ;;
        3) DS="ipv4_only";   DESC="仅 IPv4" ;;
        4) DS="ipv6_only";   DESC="仅 IPv6" ;;
        5) DS="AsIs";        DESC="系统默认" ;;
        0) return ;;
        *) warn "无效选项"; return ;;
    esac
    _save_ip_priority "$DS"
    if has_reality || has_shadowsocks || has_ws || has_hy2; then
        rebuild_config
        _inject_all_users
        _start_sbox
    fi
    info "已生效：${DESC}"
}

# ============================================================
# 根据已有 meta 重建 sing-box config.json
# ============================================================
rebuild_config() {
    load_meta
    local IP_PRIO
    IP_PRIO=$(_read_ip_priority)

    HAS_REALITY=0; has_reality && HAS_REALITY=1
    HAS_SS=0; has_shadowsocks && HAS_SS=1
    HAS_WS=0; has_ws && HAS_WS=1
    HAS_HY2=0; has_hy2 && HAS_HY2=1

    export SBOX_CONFIG HAS_REALITY HAS_SS HAS_WS HAS_HY2 IP_PRIO
    export REALITY_PORT REALITY_SNI REALITY_PRIVATE_KEY REALITY_SHORTID
    export SS_PORT SS_METHOD SS_PASSWORD
    export WS_PORT WS_PATH CERT_DIR
    export HY2_PORT HY2_PASSWORD HY2_CERT HY2_KEY

    python3 - <<PYEOF
import json, os

cfg = {"log": {"level": "warn", "timestamp": True}, "inbounds": [], "outbounds": []}

if os.environ.get("HAS_REALITY") == "1":
    cfg["inbounds"].append({
        "type": "vless", "tag": "inbound-reality",
        "listen": "::", "listen_port": int(os.environ["REALITY_PORT"]),
        "sniff": True, "sniff_override_destination": True, "users": [],
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
        "sniff": True, "sniff_override_destination": True, "users": [],
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

if os.environ.get("HAS_HY2") == "1":
    cfg["inbounds"].append({
        "type": "hysteria2", "tag": "inbound-hy2",
        "listen": "::", "listen_port": int(os.environ["HY2_PORT"]),
        "users": [{"name": "shared", "password": os.environ["HY2_PASSWORD"]}],
        "tls": {
            "enabled": True,
            "certificate_path": os.environ["HY2_CERT"],
            "key_path": os.environ["HY2_KEY"]
        }
    })

ds = os.environ.get("IP_PRIO", "")
outbound = {"type": "direct", "tag": "direct"}
if ds and ds != "AsIs":
    outbound["domain_strategy"] = ds

cfg["outbounds"] = [outbound, {"type": "block", "tag": "block"}]

with open(os.environ["SBOX_CONFIG"], "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF
}

# ============================================================
# 注入用户到 config.json（Reality 和 WS）
# ============================================================
_inject_user() {
    local UUID=$1 NAME=$2 EXPIRE=$3 NODE=$4

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
    users = inbound.get("users")
    if users is None:
        continue
    # 移除已存在的同 UUID 用户
    inbound["users"] = [u for u in users if u.get("uuid") != uuid]
    # 按节点类型注入
    should_add = False
    if node == "both":
        should_add = True
    elif node == "reality" and tag == "inbound-reality":
        should_add = True
    elif node == "ws" and tag == "inbound-ws":
        should_add = True
    if should_add:
        user_entry = {"name": name, "uuid": uuid}
        if tag == "inbound-reality":
            user_entry["flow"] = "xtls-rprx-vision"
        inbound["users"].append(user_entry)

with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF
}

# ============================================================
# 重建后将所有 active 用户重新注入
# ============================================================
_inject_all_users() {
    [[ ! -f "$USER_DB" ]] && return
    normalize_user_db
    while IFS=: read -r NAME UUID EXPIRE STATUS NODE; do
        [[ "$STATUS" != "active" ]] && continue
        NODE=${NODE:-both}
        _inject_user "$UUID" "$NAME" "$EXPIRE" "$NODE"
    done < "$USER_DB"
}

# ============================================================
# 初始化 Reality 节点
# ============================================================
init_reality() {
    title "配置 VLESS + Reality"
    gen_keypair
    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        error "密钥生成失败"; return 1
    fi

    while true; do
        read -rp "监听端口 [默认 8443]: " REALITY_PORT
        REALITY_PORT=${REALITY_PORT:-8443}
        check_port "$REALITY_PORT" && break || warn "端口 ${REALITY_PORT} 已被占用"
    done

    read -rp "伪装域名 [默认 www.apple.com]: " REALITY_SNI
    REALITY_SNI=${REALITY_SNI:-www.apple.com}
    local REALITY_SHORTID
    REALITY_SHORTID=$(openssl rand -hex 8)

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
        check_port "$PORT" && break || warn "端口 ${PORT} 已被占用"
    done

    SS_PORT=$PORT
    SS_METHOD="2022-blake3-aes-128-gcm"
    SS_PASSWORD=$(openssl rand -base64 16)
    [[ -n "$SS_PASSWORD" ]] || { error "密码生成失败"; return 1; }

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
    local SERVER_IP
    SERVER_IP=$(get_public_ip)
    local USERINFO
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
# 初始化 WS+CF 节点
# ============================================================
init_ws_cf() {
    title "配置 VLESS + WS + TLS"
    while true; do
        read -rp "监听端口 [默认 8445]: " WS_PORT
        WS_PORT=${WS_PORT:-8445}
        check_port "$WS_PORT" && break || warn "端口 ${WS_PORT} 已被占用"
    done
    read -rp "WS 路径 [默认 /vless]: " WS_PATH
    WS_PATH=${WS_PATH:-/vless}
    read -rp "你的域名（已在 CF 解析）: " WS_DOMAIN
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
WS_CF_PORT=${WS_PORT}
WS_TLS=tls
CERT_DIR=${CERT_DIR}
EOF
    chmod 600 "$META_WS"

    rebuild_config || return 1
    _inject_all_users
    _start_sbox || return 1
    info "WS+CF 节点配置完成"
    echo -e "${YELLOW}CF 配置：${NC}${WS_DOMAIN} 解析到本机并开启橙云，SSL 使用完全（Full）"
}

# ============================================================
# Hysteria2（合并进 sing-box）
# ============================================================
init_hy2() {
    title "配置 Hysteria2"

    if has_hy2; then
        warn "Hysteria2 已存在，重新配置将生成新密码/证书"
        read -rp "确认继续？[y/N]: " C
        [[ "$C" != "y" && "$C" != "Y" ]] && warn "已取消" && return
    fi

    local PORT SNI
    read -rp "监听端口 [默认 ${HY2_PORT_DEFAULT}]: " PORT
    PORT=${PORT:-$HY2_PORT_DEFAULT}
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
        error "端口必须是 1-65535"; return 1
    fi
    check_port_udp "$PORT" || { error "UDP 端口 ${PORT} 已被占用"; return 1; }

    read -rp "伪装域名（证书 CN）[默认 www.bing.com]: " SNI
    SNI=${SNI:-www.bing.com}

    HY2_PORT=$PORT
    HY2_SNI=$SNI
    HY2_PASSWORD=$(openssl rand -hex 16)
    [[ -n "$HY2_PASSWORD" ]] || { error "密码生成失败"; return 1; }

    # 自签名证书
    HY2_CERT="${SBOX_DIR}/hy2-cert.pem"
    HY2_KEY="${SBOX_DIR}/hy2-key.pem"
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$HY2_KEY" -out "$HY2_CERT" \
        -days 3650 -subj "/CN=${HY2_SNI}" \
        -addext "subjectAltName=DNS:${HY2_SNI}" >/dev/null 2>&1
    [[ -s "$HY2_CERT" && -s "$HY2_KEY" ]] || { error "证书生成失败"; return 1; }
    chmod 644 "$HY2_CERT" && chmod 640 "$HY2_KEY"

    cat > "$META_HY2" <<EOF
HY2_PORT=${HY2_PORT}
HY2_PASSWORD=${HY2_PASSWORD}
HY2_SNI=${HY2_SNI}
HY2_CERT=${HY2_CERT}
HY2_KEY=${HY2_KEY}
EOF
    chmod 600 "$META_HY2"

    rebuild_config || return 1
    _start_sbox || return 1
    info "Hysteria2 配置完成（端口 ${HY2_PORT}/UDP，自签名证书）"
    _print_hy2_link
}

remove_hy2() {
    has_hy2 || { error "Hysteria2 未启用"; return 1; }
    read -rp "确认移除 Hysteria2？[y/N]: " C
    [[ "$C" != "y" && "$C" != "Y" ]] && warn "已取消" && return
    load_meta
    rm -f "$META_HY2" "$HY2_CERT" "$HY2_KEY"
    rebuild_config
    _inject_all_users
    _start_sbox
    info "Hysteria2 已移除"
}

_print_hy2_link() {
    has_hy2 || return 1
    local HY2_PORT HY2_PASSWORD HY2_SNI SERVER_IP
    HY2_PORT=$(read_kv "$META_HY2" "HY2_PORT")
    HY2_PASSWORD=$(read_kv "$META_HY2" "HY2_PASSWORD")
    HY2_SNI=$(read_kv "$META_HY2" "HY2_SNI")
    SERVER_IP=$(get_public_ip)
    echo ""
    echo -e "${GREEN}===== Hysteria2 信息 =====${NC}"
    echo -e "地址   : ${SERVER_IP}"
    echo -e "端口   : ${HY2_PORT} (UDP)"
    echo -e "密码   : ${HY2_PASSWORD}"
    echo -e "SNI    : ${HY2_SNI}"
    echo -e "证书   : 自签名，客户端需 insecure"
    echo -e "${CYAN}分享链接:${NC}"
    echo "hy2://${HY2_PASSWORD}@${SERVER_IP}:${HY2_PORT}/?sni=${HY2_SNI}&insecure=1#Hysteria2-${HY2_PORT}"
    echo ""
}

show_hy2_link() {
    has_hy2 || { error "Hysteria2 尚未配置"; return 1; }
    _print_hy2_link
}

# ============================================================
# 节点配置选择菜单
# ============================================================
init_config() {
    title "节点配置..."
    mkdir -p "$SBOX_DIR"
    touch "$USER_DB" && chmod 600 "$USER_DB"
    normalize_user_db
    load_meta

    echo ""
    echo "当前节点状态："
    has_reality     && echo -e "  ${GREEN}✓${NC} Reality 已启用"    || echo -e "  ${RED}✗${NC} Reality 未启用"
    has_shadowsocks && echo -e "  ${GREEN}✓${NC} Shadowsocks 已启用" || echo -e "  ${RED}✗${NC} Shadowsocks 未启用"
    has_ws          && echo -e "  ${GREEN}✓${NC} WS+CF 已启用"      || echo -e "  ${RED}✗${NC} WS+CF 未启用"
    has_hy2         && echo -e "  ${GREEN}✓${NC} Hysteria2 已启用"  || echo -e "  ${RED}✗${NC} Hysteria2 未启用"
    echo ""
    echo -e "  ${GREEN}1.${NC} 配置 VLESS + Reality"
    echo -e "  ${GREEN}2.${NC} 配置 Shadowsocks"
    echo -e "  ${GREEN}3.${NC} 配置 VLESS + WS + TLS"
    echo -e "  ${GREEN}4.${NC} 配置 Hysteria2"
    has_reality     && echo -e "  ${RED}5.${NC} 移除 Reality"
    has_shadowsocks && echo -e "  ${RED}6.${NC} 移除 Shadowsocks"
    has_ws          && echo -e "  ${RED}7.${NC} 移除 WS+CF"
    has_hy2         && echo -e "  ${RED}8.${NC} 移除 Hysteria2"
    echo ""
    read -rp "选择: " MODE_SEL
    case $MODE_SEL in
        1)
            if has_reality; then
                warn "Reality 已存在，重新配置将覆盖"
                read -rp "确认？[y/N]: " C
                [[ "$C" != "y" && "$C" != "Y" ]] && return
            fi
            init_reality ;;
        2) init_shadowsocks ;;
        3) init_ws_cf ;;
        4) init_hy2 ;;
        5)
            has_reality || { error "Reality 未启用"; return; }
            read -rp "确认移除 Reality？[y/N]: " C
            [[ "$C" != "y" && "$C" != "Y" ]] && return
            rm -f "$META_REALITY"
            rebuild_config; _inject_all_users; _start_sbox
            info "Reality 已移除" ;;
        6)
            has_shadowsocks || { error "SS 未启用"; return; }
            read -rp "确认移除 Shadowsocks？[y/N]: " C
            [[ "$C" != "y" && "$C" != "Y" ]] && return
            rm -f "$META_SS"
            rebuild_config; _inject_all_users; _start_sbox
            info "Shadowsocks 已移除" ;;
        7)
            has_ws || { error "WS 未启用"; return; }
            read -rp "确认移除 WS+CF？[y/N]: " C
            [[ "$C" != "y" && "$C" != "Y" ]] && return
            rm -f "$META_WS"
            rebuild_config; _inject_all_users; _start_sbox
            info "WS+CF 已移除" ;;
        8) remove_hy2 ;;
        *) error "无效选择" ;;
    esac
}
# ============================================================
# 打印用户分享链接
# ============================================================
_print_link() {
    local USERNAME=$1 UUID=$2 EXPIRE=$3 NODE=${4:-both}
    load_meta

    local EXPIRE_SHOW
    EXPIRE_SHOW=$(expire_display "$EXPIRE")

    echo ""
    echo -e "${GREEN}===== 节点信息 =====${NC}"
    echo -e "用户名 : ${USERNAME}"
    echo -e "UUID   : ${UUID}"
    echo -e "到期   : ${EXPIRE_SHOW}"
    echo -e "节点   : ${NODE}"

    if [[ "$NODE" == "reality" || "$NODE" == "both" ]] && has_reality; then
        local SERVER_IP SHORTID
        SERVER_IP=$(get_public_ip)
        SHORTID=$(python3 -c "
import json
d=json.load(open('$SBOX_CONFIG', encoding='utf-8'))
for i in d.get('inbounds',[]):
    if i.get('tag')=='inbound-reality':
        print(i['tls']['reality']['short_id'][0]); break
" 2>/dev/null)

        echo ""
        echo -e "${CYAN}── Reality 节点 ──${NC}"
        echo -e "地址   : ${SERVER_IP}"
        echo -e "端口   : ${REALITY_PORT}"
        echo -e "公钥   : ${REALITY_PUBLIC_KEY}"
        echo -e "SNI    : ${REALITY_SNI}"
        echo -e "ShortID: ${SHORTID}"

        local LINK="vless://${UUID}@${SERVER_IP}:${REALITY_PORT}/?type=tcp&encryption=none&flow=xtls-rprx-vision&sni=${REALITY_SNI}&fp=chrome&security=reality&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORTID}#${USERNAME}-reality"
        echo -e "${CYAN}分享链接:${NC}"
        echo "$LINK"
    fi

    if [[ "$NODE" == "ws" || "$NODE" == "both" ]] && has_ws; then
        local ENCODED_PATH ENCODED_NAME
        ENCODED_PATH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${WS_PATH}'))")
        ENCODED_NAME=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${USERNAME}-ws'))")
        echo ""
        echo -e "${CYAN}── WS+CF 节点 ──${NC}"
        echo -e "域名   : ${WS_DOMAIN}"
        echo -e "端口   : ${WS_CF_PORT:-443}"
        echo -e "WS路径 : ${WS_PATH}"
        echo -e "TLS    : 开启"
        echo -e "SNI    : ${WS_DOMAIN}"
        local WS_LINK="vless://${UUID}@${WS_DOMAIN}:${WS_CF_PORT:-443}/?type=ws&encryption=none&host=${WS_DOMAIN}&path=${ENCODED_PATH}&security=tls&sni=${WS_DOMAIN}#${ENCODED_NAME}"
        echo -e "${CYAN}分享链接:${NC}"
        echo "$WS_LINK"
    fi
    echo ""
}

# ============================================================
# 添加用户
# ============================================================
add_user() {
    load_meta
    normalize_user_db

    read -rp "用户名（备注用）: " USERNAME
    [[ -z "$USERNAME" ]] && error "用户名不能为空" && return
    validate_username "$USERNAME" || return

    if user_exists "$USERNAME"; then
        error "用户 ${USERNAME} 已存在"; return
    fi

    local NODE="both"
    if has_reality && has_ws; then
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
    elif has_reality; then
        NODE="reality"
    elif has_ws; then
        NODE="ws"
    else
        error "尚未配置 Reality 或 WS 节点，请先初始化"
        return
    fi

    read -rp "到期天数 [默认 999 天]: " DAYS
    DAYS=${DAYS:-999}
    if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
        error "天数必须是纯数字"; return
    fi

    EXPIRE=$(expire_noon_str "$DAYS")
    [[ -z "$EXPIRE" ]] && { error "到期时间计算失败"; return; }

    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "${USERNAME}:${UUID}:${EXPIRE}:active:${NODE}" >> "$USER_DB"
    _inject_user "$UUID" "$USERNAME" "$EXPIRE" "$NODE"

    validate_sbox_config || {
        python3 - <<PYEOF
from pathlib import Path
p = Path("$USER_DB")
lines = p.read_text(encoding='utf-8', errors='ignore').splitlines()
out = [l for l in lines if not (len(l.split(':')) >= 2 and l.split(':')[1] == "$UUID")]
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
        rebuild_config; _inject_all_users
        error "配置校验失败，已回滚本次添加"; return 1
    }

    _start_sbox || {
        python3 - <<PYEOF
from pathlib import Path
p = Path("$USER_DB")
lines = p.read_text(encoding='utf-8', errors='ignore').splitlines()
out = [l for l in lines if not (len(l.split(':')) >= 2 and l.split(':')[1] == "$UUID")]
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
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
    validate_username "$USERNAME" || return

    if ! user_exists "$USERNAME"; then
        error "用户不存在"; return
    fi

    UUID=$(get_user_field "$USERNAME" 2)
    validate_uuid "$UUID" || return
    local USER_NODE DEL_NODE="both"
    USER_NODE=$(get_user_field "$USERNAME" 5)
    USER_NODE=${USER_NODE:-both}

    if [[ "$USER_NODE" == "both" ]] && has_reality && has_ws; then
        echo "删除哪个节点的权限？"
        echo "  1. Reality + WS（彻底删除）"
        echo "  2. 仅 Reality"
        echo "  3. 仅 WS"
        read -rp "选择 [1/2/3，默认1]: " DEL_SEL
        case ${DEL_SEL:-1} in 2) DEL_NODE="reality" ;; 3) DEL_NODE="ws" ;; *) DEL_NODE="both" ;; esac
    else
        DEL_NODE="$USER_NODE"
    fi

    # 从 config.json 移除
    python3 - <<PYEOF
import json
del_node = "$DEL_NODE"
with open("$SBOX_CONFIG", "r", encoding="utf-8") as f:
    cfg = json.load(f)
for inbound in cfg.get("inbounds", []):
    tag = inbound.get("tag", "")
    users = inbound.get("users")
    if users is None:
        continue
    if del_node == "both" or (del_node == "reality" and tag == "inbound-reality") or (del_node == "ws" and tag == "inbound-ws"):
        inbound["users"] = [u for u in users if u.get("uuid") != "$UUID"]
with open("$SBOX_CONFIG", "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF

    if [[ "$DEL_NODE" == "both" || "$DEL_NODE" == "$USER_NODE" ]]; then
        # 彻底删除
        python3 - <<PYEOF
from pathlib import Path
p = Path("$USER_DB")
lines = p.read_text(encoding='utf-8', errors='ignore').splitlines()
out = [l for l in lines if not (l.startswith("$USERNAME:") and l.split(":")[0] == "$USERNAME")]
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
        info "用户 ${USERNAME} 已彻底删除"
    else
        # 部分删除：只移除一个节点
        local NEW_NODE
        [[ "$DEL_NODE" == "reality" ]] && NEW_NODE="ws" || NEW_NODE="reality"
        DB_PATH="$USER_DB" TARGET_USER="$USERNAME" NEW_NODE="$NEW_NODE" python3 - <<'PYEOF'
import os
from pathlib import Path
p = Path(os.environ["DB_PATH"])
out = []
for line in p.read_text(encoding="utf-8", errors="ignore").splitlines():
    parts = line.split(":")
    if parts and parts[0] == os.environ["TARGET_USER"]:
        parts = (parts + ["both"] * 5)[:5]
        parts[4] = os.environ["NEW_NODE"]
    out.append(":".join(parts))
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
        info "用户 ${USERNAME} 已移除 ${DEL_NODE} 权限，保留 ${NEW_NODE}"
    fi

    validate_sbox_config || { rebuild_config; _inject_all_users; }
    systemctl restart "$SERVICE_NAME"
}

# ============================================================
# 禁用 / 启用用户
# ============================================================
toggle_user() {
    local ACTION=$1
    title "${ACTION} 用户"
    normalize_user_db
    list_users_brief

    read -rp "输入用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return
    validate_username "$USERNAME" || return

    if ! user_exists "$USERNAME"; then
        error "用户不存在"; return
    fi

    UUID=$(get_user_field "$USERNAME" 2)
    validate_uuid "$UUID" || return
    local USER_NODE OP_NODE
    USER_NODE=$(get_user_field "$USERNAME" 5)
    USER_NODE=${USER_NODE:-both}
    OP_NODE="$USER_NODE"

    if [[ "$ACTION" == "disable" ]]; then
        # 从 config.json 移除
        python3 - <<PYEOF
import json
op_node = "$OP_NODE"
with open("$SBOX_CONFIG", "r", encoding="utf-8") as f:
    cfg = json.load(f)
for inbound in cfg.get("inbounds", []):
    tag = inbound.get("tag", "")
    users = inbound.get("users")
    if users is None:
        continue
    if op_node == "both" or (op_node == "reality" and tag == "inbound-reality") or (op_node == "ws" and tag == "inbound-ws"):
        inbound["users"] = [u for u in users if u.get("uuid") != "$UUID"]
with open("$SBOX_CONFIG", "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF

        # 更新 db 状态
        python3 - <<PYEOF
from pathlib import Path
p = Path("$USER_DB")
lines = p.read_text(encoding='utf-8', errors='ignore').splitlines()
out = []
for line in lines:
    if not line.startswith("$USERNAME:"):
        out.append(line); continue
    parts = line.split(":")
    if len(parts) < 5:
        parts += ["both"] * (5 - len(parts))
    parts[3] = "disabled"
    out.append(":".join(parts[:5]))
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
        info "用户 ${USERNAME} 已禁用"
    else
        # 启用
        local EXPIRE
        EXPIRE=$(get_user_field "$USERNAME" 3)
        local EXPIRE_TS NOW_TS
        EXPIRE_TS=$(expire_to_ts "$EXPIRE")
        NOW_TS=$(now_shanghai_ts)
        if [[ -n "$EXPIRE_TS" ]] && (( NOW_TS >= EXPIRE_TS )); then
            warn "用户 ${USERNAME} 已过期（$(expire_display "$EXPIRE")），无法启用"
            warn "请先重置到期时间再启用"
            return
        fi

        _inject_user "$UUID" "$USERNAME" "$EXPIRE" "$OP_NODE"

        python3 - <<PYEOF
from pathlib import Path
p = Path("$USER_DB")
lines = p.read_text(encoding='utf-8', errors='ignore').splitlines()
out = []
for line in lines:
    if not line.startswith("$USERNAME:"):
        out.append(line); continue
    parts = line.split(":")
    if len(parts) < 5:
        parts += ["both"] * (5 - len(parts))
    parts[3] = "active"
    out.append(":".join(parts[:5]))
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
        info "用户 ${USERNAME} 已启用"
    fi

    validate_sbox_config || { rebuild_config; _inject_all_users; return 1; }
    systemctl restart "$SERVICE_NAME"
}

# ============================================================
# 重置到期时间
# ============================================================
renew_user() {
    title "重置到期时间"
    normalize_user_db
    list_users_brief

    read -rp "输入用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return
    validate_username "$USERNAME" || return

    if ! user_exists "$USERNAME"; then
        error "用户不存在"; return
    fi

    read -rp "续期天数 [默认 999 天]: " DAYS
    DAYS=${DAYS:-999}
    if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
        error "天数必须是纯数字"; return
    fi

    NEW_EXPIRE=$(expire_noon_str "$DAYS")
    [[ -z "$NEW_EXPIRE" ]] && { error "到期时间计算失败"; return; }

    UUID=$(get_user_field "$USERNAME" 2)
    validate_uuid "$UUID" || return
    local STATUS NODE
    STATUS=$(get_user_field "$USERNAME" 4)
    NODE=$(get_user_field "$USERNAME" 5)
    NODE=${NODE:-both}
    STATUS=${STATUS:-active}

    # 更新 db（续期后恢复为 active）
    python3 - <<PYEOF
from pathlib import Path
p = Path("$USER_DB")
lines = p.read_text(encoding='utf-8', errors='ignore').splitlines()
out = []
for line in lines:
    parts = line.split(":")
    if len(parts) >= 2 and parts[0] == "$USERNAME" and parts[1] == "$UUID":
        out.append("$USERNAME:$UUID:$NEW_EXPIRE:active:$NODE")
    else:
        out.append(line)
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF

    _inject_user "$UUID" "$USERNAME" "$NEW_EXPIRE" "$NODE"
    validate_sbox_config && systemctl restart "$SERVICE_NAME"

    if [[ "$STATUS" == "disabled" ]]; then
        info "用户 ${USERNAME} 到期已更新为 ${NEW_EXPIRE}，已自动恢复启用"
    else
        info "用户 ${USERNAME} 到期已更新为 ${NEW_EXPIRE}"
    fi
}

# ============================================================
# 列出用户（完整版）
# ============================================================
list_users() {
    title "用户列表"
    normalize_user_db
    [[ ! -s "$USER_DB" ]] && warn "暂无用户" && return

    local TOTAL ACTIVE DISABLED
    TOTAL=$(wc -l < "$USER_DB")
    ACTIVE=$(grep -c ":active:" "$USER_DB" 2>/dev/null || echo 0)
    DISABLED=$((TOTAL - ACTIVE))
    echo -e "  总计 ${CYAN}${TOTAL}${NC} 个  ${GREEN}活跃 ${ACTIVE}${NC}  ${RED}禁用 ${DISABLED}${NC}\n"
    echo -e "  ${YELLOW}%-15s %-38s %-20s %-8s %-8s${NC}" "用户名" "UUID" "到期时间" "状态" "节点"
    echo -e "  ───────────────────────────────────────────────────────────────────────────────────────────────"
    while IFS=: read -r NAME UUID EXPIRE STATUS NODE; do
        NODE=${NODE:-both}
        local COLOR=$NC STATUS_ICON="○" EXPIRE_SHOW
        EXPIRE_SHOW=$(expire_display "$EXPIRE")
        if [[ "$STATUS" == "active" ]]; then
            COLOR=$GREEN; STATUS_ICON="●"
        elif [[ "$STATUS" == "disabled" ]]; then
            COLOR=$RED; STATUS_ICON="○"
        fi
        printf "  ${COLOR}%-15s %-38s %-20s %-8s %-8s${NC}\n" \
            "$NAME" "$UUID" "$EXPIRE_SHOW" "${STATUS_ICON} ${STATUS}" "$NODE"
    done < "$USER_DB"
    echo ""
}

# ============================================================
# 列出用户（简略版）
# ============================================================
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

# ============================================================
# 查看用户分享链接
# ============================================================
show_user_link() {
    title "查看用户分享链接"
    normalize_user_db
    list_users_brief

    read -rp "输入用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return
    validate_username "$USERNAME" || return

    if ! user_exists "$USERNAME"; then
        error "用户不存在"; return
    fi

    local UUID EXPIRE NODE STATUS
    UUID=$(get_user_field "$USERNAME" 2)
    validate_uuid "$UUID" || return
    EXPIRE=$(get_user_field "$USERNAME" 3)
    STATUS=$(get_user_field "$USERNAME" 4)
    NODE=$(get_user_field "$USERNAME" 5)
    NODE=${NODE:-both}

    if [[ "$STATUS" == "disabled" ]]; then
        warn "用户 ${USERNAME} 当前已禁用"
    fi

    _print_link "$USERNAME" "$UUID" "$EXPIRE" "$NODE"
}

# ============================================================
# 到期检查（cron 调用）
# ============================================================
check_expire() {
    title "检查到期用户..."
    normalize_user_db
    local NOW_TS
    NOW_TS=$(now_shanghai_ts)
    local CHANGED=0
    local EXPIRED_UUIDS=""

    [[ ! -f "$USER_DB" ]] && info "暂无用户" && return

    while IFS=: read -r NAME UUID EXPIRE STATUS NODE; do
        [[ "$STATUS" != "active" ]] && continue
        local EXPIRE_TS
        EXPIRE_TS=$(expire_to_ts "$EXPIRE")
        [[ -z "$EXPIRE_TS" ]] && continue
        if (( NOW_TS >= EXPIRE_TS )); then
            warn "用户 ${NAME} 已到期（$(expire_display "$EXPIRE")），自动禁用"
            EXPIRED_UUIDS="${EXPIRED_UUIDS} ${UUID}"
            CHANGED=1
        fi
    done < "$USER_DB"

    if [[ $CHANGED -eq 1 ]]; then
        # 批量更新 db
        BATCH_UUIDS="$EXPIRED_UUIDS" DB_PATH="$USER_DB" python3 - <<'PYEOF'
import os
from pathlib import Path
uuids = set(os.environ["BATCH_UUIDS"].split())
p = Path(os.environ["DB_PATH"])
lines = p.read_text(encoding='utf-8', errors='ignore').splitlines()
out = []
for line in lines:
    parts = line.split(":")
    if len(parts) >= 2 and parts[1] in uuids:
        if len(parts) < 5:
            parts += ["both"] * (5 - len(parts))
        parts[3] = "disabled"
        out.append(":".join(parts[:5]))
    else:
        out.append(line)
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF

        # 批量从 config.json 移除
        BATCH_UUIDS="$EXPIRED_UUIDS" CFG_PATH="$SBOX_CONFIG" python3 - <<'PYEOF'
import json, os
expired = set(os.environ["BATCH_UUIDS"].split())
with open(os.environ["CFG_PATH"], "r", encoding="utf-8") as f:
    cfg = json.load(f)
for inbound in cfg.get("inbounds", []):
    users = inbound.get("users")
    if users is None:
        continue
    inbound["users"] = [u for u in users if u.get("uuid") not in expired]
with open(os.environ["CFG_PATH"], "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF

        validate_sbox_config && systemctl restart "$SERVICE_NAME"
        info "已重启 sing-box"
    else
        info "没有到期用户"
    fi
}
# ============================================================
# 节点信息展示
# ============================================================
show_info() {
    title "节点信息"
    load_meta
    normalize_user_db

    local SBOX_STATUS USER_COUNT ACTIVE_COUNT
    local PUBLIC_IP LOAD_INFO MEM_INFO SWAP_INFO UPTIME_INFO

    SBOX_STATUS=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)
    USER_COUNT=0; [[ -f "$USER_DB" ]] && USER_COUNT=$(wc -l < "$USER_DB")
    ACTIVE_COUNT=0; [[ -f "$USER_DB" ]] && ACTIVE_COUNT=$(grep -c ":active:" "$USER_DB" 2>/dev/null || echo 0)

    PUBLIC_IP=$(get_public_ip)
    LOAD_INFO=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
    MEM_INFO=$(free -m | awk '/^Mem:/ {printf "%d/%dMB", $3, $2}' 2>/dev/null)
    SWAP_INFO=$(free -m | awk '/^Swap:/ {printf "%d/%dMB", $3, $2}' 2>/dev/null)
    UPTIME_INFO=$(uptime -p 2>/dev/null | sed 's/^up //')

    echo -e "状态   : $( [[ "$SBOX_STATUS" == "active" ]] && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}已停止${NC}" )"
    echo -e "用户数 : 共 ${USER_COUNT} 个，活跃 ${ACTIVE_COUNT} 个"
    echo -e "公网IP : ${PUBLIC_IP}"
    echo -e "负载   : ${LOAD_INFO:-N/A}  内存 ${MEM_INFO:-N/A}  交换 ${SWAP_INFO:-N/A}"
    echo -e "在线   : ${UPTIME_INFO:-N/A}"
    echo ""

    if has_reality; then
        local SHORTID
        SHORTID=$(python3 -c "
import json
d=json.load(open('$SBOX_CONFIG', encoding='utf-8'))
for i in d.get('inbounds',[]):
    if i.get('tag')=='inbound-reality':
        print(i['tls']['reality']['short_id'][0]); break
" 2>/dev/null)
        echo -e "${CYAN}── Reality 节点 ──${NC}"
        echo -e "地址   : ${PUBLIC_IP}"
        echo -e "端口   : ${REALITY_PORT}"
        echo -e "公钥   : ${REALITY_PUBLIC_KEY}"
        echo -e "SNI    : ${REALITY_SNI}"
        echo -e "ShortID: ${SHORTID}"
        echo -e "协议   : VLESS+Reality+TCP"
        if [[ -f "$USER_DB" ]]; then
            echo -e "${CYAN}分享链接:${NC}"
            local RNAME RUUID REXP RSTATUS RNODE
            while IFS=: read -r RNAME RUUID REXP RSTATUS RNODE; do
                [[ "$RSTATUS" != "active" ]] && continue
                RNODE=${RNODE:-both}
                [[ "$RNODE" != "reality" && "$RNODE" != "both" ]] && continue
                echo "[${RNAME}] vless://${RUUID}@${PUBLIC_IP}:${REALITY_PORT}/?type=tcp&encryption=none&flow=xtls-rprx-vision&sni=${REALITY_SNI}&fp=chrome&security=reality&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORTID}#${RNAME}-reality"
            done < "$USER_DB"
        fi
        echo ""
    fi

    if has_shadowsocks; then
        local SS_USERINFO_SHOW SS_LINK_SHOW
        SS_USERINFO_SHOW=$(printf '%s' "${SS_METHOD}:${SS_PASSWORD}" | base64 -w0)
        SS_LINK_SHOW="ss://${SS_USERINFO_SHOW}@${PUBLIC_IP}:${SS_PORT}#Shadowsocks-${SS_PORT}"
        echo -e "${CYAN}── Shadowsocks 节点 ──${NC}"
        echo -e "地址   : ${PUBLIC_IP}"
        echo -e "端口   : ${SS_PORT}"
        echo -e "加密   : ${SS_METHOD}"
        echo -e "密码   : ${SS_PASSWORD}"
        echo -e "${CYAN}分享链接:${NC}"
        echo "$SS_LINK_SHOW"
        echo ""
    fi

    if has_ws; then
        echo -e "${CYAN}── WS+CF 节点 ──${NC}"
        echo -e "域名   : ${WS_DOMAIN}"
        echo -e "端口   : ${WS_CF_PORT:-443}"
        echo -e "WS路径 : ${WS_PATH}"
        echo -e "协议   : VLESS+WS+TLS"
        echo ""
    fi

    if has_hy2; then
        local HY2_STATUS HY2_PORT_SHOW HY2_PASSWORD_SHOW HY2_SNI_SHOW HY2_LINK_SHOW
        HY2_STATUS=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)
        HY2_PORT_SHOW=$(read_kv "$META_HY2" "HY2_PORT")
        HY2_PASSWORD_SHOW=$(read_kv "$META_HY2" "HY2_PASSWORD")
        HY2_SNI_SHOW=$(read_kv "$META_HY2" "HY2_SNI")
        HY2_LINK_SHOW="hy2://${HY2_PASSWORD_SHOW}@${PUBLIC_IP}:${HY2_PORT_SHOW}/?sni=${HY2_SNI_SHOW}&insecure=1#Hysteria2-${HY2_PORT_SHOW}"
        echo -e "${CYAN}── Hysteria2 节点 ──${NC}"
        echo -e "状态   : $( [[ "$HY2_STATUS" == "active" ]] && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}已停止${NC}" )"
        echo -e "地址   : ${PUBLIC_IP}"
        echo -e "端口   : ${HY2_PORT_SHOW} (UDP)"
        echo -e "密码   : ${HY2_PASSWORD_SHOW}"
        echo -e "SNI    : ${HY2_SNI_SHOW}"
        echo -e "协议   : Hysteria2（自签名，客户端需 insecure）"
        echo -e "${CYAN}分享链接:${NC}"
        echo "$HY2_LINK_SHOW"
        echo ""
    fi

    if ! has_reality && ! has_shadowsocks && ! has_ws && ! has_hy2; then
        warn "尚未配置任何节点"
    fi
}

# ============================================================
# 更新 sing-box
# ============================================================
update_sbox() {
    title "更新 sing-box..."
    local CURRENT_VER
    CURRENT_VER=$("$SBOX_BIN" version 2>/dev/null | awk '{print $NF}')
    info "当前版本: ${CURRENT_VER:-未知}"
    info "正在更新..."

    bash <(curl -fsSL https://sing-box.app/deb-install.sh) 2>/dev/null
    local NEW_VER
    NEW_VER=$("$SBOX_BIN" version 2>/dev/null | awk '{print $NF}')
    if [[ "$CURRENT_VER" == "$NEW_VER" ]]; then
        info "已是最新版本: ${NEW_VER:-未知}"
    else
        info "更新完成: ${CURRENT_VER:-未知} → ${NEW_VER:-未知}"
    fi
    systemctl restart "$SERVICE_NAME"
    info "sing-box 已重启"
}

# ============================================================
# 更新脚本
# ============================================================
update_script() {
    title "更新管理脚本..."
    local SCRIPT_URL="https://raw.githubusercontent.com/chenege-ck/vless-manager/main/singbox-manager.sh"
    info "正在从 GitHub 拉取最新版本..."
    local TMP_SCRIPT="/tmp/singbox_new.sh"
    curl -sL "$SCRIPT_URL" -o "$TMP_SCRIPT"
    if [[ $? -ne 0 || ! -s "$TMP_SCRIPT" ]]; then
        error "下载失败，请检查网络"; return
    fi
    if ! bash -n "$TMP_SCRIPT" 2>/dev/null; then
        error "脚本语法错误，取消更新"; rm -f "$TMP_SCRIPT"; return
    fi
    cp "$TMP_SCRIPT" /usr/local/bin/singbox_manager.sh
    chmod +x /usr/local/bin/singbox_manager.sh
    rm -f "$TMP_SCRIPT"
    info "脚本已更新"
    info "正在重新启动新版本..."
    sleep 1
    exec bash /usr/local/bin/singbox_manager.sh
}

# ============================================================
# Telegram 机器人内嵌脚本提取
# ============================================================
extract_telegram_runtime() {
    mkdir -p "$SBOX_DIR" /etc/vless-manager
    awk '
        /^###__SBOX_TG_BOT_PY__###$/ {inside=1; next}
        /^###__END_SBOX_TG_BOT_PY__###$/ {inside=0; exit}
        inside {sub(/^#TG\|/, ""); print}
    ' "$0" > /etc/vless-manager/sbox_tg_bot.py
    [[ -s /etc/vless-manager/sbox_tg_bot.py ]] || { error "机器人程序提取失败"; return 1; }
    chmod 700 /etc/vless-manager/sbox_tg_bot.py
}

# ============================================================
# 安装 Telegram 机器人（精简版：仅管理+延迟，无流量统计）
# ============================================================
install_telegram_bot() {
    title "安装 Telegram 管理机器人"
    command -v python3 >/dev/null 2>&1 || { error "缺少 python3"; return 1; }
    [[ -x "$SBOX_BIN" ]] || { error "请先安装 sing-box"; return 1; }

    local BOT_TOKEN BOT_INFO BOT_USERNAME BIND_TOKEN BIND_URL
    read -rsp "输入 Bot Token（不显示）: " BOT_TOKEN
    echo ""
    [[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{20,}$ ]] || { error "Token 格式不正确"; return 1; }

    BOT_INFO=$(curl -fsS --max-time 15 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null) || {
        error "无法验证 Token，请检查网络"; return 1
    }
    BOT_USERNAME=$(BOT_INFO="$BOT_INFO" python3 -c "
import json, os
data = json.loads(os.environ['BOT_INFO'])
print(data['result']['username'] if data.get('ok') else '')
" 2>/dev/null)
    [[ "$BOT_USERNAME" =~ ^[A-Za-z0-9_]{5,}$ ]] || { error "Token 验证失败"; return 1; }

    # 注册命令菜单
    curl -fsS --max-time 15 "https://api.telegram.org/bot${BOT_TOKEN}/setMyCommands" \
        -d '{"commands":[{"command":"start","description":"帮助"},{"command":"users","description":"用户列表"},{"command":"user","description":"用户详情：/user 用户名"},{"command":"expiring","description":"7天内到期用户"},{"command":"ping","description":"延迟测试"},{"command":"status","description":"机器人状态"}]}' \
        >/dev/null 2>&1 && info "已注册命令快捷键" || warn "命令快捷键注册失败"

    BIND_TOKEN=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')
    BIND_URL="https://t.me/${BOT_USERNAME}?start=${BIND_TOKEN}"

    extract_telegram_runtime || return 1

    cat > /etc/vless-manager/bot.conf <<EOF
BOT_TOKEN=${BOT_TOKEN}
ADMIN_CHAT_IDS=
BIND_TOKEN=${BIND_TOKEN}
USER_DB=${USER_DB}
PING_INTERVAL=600
PING_HOST=1.1.1.1
EOF
    chmod 600 /etc/vless-manager/bot.conf

    cat > /etc/systemd/system/sbox-tgbot.service <<EOF
[Unit]
Description=sing-box VLESS Telegram bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /etc/vless-manager/sbox_tg_bot.py --config /etc/vless-manager/bot.conf
Restart=always
RestartSec=5
User=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/etc/sing-box /etc/vless-manager
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sbox-tgbot.service >/dev/null 2>&1
    systemctl restart sbox-tgbot.service
    sleep 2

    if systemctl is-active --quiet sbox-tgbot.service; then
        info "Telegram 机器人已启动"
        echo ""
        title "扫码绑定 Telegram"
        if command -v qrencode >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq qrencode >/dev/null 2>&1); then
            qrencode -t ANSIUTF8 "$BIND_URL"
        else
            warn "请直接打开下方链接"
        fi
        echo -e "  ${CYAN}${BIND_URL}${NC}"
        echo ""
        info "用 Telegram 扫码或打开链接，点击"开始"完成绑定"
        warn "绑定链接仅可使用一次"
    else
        error "服务启动失败，运行 journalctl -u sbox-tgbot -n 20 查看"
        return 1
    fi
}

# ============================================================
# Telegram 服务状态 / 日志
# ============================================================
telegram_bot_status() {
    title "Telegram 服务状态"
    systemctl --no-pager --full status sbox-tgbot.service 2>/dev/null || true
}

telegram_bot_logs() {
    title "Telegram 最近日志"
    journalctl -u sbox-tgbot.service -n 40 --no-pager
}

# ============================================================
# 卸载 Telegram 机器人
# ============================================================
uninstall_telegram_bot() {
    read -rp "确认卸载机器人？[y/N]: " C
    [[ "$C" != "y" && "$C" != "Y" ]] && return
    systemctl disable --now sbox-tgbot.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/sbox-tgbot.service
    rm -rf /etc/vless-manager
    systemctl daemon-reload
    info "机器人已卸载"
}

# ============================================================
# Telegram 机器人子菜单
# ============================================================
telegram_bot_menu() {
    while true; do
        clear
        title "Telegram 机器人"
        echo -e "  ${GREEN}1.${NC} 安装 / 重新配置"
        echo -e "  ${GREEN}2.${NC} 查看运行状态"
        echo -e "  ${GREEN}3.${NC} 重启机器人"
        echo -e "  ${GREEN}4.${NC} 查看最近日志"
        echo -e "  ${RED}5.${NC} 卸载机器人"
        echo -e "  ${GREEN}0.${NC} 返回主菜单"
        echo ""
        read -rp "请选择: " TG_OPT
        case "$TG_OPT" in
            1) install_telegram_bot ;;
            2) telegram_bot_status ;;
            3) systemctl restart sbox-tgbot.service && info "已重启" ;;
            4) telegram_bot_logs ;;
            5) uninstall_telegram_bot ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
        echo ""; read -rp "按 Enter 继续..." _
    done
}
# ============================================================
# 安装快捷命令 c
# ============================================================
install_shortcut() {
    local SELF_PATH
    SELF_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [[ "$SELF_PATH" != "/usr/local/bin/singbox_manager.sh" ]]; then
        cp "$SELF_PATH" /usr/local/bin/singbox_manager.sh
        chmod +x /usr/local/bin/singbox_manager.sh
    fi
    cat > /usr/local/bin/c <<'EOF'
#!/bin/bash
bash /usr/local/bin/singbox_manager.sh
EOF
    chmod +x /usr/local/bin/c
}

# ============================================================
# 设置 cron 到期检查
# ============================================================
setup_cron() {
    local EXPIRE_CMD="*/5 * * * * /usr/local/bin/singbox_manager.sh --check-expire >> /var/log/sbox-expire.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "check-expire"; echo "$EXPIRE_CMD") | crontab -
    info "已设置每 5 分钟自动检查到期用户"

    mkdir -p /var/log
    cat > /etc/logrotate.d/sbox-expire <<'EOF'
/var/log/sbox-expire.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF
    info "已配置日志轮转"
}

# ============================================================
# CLI 模式（供 cron 调用）
# ============================================================
if [[ "$1" == "--check-expire" ]]; then
    normalize_user_db
    check_expire
    exit 0
fi

# ============================================================
# 主菜单
# ============================================================
main_menu() {
    while true; do
        clear
        normalize_user_db
        load_meta

        local SBOX_STATUS USER_COUNT ACTIVE_COUNT
        SBOX_STATUS=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)
        USER_COUNT=0; [[ -f "$USER_DB" ]] && USER_COUNT=$(wc -l < "$USER_DB")
        ACTIVE_COUNT=0; [[ -f "$USER_DB" ]] && ACTIVE_COUNT=$(grep -c ":active:" "$USER_DB" 2>/dev/null || echo 0)

        local MODE_STR=""
        has_reality     && MODE_STR="Reality"
        has_shadowsocks && MODE_STR="${MODE_STR:+$MODE_STR+}SS"
        has_ws          && MODE_STR="${MODE_STR:+$MODE_STR+}WS"
        has_hy2         && MODE_STR="${MODE_STR:+$MODE_STR+}HY2"
        [[ -z "$MODE_STR" ]] && MODE_STR="未配置"

        local STATUS_COLOR=$RED STATUS_TEXT="● 已停止"
        [[ "$SBOX_STATUS" == "active" ]] && STATUS_COLOR=$GREEN && STATUS_TEXT="● 运行中"

        local TG_STATUS="未安装"
        systemctl is-active --quiet sbox-tgbot.service 2>/dev/null && TG_STATUS="运行中"

        echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}智能节点控制台 (sing-box)  v1.0${NC}           ${BLUE}║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  sing-box ${STATUS_COLOR}${STATUS_TEXT}${NC}   模式 ${YELLOW}${MODE_STR}${NC}"
        echo -e "${BLUE}║${NC}  用户 ${GREEN}${ACTIVE_COUNT}${NC} 活跃 / ${USER_COUNT} 总计   TG ${CYAN}${TG_STATUS}${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}▣ 节点中心${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}1.${NC}  安装 sing-box 并配置节点"
        echo -e "${BLUE}║${NC}   ${GREEN}2.${NC}  添加 / 移除协议节点"
        echo -e "${BLUE}╠══════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}▣ 用户中心${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}3.${NC}  新建用户          ${GREEN}4.${NC}  删除用户"
        echo -e "${BLUE}║${NC}   ${GREEN}5.${NC}  禁用用户          ${GREEN}6.${NC}  启用用户"
        echo -e "${BLUE}║${NC}   ${GREEN}7.${NC}  用户续期          ${GREEN}8.${NC}  用户列表"
        echo -e "${BLUE}║${NC}   ${GREEN}9.${NC}  查看分享链接"
        echo -e "${BLUE}╠══════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}▣ Telegram${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}10.${NC} Telegram 机器人管理"
        echo -e "${BLUE}║${NC}   ${GREEN}11.${NC} 节点运行信息"
        echo -e "${BLUE}╠══════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}▣ 系统维护${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}12.${NC} 更新 sing-box     ${GREEN}13.${NC} 更新管理脚本"
        echo -e "${BLUE}║${NC}   ${GREEN}14.${NC} IPv4/IPv6 优先级  ${RED}15.${NC} 卸载 sing-box"
        echo -e "${BLUE}║${NC}   ${GREEN}0.${NC}   退出"
        echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
        echo -ne " 请选择 » "
        read -r OPT

        case $OPT in
            1)  check_system; set_shanghai_timezone; install_sbox; init_config; setup_cron ;;
            2)  init_config ;;
            3)  add_user ;;
            4)  delete_user ;;
            5)  toggle_user disable ;;
            6)  toggle_user enable ;;
            7)  renew_user ;;
            8)  list_users ;;
            9)  show_user_link ;;
            10) telegram_bot_menu ;;
            11) show_info ;;
            12) update_sbox ;;
            13) update_script ;;
            14) ip_priority_menu ;;
            15) uninstall_sbox ;;
            0)  echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *)  warn "无效选项" ;;
        esac

        echo ""
        echo -ne "${BLUE}按 Enter 返回菜单...${NC}"
        read -r _
    done
}

# ============================================================
# 脚本入口
# ============================================================
check_system
normalize_user_db
install_shortcut
main_menu


###__SBOX_TG_BOT_PY__###
#TG|#!/usr/bin/env python3
#TG|"""Sing-box VLESS Telegram management bot (no traffic stats)."""
#TG|from __future__ import annotations
#TG|
#TG|import argparse
#TG|import html
#TG|import json
#TG|import os
#TG|import re
#TG|import secrets
#TG|import socket
#TG|import subprocess
#TG|import threading
#TG|import time
#TG|import urllib.error
#TG|import urllib.parse
#TG|import urllib.request
#TG|from datetime import datetime
#TG|from pathlib import Path
#TG|from typing import Optional
#TG|
#TG|DEFAULT_CONFIG = Path("/etc/vless-manager/bot.conf")
#TG|DEFAULT_USERS = Path("/etc/sing-box/users.db")
#TG|BIND_LOCK = threading.Lock()
#TG|
#TG|
#TG|def parse_config(path: Path) -> dict:
#TG|    result = {}
#TG|    if not path.exists():
#TG|        return result
#TG|    for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
#TG|        line = raw.strip()
#TG|        if not line or line.startswith("#") or "=" not in line:
#TG|            continue
#TG|        key, value = line.split("=", 1)
#TG|        result[key.strip()] = value.strip()
#TG|    ids = set()
#TG|    for item in result.get("ADMIN_CHAT_IDS", "").split(","):
#TG|        item = item.strip()
#TG|        if item.isdigit() and int(item) > 0:
#TG|            ids.add(int(item))
#TG|    result["ADMIN_CHAT_IDS"] = ids
#TG|    return result
#TG|
#TG|
#TG|def is_authorized(config: dict, chat_id: int) -> bool:
#TG|    return int(chat_id) in config.get("ADMIN_CHAT_IDS", set())
#TG|
#TG|
#TG|def is_authorized_message(config: dict, message: dict) -> bool:
#TG|    sender_id = (message.get("from") or {}).get("id")
#TG|    return sender_id is not None and is_authorized(config, int(sender_id))
#TG|
#TG|
#TG|def validate_bot_config(config: dict) -> None:
#TG|    if not config.get("BOT_TOKEN"):
#TG|        raise ValueError("请先配置 BOT_TOKEN")
#TG|    if not config.get("ADMIN_CHAT_IDS") and not config.get("BIND_TOKEN"):
#TG|        raise ValueError("机器人尚未绑定")
#TG|
#TG|
#TG|def update_config_values(path: Path, values: dict) -> None:
#TG|    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines() if path.exists() else []
#TG|    pending = dict(values)
#TG|    output = []
#TG|    for line in lines:
#TG|        key = line.split("=", 1)[0].strip() if "=" in line else ""
#TG|        if key in pending:
#TG|            output.append(f"{key}={pending.pop(key)}")
#TG|        else:
#TG|            output.append(line)
#TG|    output.extend(f"{k}={v}" for k, v in pending.items())
#TG|    tmp = path.with_name(f".{path.name}.{secrets.token_hex(6)}.tmp")
#TG|    try:
#TG|        tmp.write_text("\n".join(output) + "\n", encoding="utf-8")
#TG|        tmp.chmod(0o600)
#TG|        os.replace(tmp, path)
#TG|    finally:
#TG|        try:
#TG|            tmp.unlink()
#TG|        except FileNotFoundError:
#TG|            pass
#TG|
#TG|
#TG|def claim_binding(config_path: Path, config: dict, message: dict) -> bool:
#TG|    chat = message.get("chat") or {}
#TG|    sender_id = (message.get("from") or {}).get("id")
#TG|    parts = message.get("text", "").strip().split(maxsplit=1)
#TG|    if chat.get("type") != "private" or sender_id is None or len(parts) != 2:
#TG|        return False
#TG|    command = parts[0].split("@", 1)[0].lower()
#TG|    supplied = parts[1].strip()
#TG|    with BIND_LOCK:
#TG|        expected = str(config.get("BIND_TOKEN", ""))
#TG|        if command != "/start" or not expected or not secrets.compare_digest(supplied, expected):
#TG|            return False
#TG|        admin_id = int(sender_id)
#TG|        update_config_values(config_path, {"ADMIN_CHAT_IDS": str(admin_id), "BIND_TOKEN": ""})
#TG|        config["ADMIN_CHAT_IDS"] = {admin_id}
#TG|        config["BIND_TOKEN"] = ""
#TG|        return True
#TG|
#TG|
#TG|def read_users(path: Path = DEFAULT_USERS) -> list[dict]:
#TG|    users = []
#TG|    if not path.exists():
#TG|        return users
#TG|    for raw in path.read_text(encoding="utf-8", errors="ignore").splitlines():
#TG|        parts = raw.strip().split(":")
#TG|        if len(parts) < 5:
#TG|            continue
#TG|        users.append({
#TG|            "name": parts[0], "uuid": parts[1], "expire": parts[2],
#TG|            "status": parts[3], "node": parts[4] or "both",
#TG|        })
#TG|    return users
#TG|
#TG|
#TG|def parse_expire(value: str) -> Optional[datetime]:
#TG|    for fmt in ("%Y-%m-%d_%H-%M-%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
#TG|        try:
#TG|            dt = datetime.strptime(value, fmt)
#TG|            if fmt == "%Y-%m-%d":
#TG|                dt = dt.replace(hour=12)
#TG|            return dt
#TG|        except ValueError:
#TG|            pass
#TG|    return None
#TG|
#TG|
#TG|def remaining_days(expire: str, now: Optional[datetime] = None) -> Optional[int]:
#TG|    dt = parse_expire(expire)
#TG|    if not dt:
#TG|        return None
#TG|    now = now or datetime.now()
#TG|    seconds = (dt - now).total_seconds()
#TG|    return 0 if seconds <= 0 else int((seconds + 86399) // 86400)
#TG|
#TG|
#TG|def tg_request(token: str, method: str, data: Optional[dict] = None) -> dict:
#TG|    url = f"https://api.telegram.org/bot{token}/{method}"
#TG|    encoded = urllib.parse.urlencode(data or {}).encode()
#TG|    req = urllib.request.Request(url, data=encoded)
#TG|    with urllib.request.urlopen(req, timeout=65) as resp:
#TG|        result = json.loads(resp.read().decode("utf-8"))
#TG|    if not result.get("ok"):
#TG|        raise RuntimeError(result.get("description", "Telegram API 错误"))
#TG|    return result
#TG|
#TG|
#TG|def send_message(token: str, chat_id: int, text: str) -> None:
#TG|    tg_request(token, "sendMessage", {
#TG|        "chat_id": str(chat_id), "text": text, "parse_mode": "HTML",
#TG|        "disable_web_page_preview": "true",
#TG|    })
#TG|
#TG|
#TG|def measure_ping_latency(host: str = "1.1.1.1") -> Optional[float]:
#TG|    try:
#TG|        res = subprocess.run(
#TG|            ["ping", "-c", "4", "-W", "3", host],
#TG|            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
#TG|            timeout=20, check=False,
#TG|        )
#TG|        out = res.stdout.decode("utf-8", errors="ignore") or ""
#TG|    except Exception:
#TG|        return None
#TG|    m = re.search(r"min/avg/max/(?:mdev|stddev)\s*=\s*[\d.]+/([\d.]+)/[\d.]+/[\d.]+", out)
#TG|    return float(m.group(1)) if m else None
#TG|
#TG|
#TG|def measure_tcp_latency(host: str, port: int = 80, timeout: float = 4.0) -> Optional[float]:
#TG|    try:
#TG|        ip = socket.gethostbyname(host)
#TG|        t0 = time.monotonic()
#TG|        with socket.create_connection((ip, port), timeout=timeout):
#TG|            return (time.monotonic() - t0) * 1000.0
#TG|    except Exception:
#TG|        return None
#TG|
#TG|
#TG|CARRIER_TARGETS = [
#TG|    ("联通", "sc-cu-v4.ip.zstaticcdn.com", 80),
#TG|    ("移动", "sc-cm-v4.ip.zstaticcdn.com", 80),
#TG|    ("电信", "sc-ct-v4.ip.zstaticcdn.com", 80),
#TG|]
#TG|
#TG|
#TG|def ping_text(host: str = "1.1.1.1") -> str:
#TG|    lines = ["📡 <b>延迟测试</b>", ""]
#TG|    lat = measure_ping_latency(host)
#TG|    if lat is None:
#TG|        lines.append(f"🌐 <code>{html.escape(host)}</code> <b>无响应</b>")
#TG|    else:
#TG|        level = "🟢" if lat < 100 else ("🟡" if lat < 250 else "🔴")
#TG|        lines.append(f"🌐 <code>{html.escape(host)}</code> → {level} <b>{lat:.1f} ms</b>")
#TG|    lines.append("")
#TG|    for name, c_host, c_port in CARRIER_TARGETS:
#TG|        c_lat = measure_tcp_latency(c_host, c_port)
#TG|        label = f"{name} TCP"
#TG|        if c_lat is None:
#TG|            lines.append(f"{label} <b>无响应</b>")
#TG|        else:
#TG|            c_level = "🟢" if c_lat < 100 else ("🟡" if c_lat < 250 else "🔴")
#TG|            lines.append(f"{label} → {c_level} <b>{c_lat:.1f} ms</b>")
#TG|    return "\n".join(lines)
#TG|
#TG|
#TG|def users_text(users: list[dict]) -> str:
#TG|    rows = ["👥 <b>用户列表</b>", ""]
#TG|    for user in users:
#TG|        days = remaining_days(user["expire"])
#TG|        left = "未知" if days is None else ("已到期" if days == 0 else f"{days}天")
#TG|        icon = "🟢" if user["status"] == "active" else "🔴"
#TG|        rows.append(f"{icon} <code>{html.escape(user['name'])}</code> · {left} · {html.escape(user['node'])}")
#TG|    return "\n".join(rows) if len(rows) > 2 else "暂无用户"
#TG|
#TG|
#TG|def user_text(user: dict) -> str:
#TG|    days = remaining_days(user["expire"])
#TG|    day_text = "未知" if days is None else ("已到期" if days == 0 else f"{days} 天")
#TG|    expire = parse_expire(user["expire"])
#TG|    expire_text = expire.strftime("%Y-%m-%d %H:%M") if expire else user["expire"]
#TG|    state = "🟢 正常" if user["status"] == "active" else "🔴 已禁用"
#TG|    return (
#TG|        f"👤 <b>{html.escape(user['name'])}</b>\n"
#TG|        f"状态：{state}\n节点：{html.escape(user['node'])}\n"
#TG|        f"到期：{html.escape(expire_text)}\n剩余：<b>{day_text}</b>"
#TG|    )
#TG|
#TG|
#TG|def command_reply(text: str, users_path: Path) -> str:
#TG|    parts = text.strip().split(maxsplit=1)
#TG|    command = parts[0].split("@", 1)[0].lower() if parts else "/start"
#TG|    users = read_users(users_path)
#TG|    if command in ("/start", "/help"):
#TG|        return (
#TG|            "🤖 <b>VLESS 管理机器人</b>\n\n"
#TG|            "/users — 用户列表\n"
#TG|            "/user 用户名 — 用户详情\n"
#TG|            "/expiring — 7天内到期用户\n"
#TG|            "/ping — 延迟测试（三网 TCP）\n"
#TG|            "/status — 机器人状态"
#TG|        )
#TG|    if command == "/users":
#TG|        return users_text(users)
#TG|    if command == "/user":
#TG|        if len(parts) < 2:
#TG|            return "用法：<code>/user 用户名</code>"
#TG|        name = parts[1].strip()
#TG|        user = next((u for u in users if u["name"] == name), None)
#TG|        return user_text(user) if user else "未找到该用户"
#TG|    if command == "/expiring":
#TG|        selected = [u for u in users if (d := remaining_days(u["expire"])) is not None and d <= 7]
#TG|        return "⏰ <b>7天内到期</b>\n\n" + (users_text(selected) if selected else "暂无")
#TG|    if command == "/ping":
#TG|        return ping_text()
#TG|    if command == "/status":
#TG|        return "✅ 机器人在线\n🕐 " + datetime.now().strftime("%Y-%m-%d %H:%M:%S")
#TG|    return "未知命令，请发送 /help"
#TG|
#TG|
#TG|def handle_message(token: str, config_path: Path, cfg: dict, message: dict, users_path: Path) -> None:
#TG|    started = time.monotonic()
#TG|    chat_id = (message.get("chat") or {}).get("id")
#TG|    text = message.get("text", "")
#TG|    if chat_id is None or not text:
#TG|        return
#TG|    if claim_binding(config_path, cfg, message):
#TG|        send_message(token, int(chat_id), "✅ <b>绑定成功</b>\n\n发送 /start 查看可用命令。")
#TG|        print(f"binding=success admin={chat_id}", flush=True)
#TG|        return
#TG|    if not is_authorized_message(cfg, message):
#TG|        send_message(token, int(chat_id), "⛔ 未授权。请重新配置并扫描绑定二维码。")
#TG|        return
#TG|    send_message(token, int(chat_id), command_reply(text, users_path))
#TG|    print(f"command={text.split(maxsplit=1)[0]} elapsed={time.monotonic() - started:.3f}s", flush=True)
#TG|
#TG|
#TG|def run_bot(config_path: Path) -> None:
#TG|    cfg = parse_config(config_path)
#TG|    token = cfg.get("BOT_TOKEN", "")
#TG|    try:
#TG|        validate_bot_config(cfg)
#TG|    except ValueError as exc:
#TG|        raise SystemExit(str(exc)) from exc
#TG|    users_path = Path(cfg.get("USER_DB", str(DEFAULT_USERS)))
#TG|    offset = 0
#TG|    import concurrent.futures
#TG|    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
#TG|        while True:
#TG|            try:
#TG|                result = tg_request(token, "getUpdates", {"timeout": "50", "offset": str(offset), "limit": "20"})
#TG|                updates = result.get("result", [])
#TG|                if updates:
#TG|                    offset = max(int(item["update_id"]) for item in updates) + 1
#TG|                    tg_request(token, "getUpdates", {"timeout": "0", "offset": str(offset), "limit": "1"})
#TG|                    for update in updates:
#TG|                        pool.submit(handle_message, token, config_path, cfg, update.get("message") or {}, users_path)
#TG|            except (urllib.error.URLError, TimeoutError, RuntimeError, json.JSONDecodeError) as exc:
#TG|                print(f"bot: {exc}", flush=True)
#TG|                time.sleep(2)
#TG|
#TG|
#TG|def main() -> None:
#TG|    parser = argparse.ArgumentParser()
#TG|    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
#TG|    args = parser.parse_args()
#TG|    run_bot(args.config)
#TG|
#TG|
#TG|if __name__ == "__main__":
#TG|    main()
###__END_SBOX_TG_BOT_PY__###
