
#!/bin/bash
# VLESS 一键管理脚本 v5.4
# 支持：VLESS+Reality 和 VLESS+WS+CF 两种模式，可同时运行
# 新增功能：查看用户 YAML 节点（菜单 16）

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
META_WS="/usr/local/etc/xray/meta-ws.conf"
META="/usr/local/etc/xray/meta.conf"

info()  { echo -e "${GREEN}  ✓${NC}  $1"; }
warn()  { echo -e "${YELLOW}  ⚠${NC}  $1"; }
error() { echo -e "${RED}  ✗${NC}  $1"; }
title() { echo -e "\n${BLUE}┌─${NC} ${CYAN}$1${NC}"; echo -e "${BLUE}└────────────────────────────${NC}"; }

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
# 安全读取 key=value 配置
# ============================================================
read_kv() {
    local file="$1"
    local key="$2"
    [[ -f "$file" ]] || return 1
    awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$file"
}

# ============================================================
# 获取公网 IP
# ============================================================
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
# 加载元数据
# ============================================================
load_meta() {
    REALITY_PRIVATE_KEY=""
    REALITY_PUBLIC_KEY=""
    REALITY_SNI=""
    REALITY_PORT=""
    REALITY_SHORTID=""

    WS_PORT=""
    WS_PATH=""
    WS_DOMAIN=""
    WS_CF_PORT=""
    WS_TLS=""
    CERT_DIR=""

    if [[ -f "$META_REALITY" ]]; then
        REALITY_PRIVATE_KEY=$(read_kv "$META_REALITY" "REALITY_PRIVATE_KEY")
        REALITY_PUBLIC_KEY=$(read_kv "$META_REALITY" "REALITY_PUBLIC_KEY")
        REALITY_SNI=$(read_kv "$META_REALITY" "REALITY_SNI")
        REALITY_PORT=$(read_kv "$META_REALITY" "REALITY_PORT")
        REALITY_SHORTID=$(read_kv "$META_REALITY" "REALITY_SHORTID")
    fi

    if [[ -f "$META_WS" ]]; then
        WS_PORT=$(read_kv "$META_WS" "WS_PORT")
        WS_PATH=$(read_kv "$META_WS" "WS_PATH")
        WS_DOMAIN=$(read_kv "$META_WS" "WS_DOMAIN")
        WS_CF_PORT=$(read_kv "$META_WS" "WS_CF_PORT")
        WS_TLS=$(read_kv "$META_WS" "WS_TLS")
        CERT_DIR=$(read_kv "$META_WS" "CERT_DIR")
        CERT_DIR=${CERT_DIR:-/usr/local/etc/xray/ssl}
    fi

    if [[ ! -f "$META_REALITY" && ! -f "$META_WS" && -f "$META" ]]; then
        REALITY_PRIVATE_KEY=$(read_kv "$META" "REALITY_PRIVATE_KEY")
        REALITY_PUBLIC_KEY=$(read_kv "$META" "REALITY_PUBLIC_KEY")
        REALITY_SNI=$(read_kv "$META" "REALITY_SNI")
        REALITY_PORT=$(read_kv "$META" "REALITY_PORT")
        REALITY_SHORTID=$(read_kv "$META" "REALITY_SHORTID")

        WS_PORT=$(read_kv "$META" "WS_PORT")
        WS_PATH=$(read_kv "$META" "WS_PATH")
        WS_DOMAIN=$(read_kv "$META" "WS_DOMAIN")
        WS_CF_PORT=$(read_kv "$META" "WS_CF_PORT")
        WS_TLS=$(read_kv "$META" "WS_TLS")
        CERT_DIR=$(read_kv "$META" "CERT_DIR")
        CERT_DIR=${CERT_DIR:-/usr/local/etc/xray/ssl}
    fi
}

# ============================================================
# 检查节点是否启用
# ============================================================
has_reality() { [[ -f "$META_REALITY" ]]; }
has_ws()      { [[ -f "$META_WS" ]]; }

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
# 修复 apt 源
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
    fix_apt || return 1
    apt-get install -y -qq curl unzip openssl python3
    [[ $? -ne 0 ]] && error "依赖安装失败" && return 1
    info "依赖安装完成"
}

