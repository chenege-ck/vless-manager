#!/bin/bash
# VLESS 智能节点控制台 v6.3
# Reality + WS + 用户管理 + Telegram + BBR/iperf3

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

XRAY_CONFIG="/usr/local/etc/xray/config.json"
USER_DB="/usr/local/etc/xray/users.db"
XRAY_BIN="/usr/local/bin/xray"
META_REALITY="/usr/local/etc/xray/meta-reality.conf"
META="/usr/local/etc/xray/meta.conf"
SS_CONFIG="/usr/local/etc/xray/shadowsocks.conf"
SS_PORT=8668
TG_DIR="/usr/local/lib/vless-manager"
TG_SCRIPT="${TG_DIR}/vless_tg_bot.py"
TG_CONFIG="/etc/vless-manager/bot.conf"
TRAFFIC_DB="/usr/local/etc/xray/traffic.db"
BBR_CONFIG="/etc/sysctl.d/99-vless-bbr.conf"
BBR_MODULE_CONFIG="/etc/modules-load.d/vless-bbr.conf"
IPERF_SERVICE="/etc/systemd/system/vless-iperf3.service"
IPERF_PORT=5201

info()  { echo -e "${GREEN}  ✓${NC}  $1"; }
warn()  { echo -e "${YELLOW}  ⚠${NC}  $1"; }
error() { echo -e "${RED}  ✗${NC}  $1"; }
title() { echo -e "\n${BLUE}┌─${NC} ${CYAN}$1${NC}"; echo -e "${BLUE}└────────────────────────────${NC}"; }

validate_username() {
    local value="$1"
    [[ "$value" =~ ^[A-Za-z0-9_-]+$ ]] || {
        error "用户名只能包含英文字母、数字、下划线和短横线"
        return 1
    }
}

validate_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || {
        error "用户数据库中的 UUID 格式异常，操作已停止"
        return 1
    }
}

user_exists() {
    awk -F: -v n="$1" '$1==n {found=1; exit} END {exit !found}' "$USER_DB" 2>/dev/null
}

get_user_field() {
    awk -F: -v n="$1" -v f="$2" '$1==n {print $f; exit}' "$USER_DB" 2>/dev/null
}

[[ $EUID -ne 0 ]] && error "请用 root 运行此脚本" && exit 1
# ============================================================
# 仅支持 Debian
# ============================================================
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
        *)
            error "仅支持 Debian 11/12/13，当前版本代号: ${CODENAME:-unknown}"
            exit 1
            ;;
    esac
}

# ============================================================
# 设置系统时区为上海
# ============================================================
set_shanghai_timezone() {
    title "设置系统时区"

    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-timezone Asia/Shanghai 2>/dev/null
    else
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
        echo "Asia/Shanghai" > /etc/timezone
    fi

    if [[ "$(readlink -f /etc/localtime 2>/dev/null)" == "/usr/share/zoneinfo/Asia/Shanghai" ]]; then
        info "系统时区已设置为 Asia/Shanghai（上海）"
    else
        warn "时区设置可能未生效，请手动执行: timedatectl set-timezone Asia/Shanghai"
    fi
}

# ============================================================
# 上海时间工具
# ============================================================
now_shanghai_ts() {
    TZ=Asia/Shanghai date +%s
}

expire_noon_str() {
    local days="$1"
    TZ=Asia/Shanghai date -d "+${days} days 12:00:00" "+%Y-%m-%d_%H-%M-%S" 2>/dev/null
}