# ============================================================
# 安装 Xray
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
# 卸载 Xray
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
    OUTPUT=$($XRAY_BIN x25519

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
    normalize_user_db
    load_meta

    echo ""
    echo "当前节点状态："
    has_reality && echo -e "  ${GREEN}✓${NC} Reality 已启用" || echo -e "  ${RED}✗${NC} Reality 未启用"
    has_ws      && echo -e "  ${GREEN}✓${NC} WS+CF   已启用" || echo -e "  ${RED}✗${NC} WS+CF   未启用"
    echo ""
    echo "请选择要操作的节点："
    echo -e "  ${GREEN}1.${NC} 配置 VLESS + Reality"
    echo -e "  ${GREEN}2.${NC} 配置 VLESS + WS + CF"
    has_reality && echo -e "  ${RED}3.${NC} 移除 Reality 节点"
    has_ws      && echo -e "  ${RED}4.${NC} 移除 WS+CF 节点"
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
        2)
            if has_ws; then
                warn "WS+CF 节点已存在，重新配置将覆盖"
                read -rp "确认继续？[y/N]: " C
                [[ "$C" != "y" && "$C" != "Y" ]] && warn "已取消" && return
            fi
            init_ws_cf
            ;;
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
            has_ws || { error "WS+CF 节点未启用"; return; }
            read -rp "确认移除 WS+CF 节点？[y/N]: " C
            [[ "$C" != "y" && "$C" != "Y" ]] && warn "已取消" && return
            rm -f "$META_WS"
            rebuild_config
            _inject_all_users
            _start_xray
            info "WS+CF 节点已移除"
            ;;
        *) error "无效选择" ;;
    esac
}

# ============================================================
# 初始化 Reality
# ============================================================
init_reality() {
    gen_keypair
    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        error "密钥生成失败"
        return
    fi

    while true; do
        read -rp "监听端口 [默认 443]: " REALITY_PORT
        REALITY_PORT=${REALITY_PORT:-443}
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
# 初始化 WS+CF
# ============================================================
init_ws_cf() {
    while true; do
        read -rp "监听端口 [默认 443]: " WS_PORT
        WS_PORT=${WS_PORT:-443}
        check_port "$WS_PORT" && break || warn "端口 ${WS_PORT} 已被占用，请换一个"
    done

    read -rp "WS 路径 [默认 /vless]: " WS_PATH
    WS_PATH=${WS_PATH:-/vless}

    read -rp "你的域名（已在 CF 解析的域名）: " WS_DOMAIN
    [[ -z "$WS_DOMAIN" ]] && error "域名不能为空" && return

    local CERT_DIR="/usr/local/etc/xray/ssl"
    mkdir -p "$CERT_DIR"
    info "正在生成自签证书..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "${CERT_DIR}/ws.key" \
        -out "${CERT_DIR}/ws.crt" \
        -days 3650 \
        -subj "/CN=${WS_DOMAIN}" \
        -addext "subjectAltName=DNS:${WS_DOMAIN}" 2>/dev/null

    chmod 644 "${CERT_DIR}/ws.key"
    chmod 644 "${CERT_DIR}/ws.crt"

    info "自签证书生成完成"

    cat > "$META_WS" <<EOF
WS_PORT=${WS_PORT}
WS_PATH=${WS_PATH}
WS_DOMAIN=${WS_DOMAIN}
WS_CF_PORT=${WS_PORT}
WS_TLS=tls
CERT_DIR=${CERT_DIR}
EOF
    chmod 600 "$META_WS"

    rebuild_config
    _inject_all_users
    _start_xray
    info "WS+CF 节点配置完成"
    echo ""
    echo -e "${YELLOW}═══ Cloudflare 配置说明 ═══${NC}"
    echo -e "1. CF 域名解析：${WS_DOMAIN} → 本机 IP，开启${GREEN}橙云代理${NC}"
    echo -e "2. CF SSL 模式设为 ${GREEN}完全（Full）${NC}"
    echo -e "3. 客户端配置："
    echo -e "   地址   : ${WS_DOMAIN}"
    echo -e "   端口   : ${WS_PORT}"
    echo -e "   WS路径 : ${WS_PATH}"
    echo -e "   TLS    : 开启"
    echo -e "   SNI    : ${WS_DOMAIN}"
    echo ""
}

# ============================================================
# 重建 config.json（支持双节点）
# ============================================================
rebuild_config() {
    load_meta
    local IP_PRIO=""
    [[ -f "$META_REALITY" ]] && IP_PRIO=$(read_kv "$META_REALITY" "IP_PRIORITY")
    [[ -z "$IP_PRIO" && -f "$META_WS" ]] && IP_PRIO=$(read_kv "$META_WS" "IP_PRIORITY")
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

    if has_ws; then
        CERT_DIR=${CERT_DIR:-/usr/local/etc/xray/ssl}
        INBOUNDS="${INBOUNDS}
    {
      \"port\": ${WS_PORT},
      \"listen\": \"0.0.0.0\",
      \"protocol\": \"vless\",
      \"settings\": { \"clients\": [], \"decryption\": \"none\" },
      \"streamSettings\": {
        \"network\": \"ws\",
        \"security\": \"tls\",
        \"tlsSettings\": {
          \"certificates\": [
            {
              \"certificateFile\": \"${CERT_DIR}/ws.crt\",
              \"keyFile\": \"${CERT_DIR}/ws.key\"
            }
          ]
        },
        \"wsSettings\": { \"path\": \"${WS_PATH}\", \"host\": \"${WS_DOMAIN}\" }
      },
      \"sniffing\": { \"enabled\": true, \"destOverride\": [\"http\",\"tls\"] },
      \"tag\": \"inbound-ws\"
    },"
    fi

    INBOUNDS="${INBOUNDS%,}"

    cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
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
# 启动 Xray
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
# 注入用户到 config.json
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
    if node == "both" or (node == "reality" and tag == "inbound-reality") or (node == "ws" and tag == "inbound-ws"):
        flow = "xtls-rprx-vision" if tag == "inbound-reality" else ""
        clients.append({"id": uuid, "flow": flow, "email": name, "comment": expire})
    inbound["settings"]["clients"] = clients

with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF
}

# ============================================================
# 重建后注入所有 active 用户
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
        SHORTID=$(python3 -c "import json; d=json.load(open('$XRAY_CONFIG', encoding='utf-8'));
for i in d['inbounds']:
    if i.get('tag')=='inbound-reality':
        print(i['streamSettings']['realitySettings']['shortIds'][0])")

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
        WS_CF_PORT=${WS_CF_PORT:-443}
        WS_TLS=${WS_TLS:-tls}

        local ENCODED_PATH
        ENCODED_PATH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${WS_PATH}'))")

        local ENCODED_NAME
        ENCODED_NAME=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${USERNAME}-ws'))")

        echo ""
        echo -e "${CYAN}── WS+CF 节点 ──${NC}"
        echo -e "域名   : ${WS_DOMAIN}"
        echo -e "端口   : ${WS_CF_PORT}"
        echo -e "WS路径 : ${WS_PATH}"
        echo -e "TLS    : 开启"
        echo -e "SNI    : ${WS_DOMAIN}"

        local LINK="vless://${UUID}@${WS_DOMAIN}:${WS_CF_PORT}/?type=ws&encryption=none&host=${WS_DOMAIN}&path=${ENCODED_PATH}&security=${WS_TLS}&sni=${WS_DOMAIN}#${ENCODED_NAME}"

        echo -e "${CYAN}分享链接:${NC}"
        echo "$LINK"
    fi

    echo ""
}