expire_to_ts() {
    local expire="$1"

    if [[ "$expire" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
        local d="${expire%%_*}"
        local t="${expire#*_}"
        TZ=Asia/Shanghai date -d "${d} ${t//-/:}" +%s 2>/dev/null
        return
    fi

    if [[ "$expire" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        TZ=Asia/Shanghai date -d "${expire} 12:00:00" +%s 2>/dev/null
        return
    fi

    local normalized="${expire/T/ }"
    TZ=Asia/Shanghai date -d "$normalized" +%s 2>/dev/null
}

expire_display() {
    local expire="$1"
    if [[ "$expire" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
        local d="${expire%%_*}"
        local t="${expire#*_}"
        echo "${d} ${t//-/:}"
    elif [[ "$expire" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        echo "${expire/T/ }"
    elif [[ "$expire" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "${expire} 12:00:00"
    else
        echo "$expire"
    fi
}

# ============================================================
# 安全读取 key=value 配置，避免 source 执行任意内容
# ============================================================
read_kv() {
    local file="$1"
    local key="$2"
    [[ -f "$file" ]] || return 1
    awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file"
}

# ============================================================
# 获取公网 IP（失败兜底）
# ============================================================
get_public_ip() {
    local ip=""
    # 先尝试 IPv4
    ip=$(curl -s4 --max-time 5 ip.sb 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null)
    [[ -z "$ip" ]] && ip=$(curl -s4 --max-time 5 api.ipify.org 2>/dev/null)
    # IPv4 全失败则尝试 IPv6（纯 IPv6 机器）
    if [[ -z "$ip" ]]; then
        ip=$(curl -s6 --max-time 5 ip.sb 2>/dev/null)
        [[ -z "$ip" ]] && ip=$(curl -s6 --max-time 5 ifconfig.me 2>/dev/null)
    fi
    echo "${ip:-<请手动填写服务器IP>}"
}

# ============================================================
# users.db 统一格式：NAME:UUID:EXPIRE:STATUS:NODE
# ============================================================
normalize_user_db() {
    [[ ! -f "$USER_DB" ]] && return 0
    python3 - <<PYEOF
from pathlib import Path
import re

p = Path("$USER_DB")
lines = p.read_text(encoding="utf-8", errors="ignore").splitlines()
out = []
changed = False

def normalize_expire(exp: str) -> str:
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

# ============================================================
# 加载元数据（不再 source）
# ============================================================
load_meta() {
    REALITY_PRIVATE_KEY=""
    REALITY_PUBLIC_KEY=""
    REALITY_SNI=""
    REALITY_PORT=""
    REALITY_SHORTID=""
    SS_PORT=8668
    SS_METHOD="aes-256-gcm"
    SS_PASSWORD=""

    if [[ -f "$META_REALITY" ]]; then
        REALITY_PRIVATE_KEY=$(read_kv "$META_REALITY" "REALITY_PRIVATE_KEY")
        REALITY_PUBLIC_KEY=$(read_kv "$META_REALITY" "REALITY_PUBLIC_KEY")
        REALITY_SNI=$(read_kv "$META_REALITY" "REALITY_SNI")
        REALITY_PORT=$(read_kv "$META_REALITY" "REALITY_PORT")
        REALITY_SHORTID=$(read_kv "$META_REALITY" "REALITY_SHORTID")
    fi
    if [[ -f "$SS_CONFIG" ]]; then
        SS_PORT=$(read_kv "$SS_CONFIG" "SS_PORT")
        SS_METHOD=$(read_kv "$SS_CONFIG" "SS_METHOD")
        SS_PASSWORD=$(read_kv "$SS_CONFIG" "SS_PASSWORD")
    fi
}

has_reality() { [[ -f "$META_REALITY" ]]; }
has_shadowsocks() { [[ -f "$SS_CONFIG" ]]; }

# ============================================================
# 配置校验
# ============================================================
validate_xray_config() {
    [[ ! -f "$XRAY_CONFIG" ]] && error "配置文件不存在: $XRAY_CONFIG" && return 1

    python3 -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8'))" "$XRAY_CONFIG" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        error "config.json 不是合法 JSON"
        return 1
    fi

    "$XRAY_BIN" run -test -config "$XRAY_CONFIG" >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        error "Xray 配置校验失败，未执行重启"
        return 1
    fi

    return 0
}

# ============================================================
# 修复 apt 源（仅 Debian 11/12/13）
# ============================================================
fix_apt() {
    local CODENAME
    CODENAME=$(awk -F= '/^VERSION_CODENAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release 2>/dev/null)

    [[ -z "$CODENAME" ]] && error "无法识别 Debian 版本代号" && return 1

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
        *)
            error "不支持的 Debian 版本代号: $CODENAME"
            return 1
            ;;
    esac

    apt-get update -qq
    if [[ $? -ne 0 ]]; then
        error "apt 源修复后仍然更新失败，请手动检查 /etc/apt/sources.list"
        return 1
    fi

    info "apt 源已修复: ${CODENAME}"
    return 0
}

# ============================================================
# 安装依赖
# ============================================================
install_deps() {
    title "安装依赖..."

    info "正在使用当前 apt 软件源更新索引..."
    if ! apt-get update -qq; then
        warn "当前 apt 软件源更新失败"
        warn "自动修复会备份并覆盖 /etc/apt/sources.list"

        local REPAIR_APT
        read -rp "apt 更新失败，是否自动修复软件源？[y/N]: " REPAIR_APT
        if [[ "$REPAIR_APT" == "y" || "$REPAIR_APT" == "Y" ]]; then
            fix_apt || return 1
        else
            error "已取消修复 apt 源，未修改 /etc/apt/sources.list"
            return 1
        fi
    else
        info "当前 apt 软件源可用，保持原配置不变"
    fi

    apt-get install -y -qq curl unzip openssl python3
    [[ $? -ne 0 ]] && error "依赖安装失败" && return 1
    info "依赖安装完成"
}

# ============================================================
# ============================================================
# 安装 xray
# ============================================================
install_xray() {
    title "安装 Xray..."
    if [[ -f "$XRAY_BIN" ]]; then
        warn "Xray 已安装，跳过"
        return
    fi
    install_deps || return 1

    [[ -f "$XRAY_CONFIG" ]] && cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak"
    curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o /tmp/xray-install.sh
    bash /tmp/xray-install.sh install
    [[ $? -ne 0 ]] && error "安装失败，请检查网络" && exit 1

    [[ -f "${XRAY_CONFIG}.bak" ]] && mv "${XRAY_CONFIG}.bak" "$XRAY_CONFIG" && info "已恢复原配置"
    info "Xray 安装成功"
}

# ============================================================
# 卸载 xray
# ============================================================
uninstall_xray() {
    title "卸载 Xray..."
    read -rp "确认卸载？将删除所有配置和用户数据 [y/N]: " CONFIRM
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && warn "已取消" && return

    systemctl stop xray 2>/dev/null
    systemctl disable xray 2>/dev/null
    curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o /tmp/xray-install.sh
    bash /tmp/xray-install.sh remove
    rm -rf /usr/local/etc/xray
    rm -f /var/log/xray/access.log /var/log/xray/error.log
    crontab -l 2>/dev/null | grep -v "check-expire" | crontab -
    rm -f /usr/local/bin/c
    info "Xray 已完全卸载"
    exit 0
}

# ============================================================
# 生成密钥对
# ============================================================
gen_keypair() {
    local OUTPUT
    OUTPUT=$($XRAY_BIN x25519 2>/dev/null)
    PRIVATE_KEY=$(echo "$OUTPUT" | grep -i "PrivateKey" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$OUTPUT" | grep -i "PublicKey\|Public" | awk '{print $NF}')
}

# ============================================================
# 检查端口是否占用
# ============================================================
check_port() {
    ss -tlnp | grep -q ":${1} " && return 1 || return 0
}

# ============================================================
# 初始化配置 - 选择协议
# ============================================================
init_config() {
    title "节点配置..."
    mkdir -p /usr/local/etc/xray
    touch "$USER_DB"
    chmod 600 "$USER_DB"
    normalize_user_db
    load_meta

    echo ""
    echo "当前节点状态："
    has_reality && echo -e "  ${GREEN}✓${NC} Reality 已启用" || echo -e "  ${RED}✗${NC} Reality 未启用"
    has_shadowsocks && echo -e "  ${GREEN}✓${NC} Shadowsocks 已启用" || echo -e "  ${RED}✗${NC} Shadowsocks 未启用"
    echo ""
    echo "请选择要操作的节点："
    echo -e "  ${GREEN}1.${NC} 配置 VLESS + Reality"
    echo -e "  ${GREEN}2.${NC} 配置 Shadowsocks + aes-256-gcm"
    has_reality && echo -e "  ${RED}3.${NC} 移除 Reality 节点"
    has_shadowsocks && echo -e "  ${RED}4.${NC} 移除 Shadowsocks 节点"
    echo ""
    read -rp "选择: " MODE_SEL
    case $MODE_SEL in
        1)
            if has_reality; then
                warn "Reality 节点已存在，重新配置将覆盖"
                read -rp "确认继续？[y/N]: " C
                [[ "$C" != "y" && "$C" != "Y" ]] && warn "已取消" && return
            fi
            init_reality
            ;;
        2) init_shadowsocks ;;
        3)
            has_reality || { error "Reality 节点未启用"; return; }
            read -rp "确认移除 Reality 节点？[y/N]: " C
            [[ "$C" != "y" && "$C" != "Y" ]] && warn "已取消" && return
            rm -f "$META_REALITY"
            rebuild_config
            _inject_all_users
            _start_xray
            info "Reality 节点已移除"
            ;;
        4)
            has_shadowsocks || { error "Shadowsocks 节点未启用"; return; }
            read -rp "确认移除 Shadowsocks 节点？[y/N]: " C
            [[ "$C" != "y" && "$C" != "Y" ]] && warn "已取消" && return
            rm -f "$SS_CONFIG"
            rebuild_config
            _inject_all_users
            _start_xray
            info "Shadowsocks 节点已移除"
            ;;
        *) error "无效选择" ;;
    esac
}

# ============================================================
# 初始化 Reality（保留原创建逻辑）
# ============================================================
init_reality() {
    gen_keypair
    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        error "密钥生成失败"
        return
    fi

    while true; do
        read -rp "监听端口 [默认 8443]: " REALITY_PORT
        REALITY_PORT=${REALITY_PORT:-8443}
        check_port "$REALITY_PORT" && break || warn "端口 ${REALITY_PORT} 已被占用，请换一个"
    done

    read -rp "伪装域名 [默认 www.apple.com]: " REALITY_SNI
    REALITY_SNI=${REALITY_SNI:-www.apple.com}
    local REALITY_SHORTID
    REALITY_SHORTID=$(openssl rand -hex 4)

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
    _start_xray
    info "Reality 节点配置完成"
    info "公钥: ${PUBLIC_KEY}"
}

# ============================================================
# 初始化 Shadowsocks（共享密码入口）
# ============================================================
init_shadowsocks() {
    title "配置 Shadowsocks"
    local EXISTING_PASSWORD
    load_meta
    if has_shadowsocks; then
        warn "Shadowsocks 已存在，重新配置会生成新密码并使旧密码失效"
        read -rp "确认继续？[y/N]: " C
        [[ "$C" != "y" && "$C" != "Y" ]] && return
    fi
    check_port "$SS_PORT" || {
        error "端口 ${SS_PORT} 已被其他程序占用"
        return 1
    }
    SS_METHOD="aes-256-gcm"
    SS_PASSWORD=$(openssl rand -base64 32 | tr -d '=+/\n' | cut -c1-32)
    [[ ${#SS_PASSWORD} -ge 24 ]] || { error "随机密码生成失败"; return 1; }
    cat > "$SS_CONFIG" <<EOF
SS_PORT=${SS_PORT}
SS_METHOD=${SS_METHOD}
SS_PASSWORD=${SS_PASSWORD}
EOF
    chmod 600 "$SS_CONFIG"
    rebuild_config || return 1
    _inject_all_users
    _start_xray || return 1
    info "Shadowsocks 配置完成"
    show_protocol_links
}

show_protocol_links() {
    load_meta
    local SERVER_IP SS_USERINFO SS_LINK
    SERVER_IP=$(get_public_ip)
    echo ""
    echo -e "${GREEN}===== 协议节点信息 =====${NC}"
    if has_reality; then
        echo -e "${CYAN}Reality${NC}: ${SERVER_IP}:${REALITY_PORT}"
    fi
    if has_shadowsocks; then
        SS_USERINFO=$(printf '%s' "${SS_METHOD}:${SS_PASSWORD}" | base64 -w0)
        SS_LINK="ss://${SS_USERINFO}@${SERVER_IP}:${SS_PORT}#Shadowsocks-${SS_PORT}"
        echo -e "${CYAN}Shadowsocks${NC}: ${SERVER_IP}:${SS_PORT}"
        echo -e "加密   : ${SS_METHOD}"
        echo -e "密码   : ${SS_PASSWORD}"
        echo -e "分享链接:"
        echo "$SS_LINK"
    fi
    echo ""
}

show_ss_link() {
    has_shadowsocks || { error "Shadowsocks 节点尚未配置"; return 1; }
    show_protocol_links
}

# ============================================================
# 根据已有 meta 重建 config.json（仅 Reality + Shadowsocks）
# 保留节点结构，只修复 JSON 合法性
# ============================================================
rebuild_config() {
    load_meta
    local IP_PRIO=""
    [[ -f "$META_REALITY" ]] && IP_PRIO=$(read_kv "$META_REALITY" "IP_PRIORITY")
    [[ -z "$IP_PRIO" && -f "$META" ]] && IP_PRIO=$(read_kv "$META" "IP_PRIORITY")
    IP_PRIO=${IP_PRIO:-AsIs}
    local INBOUNDS=""

    if has_reality; then
        INBOUNDS="${INBOUNDS}
    {
      \"port\": ${REALITY_PORT},
      \"protocol\": \"vless\",
      \"settings\": { \"clients\": [], \"decryption\": \"none\" },
      \"streamSettings\": {
        \"network\": \"tcp\",
        \"security\": \"reality\",
        \"realitySettings\": {
          \"show\": false,
          \"dest\": \"${REALITY_SNI}:443\",
          \"xver\": 0,
          \"serverNames\": [\"${REALITY_SNI}\"],
          \"privateKey\": \"${REALITY_PRIVATE_KEY}\",
          \"shortIds\": [\"${REALITY_SHORTID}\"]
        }
      },
      \"sniffing\": { \"enabled\": true, \"destOverride\": [\"http\",\"tls\"] },
      \"tag\": \"inbound-reality\"
    },"
    fi

    if has_shadowsocks; then
        INBOUNDS="${INBOUNDS}
    {
      \"port\": ${SS_PORT},
      \"listen\": \"0.0.0.0\",
      \"protocol\": \"shadowsocks\",
      \"settings\": {
        \"method\": \"${SS_METHOD}\",
        \"password\": \"${SS_PASSWORD}\",
        \"network\": \"tcp,udp\"
      },
      \"tag\": \"inbound-shadowsocks\"
    },"
    fi

    INBOUNDS="${INBOUNDS%,}"

    cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    }
  },
  "api": {
    "tag": "api",
    "listen": "127.0.0.1:10085",
    "services": ["StatsService"]
  },
  "routing": {
    "rules": []
  },
  "inbounds": [
    ${INBOUNDS}
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct", "settings": { "domainStrategy": "${IP_PRIO}" } },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
}

# ============================================================
# 启动 xray（先校验后重启）
# ============================================================
_start_xray() {
    validate_xray_config || return 1
    systemctl enable xray >/dev/null 2>&1
    systemctl restart xray
    sleep 1
    if systemctl is-active --quiet xray; then
        info "Xray 已启动"
        return 0
    else
        error "Xray 启动失败，运行 journalctl -u xray -n 20 查看日志"
        return 1
    fi
}

# ============================================================
# 注入用户到 config.json（指定节点类型）
# ============================================================
_inject_user() {
    local UUID=$1
    local NAME=$2
    local EXPIRE=$3
    local NODE=$4

    INJECT_UUID="$UUID" INJECT_NAME="$NAME" INJECT_EXPIRE="$EXPIRE" INJECT_NODE="$NODE" \
    INJECT_CONFIG="$XRAY_CONFIG" python3 - <<'PYEOF'
import json, os
uuid   = os.environ["INJECT_UUID"]
name   = os.environ["INJECT_NAME"]
expire = os.environ["INJECT_EXPIRE"]
node   = os.environ["INJECT_NODE"]
cfg_path = os.environ["INJECT_CONFIG"]

with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

for inbound in cfg["inbounds"]:
    tag = inbound.get("tag", "")
    if "clients" not in inbound.get("settings", {}):
        continue
    clients = inbound["settings"]["clients"]
    clients = [c for c in clients if c.get("id") != uuid]
    if node in ("both", "reality") and tag == "inbound-reality":
        flow = "xtls-rprx-vision" if tag == "inbound-reality" else ""
        clients.append({"id": uuid, "flow": flow, "email": name, "comment": expire})
    inbound["settings"]["clients"] = clients

with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF
}

# ============================================================
# 重建后将所有 active 用户按节点类型重新注入
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
# 打印节点分享链接
# ============================================================
_print_link() {
    local USERNAME=$1
    local UUID=$2
    local EXPIRE=$3
    local NODE=${4:-both}
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
        local SERVER_IP
        SERVER_IP=$(get_public_ip)

        local SHORTID
        SHORTID=$(python3 -c "import json; d=json.load(open('$XRAY_CONFIG', encoding='utf-8')); [print(i['streamSettings']['realitySettings']['shortIds'][0]) for i in d['inbounds'] if i.get('tag')=='inbound-reality']" 2>/dev/null)

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

    echo ""
}

# ============================================================
# ============================================================
# 添加用户
# ============================================================
add_user() {
    title "添加用户"
    load_meta
    normalize_user_db

    read -rp "用户名（备注用）: " USERNAME
    [[ -z "$USERNAME" ]] && error "用户名不能为空" && return
    validate_username "$USERNAME" || return

    if user_exists "$USERNAME"; then
        error "用户 ${USERNAME} 已存在"
        return
    fi

    local NODE="both"
    if has_reality; then
        NODE="reality"
    else
        error "尚未配置 Reality 节点，请先选择菜单 1 初始化"
        return
    fi

    read -rp "到期天数 [默认 999 天]: " DAYS
    DAYS=${DAYS:-999}

    if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
        error "到期天数必须是纯数字"
        return
    fi

    EXPIRE=$(expire_noon_str "$DAYS")
    [[ -z "$EXPIRE" ]] && error "到期时间计算失败" && return

    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "${USERNAME}:${UUID}:${EXPIRE}:active:${NODE}" >> "$USER_DB"
    _inject_user "$UUID" "$USERNAME" "$EXPIRE" "$NODE"

    validate_xray_config || {
        # UUID 唯一，用 UUID 定位回滚，安全精确
        python3 - <<PYEOF
from pathlib import Path
p = Path("$USER_DB")
lines = p.read_text(encoding='utf-8', errors='ignore').splitlines()
out = [l for l in lines if not (len(l.split(':')) >= 2 and l.split(':')[1] == "$UUID")]
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
        rebuild_config
        _inject_all_users
        error "配置校验失败，已回滚本次添加"
        return 1
    }

    _start_xray || {
        python3 - <<PYEOF
from pathlib import Path
p = Path("$USER_DB")
lines = p.read_text(encoding='utf-8', errors='ignore').splitlines()
out = [l for l in lines if not (len(l.split(':')) >= 2 and l.split(':')[1] == "$UUID")]
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
        rebuild_config
        _inject_all_users
        error "Xray 重启失败，已回滚本次添加"
        return 1
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

    # 精确匹配：用户名后紧跟冒号，避免前缀误删
    if ! user_exists "$USERNAME"; then
        error "用户不存在"
        return
    fi

    UUID=$(get_user_field "$USERNAME" 2)
    validate_uuid "$UUID" || return
    local DEL_NODE="reality"

    python3 - <<PYEOF
import json
del_node = "$DEL_NODE"
with open("$XRAY_CONFIG", "r", encoding="utf-8") as f:
    cfg = json.load(f)
for inbound in cfg["inbounds"]:
    tag = inbound.get("tag", "")
    if "clients" not in inbound.get("settings", {}):
        continue
    if del_node == "reality" and tag == "inbound-reality":
        clients = inbound["settings"]["clients"]
        inbound["settings"]["clients"] = [c for c in clients if c.get("id") != "$UUID"]
with open("$XRAY_CONFIG", "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF

    if [[ "$DEL_NODE" == "reality" ]]; then
        # 用 python 精确删除，避免 sed 前缀误匹配
        python3 - <<PYEOF
from pathlib import Path
p = Path("$USER_DB")
lines = p.read_text(encoding='utf-8', errors='ignore').splitlines()
out = [l for l in lines if not (l.startswith("$USERNAME:") and l.split(":")[0] == "$USERNAME")]
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
        info "用户 ${USERNAME} 已彻底删除"
    fi

    validate_xray_config || {
        rebuild_config
        _inject_all_users
    }
    systemctl restart xray
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
        error "用户不存在"
        return
    fi

    read -rp "续期天数 [默认 999 天]: " DAYS
    DAYS=${DAYS:-999}

    if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
        error "续期天数必须是纯数字"
        return
    fi

    NEW_EXPIRE=$(expire_noon_str "$DAYS")
    [[ -z "$NEW_EXPIRE" ]] && error "到期时间计算失败" && return

    UUID=$(get_user_field "$USERNAME" 2)
    validate_uuid "$UUID" || return
    local STATUS NODE
    STATUS=$(get_user_field "$USERNAME" 4)
    NODE=$(get_user_field "$USERNAME" 5)
    NODE=${NODE:-both}
    STATUS=${STATUS:-active}

    # 续期后统一恢复为 active（无论原来是什么状态）
    local NEW_STATUS="active"

    python3 - <<PYEOF
from pathlib import Path
p = Path("$USER_DB")
lines = p.read_text(encoding='utf-8', errors='ignore').splitlines()
out = []
for line in lines:
    parts = line.split(":")
    if len(parts) >= 2 and parts[0] == "$USERNAME" and parts[1] == "$UUID":
        out.append("$USERNAME:$UUID:$NEW_EXPIRE:$NEW_STATUS:$NODE")
    else:
        out.append(line)
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF

    # 无论原来 active 还是 disabled，续期后都重新注入并启动
    _inject_user "$UUID" "$USERNAME" "$NEW_EXPIRE" "$NODE"
    validate_xray_config && systemctl restart xray

    if [[ "$STATUS" == "disabled" ]]; then
        info "用户 ${USERNAME} 到期时间已更新为 ${NEW_EXPIRE}，已自动恢复启用"
    else
        info "用户 ${USERNAME} 到期时间已更新为 ${NEW_EXPIRE}"
    fi
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
        error "用户不存在"
        return
    fi

    UUID=$(get_user_field "$USERNAME" 2)
    validate_uuid "$UUID" || return
    local OP_NODE="reality"

    if [[ "$ACTION" == "disable" ]]; then
        python3 - <<PYEOF
import json
op_node = "$OP_NODE"
with open("$XRAY_CONFIG", "r", encoding="utf-8") as f:
    cfg = json.load(f)
for inbound in cfg["inbounds"]:
    tag = inbound.get("tag", "")
    if "clients" not in inbound.get("settings", {}):
        continue
    if op_node == "reality" and tag == "inbound-reality":
        clients = inbound["settings"]["clients"]
        inbound["settings"]["clients"] = [c for c in clients if c.get("id") != "$UUID"]
with open("$XRAY_CONFIG", "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF

        python3 - <<PYEOF
from pathlib import Path
p = Path("$USER_DB")
lines = p.read_text(encoding='utf-8', errors='ignore').splitlines()
out = []
for line in lines:
    if not line.startswith("$USERNAME:"):
        out.append(line)
        continue
    parts = line.split(":")
    if len(parts) < 5:
        parts += ["both"] * (5 - len(parts))
    parts[3] = "disabled"
    out.append(":".join(parts[:5]))
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
        info "用户 ${USERNAME} 已禁用（节点: ${OP_NODE}）"
    else
        local EXPIRE
        EXPIRE=$(get_user_field "$USERNAME" 3)

        # 检查是否已过期，过期不允许直接启用
        local EXPIRE_TS NOW_TS
        EXPIRE_TS=$(expire_to_ts "$EXPIRE")
        NOW_TS=$(now_shanghai_ts)
        if [[ -n "$EXPIRE_TS" ]] && (( NOW_TS >= EXPIRE_TS )); then
            warn "用户 ${USERNAME} 已过期（$(expire_display "$EXPIRE")），无法启用"
            warn "请先使用菜单 8 重置到期时间再启用"
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
        out.append(line)
        continue
    parts = line.split(":")
    if len(parts) < 5:
        parts += ["both"] * (5 - len(parts))
    parts[3] = "active"
    out.append(":".join(parts[:5]))
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
        info "用户 ${USERNAME} 已启用（节点: ${OP_NODE}）"
    fi

    validate_xray_config || {
        rebuild_config
        _inject_all_users
        return 1
    }

    systemctl restart xray
}

# ============================================================
# 到期检查（按上海时间，到期日当天 12:00 断开）
# ============================================================
check_expire() {
    title "检查到期用户..."
    normalize_user_db
    local NOW_TS
    NOW_TS=$(now_shanghai_ts)
    local CHANGED=0
    local EXPIRED_NAMES=""
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
            EXPIRED_NAMES="${EXPIRED_NAMES} ${NAME}"
            CHANGED=1
        fi
    done < "$USER_DB"

    if [[ $CHANGED -eq 1 ]]; then
        # 批量更新 db：一次 python 调用完成所有到期用户状态变更
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

        # 批量从 config.json 移除到期用户
        BATCH_UUIDS="$EXPIRED_UUIDS" CFG_PATH="$XRAY_CONFIG" python3 - <<'PYEOF'
import json, os
expired = set(os.environ["BATCH_UUIDS"].split())
cfg_path = os.environ["CFG_PATH"]
with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)
for inbound in cfg["inbounds"]:
    if "clients" not in inbound.get("settings", {}):
        continue
    inbound["settings"]["clients"] = [
        c for c in inbound["settings"]["clients"] if c.get("id") not in expired
    ]
with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF

        validate_xray_config && systemctl restart xray
        info "已重启 Xray"
    else
        info "没有到期用户"
    fi
}

# ============================================================
# 列出用户
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
        local COLOR=$NC
        local STATUS_ICON="○"
        local EXPIRE_SHOW
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
        error "用户不存在"
        return
    fi

    local UUID EXPIRE NODE STATUS
    UUID=$(get_user_field "$USERNAME" 2)
    validate_uuid "$UUID" || return
    EXPIRE=$(get_user_field "$USERNAME" 3)
    STATUS=$(get_user_field "$USERNAME" 4)
    NODE=$(get_user_field "$USERNAME" 5)
    NODE=${NODE:-both}

    if [[ "$STATUS" == "disabled" ]]; then
        warn "用户 ${USERNAME} 当前已禁用，链接仍可查看但节点不会响应"
    fi

    _print_link "$USERNAME" "$UUID" "$EXPIRE" "$NODE"
}

# ============================================================
# 主机信息
# ============================================================
show_host_status() {
    local PUBLIC_IP LOAD_INFO MEM_INFO

    PUBLIC_IP=$(get_public_ip)
    LOAD_INFO=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
    [[ -z "$LOAD_INFO" ]] && LOAD_INFO="N/A"

    MEM_INFO=$(free -m | awk '/^Mem:/ {printf "%d/%dMB", $3, $2}' 2>/dev/null)
    [[ -z "$MEM_INFO" ]] && MEM_INFO="N/A"

    cat <<EOF
║  IP   ${PUBLIC_IP}
║  负载 ${LOAD_INFO}  内存 ${MEM_INFO}
EOF
}
# ============================================================
# ============================================================
# 节点信息
# ============================================================
show_info() {
    title "节点信息"
    load_meta
    normalize_user_db

    local XRAY_STATUS USER_COUNT ACTIVE_COUNT
    local PUBLIC_IP LOAD_INFO MEM_INFO SWAP_INFO UPTIME_INFO

    XRAY_STATUS=$(systemctl is-active xray 2>/dev/null)
    USER_COUNT=0; [[ -f "$USER_DB" ]] && USER_COUNT=$(wc -l < "$USER_DB")
    ACTIVE_COUNT=0; [[ -f "$USER_DB" ]] && ACTIVE_COUNT=$(grep -c ":active:" "$USER_DB" 2>/dev/null || echo 0)

    PUBLIC_IP=$(get_public_ip)
    LOAD_INFO=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
    [[ -z "$LOAD_INFO" ]] && LOAD_INFO="N/A"

    MEM_INFO=$(free -m | awk '/^Mem:/ {printf "%d/%dMB", $3, $2}' 2>/dev/null)
    [[ -z "$MEM_INFO" ]] && MEM_INFO="N/A"

    SWAP_INFO=$(free -m | awk '/^Swap:/ {printf "%d/%dMB", $3, $2}' 2>/dev/null)
    [[ -z "$SWAP_INFO" ]] && SWAP_INFO="N/A"

    UPTIME_INFO=$(uptime -p 2>/dev/null | sed 's/^up //')
    [[ -z "$UPTIME_INFO" ]] && UPTIME_INFO="N/A"

    echo -e "状态   : $( [[ "$XRAY_STATUS" == "active" ]] && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}已停止${NC}" )"
    echo -e "用户数 : 共 ${USER_COUNT} 个，活跃 ${ACTIVE_COUNT} 个"
    echo -e "公网IP : ${PUBLIC_IP}"
    echo -e "负载   : ${LOAD_INFO}"
    echo -e "内存   : ${MEM_INFO}"
    echo -e "交换   : ${SWAP_INFO}"
    echo -e "在线   : ${UPTIME_INFO}"
    echo ""

    if has_reality; then
        local SHORTID
        SHORTID=$(python3 -c "import json; d=json.load(open('$XRAY_CONFIG', encoding='utf-8')); [print(i['streamSettings']['realitySettings']['shortIds'][0]) for i in d['inbounds'] if i.get('tag')=='inbound-reality']" 2>/dev/null)
        echo -e "${CYAN}── Reality 节点 ──${NC}"
        echo -e "地址   : ${PUBLIC_IP}"
        echo -e "端口   : ${REALITY_PORT}"
        echo -e "公钥   : ${REALITY_PUBLIC_KEY}"
        echo -e "SNI    : ${REALITY_SNI}"
        echo -e "ShortID: ${SHORTID}"
        echo -e "协议   : VLESS+Reality+TCP"
        echo ""
    fi

    if has_shadowsocks; then
        echo -e "${CYAN}── Shadowsocks 节点 ──${NC}"
        echo -e "地址   : ${PUBLIC_IP}"
        echo -e "端口   : ${SS_PORT}"
        echo -e "加密   : ${SS_METHOD}"
        echo -e "密码   : ${SS_PASSWORD}"
        echo -e "协议   : Shadowsocks"
        echo ""
    fi

    if ! has_reality && ! has_shadowsocks; then
        warn "尚未配置任何节点，请选择菜单 1 或 2 初始化"
    fi
}
# ============================================================
# 设置 cron
# ============================================================
setup_cron() {
    SCRIPT_URL="https://raw.githubusercontent.com/chenege-ck/vless-manager/main/vless.sh"
    EXPIRE_CMD="*/5 * * * * /usr/local/bin/vless_script.sh --check-expire >> /var/log/xray-expire.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "check-expire"; echo "$EXPIRE_CMD") | crontab -
    info "已设置每 5 分钟自动检查到期用户（上海时间）"

    mkdir -p /var/log/xray

    cat > /etc/logrotate.d/xray-expire <<EOF
/var/log/xray-expire.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF
    cat > /etc/logrotate.d/xray <<EOF
/var/log/xray/*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 0640 nobody root
    postrotate
        systemctl kill -s USR1 xray 2>/dev/null || true
    endscript
}
EOF
    info "已配置日志自动轮转（每周轮转，保留4周）"
}

# ============================================================
# Telegram 机器人与流量统计
# ============================================================
extract_telegram_runtime() {
    mkdir -p "$TG_DIR" /etc/vless-manager /usr/local/etc/xray
    awk '
        /^###__VLESS_TG_BOT_PY__###$/ {inside=1; next}
        /^###__END_VLESS_TG_BOT_PY__###$/ {inside=0; exit}
        inside {sub(/^#TG\|/, ""); print}
    ' "$0" > "$TG_SCRIPT"
    [[ -s "$TG_SCRIPT" ]] || { error "机器人程序提取失败"; return 1; }
    chmod 700 "$TG_SCRIPT"
}

enable_xray_stats() {
    [[ -f "$XRAY_CONFIG" ]] || { error "Xray 配置不存在"; return 1; }
    local TMP_CONFIG BACKUP_CONFIG
    TMP_CONFIG=$(mktemp /tmp/xray-stats.XXXXXX.json) || return 1
    BACKUP_CONFIG="${XRAY_CONFIG}.pre-telegram.$(date +%s).bak"
    cp "$XRAY_CONFIG" "$BACKUP_CONFIG" || { rm -f "$TMP_CONFIG"; return 1; }

    XRAY_STATS_SOURCE="$XRAY_CONFIG" XRAY_STATS_TARGET="$TMP_CONFIG" python3 - <<'PYEOF'
import json, os
src = os.environ["XRAY_STATS_SOURCE"]
dst = os.environ["XRAY_STATS_TARGET"]
with open(src, "r", encoding="utf-8") as f:
    cfg = json.load(f)
cfg["stats"] = {}
levels = cfg.setdefault("policy", {}).setdefault("levels", {})
level0 = levels.setdefault("0", {})
level0["statsUserUplink"] = True
level0["statsUserDownlink"] = True
api = cfg.setdefault("api", {})
api.setdefault("tag", "api")
api.setdefault("listen", "127.0.0.1:10085")
services = set(api.get("services", []))
services.add("StatsService")
api["services"] = sorted(services)
with open(dst, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
PYEOF
    if [[ $? -ne 0 ]] || ! "$XRAY_BIN" run -test -config "$TMP_CONFIG" >/dev/null 2>&1; then
        rm -f "$TMP_CONFIG"
        error "开启流量统计失败，原配置未修改"
        return 1
    fi
    cp "$TMP_CONFIG" "$XRAY_CONFIG"
    rm -f "$TMP_CONFIG"
    systemctl restart xray
    systemctl is-active --quiet xray || {
        cp "$BACKUP_CONFIG" "$XRAY_CONFIG"
        systemctl restart xray
        error "Xray 启动失败，已恢复原配置"
        return 1
    }
    info "已在现有配置上开启 Xray 用户流量统计"
}

install_telegram_bot() {
    title "安装 Telegram 智能管家"
    command -v python3 >/dev/null 2>&1 || { error "缺少 python3，请先安装依赖"; return 1; }
    [[ -x "$XRAY_BIN" ]] || { error "请先安装 Xray"; return 1; }

    local BOT_TOKEN BOT_INFO BOT_USERNAME BIND_TOKEN BIND_URL
    read -rsp "输入 Bot Token（输入内容不会显示）: " BOT_TOKEN
    echo ""
    [[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{20,}$ ]] || { error "Bot Token 格式不正确"; return 1; }

    BOT_INFO=$(curl -fsS --max-time 15 "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null) || {
        error "无法验证 Bot Token，请检查 Token 和服务器网络"
        return 1
    }
    BOT_USERNAME=$(BOT_INFO="$BOT_INFO" python3 - <<'PYEOF'
import json, os
try:
    data = json.loads(os.environ["BOT_INFO"])
    print(data["result"]["username"] if data.get("ok") else "")
except (KeyError, TypeError, json.JSONDecodeError):
    print("")
PYEOF
)
    [[ "$BOT_USERNAME" =~ ^[A-Za-z0-9_]{5,}$ ]] || { error "Token 验证失败，未取得机器人用户名"; return 1; }
    BIND_TOKEN=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')
    BIND_URL="https://t.me/${BOT_USERNAME}?start=${BIND_TOKEN}"

    extract_telegram_runtime || return 1
    cat > "$TG_CONFIG" <<EOF
BOT_TOKEN=${BOT_TOKEN}
ADMIN_CHAT_IDS=
BIND_TOKEN=${BIND_TOKEN}
USER_DB=${USER_DB}
TRAFFIC_DB=${TRAFFIC_DB}
XRAY_BIN=${XRAY_BIN}
COLLECT_INTERVAL=60
EOF
    chmod 600 "$TG_CONFIG"

    cat > /etc/systemd/system/vless-traffic.service <<EOF
[Unit]
Description=VLESS per-user traffic collector
After=network-online.target xray.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${TG_SCRIPT} --config ${TG_CONFIG} --collector
Restart=always
RestartSec=5
User=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/usr/local/etc/xray
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/vless-tgbot.service <<EOF
[Unit]
Description=VLESS Telegram management bot
After=network-online.target vless-traffic.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${TG_SCRIPT} --config ${TG_CONFIG}
Restart=always
RestartSec=5
User=root
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/usr/local/etc/xray /etc/vless-manager
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

    enable_xray_stats || return 1
    chmod 600 "$USER_DB" 2>/dev/null || true
    touch "$TRAFFIC_DB"
    chmod 600 "$TRAFFIC_DB"
    systemctl daemon-reload
    systemctl enable vless-traffic.service vless-tgbot.service >/dev/null 2>&1
    systemctl restart vless-traffic.service vless-tgbot.service
    sleep 2
    if systemctl is-active --quiet vless-traffic.service && systemctl is-active --quiet vless-tgbot.service; then
        info "Telegram 机器人和流量采集器已启动"
        echo ""
        title "扫码绑定 Telegram"
        if ! command -v qrencode >/dev/null 2>&1; then
            info "正在安装二维码工具..."
            apt-get update -qq && apt-get install -y -qq qrencode >/dev/null 2>&1 || true
        fi
        if command -v qrencode >/dev/null 2>&1; then
            qrencode -t ANSIUTF8 "$BIND_URL"
        else
            warn "二维码工具安装失败，请直接打开下方链接"
        fi
        echo -e "  ${CYAN}${BIND_URL}${NC}"
        echo ""
        info "用 Telegram 扫码或打开链接，再点击“开始”即可完成绑定"
        warn "绑定链接仅可使用一次；重新配置机器人会生成新链接"
        warn "首次启用统计后，从现在开始记录流量；无法补算以前的流量"
    else
        error "服务启动失败，请选择“查看机器人日志”排查"
        return 1
    fi
}

telegram_bot_status() {
    title "Telegram 服务状态"
    systemctl --no-pager --full status vless-tgbot.service vless-traffic.service 2>/dev/null || true
}

telegram_bot_logs() {
    title "Telegram 最近日志"
    journalctl -u vless-tgbot.service -u vless-traffic.service -n 60 --no-pager
}

uninstall_telegram_bot() {
    read -rp "确认卸载机器人？流量历史默认保留 [y/N]: " C
    [[ "$C" != "y" && "$C" != "Y" ]] && return
    systemctl disable --now vless-tgbot.service vless-traffic.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/vless-tgbot.service /etc/systemd/system/vless-traffic.service
    rm -rf "$TG_DIR" /etc/vless-manager
    systemctl daemon-reload
    info "机器人已卸载，流量数据库仍保留在 ${TRAFFIC_DB}"
}

telegram_bot_menu() {
    while true; do
        clear
        title "Telegram 机器人与流量统计"
        echo -e "  ${GREEN}1.${NC} 安装 / 重新配置机器人"
        echo -e "  ${GREEN}2.${NC} 查看运行状态"
        echo -e "  ${GREEN}3.${NC} 重启机器人与采集器"
        echo -e "  ${GREEN}4.${NC} 查看最近日志"
        echo -e "  ${RED}5.${NC} 卸载机器人"
        echo -e "  ${GREEN}0.${NC} 返回主菜单"
        echo ""
        read -rp "请选择: " TG_OPT
        case "$TG_OPT" in
            1) install_telegram_bot ;;
            2) telegram_bot_status ;;
            3) systemctl restart vless-traffic.service vless-tgbot.service && info "服务已重启" ;;
            4) telegram_bot_logs ;;
            5) uninstall_telegram_bot ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
        echo ""; read -rp "按 Enter 继续..." _
    done
}

# ============================================================
# IP 优先级设置 — 通过 Xray freedom domainStrategy 控制
# gai.conf 对 Xray 无效，必须在 config.json 中设置
# ============================================================
get_ip_priority_mode() {
    local ds=""
    [[ -f "$META_REALITY" ]] && ds=$(read_kv "$META_REALITY" "IP_PRIORITY")
    [[ -z "$ds" && -f "$META" ]] && ds=$(read_kv "$META" "IP_PRIORITY")
    [[ -z "$ds" && -f "$META" ]] && ds=$(read_kv "$META" "IP_PRIORITY")
    case "$ds" in
        UseIPv4v6) echo "IPv4 优先（v4失败自动切v6）" ;;
        UseIPv6v4) echo "IPv6 优先（v6失败自动切v4）" ;;
        UseIPv4)   echo "仅 IPv4" ;;
        UseIPv6)   echo "仅 IPv6" ;;
        *)         echo "系统默认（AsIs）" ;;
    esac
}

_save_ip_priority() {
    local ds="$1"
    local saved=0
    for f in "$META_REALITY" "$META"; do
        [[ -f "$f" ]] || continue
        if grep -q "^IP_PRIORITY=" "$f" 2>/dev/null; then
            sed -i "s|^IP_PRIORITY=.*|IP_PRIORITY=${ds}|" "$f"
        else
            echo "IP_PRIORITY=${ds}" >> "$f"
        fi
        saved=1
    done
    # 如果一个 meta 文件都没有（未初始化），暂存到 META
    if [[ $saved -eq 0 ]]; then
        mkdir -p "$(dirname "$META")"
        echo "IP_PRIORITY=${ds}" >> "$META"
    fi
}

ip_priority_menu() {
    title "网络优先级（IPv4/IPv6）"
    load_meta

    local CURRENT_MODE
    CURRENT_MODE=$(get_ip_priority_mode)

    echo ""
    echo -e "当前模式：${CYAN}${CURRENT_MODE}${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} IPv4 优先   — 优先走 v4，v4 不通自动切 v6"
    echo -e "  ${GREEN}2.${NC} IPv6 优先   — 优先走 v6，v6 不通自动切 v4"
    echo -e "  ${GREEN}3.${NC} 仅 IPv4     — 强制只走 v4，v6 完全不用"
    echo -e "  ${GREEN}4.${NC} 仅 IPv6     — 强制只走 v6，v4 完全不用"
    echo -e "  ${GREEN}5.${NC} 系统默认   — 由 Xray 自动决定（AsIs）"
    echo -e "  ${GREEN}0.${NC} 返回"
    echo ""
    read -rp "选择: " OPT

    local DS=""
    local DESC=""
    case "$OPT" in
        1) DS="UseIPv4v6"; DESC="IPv4 优先" ;;
        2) DS="UseIPv6v4"; DESC="IPv6 优先" ;;
        3) DS="UseIPv4";   DESC="仅 IPv4" ;;
        4) DS="UseIPv6";   DESC="仅 IPv6" ;;
        5) DS="AsIs";      DESC="系统默认" ;;
        0) return ;;
        *) warn "无效选项"; return ;;
    esac

    _save_ip_priority "$DS"

    if has_reality || has_shadowsocks; then
        rebuild_config
        _inject_all_users
        _start_xray
    fi

    echo ""
    info "已生效：${DESC}"
}

# ============================================================
# BBR 与 iperf3 网络测试
# ============================================================
show_bbr_status() {
    title "BBR 状态检测"

    local KERNEL AVAILABLE CURRENT QDISC MODULE_STATE STATUS_TEXT
    KERNEL=$(uname -r 2>/dev/null || echo "未知")
    AVAILABLE=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    CURRENT=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)

    if [[ -d /sys/module/tcp_bbr ]]; then
        MODULE_STATE="已加载"
    elif modinfo tcp_bbr >/dev/null 2>&1; then
        MODULE_STATE="内核支持，尚未加载"
    else
        MODULE_STATE="当前内核不支持"
    fi

    if [[ "$CURRENT" == "bbr" && "$QDISC" == "fq" ]]; then
        STATUS_TEXT="${GREEN}BBR + fq 已生效${NC}"
    elif [[ "$AVAILABLE" == *bbr* ]]; then
        STATUS_TEXT="${YELLOW}支持 BBR，但尚未完整启用${NC}"
    else
        STATUS_TEXT="${RED}当前内核未提供 BBR${NC}"
    fi

    echo -e "内核版本 : ${KERNEL}"
    echo -e "BBR 模块 : ${MODULE_STATE}"
    echo -e "可用算法 : ${AVAILABLE:-读取失败}"
    echo -e "当前算法 : ${CURRENT:-读取失败}"
    echo -e "队列算法 : ${QDISC:-读取失败}"
    echo -e "综合状态 : ${STATUS_TEXT}"
    [[ -f "$BBR_CONFIG" ]] && echo -e "脚本配置 : ${BBR_CONFIG}" || echo -e "脚本配置 : 未创建"
}

enable_bbr() {
    title "开启 BBR"

    local TMP_CONFIG BACKUP_CONFIG="" AVAILABLE CURRENT QDISC
    modprobe tcp_bbr >/dev/null 2>&1 || {
        error "当前内核无法加载 tcp_bbr，本脚本不会自动更换内核"
        return 1
    }

    AVAILABLE=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    [[ "$AVAILABLE" == *bbr* ]] || {
        error "tcp_available_congestion_control 中没有 bbr，无法开启"
        return 1
    }

    TMP_CONFIG=$(mktemp /tmp/vless-bbr.XXXXXX) || return 1
    cat > "$TMP_CONFIG" <<'EOF'
# Managed by VLESS Manager. Only BBR and fq are configured here.
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    if [[ -f "$BBR_CONFIG" ]]; then
        BACKUP_CONFIG="${BBR_CONFIG}.bak.$(date +%s)"
        cp "$BBR_CONFIG" "$BACKUP_CONFIG" || { rm -f "$TMP_CONFIG"; return 1; }
    fi
    cp "$TMP_CONFIG" "$BBR_CONFIG" || { rm -f "$TMP_CONFIG"; return 1; }
    rm -f "$TMP_CONFIG"
    printf '%s\n' tcp_bbr > "$BBR_MODULE_CONFIG"

    if ! sysctl -p "$BBR_CONFIG" >/dev/null 2>&1; then
        [[ -n "$BACKUP_CONFIG" ]] && cp "$BACKUP_CONFIG" "$BBR_CONFIG" || rm -f "$BBR_CONFIG"
        sysctl --system >/dev/null 2>&1 || true
        error "BBR 参数应用失败，已恢复原配置"
        return 1
    fi

    CURRENT=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    if [[ "$CURRENT" != "bbr" || "$QDISC" != "fq" ]]; then
        [[ -n "$BACKUP_CONFIG" ]] && cp "$BACKUP_CONFIG" "$BBR_CONFIG" || rm -f "$BBR_CONFIG"
        sysctl --system >/dev/null 2>&1 || true
        error "运行时验证失败，已恢复原配置"
        return 1
    fi

    info "BBR + fq 已开启并持久化，无需重启即可作用于新连接"
    show_bbr_status
}

install_iperf3() {
    title "安装 iperf3"
    if command -v iperf3 >/dev/null 2>&1; then
        info "iperf3 已安装：$(iperf3 --version 2>/dev/null | awk 'NR==1{print $2}')"
        return 0
    fi
    apt-get update -qq || { error "apt 软件索引更新失败"; return 1; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iperf3 || {
        error "iperf3 安装失败"
        return 1
    }
    command -v iperf3 >/dev/null 2>&1 || { error "安装完成但未找到 iperf3"; return 1; }
    info "iperf3 安装完成"
}

show_iperf3_commands() {
    local PUBLIC_IP
    PUBLIC_IP=$(get_public_ip)
    echo ""
    echo -e "服务器地址：${CYAN}${PUBLIC_IP}${NC}  端口：${CYAN}${IPERF_PORT}/TCP${NC}"
    echo ""
    echo "本地上传测试："
    echo -e "  ${CYAN}iperf3 -c ${PUBLIC_IP} -p ${IPERF_PORT} -t 30 -O 5${NC}"
    echo "本地下载测试（重点测试 BBR）："
    echo -e "  ${CYAN}iperf3 -c ${PUBLIC_IP} -p ${IPERF_PORT} -R -t 30 -O 5${NC}"
    echo "本地四线程下载测试："
    echo -e "  ${CYAN}iperf3 -c ${PUBLIC_IP} -p ${IPERF_PORT} -R -P 4 -t 30 -O 5${NC}"
    echo "JSON 结果（建议执行并把三个文件发给我）："
    echo -e "  ${CYAN}iperf3 -c ${PUBLIC_IP} -p ${IPERF_PORT} -t 30 -O 5 -J > upload.json${NC}"
    echo -e "  ${CYAN}iperf3 -c ${PUBLIC_IP} -p ${IPERF_PORT} -R -t 30 -O 5 -J > download.json${NC}"
    echo -e "  ${CYAN}iperf3 -c ${PUBLIC_IP} -p ${IPERF_PORT} -R -P 4 -t 30 -O 5 -J > download-4streams.json${NC}"
    warn "测试完成后请停止 iperf3；脚本不会自动修改防火墙或云安全组"
}

start_iperf3_server() {
    title "启动 iperf3 测试服务"
    install_iperf3 || return 1

    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${IPERF_PORT}$" && \
       ! systemctl is-active --quiet vless-iperf3.service 2>/dev/null; then
        error "TCP ${IPERF_PORT} 端口已被其他程序占用"
        return 1
    fi

    cat > "$IPERF_SERVICE" <<EOF
[Unit]
Description=Temporary VLESS Manager iperf3 test server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/iperf3 -s -p ${IPERF_PORT}
Restart=no
RuntimeMaxSec=30min
User=nobody
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl start vless-iperf3.service
    sleep 1
    if ! systemctl is-active --quiet vless-iperf3.service; then
        error "iperf3 启动失败"
        journalctl -u vless-iperf3.service -n 20 --no-pager
        return 1
    fi
    info "iperf3 测试服务已启动（未设置开机自启，30 分钟后自动停止）"
    show_iperf3_commands
}

stop_iperf3_server() {
    title "停止 iperf3 测试服务"
    systemctl disable --now vless-iperf3.service >/dev/null 2>&1 || true
    rm -f "$IPERF_SERVICE"
    systemctl daemon-reload
    info "iperf3 测试服务已停止，systemd 单元已删除"
}

show_iperf3_status() {
    title "iperf3 服务状态"
    if ! command -v iperf3 >/dev/null 2>&1; then
        warn "iperf3 尚未安装"
        return
    fi
    if systemctl is-active --quiet vless-iperf3.service 2>/dev/null; then
        info "iperf3 正在运行"
        ss -ltnp 2>/dev/null | grep -E ":${IPERF_PORT}[[:space:]]" || true
        show_iperf3_commands
    else
        warn "iperf3 当前未运行"
    fi
}

network_test_menu() {
    while true; do
        clear
        title "BBR / iperf3 网络测试"
        echo -e "  ${GREEN}1.${NC} 检测 BBR 状态"
        echo -e "  ${GREEN}2.${NC} 开启 BBR（仅 bbr + fq）"
        echo -e "  ${GREEN}3.${NC} 安装 iperf3"
        echo -e "  ${GREEN}4.${NC} 启动 iperf3 测试服务"
        echo -e "  ${GREEN}5.${NC} 停止 iperf3 测试服务"
        echo -e "  ${GREEN}6.${NC} 查看 iperf3 状态与测试命令"
        echo -e "  ${GREEN}0.${NC} 返回主菜单"
        echo ""
        read -rp "请选择: " NET_OPT
        case "$NET_OPT" in
            1) show_bbr_status ;;
            2) enable_bbr ;;
            3) install_iperf3 ;;
            4) start_iperf3_server ;;
            5) stop_iperf3_server ;;
            6) show_iperf3_status ;;
            0) return ;;
            *) warn "无效选项" ;;
        esac
        echo ""
        read -rp "按 Enter 继续..." _
    done
}

# ============================================================
# 一键更新 Xray
# ============================================================
update_xray() {
    title "更新 Xray..."
    local CURRENT_VER
    CURRENT_VER=$($XRAY_BIN -version 2>/dev/null | awk 'NR==1{print $2}')
    info "当前版本: ${CURRENT_VER}"
    info "正在下载最新版本..."

    [[ -f "$XRAY_CONFIG" ]] && cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak"
    curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o /tmp/xray-install.sh
    bash /tmp/xray-install.sh install

    [[ -f "${XRAY_CONFIG}.bak" ]] && mv "${XRAY_CONFIG}.bak" "$XRAY_CONFIG" && info "已恢复原配置"

    validate_xray_config || {
        error "恢复后的配置校验失败，已取消重启"
        return 1
    }

    local NEW_VER
    NEW_VER=$($XRAY_BIN -version 2>/dev/null | awk 'NR==1{print $2}')
    if [[ "$CURRENT_VER" == "$NEW_VER" ]]; then
        info "已是最新版本: ${NEW_VER}"
    else
        info "更新完成: ${CURRENT_VER} → ${NEW_VER}"
    fi
    systemctl restart xray
    info "Xray 已重启"
}

# ============================================================
# 更新脚本到最新版本
# ============================================================
update_script() {
    title "更新管理脚本..."
    local SCRIPT_URL="https://raw.githubusercontent.com/chenege-ck/vless-manager/main/vless.sh"
    info "正在从 GitHub 拉取最新版本..."
    local TMP_SCRIPT="/tmp/vless_new.sh"
    curl -sL "$SCRIPT_URL" -o "$TMP_SCRIPT"
    if [[ $? -ne 0 || ! -s "$TMP_SCRIPT" ]]; then
        error "下载失败，请检查网络"
        return
    fi
    if ! bash -n "$TMP_SCRIPT" 2>/dev/null; then
        error "脚本语法错误，取消更新"
        rm -f "$TMP_SCRIPT"
        return
    fi
    cp "$TMP_SCRIPT" /usr/local/bin/vless_script.sh
    chmod +x /usr/local/bin/vless_script.sh
    rm -f "$TMP_SCRIPT"
    info "脚本已更新，用户数据完整保留"
    info "正在重新启动新版本..."
    sleep 1
    exec bash /usr/local/bin/vless_script.sh
}

# ============================================================
# 安装快捷命令 c
# ============================================================
install_shortcut() {
    local SELF_PATH
    SELF_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [[ "$SELF_PATH" != "/usr/local/bin/vless_script.sh" ]]; then
        local SCRIPT_URL="https://raw.githubusercontent.com/chenege-ck/vless-manager/main/vless.sh"
        curl -sL "$SCRIPT_URL" -o /usr/local/bin/vless_script.sh
        if [[ $? -ne 0 || ! -s /usr/local/bin/vless_script.sh ]]; then
            error "脚本下载失败，请检查网络后重试"
            exit 1
        fi
        chmod +x /usr/local/bin/vless_script.sh
    fi
    cat > /usr/local/bin/c <<EOF
#!/bin/bash
bash /usr/local/bin/vless_script.sh
EOF
    chmod +x /usr/local/bin/c
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
# ============================================================
# 主菜单
# ============================================================
main_menu() {
    while true; do
        clear
        normalize_user_db
        load_meta

        local XRAY_STATUS USER_COUNT
        XRAY_STATUS=$(systemctl is-active xray 2>/dev/null)
        USER_COUNT=0; [[ -f "$USER_DB" ]] && USER_COUNT=$(wc -l < "$USER_DB")
        local ACTIVE_COUNT=0
        [[ -f "$USER_DB" ]] && ACTIVE_COUNT=$(grep -c ":active:" "$USER_DB" 2>/dev/null || echo 0)

        local MODE_STR=""
        has_reality && MODE_STR="Reality"
        has_shadowsocks && MODE_STR="${MODE_STR:+$MODE_STR+}SS"
        [[ -z "$MODE_STR" ]] && MODE_STR="未配置"

        local STATUS_COLOR=$RED
        local STATUS_TEXT="● 已停止"
        [[ "$XRAY_STATUS" == "active" ]] && STATUS_COLOR=$GREEN && STATUS_TEXT="● 运行中"

        local TG_STATUS="未安装"
        systemctl is-active --quiet vless-tgbot.service 2>/dev/null && TG_STATUS="运行中"

        echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║${NC}       ${CYAN}VLESS 智能节点控制台  v6.3${NC}          ${BLUE}║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  Xray ${STATUS_COLOR}${STATUS_TEXT}${NC}   模式 ${YELLOW}${MODE_STR}${NC}"
        echo -e "${BLUE}║${NC}  用户 ${GREEN}${ACTIVE_COUNT}${NC} 活跃 / ${USER_COUNT} 总计   TG ${CYAN}${TG_STATUS}${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}▣ 节点中心${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}1.${NC}  安装 Xray 并配置节点"
        echo -e "${BLUE}║${NC}   ${GREEN}2.${NC}  添加 / 移除协议节点"
        echo -e "${BLUE}╠══════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}▣ 用户中心${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}3.${NC}  新建用户          ${GREEN}4.${NC}  删除用户"
        echo -e "${BLUE}║${NC}   ${GREEN}5.${NC}  禁用用户          ${GREEN}6.${NC}  启用用户"
        echo -e "${BLUE}║${NC}   ${GREEN}7.${NC}  用户续期          ${GREEN}8.${NC}  用户列表"
        echo -e "${BLUE}║${NC}   ${GREEN}9.${NC}  查看分享链接"
        echo -e "${BLUE}╠══════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}▣ 监控与机器人${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}10.${NC} 检查到期用户     ${GREEN}11.${NC} 节点运行信息"
        echo -e "${BLUE}║${NC}   ${GREEN}12.${NC} Telegram 机器人与流量统计"
        echo -e "${BLUE}╠══════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}▣ 系统维护${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}13.${NC} 更新 Xray        ${GREEN}14.${NC} 更新管理脚本"
        echo -e "${BLUE}║${NC}   ${GREEN}15.${NC} IPv4 / IPv6 优先级"
        echo -e "${BLUE}║${NC}   ${GREEN}17.${NC} BBR / iperf3 网络测试"
        echo -e "${BLUE}║${NC}   ${RED}16.${NC} 卸载 Xray         ${RED}0.${NC}  退出"
        echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
        echo -ne " 请选择 » "
        read -r OPT

        case $OPT in
            1)  check_system; set_shanghai_timezone; install_xray; init_config; setup_cron ;;
            2)  init_config ;;
            3)  add_user ;;
            4)  delete_user ;;
            5)  toggle_user disable ;;
            6)  toggle_user enable ;;
            7)  renew_user ;;
            8)  list_users ;;
            9)  show_user_link ;;
            10) check_expire ;;
            11) show_info ;;
            12) telegram_bot_menu ;;
            13) update_xray ;;
            14) update_script ;;
            15) ip_priority_menu ;;
            16) uninstall_xray ;;
            17) network_test_menu ;;
            0)  echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *)  warn "无效选项，请重新选择" ;;
        esac

        echo ""
        echo -ne "${BLUE}按 Enter 返回菜单...${NC}"
        read -r _
    done
}

check_system
normalize_user_db
install_shortcut
main_menu


###__VLESS_TG_BOT_PY__###
#TG|#!/usr/bin/env python3
#TG|"""VLESS Manager Telegram bot and Xray traffic collector (stdlib only)."""
#TG|from __future__ import annotations
#TG|
#TG|import argparse
#TG|import concurrent.futures
#TG|import html
#TG|import json
#TG|import os
#TG|import re
#TG|import secrets
#TG|import sqlite3
#TG|import subprocess
#TG|import threading
#TG|import time
#TG|import urllib.error
#TG|import urllib.parse
#TG|import urllib.request
#TG|from datetime import datetime
#TG|from pathlib import Path
#TG|from typing import Dict, Iterable, Optional, Tuple
#TG|
#TG|DEFAULT_CONFIG = Path("/etc/vless-manager/bot.conf")
#TG|DEFAULT_USERS = Path("/usr/local/etc/xray/users.db")
#TG|DEFAULT_DB = Path("/usr/local/etc/xray/traffic.db")
#TG|DEFAULT_XRAY = Path("/usr/local/bin/xray")
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
#TG|        raise ValueError("机器人尚未绑定，请重新配置并扫描绑定二维码")
#TG|
#TG|
#TG|def update_config_values(path: Path, values: dict[str, str]) -> None:
#TG|    lines = path.read_text(encoding="utf-8", errors="ignore").splitlines() if path.exists() else []
#TG|    pending = dict(values)
#TG|    output = []
#TG|    for line in lines:
#TG|        key = line.split("=", 1)[0].strip() if "=" in line else ""
#TG|        if key in pending:
#TG|            output.append(f"{key}={pending.pop(key)}")
#TG|        else:
#TG|            output.append(line)
#TG|    output.extend(f"{key}={value}" for key, value in pending.items())
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
#TG|    if seconds <= 0:
#TG|        return 0
#TG|    return int((seconds + 86399) // 86400)
#TG|
#TG|
#TG|def init_db(path: Path = DEFAULT_DB) -> None:
#TG|    path.parent.mkdir(parents=True, exist_ok=True)
#TG|    with sqlite3.connect(path, timeout=30) as db:
#TG|        db.execute("PRAGMA busy_timeout=30000")
#TG|        db.executescript("""
#TG|        CREATE TABLE IF NOT EXISTS counters (
#TG|            username TEXT PRIMARY KEY,
#TG|            uplink INTEGER NOT NULL,
#TG|            downlink INTEGER NOT NULL,
#TG|            updated_at TEXT NOT NULL
#TG|        );
#TG|        CREATE TABLE IF NOT EXISTS traffic_daily (
#TG|            day TEXT NOT NULL,
#TG|            username TEXT NOT NULL,
#TG|            uplink INTEGER NOT NULL DEFAULT 0,
#TG|            downlink INTEGER NOT NULL DEFAULT 0,
#TG|            PRIMARY KEY(day, username)
#TG|        );
#TG|        CREATE TABLE IF NOT EXISTS bot_state (
#TG|            key TEXT PRIMARY KEY,
#TG|            value TEXT NOT NULL
#TG|        );
#TG|        """)
#TG|    try:
#TG|        path.chmod(0o600)
#TG|    except OSError:
#TG|        pass
#TG|
#TG|
#TG|def record_snapshot(path: Path, counters: Dict[str, Tuple[int, int]], now: Optional[datetime] = None) -> None:
#TG|    """Persist positive deltas. A lower counter means Xray restarted; count from zero."""
#TG|    init_db(path)
#TG|    now = now or datetime.now()
#TG|    stamp = now.isoformat(timespec="seconds")
#TG|    day = now.strftime("%Y-%m-%d")
#TG|    with sqlite3.connect(path, timeout=30) as db:
#TG|        db.execute("PRAGMA busy_timeout=30000")
#TG|        for username, values in counters.items():
#TG|            current_up, current_down = max(0, int(values[0])), max(0, int(values[1]))
#TG|            row = db.execute(
#TG|                "SELECT uplink, downlink, updated_at FROM counters WHERE username=?", (username,)
#TG|            ).fetchone()
#TG|            if row is None:
#TG|                delta_up = delta_down = 0
#TG|            else:
#TG|                try:
#TG|                    gap = (now - datetime.fromisoformat(row[2])).total_seconds()
#TG|                except (TypeError, ValueError):
#TG|                    gap = 999999
#TG|                if gap > 300:
#TG|                    # A long collector outage cannot be split accurately by day.
#TG|                    delta_up = delta_down = 0
#TG|                else:
#TG|                    delta_up = current_up - row[0] if current_up >= row[0] else current_up
#TG|                    delta_down = current_down - row[1] if current_down >= row[1] else current_down
#TG|            db.execute(
#TG|                "INSERT INTO counters(username,uplink,downlink,updated_at) VALUES(?,?,?,?) "
#TG|                "ON CONFLICT(username) DO UPDATE SET uplink=excluded.uplink, "
#TG|                "downlink=excluded.downlink, updated_at=excluded.updated_at",
#TG|                (username, current_up, current_down, stamp),
#TG|            )
#TG|            if delta_up or delta_down:
#TG|                db.execute(
#TG|                    "INSERT INTO traffic_daily(day,username,uplink,downlink) VALUES(?,?,?,?) "
#TG|                    "ON CONFLICT(day,username) DO UPDATE SET "
#TG|                    "uplink=uplink+excluded.uplink, downlink=downlink+excluded.downlink",
#TG|                    (day, username, delta_up, delta_down),
#TG|                )
#TG|
#TG|
#TG|def _usage(path: Path, username: Optional[str], where: str, value: str) -> Tuple[int, int]:
#TG|    init_db(path)
#TG|    sql = f"SELECT COALESCE(SUM(uplink),0), COALESCE(SUM(downlink),0) FROM traffic_daily WHERE {where}"
#TG|    args: list[object] = [value]
#TG|    if username:
#TG|        sql += " AND username=?"
#TG|        args.append(username)
#TG|    with sqlite3.connect(path, timeout=30) as db:
#TG|        row = db.execute(sql, args).fetchone()
#TG|    return int(row[0]), int(row[1])
#TG|
#TG|
#TG|def usage_for_day(path: Path, username: Optional[str], day: str) -> Tuple[int, int]:
#TG|    return _usage(path, username, "day=?", day)
#TG|
#TG|
#TG|def usage_for_month(path: Path, username: Optional[str], month: str) -> Tuple[int, int]:
#TG|    return _usage(path, username, "substr(day,1,7)=?", month)
#TG|
#TG|
#TG|def format_bytes(value: int) -> str:
#TG|    amount = float(max(0, value))
#TG|    units = ["B", "KB", "MB", "GB", "TB", "PB"]
#TG|    for unit in units:
#TG|        if amount < 1024 or unit == units[-1]:
#TG|            return f"{int(amount)} B" if unit == "B" else f"{amount:.2f} {unit}"
#TG|        amount /= 1024
#TG|    return "0 B"
#TG|
#TG|
#TG|def parse_xray_stats(output: str) -> Dict[str, Tuple[int, int]]:
#TG|    payload = json.loads(output)
#TG|    found: dict[str, dict[str, int]] = {}
#TG|    for stat in payload.get("stat", []):
#TG|        match = re.fullmatch(r"user>>>(.+?)>>>traffic>>>(uplink|downlink)", str(stat.get("name", "")))
#TG|        if not match:
#TG|            continue
#TG|        username, direction = match.groups()
#TG|        found.setdefault(username, {})[direction] = max(0, int(stat.get("value", 0)))
#TG|    return {
#TG|        username: (values["uplink"], values["downlink"])
#TG|        for username, values in found.items()
#TG|        if "uplink" in values and "downlink" in values
#TG|    }
#TG|
#TG|
#TG|def query_xray_counters(xray_bin: Path = DEFAULT_XRAY, server: str = "127.0.0.1:10085") -> Dict[str, Tuple[int, int]]:
#TG|    proc = subprocess.run(
#TG|        [str(xray_bin), "api", "statsquery", f"--server={server}", "-pattern", "user>>>", "-reset=false"],
#TG|        text=True, capture_output=True, timeout=20, check=False,
#TG|    )
#TG|    if proc.returncode != 0:
#TG|        raise RuntimeError((proc.stderr or proc.stdout or "Xray Stats API 查询失败").strip())
#TG|    return parse_xray_stats(proc.stdout)
#TG|
#TG|
#TG|def tg_request(token: str, method: str, data: Optional[dict] = None) -> dict:
#TG|    url = f"https://api.telegram.org/bot{token}/{method}"
#TG|    encoded = urllib.parse.urlencode(data or {}).encode()
#TG|    req = urllib.request.Request(url, data=encoded)
#TG|    with urllib.request.urlopen(req, timeout=65) as response:
#TG|        result = json.loads(response.read().decode("utf-8"))
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
#TG|def usage_text(db_path: Path, username: Optional[str] = None) -> str:
#TG|    now = datetime.now()
#TG|    today = usage_for_day(db_path, username, now.strftime("%Y-%m-%d"))
#TG|    month = usage_for_month(db_path, username, now.strftime("%Y-%m"))
#TG|    who = f"用户 <b>{html.escape(username)}</b>" if username else "全部用户"
#TG|    return (
#TG|        f"📊 <b>{who}流量统计</b>\n\n"
#TG|        f"📅 今日\n  ↑ {format_bytes(today[0])}  ↓ {format_bytes(today[1])}\n"
#TG|        f"  合计：<b>{format_bytes(sum(today))}</b>\n\n"
#TG|        f"🗓 本月\n  ↑ {format_bytes(month[0])}  ↓ {format_bytes(month[1])}\n"
#TG|        f"  合计：<b>{format_bytes(sum(month))}</b>"
#TG|    )
#TG|
#TG|
#TG|def user_text(user: dict, db_path: Path) -> str:
#TG|    days = remaining_days(user["expire"])
#TG|    day_text = "未知" if days is None else ("已到期" if days == 0 else f"{days} 天")
#TG|    expire = parse_expire(user["expire"])
#TG|    expire_text = expire.strftime("%Y-%m-%d %H:%M") if expire else user["expire"]
#TG|    state = "🟢 正常" if user["status"] == "active" else "🔴 已禁用"
#TG|    return (
#TG|        f"👤 <b>{html.escape(user['name'])}</b>\n"
#TG|        f"状态：{state}\n节点：{html.escape(user['node'])}\n"
#TG|        f"到期：{html.escape(expire_text)}\n剩余：<b>{day_text}</b>\n\n"
#TG|        + usage_text(db_path, user["name"])
#TG|    )
#TG|
#TG|
#TG|def users_text(users: Iterable[dict]) -> str:
#TG|    rows = ["👥 <b>用户列表</b>", ""]
#TG|    for user in users:
#TG|        days = remaining_days(user["expire"])
#TG|        left = "未知" if days is None else ("已到期" if days == 0 else f"{days}天")
#TG|        icon = "🟢" if user["status"] == "active" else "🔴"
#TG|        rows.append(f"{icon} <code>{html.escape(user['name'])}</code> · {left} · {html.escape(user['node'])}")
#TG|    return "\n".join(rows) if len(rows) > 2 else "暂无用户"
#TG|
#TG|
#TG|def command_reply(text: str, users_path: Path, db_path: Path) -> str:
#TG|    parts = text.strip().split(maxsplit=1)
#TG|    command = parts[0].split("@", 1)[0].lower() if parts else "/start"
#TG|    users = read_users(users_path)
#TG|    if command in ("/start", "/help"):
#TG|        return (
#TG|            "🤖 <b>VLESS 智能管家</b>\n\n"
#TG|            "/users — 用户与到期概览\n"
#TG|            "/user 用户名 — 用户详情与流量\n"
#TG|            "/today — 今日全部流量\n"
#TG|            "/month — 本月全部流量\n"
#TG|            "/expiring — 7天内到期用户\n"
#TG|            "/status — 机器人状态"
#TG|        )
#TG|    if command == "/users":
#TG|        return users_text(users)
#TG|    if command in ("/today", "/month"):
#TG|        return usage_text(db_path)
#TG|    if command == "/user":
#TG|        if len(parts) < 2:
#TG|            return "用法：<code>/user 用户名</code>"
#TG|        name = parts[1].strip()
#TG|        user = next((u for u in users if u["name"] == name), None)
#TG|        return user_text(user, db_path) if user else "未找到该用户"
#TG|    if command == "/expiring":
#TG|        selected = [u for u in users if (days := remaining_days(u["expire"])) is not None and days <= 7]
#TG|        return "⏰ <b>7天内到期</b>\n\n" + (users_text(selected) if selected else "暂无")
#TG|    if command == "/status":
#TG|        return "✅ 机器人在线\n✅ 流量数据库可读取\n🕐 " + datetime.now().strftime("%Y-%m-%d %H:%M:%S")
#TG|    return "未知命令，请发送 /help"
#TG|
#TG|
#TG|def handle_message(token: str, config_path: Path, cfg: dict, message: dict, users_path: Path, db_path: Path) -> None:
#TG|    started = time.monotonic()
#TG|    chat_id = (message.get("chat") or {}).get("id")
#TG|    text = message.get("text", "")
#TG|    if chat_id is None or not text:
#TG|        return
#TG|    if claim_binding(config_path, cfg, message):
#TG|        send_message(token, int(chat_id), "✅ <b>绑定成功</b>\n\n你已成为此服务器的 Telegram 管理员。\n发送 /start 查看可用命令。")
#TG|        print(f"binding=success admin={chat_id}", flush=True)
#TG|        return
#TG|    if not is_authorized_message(cfg, message):
#TG|        send_message(token, int(chat_id), "⛔ 未授权或绑定链接已失效。\n请在服务器上重新配置机器人并扫描新的二维码。")
#TG|        return
#TG|    send_message(token, int(chat_id), command_reply(text, users_path, db_path))
#TG|    print(f"command={text.split(maxsplit=1)[0]} elapsed={time.monotonic() - started:.3f}s", flush=True)
#TG|
#TG|
#TG|def run_collector(config_path: Path, once: bool = False) -> None:
#TG|    cfg = parse_config(config_path)
#TG|    db_path = Path(cfg.get("TRAFFIC_DB", str(DEFAULT_DB)))
#TG|    xray_bin = Path(cfg.get("XRAY_BIN", str(DEFAULT_XRAY)))
#TG|    interval = max(30, int(cfg.get("COLLECT_INTERVAL", "60")))
#TG|    while True:
#TG|        try:
#TG|            record_snapshot(db_path, query_xray_counters(xray_bin))
#TG|        except Exception as exc:
#TG|            print(f"collector: {exc}", flush=True)
#TG|        if once:
#TG|            return
#TG|        time.sleep(interval)
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
#TG|    db_path = Path(cfg.get("TRAFFIC_DB", str(DEFAULT_DB)))
#TG|    offset = 0
#TG|    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
#TG|        while True:
#TG|            try:
#TG|                result = tg_request(token, "getUpdates", {"timeout": "50", "offset": str(offset), "limit": "20"})
#TG|                updates = result.get("result", [])
#TG|                if updates:
#TG|                    offset = max(int(item["update_id"]) for item in updates) + 1
#TG|                    # Acknowledge the batch immediately; process replies concurrently.
#TG|                    tg_request(token, "getUpdates", {"timeout": "0", "offset": str(offset), "limit": "1"})
#TG|                    for update in updates:
#TG|                        pool.submit(handle_message, token, config_path, cfg, update.get("message") or {}, users_path, db_path)
#TG|            except (urllib.error.URLError, TimeoutError, RuntimeError, json.JSONDecodeError) as exc:
#TG|                print(f"bot: {exc}", flush=True)
#TG|                time.sleep(2)
#TG|
#TG|
#TG|def main() -> None:
#TG|    parser = argparse.ArgumentParser()
#TG|    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
#TG|    parser.add_argument("--collector", action="store_true")
#TG|    parser.add_argument("--collect-once", action="store_true")
#TG|    args = parser.parse_args()
#TG|    if args.collector or args.collect_once:
#TG|        run_collector(args.config, once=args.collect_once)
#TG|    else:
#TG|        run_bot(args.config)
#TG|
#TG|
#TG|if __name__ == "__main__":
#TG|    main()
###__END_VLESS_TG_BOT_PY__###