# ============================================================
# 新增功能：输出用户 YAML 节点
# ============================================================
_print_yaml() {
    local USERNAME=$1
    local UUID=$2
    local EXPIRE=$3
    local NODE=$4

    load_meta

    echo ""
    echo "proxies:"

    # Reality 节点
    if [[ "$NODE" == "reality" || "$NODE" == "both" ]] && has_reality; then
        local SERVER_IP SHORTID
        SERVER_IP=$(get_public_ip)
        SHORTID=$(python3 -c "import json; d=json.load(open('$XRAY_CONFIG', encoding='utf-8'));
for i in d['inbounds']:
    if i.get('tag')=='inbound-reality':
        print(i['streamSettings']['realitySettings']['shortIds'][0])")

        cat <<EOF
  - name: ${USERNAME}-reality
    type: vless
    server: ${SERVER_IP}
    port: ${REALITY_PORT}
    uuid: ${UUID}
    flow: xtls-rprx-vision
    tls: true
    reality:
      public-key: ${REALITY_PUBLIC_KEY}
      short-id: ${SHORTID}
    sni: ${REALITY_SNI}
    fingerprint: chrome
EOF
    fi

    # WS 节点
    if [[ "$NODE" == "ws" || "$NODE" == "both" ]] && has_ws; then
        cat <<EOF
  - name: ${USERNAME}-ws
    type: vless
    server: ${WS_DOMAIN}
    port: ${WS_CF_PORT}
    uuid: ${UUID}
    tls: true
    network: ws
    ws-opts:
      path: ${WS_PATH}
      headers:
        Host: ${WS_DOMAIN}
    sni: ${WS_DOMAIN}
EOF
    fi

    echo ""
}

# ============================================================
# 查看用户 YAML 节点（菜单 16）
# ============================================================
view_user_yaml() {
    title "查看用户 YAML 节点"
    normalize_user_db
    list_users_brief

    read -rp "输入用户名: " USERNAME
    [[ -z "$USERNAME" ]] && error "用户名不能为空" && return

    local LINE
    LINE=$(grep "^${USERNAME}:" "$USER_DB" 2>/dev/null)

    if [[ -z "$LINE" ]]; then
        error "用户不存在: ${USERNAME}"
        return
    fi

    IFS=: read -r NAME UUID EXPIRE STATUS NODE <<< "$LINE"

    if [[ "$STATUS" != "active" ]]; then
        warn "用户状态不是 active，仍然生成 YAML"
    fi

    _print_yaml "$NAME" "$UUID" "$EXPIRE" "$NODE"
}

# ============================================================
# 添加用户
# ============================================================
add_user() {
    title "添加用户"
    load_meta
    normalize_user_db

    read -rp "用户名（备注用）: " USERNAME
    [[ -z "$USERNAME" ]] && error "用户名不能为空" && return
    if [[ "$USERNAME" =~ [:/\ ] ]]; then
        error "用户名不能包含 : / 空格 等特殊字符"
        return
    fi

    if grep -q "^${USERNAME}:" "$USER_DB" 2>/dev/null; then
        error "用户 ${USERNAME} 已存在"
        return
    fi

    local NODE="both"
    if has_reality && has_ws; then
        echo ""
        echo "请选择加入的节点："
        echo -e "  1. 两个节点都加入"
        echo -e "  2. 仅 Reality"
        echo -e "  3. 仅 WS+CF"
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
        error "尚未配置任何节点，请先选择菜单 1 初始化"
        return
    fi

    read -rp "到期天数 [默认 30 天]: " DAYS
    DAYS=${DAYS:-30}

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

    read -rp "输入要删除的用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return

    if ! grep -qP "^${USERNAME}:" "$USER_DB" 2>/dev/null; then
        error "用户不存在"
        return
    fi

    UUID=$(grep -P "^${USERNAME}:" "$USER_DB" | head -1 | cut -d: -f2)
    local USER_NODE
    USER_NODE=$(grep -P "^${USERNAME}:" "$USER_DB" | head -1 | cut -d: -f5)
    USER_NODE=${USER_NODE:-both}

    local DEL_NODE="both"
    if has_reality && has_ws && [[ "$USER_NODE" == "both" ]]; then
        echo ""
        echo "删除哪个节点的权限？"
        echo -e "  1. 两个节点都删除（彻底删除用户）"
        echo -e "  2. 仅删除 Reality 权限"
        echo -e "  3. 仅删除 WS+CF 权限"
        read -rp "选择 [1/2/3，默认1]: " DEL_SEL
        case ${DEL_SEL:-1} in
            2) DEL_NODE="reality" ;;
            3) DEL_NODE="ws" ;;
            *) DEL_NODE="both" ;;
        esac
    fi

    python3 - <<PYEOF
import json
del_node = "$DEL_NODE"
with open("$XRAY_CONFIG", "r", encoding="utf-8") as f:
    cfg = json.load(f)
for inbound in cfg["inbounds"]:
    tag = inbound.get("tag", "")
    if "clients" not in inbound.get("settings", {}):
        continue
    if del_node == "both" or (del_node == "reality" and tag == "inbound-reality") or (del_node == "ws" and tag == "inbound-ws"):
        clients = inbound["settings"]["clients"]
        inbound["settings"]["clients"] = [c for c in clients if c.get("id") != "$UUID"]
with open("$XRAY_CONFIG", "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF

    if [[ "$DEL_NODE" == "both" ]]; then
        python3 - <<PYEOF
from pathlib import Path
p = Path("$USER_DB")
lines = p.read_text(encoding='utf-8', errors='ignore').splitlines()
out = [l for l in lines if not (l.startswith("$USERNAME:") and l.split(":")[0] == "$USERNAME")]
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
        info "用户 ${USERNAME} 已彻底删除"
    else
        local NEW_NODE
        if [[ "$DEL_NODE" == "reality" ]]; then
            NEW_NODE="ws"
        else
            NEW_NODE="reality"
        fi
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
    parts[4] = "$NEW_NODE"
    out.append(":".join(parts[:5]))
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
        info "用户 ${USERNAME} 的 ${DEL_NODE} 节点权限已移除，保留 ${NEW_NODE} 节点"
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

    if ! grep -q "^${USERNAME}:" "$USER_DB" 2>/dev/null; then
        error "用户不存在"
        return
    fi

    read -rp "续期天数 [默认 30 天]: " DAYS
    DAYS=${DAYS:-30}

    if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
        error "续期天数必须是纯数字"
        return
    fi

    NEW_EXPIRE=$(expire_noon_str "$DAYS")
    [[ -z "$NEW_EXPIRE" ]] && error "到期时间计算失败" && return

    UUID=$(grep -P "^${USERNAME}:" "$USER_DB" | head -1 | cut -d: -f2)
    local STATUS NODE
    STATUS=$(grep -P "^${USERNAME}:" "$USER_DB" | head -1 | cut -d: -f4)
    NODE=$(grep -P "^${USERNAME}:" "$USER_DB" | head -1 | cut -d: -f5)
    NODE=${NODE:-both}
    STATUS=${STATUS:-active}

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

    if ! grep -q "^${USERNAME}:" "$USER_DB" 2>/dev/null; then
        error "用户不存在"
        return
    fi

    UUID=$(grep "^${USERNAME}:" "$USER_DB" | cut -d: -f2)
    local USER_NODE
    USER_NODE=$(grep "^${USERNAME}:" "$USER_DB" | cut -d: -f5)
    USER_NODE=${USER_NODE:-both}

    local OP_NODE="both"
    if has_reality && has_ws && [[ "$USER_NODE" == "both" ]]; then
        echo ""
        echo "操作哪个节点？"
        echo -e "  1. 两个节点"
        echo -e "  2. 仅 Reality"
        echo -e "  3. 仅 WS+CF"
        read -rp "选择 [1/2/3，默认1]: " OP_SEL
        case ${OP_SEL:-1} in
            2) OP_NODE="reality" ;;
            3) OP_NODE="ws" ;;
            *) OP_NODE="both" ;;
        esac
    else
        OP_NODE="$USER_NODE"
    fi

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
    if op_node == "both" or (op_node == "reality" and tag == "inbound-reality") or (op_node == "ws" and tag == "inbound-ws"):
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
        EXPIRE=$(grep -P "^${USERNAME}:" "$USER_DB" | head -1 | cut -d: -f3)

        local EXPIRE_TS NOW_TS
        EXPIRE_TS=$(expire_to_ts "$EXPIRE")
        NOW_TS=$(now_shanghai_ts)
        if [[ -n "$EXPIRE_TS" ]] && (( NOW_TS >= EXPIRE_TS )); then
            warn "用户 ${USERNAME} 已过期（$(expire_display "$EXPIRE")），无法启用"
            warn "请先使用菜单 7 重置到期时间再启用"
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
# 到期检查
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

    if [[ $CHANGED -eq 1 ]];
