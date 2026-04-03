#!/bin/bash
# VLESS 一键管理脚本 v6.0
# 支持：VLESS + Reality、VLESS + WS + CF，两种模式可同时运行

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

XRAY_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
USER_DB="${XRAY_DIR}/users.db"
XRAY_BIN="/usr/local/bin/xray"

META_REALITY="${XRAY_DIR}/meta-reality.conf"
META_WS="${XRAY_DIR}/meta-ws.conf"
META="${XRAY_DIR}/meta.conf"   # 兼容旧版

SSL_DIR="${XRAY_DIR}/ssl"
ACCESS_LOG="/var/log/xray/access.log"
ERROR_LOG="/var/log/xray/error.log"
EXPIRE_LOG="/var/log/xray-expire.log"

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
title() { echo -e "\n${CYAN}$1${NC}"; }

[[ $EUID -ne 0 ]] && error "请用 root 运行此脚本" && exit 1

mkdir -p "$XRAY_DIR"
touch "$USER_DB"

# ============================================================
# 通用工具
# ============================================================
command_exists() { command -v "$1" >/dev/null 2>&1; }

get_server_ip() {
    curl -s4 --max-time 5 ip.sb 2>/dev/null \
    || curl -s4 --max-time 5 ifconfig.me 2>/dev/null \
    || curl -s4 --max-time 5 api.ipify.org 2>/dev/null
}

check_port() {
    local port="$1"
    ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" && return 1 || return 0
}

has_reality() { [[ -f "$META_REALITY" ]]; }
has_ws()      { [[ -f "$META_WS" ]]; }

load_meta() {
    [[ -f "$META_REALITY" ]] && source "$META_REALITY"
    [[ -f "$META_WS" ]] && source "$META_WS"

    # 兼容旧版 meta.conf
    if [[ ! -f "$META_REALITY" && ! -f "$META_WS" && -f "$META" ]]; then
        source "$META"
        if [[ "${MODE:-}" == "reality" ]]; then
            cat > "$META_REALITY" <<EOF
REALITY_PRIVATE_KEY=${PRIVATE_KEY}
REALITY_PUBLIC_KEY=${PUBLIC_KEY}
REALITY_SNI=${SNI}
REALITY_PORT=${PORT}
REALITY_SHORTID=${SHORTID:-$(openssl rand -hex 4)}
EOF
            chmod 600 "$META_REALITY"
        elif [[ "${MODE:-}" == "ws" ]]; then
            cat > "$META_WS" <<EOF
WS_PORT=${PORT}
WS_PATH=${WS_PATH:-/vless}
WS_DOMAIN=${DOMAIN}
WS_CF_PORT=${CF_PORT:-443}
WS_TLS=${WS_TLS:-tls}
CERT_DIR=${CERT_DIR:-$SSL_DIR}
EOF
            chmod 600 "$META_WS"
        fi
    fi
}

normalize_user_db() {
    [[ ! -f "$USER_DB" ]] && return

    python3 - <<PYEOF
from pathlib import Path

p = Path("$USER_DB")
rows = []

for raw in p.read_text(encoding="utf-8", errors="ignore").splitlines():
    raw = raw.strip()
    if not raw:
        continue

    parts = raw.split(":")
    if len(parts) == 4:
        name, uuid, expire, status = parts
        node = "both"
        rows.append(":".join([name, uuid, expire, status, node]))
    elif len(parts) >= 5:
        name, uuid, expire, status, node = parts[:5]
        if node not in ("reality", "ws", "both"):
            node = "both"
        if status not in ("active", "disabled"):
            status = "disabled"
        rows.append(":".join([name, uuid, expire, status, node]))

p.write_text(("\n".join(rows) + "\n") if rows else "", encoding="utf-8")
PYEOF
}

get_user_field() {
    local username="$1"
    local field="$2"
    grep "^${username}:" "$USER_DB" 2>/dev/null | head -n1 | cut -d: -f"$field"
}

user_exists() {
    local username="$1"
    grep -q "^${username}:" "$USER_DB" 2>/dev/null
}

get_total_users() {
    [[ -f "$USER_DB" ]] || { echo 0; return; }
    grep -c . "$USER_DB" 2>/dev/null || echo 0
}

get_active_users() {
    [[ -f "$USER_DB" ]] || { echo 0; return; }
    awk -F: 'NF>=4 && $4=="active"{c++} END{print c+0}' "$USER_DB"
}

get_disabled_users() {
    [[ -f "$USER_DB" ]] || { echo 0; return; }
    awk -F: 'NF>=4 && $4=="disabled"{c++} END{print c+0}' "$USER_DB"
}

# ============================================================
# 修复 apt 源
# ============================================================
fix_apt() {
    if grep -q "bullseye" /etc/os-release 2>/dev/null; then
        cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian bullseye main contrib non-free
deb http://deb.debian.org/debian bullseye-updates main contrib non-free
deb http://security.debian.org/debian-security bullseye-security main contrib non-free
EOF
    fi
    apt-get update -qq
}

# ============================================================
# 安装依赖
# ============================================================
install_deps() {
    title "安装依赖..."
    fix_apt
    apt-get install -y -qq curl unzip openssl python3 ca-certificates
    info "依赖安装完成"
}

# ============================================================
# 安装 Xray
# ============================================================
install_xray() {
    title "安装 Xray..."
    if [[ -x "$XRAY_BIN" ]]; then
        warn "Xray 已安装，跳过"
        return
    fi

    install_deps
    curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o /tmp/xray-install.sh
    bash /tmp/xray-install.sh install
    if [[ $? -ne 0 || ! -x "$XRAY_BIN" ]]; then
        error "安装失败，请检查网络或安装脚本"
        exit 1
    fi

    mkdir -p "$XRAY_DIR" "$SSL_DIR" /var/log/xray
    touch "$USER_DB" "$ACCESS_LOG" "$ERROR_LOG"
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
    bash /tmp/xray-install.sh remove >/dev/null 2>&1

    rm -rf "$XRAY_DIR"
    rm -f "$ACCESS_LOG" "$ERROR_LOG" "$EXPIRE_LOG"
    rm -f /etc/logrotate.d/xray /etc/logrotate.d/xray-expire
    crontab -l 2>/dev/null | grep -v "xray-expire.log" | grep -v "/usr/local/bin/vless-manager --check-expire" | grep -v "truncate.*xray" | crontab -

    info "Xray 已完全卸载"
    exit 0
}

# ============================================================
# 生成密钥对
# ============================================================
gen_keypair() {
    local output
    output=$($XRAY_BIN x25519 2>/dev/null)
    PRIVATE_KEY=$(echo "$output" | awk '/PrivateKey|Private/ {print $NF; exit}')
    PUBLIC_KEY=$(echo "$output" | awk '/PublicKey|Public/ {print $NF; exit}')
    [[ -n "$PRIVATE_KEY" && -n "$PUBLIC_KEY" ]]
}

# ============================================================
# 根据 meta 重建 config.json（支持双节点）
# ============================================================
rebuild_config() {
    local inbounds=""

    if has_reality; then
        source "$META_REALITY"
        inbounds="${inbounds}
    {
      \"port\": ${REALITY_PORT},
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [],
        \"decryption\": \"none\"
      },
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
      \"sniffing\": {
        \"enabled\": true,
        \"destOverride\": [\"http\", \"tls\"]
      },
      \"tag\": \"inbound-reality\"
    },"
    fi

    if has_ws; then
        source "$META_WS"
        CERT_DIR=${CERT_DIR:-$SSL_DIR}
        inbounds="${inbounds}
    {
      \"port\": ${WS_PORT},
      \"listen\": \"0.0.0.0\",
      \"protocol\": \"vless\",
      \"settings\": {
        \"clients\": [],
        \"decryption\": \"none\"
      },
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
        \"wsSettings\": {
          \"path\": \"${WS_PATH}\",
          \"headers\": {
            \"Host\": \"${WS_DOMAIN}\"
          }
        }
      },
      \"sniffing\": {
        \"enabled\": true,
        \"destOverride\": [\"http\", \"tls\"]
      },
      \"tag\": \"inbound-ws\"
    },"
    fi

    inbounds="${inbounds%,}"

    cat > "$XRAY_CONFIG" <<EOF
{
  "log": {
    "access": "${ACCESS_LOG}",
    "error": "${ERROR_LOG}",
    "loglevel": "warning"
  },
  "inbounds": [${inbounds}
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF
}

validate_xray_config() {
    [[ -x "$XRAY_BIN" ]] || { error "Xray 未安装"; return 1; }
    [[ -f "$XRAY_CONFIG" ]] || { error "配置文件不存在"; return 1; }

    if $XRAY_BIN run -test -config "$XRAY_CONFIG" >/dev/null 2>&1; then
        return 0
    fi

    error "Xray 配置校验失败，未重启服务"
    return 1
}

restart_xray() {
    validate_xray_config || return 1

    systemctl enable xray >/dev/null 2>&1
    systemctl restart xray
    sleep 1

    if systemctl is-active --quiet xray; then
        info "Xray 已启动"
        return 0
    else
        error "Xray 启动失败，请执行：journalctl -u xray -n 50 --no-pager"
        return 1
    fi
}

# ============================================================
# 注入用户到 config.json
# ============================================================
_inject_user() {
    local uuid="$1"
    local name="$2"
    local expire="$3"
    local node="$4"   # reality | ws | both

    python3 - <<PYEOF
import json

cfg_path = "$XRAY_CONFIG"
uuid = "$uuid"
name = "$name"
expire = "$expire"
node = "$node"

with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

for inbound in cfg.get("inbounds", []):
    tag = inbound.get("tag", "")
    clients = inbound.get("settings", {}).get("clients", [])
    clients = [c for c in clients if c.get("id") != uuid]

    should_add = (
        node == "both" or
        (node == "reality" and tag == "inbound-reality") or
        (node == "ws" and tag == "inbound-ws")
    )

    if should_add:
        client = {
            "id": uuid,
            "email": name,
            "comment": expire
        }
        if tag == "inbound-reality":
            client["flow"] = "xtls-rprx-vision"
        clients.append(client)

    inbound["settings"]["clients"] = clients

with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
PYEOF
}

_remove_user_from_config() {
    local uuid="$1"
    local node="${2:-both}"

    [[ -f "$XRAY_CONFIG" ]] || return 0

    python3 - <<PYEOF
import json

cfg_path = "$XRAY_CONFIG"
uuid = "$uuid"
node = "$node"

with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

for inbound in cfg.get("inbounds", []):
    tag = inbound.get("tag", "")
    should_remove = (
        node == "both" or
        (node == "reality" and tag == "inbound-reality") or
        (node == "ws" and tag == "inbound-ws")
    )
    if should_remove:
        clients = inbound.get("settings", {}).get("clients", [])
        inbound["settings"]["clients"] = [c for c in clients if c.get("id") != uuid]

with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
PYEOF
}

_inject_all_users() {
    [[ -f "$USER_DB" ]] || return
    while IFS=: read -r NAME UUID EXPIRE STATUS NODE; do
        [[ -z "$NAME" ]] && continue
        NODE=${NODE:-both}
        [[ "$STATUS" != "active" ]] && continue
        _inject_user "$UUID" "$NAME" "$EXPIRE" "$NODE"
    done < "$USER_DB"
}

# ============================================================
# 初始化配置
# ============================================================
init_reality() {
    if ! gen_keypair; then
        error "密钥生成失败"
        return
    fi

    local reality_port reality_sni reality_shortid
    while true; do
        read -rp "监听端口 [默认 443]: " reality_port
        reality_port=${reality_port:-443}
        check_port "$reality_port" && break || warn "端口 ${reality_port} 已被占用，请换一个"
    done

    read -rp "伪装域名 [默认 www.microsoft.com]: " reality_sni
    reality_sni=${reality_sni:-www.microsoft.com}
    reality_shortid=$(openssl rand -hex 4)

    cat > "$META_REALITY" <<EOF
REALITY_PRIVATE_KEY=${PRIVATE_KEY}
REALITY_PUBLIC_KEY=${PUBLIC_KEY}
REALITY_SNI=${reality_sni}
REALITY_PORT=${reality_port}
REALITY_SHORTID=${reality_shortid}
EOF
    chmod 600 "$META_REALITY"

    rebuild_config
    _inject_all_users
    restart_xray || return

    info "Reality 节点配置完成"
    info "公钥: ${PUBLIC_KEY}"
}

init_ws_cf() {
    local ws_port ws_path ws_domain cert_dir
    while true; do
        read -rp "监听端口 [默认 443]: " ws_port
        ws_port=${ws_port:-443}
        check_port "$ws_port" && break || warn "端口 ${ws_port} 已被占用，请换一个"
    done

    read -rp "WS 路径 [默认 /vless]: " ws_path
    ws_path=${ws_path:-/vless}
    [[ "$ws_path" != /* ]] && ws_path="/${ws_path}"

    read -rp "你的域名（已在 CF 解析的域名）: " ws_domain
    [[ -z "$ws_domain" ]] && error "域名不能为空" && return

    cert_dir="$SSL_DIR"
    mkdir -p "$cert_dir"

    info "正在生成自签证书..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "${cert_dir}/ws.key" \
        -out "${cert_dir}/ws.crt" \
        -days 3650 \
        -subj "/CN=${ws_domain}" \
        -addext "subjectAltName=DNS:${ws_domain}" >/dev/null 2>&1

    if [[ ! -f "${cert_dir}/ws.key" || ! -f "${cert_dir}/ws.crt" ]]; then
        error "自签证书生成失败"
        return
    fi

    chmod 600 "${cert_dir}/ws.key"

    cat > "$META_WS" <<EOF
WS_PORT=${ws_port}
WS_PATH=${ws_path}
WS_DOMAIN=${ws_domain}
WS_CF_PORT=${ws_port}
WS_TLS=tls
CERT_DIR=${cert_dir}
EOF
    chmod 600 "$META_WS"

    rebuild_config
    _inject_all_users
    restart_xray || return

    info "WS+CF 节点配置完成"
    echo ""
    echo -e "${YELLOW}═══ Cloudflare 配置说明 ═══${NC}"
    echo -e "1. CF 域名解析：${ws_domain} → 本机 IP，开启 ${GREEN}橙云代理${NC}"
    echo -e "2. CF SSL 模式："
    echo -e "   - 自签证书：${GREEN}Full${NC}"
    echo -e "   - 正式受信任证书：${GREEN}Full (strict)${NC}"
    echo -e "3. 客户端配置："
    echo -e "   地址   : ${ws_domain}"
    echo -e "   端口   : ${ws_port}"
    echo -e "   WS路径 : ${ws_path}"
    echo -e "   TLS    : 开启"
    echo -e "   SNI    : ${ws_domain}"
    echo ""
}

init_config() {
    title "节点配置..."
    mkdir -p "$XRAY_DIR"
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
            restart_xray
            info "Reality 节点已移除"
            ;;
        4)
            has_ws || { error "WS+CF 节点未启用"; return; }
            read -rp "确认移除 WS+CF 节点？[y/N]: " C
            [[ "$C" != "y" && "$C" != "Y" ]] && warn "已取消" && return
            rm -f "$META_WS"
            rebuild_config
            _inject_all_users
            restart_xray
            info "WS+CF 节点已移除"
            ;;
        *)
            error "无效选择"
            ;;
    esac
}

# ============================================================
# 打印节点分享链接
# ============================================================
_print_link() {
    local username="$1"
    local uuid="$2"
    local expire="$3"
    local node="${4:-both}"

    load_meta

    echo ""
    echo -e "${GREEN}===== 节点信息 =====${NC}"
    echo -e "用户名 : ${username}"
    echo -e "UUID   : ${uuid}"
    echo -e "到期   : ${expire}"
    echo -e "节点   : ${node}"

    if [[ "$node" == "reality" || "$node" == "both" ]] && has_reality; then
        source "$META_REALITY"
        local server_ip shortid link
        server_ip=$(get_server_ip)
        shortid="${REALITY_SHORTID}"

        echo ""
        echo -e "${CYAN}── Reality 节点 ──${NC}"
        echo -e "地址   : ${server_ip}"
        echo -e "端口   : ${REALITY_PORT}"
        echo -e "公钥   : ${REALITY_PUBLIC_KEY}"
        echo -e "SNI    : ${REALITY_SNI}"
        echo -e "ShortID: ${shortid}"

        link="vless://${uuid}@${server_ip}:${REALITY_PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${shortid}&type=tcp&flow=xtls-rprx-vision#${username}-reality"
        echo -e "${CYAN}分享链接:${NC}"
        echo "$link"
    fi

    if [[ "$node" == "ws" || "$node" == "both" ]] && has_ws; then
        source "$META_WS"
        local encoded_path encoded_name link ws_cf_port ws_tls
        ws_cf_port=${WS_CF_PORT:-$WS_PORT}
        ws_tls=${WS_TLS:-tls}

        encoded_path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${WS_PATH}', safe=''))")
        encoded_name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${username}-ws', safe=''))")

        echo ""
        echo -e "${CYAN}── WS+CF 节点 ──${NC}"
        echo -e "域名   : ${WS_DOMAIN}"
        echo -e "端口   : ${ws_cf_port}"
        echo -e "WS路径 : ${WS_PATH}"
        echo -e "TLS    : $( [[ "$ws_tls" == "tls" ]] && echo "开启" || echo "关闭" )"
        echo -e "SNI    : ${WS_DOMAIN}"

        link="vless://${uuid}@${WS_DOMAIN}:${ws_cf_port}?type=ws&encryption=none&host=${WS_DOMAIN}&path=${encoded_path}&security=${ws_tls}&sni=${WS_DOMAIN}#${encoded_name}"
        echo -e "${CYAN}分享链接:${NC}"
        echo "$link"
    fi

    echo ""
}

# ============================================================
# 用户管理
# ============================================================
add_user() {
    title "添加用户"
    normalize_user_db
    load_meta

    read -rp "用户名（备注用）: " USERNAME
    [[ -z "$USERNAME" ]] && error "用户名不能为空" && return

    if [[ "$USERNAME" =~ [:/[:space:]] ]]; then
        error "用户名不能包含 : / 空格"
        return
    fi

    if user_exists "$USERNAME"; then
        error "用户 ${USERNAME} 已存在"
        return
    fi

    local NODE="both"
    if has_reality && has_ws; then
        echo ""
        echo "请选择加入的节点："
        echo -e "  ${GREEN}1.${NC} 两个节点都加入"
        echo -e "  ${GREEN}2.${NC} 仅 Reality"
        echo -e "  ${GREEN}3.${NC} 仅 WS+CF"
        read -rp "选择 [1/2/3，默认1]: " NODE_SEL
        case "${NODE_SEL:-1}" in
            2) NODE="reality" ;;
            3) NODE="ws" ;;
            *) NODE="both" ;;
        esac
    elif has_reality; then
        NODE="reality"
    elif has_ws; then
        NODE="ws"
    else
        error "尚未配置任何节点，请先初始化"
        return
    fi

    echo "到期方式："
    echo "  1. 输入天数（如 30）"
    echo "  2. 输入具体日期（如 2026-12-31）"
    read -rp "选择 [1/2，默认1]: " EXPIRE_MODE
    EXPIRE_MODE=${EXPIRE_MODE:-1}

    local EXPIRE DAYS
    if [[ "$EXPIRE_MODE" == "2" ]]; then
        read -rp "到期日期 (YYYY-MM-DD): " EXPIRE
        if ! date -d "$EXPIRE" +%Y-%m-%d >/dev/null 2>&1; then
            error "日期格式错误"
            return
        fi
        EXPIRE=$(date -d "$EXPIRE" +%Y-%m-%d)
    else
        read -rp "到期天数 [默认 30 天]: " DAYS
        DAYS=${DAYS:-30}
        [[ "$DAYS" =~ ^[0-9]+$ ]] || { error "天数必须是数字"; return; }
        EXPIRE=$(date -d "+${DAYS} days" +%Y-%m-%d)
    fi

    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "${USERNAME}:${UUID}:${EXPIRE}:active:${NODE}" >> "$USER_DB"

    _inject_user "$UUID" "$USERNAME" "$EXPIRE" "$NODE"
    restart_xray || return

    _print_link "$USERNAME" "$UUID" "$EXPIRE" "$NODE"
}

delete_user() {
    title "删除用户"
    normalize_user_db
    list_users_brief

    read -rp "输入要删除的用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return

    if ! user_exists "$USERNAME"; then
        error "用户不存在"
        return
    fi

    local UUID USER_NODE DEL_NODE NEW_NODE
    UUID=$(get_user_field "$USERNAME" 2)
    USER_NODE=$(get_user_field "$USERNAME" 5)
    USER_NODE=${USER_NODE:-both}
    DEL_NODE="both"

    if has_reality && has_ws && [[ "$USER_NODE" == "both" ]]; then
        echo ""
        echo "删除哪个节点的权限？"
        echo -e "  ${GREEN}1.${NC} 两个节点都删除（彻底删除用户）"
        echo -e "  ${GREEN}2.${NC} 仅删除 Reality 权限"
        echo -e "  ${GREEN}3.${NC} 仅删除 WS+CF 权限"
        read -rp "选择 [1/2/3，默认1]: " DEL_SEL
        case "${DEL_SEL:-1}" in
            2) DEL_NODE="reality" ;;
            3) DEL_NODE="ws" ;;
            *) DEL_NODE="both" ;;
        esac
    fi

    _remove_user_from_config "$UUID" "$DEL_NODE"

    if [[ "$DEL_NODE" == "both" || "$USER_NODE" != "both" ]]; then
        sed -i "/^${USERNAME}:/d" "$USER_DB"
        info "用户 ${USERNAME} 已彻底删除"
    else
        if [[ "$DEL_NODE" == "reality" ]]; then
            NEW_NODE="ws"
        else
            NEW_NODE="reality"
        fi

        python3 - <<PYEOF
from pathlib import Path

p = Path("$USER_DB")
rows = []
for raw in p.read_text(encoding="utf-8").splitlines():
    if not raw.strip():
        continue
    parts = raw.split(":")
    if len(parts) < 5:
        continue
    name, uuid, expire, status, node = parts[:5]
    if name == "$USERNAME":
        node = "$NEW_NODE"
    rows.append(":".join([name, uuid, expire, status, node]))
p.write_text(("\n".join(rows) + "\n") if rows else "", encoding="utf-8")
PYEOF
        info "用户 ${USERNAME} 的 ${DEL_NODE} 节点权限已移除，保留 ${NEW_NODE} 节点"
    fi

    restart_xray
}

renew_user() {
    title "重置到期时间"
    normalize_user_db
    list_users_brief

    read -rp "输入用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return

    if ! user_exists "$USERNAME"; then
        error "用户不存在"
        return
    fi

    echo "到期方式："
    echo "  1. 输入天数（如 30）"
    echo "  2. 输入具体日期（如 2026-12-31）"
    read -rp "选择 [1/2，默认1]: " EXPIRE_MODE
    EXPIRE_MODE=${EXPIRE_MODE:-1}

    local NEW_EXPIRE DAYS
    if [[ "$EXPIRE_MODE" == "2" ]]; then
        read -rp "新到期日期 (YYYY-MM-DD): " NEW_EXPIRE
        if ! date -d "$NEW_EXPIRE" +%Y-%m-%d >/dev/null 2>&1; then
            error "日期格式错误"
            return
        fi
        NEW_EXPIRE=$(date -d "$NEW_EXPIRE" +%Y-%m-%d)
    else
        read -rp "续期天数 [默认 30 天]: " DAYS
        DAYS=${DAYS:-30}
        [[ "$DAYS" =~ ^[0-9]+$ ]] || { error "天数必须是数字"; return; }
        NEW_EXPIRE=$(date -d "+${DAYS} days" +%Y-%m-%d)
    fi

    python3 - <<PYEOF
from pathlib import Path

p = Path("$USER_DB")
rows = []

for raw in p.read_text(encoding="utf-8").splitlines():
    raw = raw.strip()
    if not raw:
        continue
    parts = raw.split(":")
    if len(parts) == 4:
        parts.append("both")
    if len(parts) < 5:
        continue
    name, uuid, expire, status, node = parts[:5]
    if name == "$USERNAME":
        expire = "$NEW_EXPIRE"
    rows.append(":".join([name, uuid, expire, status, node]))

p.write_text(("\n".join(rows) + "\n") if rows else "", encoding="utf-8")
PYEOF

    local UUID USER_STATUS USER_NODE
    UUID=$(get_user_field "$USERNAME" 2)
    USER_STATUS=$(get_user_field "$USERNAME" 4)
    USER_NODE=$(get_user_field "$USERNAME" 5)
    USER_NODE=${USER_NODE:-both}

    if [[ "$USER_STATUS" == "active" ]]; then
        _inject_user "$UUID" "$USERNAME" "$NEW_EXPIRE" "$USER_NODE"
        restart_xray || return
    fi

    info "用户 ${USERNAME} 到期时间已更新为 ${NEW_EXPIRE}"
}

toggle_user() {
    local ACTION="$1"
    title "$( [[ "$ACTION" == "disable" ]] && echo "禁用" || echo "启用" ) 用户"
    normalize_user_db
    list_users_brief

    read -rp "输入用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return

    if ! user_exists "$USERNAME"; then
        error "用户不存在"
        return
    fi

    local UUID EXPIRE NODE STATUS
    UUID=$(get_user_field "$USERNAME" 2)
    EXPIRE=$(get_user_field "$USERNAME" 3)
    STATUS=$(get_user_field "$USERNAME" 4)
    NODE=$(get_user_field "$USERNAME" 5)
    NODE=${NODE:-both}

    if [[ "$ACTION" == "disable" ]]; then
        [[ "$STATUS" == "disabled" ]] && warn "该用户已是禁用状态" && return

        _remove_user_from_config "$UUID" "both"

        python3 - <<PYEOF
from pathlib import Path

p = Path("$USER_DB")
rows = []

for raw in p.read_text(encoding="utf-8").splitlines():
    raw = raw.strip()
    if not raw:
        continue
    parts = raw.split(":")
    if len(parts) == 4:
        parts.append("both")
    if len(parts) < 5:
        continue
    name, uuid, expire, status, node = parts[:5]
    if name == "$USERNAME":
        status = "disabled"
    rows.append(":".join([name, uuid, expire, status, node]))

p.write_text(("\n".join(rows) + "\n") if rows else "", encoding="utf-8")
PYEOF

        restart_xray || return
        info "用户 ${USERNAME} 已禁用"
    else
        [[ "$STATUS" == "active" ]] && warn "该用户已是启用状态" && return

        _inject_user "$UUID" "$USERNAME" "$EXPIRE" "$NODE"

        python3 - <<PYEOF
from pathlib import Path

p = Path("$USER_DB")
rows = []

for raw in p.read_text(encoding="utf-8").splitlines():
    raw = raw.strip()
    if not raw:
        continue
    parts = raw.split(":")
    if len(parts) == 4:
        parts.append("both")
    if len(parts) < 5:
        continue
    name, uuid, expire, status, node = parts[:5]
    if name == "$USERNAME":
        status = "active"
    rows.append(":".join([name, uuid, expire, status, node]))

p.write_text(("\n".join(rows) + "\n") if rows else "", encoding="utf-8")
PYEOF

        restart_xray || return
        info "用户 ${USERNAME} 已启用"
    fi
}

check_expire() {
    title "检查到期用户..."
    normalize_user_db

    [[ ! -f "$USER_DB" || ! -s "$USER_DB" ]] && info "暂无用户" && return

    local TODAY
    TODAY=$(date +%Y-%m-%d)

    python3 - <<PYEOF
import json
from pathlib import Path

today = "$TODAY"
user_db = Path("$USER_DB")
cfg_path = Path("$XRAY_CONFIG")

rows = []
expired_ids = []
expired_names = []

for raw in user_db.read_text(encoding="utf-8").splitlines():
    raw = raw.strip()
    if not raw:
        continue
    parts = raw.split(":")
    if len(parts) == 4:
        parts.append("both")
    if len(parts) < 5:
        continue

    name, uuid, expire, status, node = parts[:5]

    if status == "active" and expire < today:
        status = "disabled"
        expired_ids.append(uuid)
        expired_names.append((name, expire))

    rows.append(":".join([name, uuid, expire, status, node]))

user_db.write_text(("\n".join(rows) + "\n") if rows else "", encoding="utf-8")

if expired_names:
    for name, expire in expired_names:
        print(f"EXPIRED::{name}::{expire}")

if expired_ids and cfg_path.exists():
    with open(cfg_path, "r", encoding="utf-8") as f:
        cfg = json.load(f)

    for inbound in cfg.get("inbounds", []):
        clients = inbound.get("settings", {}).get("clients", [])
        inbound["settings"]["clients"] = [c for c in clients if c.get("id") not in expired_ids]

    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
PYEOF

    local changed=0
    while IFS= read -r line; do
        [[ "$line" == EXPIRED::* ]] || continue
        changed=1
        local name expire
        name=$(echo "$line" | cut -d: -f3)
        expire=$(echo "$line" | cut -d: -f5)
        warn "用户 ${name} 已到期（${expire}），自动禁用"
    done < <(
        python3 - <<PYEOF
from pathlib import Path
today = "$TODAY"
p = Path("$USER_DB")
for raw in p.read_text(encoding="utf-8").splitlines():
    parts = raw.strip().split(":")
    if len(parts) >= 5:
        name, uuid, expire, status, node = parts[:5]
        if status == "disabled" and expire < today:
            print(f"EXPIRED::{name}::{expire}")
PYEOF
    )

    if [[ $changed -eq 1 ]]; then
        restart_xray || return
        info "到期用户处理完成"
    else
        info "没有到期用户"
    fi
}

list_users() {
    title "用户列表"
    normalize_user_db
    [[ ! -s "$USER_DB" ]] && warn "暂无用户" && return

    local TOTAL ACTIVE DISABLED
    TOTAL=$(get_total_users)
    ACTIVE=$(get_active_users)
    DISABLED=$(get_disabled_users)

    echo -e "共 ${TOTAL} 个用户  ${GREEN}活跃: ${ACTIVE}${NC}  ${RED}禁用: ${DISABLED}${NC}"
    echo ""
    printf "%-15s %-38s %-12s %-10s %-10s\n" "用户名" "UUID" "到期日" "状态" "节点"
    echo "------------------------------------------------------------------------------------------------"

    while IFS=: read -r NAME UUID EXPIRE STATUS NODE; do
        [[ -z "$NAME" ]] && continue
        NODE=${NODE:-both}
        COLOR=$NC
        [[ "$STATUS" == "disabled" ]] && COLOR=$RED
        [[ "$STATUS" == "active" ]] && COLOR=$GREEN
        printf "${COLOR}%-15s %-38s %-12s %-10s %-10s${NC}\n" "$NAME" "$UUID" "$EXPIRE" "$STATUS" "$NODE"
    done < "$USER_DB"
}

list_users_brief() {
    echo ""
    [[ ! -s "$USER_DB" ]] && echo "  （暂无用户）" && echo "" && return
    while IFS=: read -r NAME UUID EXPIRE STATUS NODE; do
        [[ -z "$NAME" ]] && continue
        NODE=${NODE:-both}
        printf "  %-15s %s  [%s] (%s)\n" "$NAME" "$EXPIRE" "$STATUS" "$NODE"
    done < "$USER_DB"
    echo ""
}

# ============================================================
# 查看节点信息
# ============================================================
show_info() {
    title "节点信息"
    load_meta

    local xray_status user_count active_count
    xray_status=$(systemctl is-active xray 2>/dev/null || echo inactive)
    user_count=$(get_total_users)
    active_count=$(get_active_users)

    echo -e "状态   : $( [[ "$xray_status" == "active" ]] && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}已停止${NC}" )"
    echo -e "用户数 : 共 ${user_count} 个，活跃 ${active_count} 个"
    echo ""

    if has_reality; then
        source "$META_REALITY"
        local server_ip
        server_ip=$(get_server_ip)

        echo -e "${CYAN}── Reality 节点 ──${NC}"
        echo -e "地址   : ${server_ip}"
        echo -e "端口   : ${REALITY_PORT}"
        echo -e "公钥   : ${REALITY_PUBLIC_KEY}"
        echo -e "SNI    : ${REALITY_SNI}"
        echo -e "ShortID: ${REALITY_SHORTID}"
        echo -e "协议   : VLESS + Reality + TCP"
        echo ""
    fi

    if has_ws; then
        source "$META_WS"
        echo -e "${CYAN}── WS+CF 节点 ──${NC}"
        echo -e "域名   : ${WS_DOMAIN}"
        echo -e "端口   : ${WS_CF_PORT:-$WS_PORT}"
        echo -e "本地端口: ${WS_PORT}"
        echo -e "WS路径 : ${WS_PATH}"
        echo -e "TLS    : ${WS_TLS:-tls}"
        echo -e "协议   : VLESS + WS + TLS"
        echo ""
    fi

    if ! has_reality && ! has_ws; then
        warn "当前未配置任何节点"
    fi
}

# ============================================================
# 设置 cron
# ============================================================
setup_cron() {
    local manager_bin="/usr/local/bin/vless-manager"

    if [[ ! -x "$manager_bin" ]]; then
        warn "未检测到本地命令 ${manager_bin}，先自动安装快捷命令"
        install_shortcut
    fi

    if [[ ! -x "$manager_bin" ]]; then
        error "快捷命令安装失败，无法设置 cron"
        return
    fi

    local EXPIRE_CMD="0 1 * * * ${manager_bin} --check-expire >> ${EXPIRE_LOG} 2>&1"
    local LOG_CMD="0 3 * * 0 truncate -s 0 ${ACCESS_LOG} ${ERROR_LOG}"

    (
        crontab -l 2>/dev/null \
        | grep -v "${manager_bin} --check-expire" \
        | grep -v "truncate -s 0 ${ACCESS_LOG} ${ERROR_LOG}"
        echo "$EXPIRE_CMD"
        echo "$LOG_CMD"
    ) | crontab -

    info "已设置每日 01:00 自动检查到期用户"
    info "已设置每周日 03:00 自动清理日志"

    cat > /etc/logrotate.d/xray-expire <<EOF
${EXPIRE_LOG} {
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

    info "已配置日志自动轮转（每周轮转，保留 4 周）"
}

# ============================================================
# BBR 优化
# ============================================================
enable_bbr() {
    title "开启 BBR 拥塞控制..."

    if ! modinfo tcp_bbr >/dev/null 2>&1; then
        error "当前内核不支持 BBR，请升级内核（建议 4.9+）"
        return
    fi

    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$current_cc" == "bbr" ]]; then
        info "BBR 已经开启，无需重复设置"
        return
    fi

    modprobe tcp_bbr 2>/dev/null

    if grep -q "^# BBR$" /etc/sysctl.conf 2>/dev/null; then
        sed -i '/^# BBR$/,/^$/d' /etc/sysctl.conf
    fi

    cat >> /etc/sysctl.conf <<EOF

# BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    sysctl -p >/dev/null 2>&1

    local new_cc
    new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$new_cc" == "bbr" ]]; then
        info "BBR 开启成功"
    else
        error "BBR 开启失败，请手动检查"
    fi
}

# ============================================================
# TCP 智能优化
# ============================================================
optimize_tcp() {
    title "TCP 智能优化..."
    echo -e "正在测试网络质量，请稍候...\n"

    local TOTAL_MS=0 TOTAL_FAIL=0 TOTAL_COUNT=0
    local TARGETS=("v4-sc-ct.oojj.de:80" "v4-sc-cm.oojj.de:80")

    for TARGET in "${TARGETS[@]}"; do
        local HOST="${TARGET%%:*}"
        local PORT="${TARGET##*:}"

        for _ in {1..20}; do
            local MS
            MS=$(curl -o /dev/null -s -w "%{time_connect}" \
                --connect-timeout 3 --max-time 5 \
                "http://${HOST}:${PORT}/" 2>/dev/null)

            if [[ $? -eq 0 && -n "$MS" && "$MS" != "0.000000" ]]; then
                local MS_INT
                MS_INT=$(python3 -c "print(int(float('${MS}') * 1000))" 2>/dev/null)
                TOTAL_MS=$((TOTAL_MS + MS_INT))
                TOTAL_COUNT=$((TOTAL_COUNT + 1))
            else
                TOTAL_FAIL=$((TOTAL_FAIL + 1))
            fi
        done
    done

    local AVG_MS=999 LOSS_PCT=100
    if [[ $TOTAL_COUNT -gt 0 ]]; then
        AVG_MS=$((TOTAL_MS / TOTAL_COUNT))
        LOSS_PCT=$(( TOTAL_FAIL * 100 / (TOTAL_COUNT + TOTAL_FAIL) ))
    fi

    echo -e "测试结果：平均延迟 ${CYAN}${AVG_MS}ms${NC}  丢包率 ${CYAN}${LOSS_PCT}%${NC}"
    echo ""

    if grep -q "^# VLESS TCP优化" /etc/sysctl.conf 2>/dev/null; then
        warn "检测到已有 TCP 优化配置，先清除旧配置..."
        sed -i '/^# VLESS TCP优化/,/^$/d' /etc/sysctl.conf
    fi

    local STRATEGY=""
    local STRATEGY_DESC=""

    if [[ $AVG_MS -lt 80 && $LOSS_PCT -lt 5 ]]; then
        STRATEGY="good"
        STRATEGY_DESC="线路优质，使用轻度优化"
    elif [[ $AVG_MS -lt 80 && $LOSS_PCT -ge 5 ]]; then
        STRATEGY="low_latency_high_loss"
        STRATEGY_DESC="延迟低但丢包高，启用重传优化"
    elif [[ $AVG_MS -ge 80 && $AVG_MS -lt 150 && $LOSS_PCT -lt 5 ]]; then
        STRATEGY="high_latency_low_loss"
        STRATEGY_DESC="延迟较高但线路稳定，加大缓冲区"
    else
        STRATEGY="bad"
        STRATEGY_DESC="线路较差，启用激进优化"
    fi

    info "优化策略：${STRATEGY_DESC}"
    echo ""

    case "$STRATEGY" in
        good)
            cat >> /etc/sysctl.conf <<EOF

# VLESS TCP优化
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
EOF
            ;;
        low_latency_high_loss)
            cat >> /etc/sysctl.conf <<EOF

# VLESS TCP优化
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_tw_reuse = 1
EOF
            ;;
        high_latency_low_loss)
            cat >> /etc/sysctl.conf <<EOF

# VLESS TCP优化
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.netdev_max_backlog = 250000
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
EOF
            ;;
        bad)
            cat >> /etc/sysctl.conf <<EOF

# VLESS TCP优化
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 8192
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
EOF
            ;;
    esac

    modprobe tcp_bbr 2>/dev/null
    sysctl -p >/dev/null 2>&1
    info "TCP 智能优化完成！策略：${STRATEGY_DESC}"
}

# ============================================================
# 网络测试
# ============================================================
network_test() {
    title "网络质量测试..."
    echo -e "测试服务器到国内各运营商的延迟和丢包率...\n"

    declare -A TARGETS=(
        ["电信-四川"]="v4-sc-ct.oojj.de:80"
        ["移动-四川"]="v4-sc-cm.oojj.de:80"
    )

    printf "%-15s %-30s %-12s %-10s\n" "线路" "节点" "延迟(ms)" "状态"
    echo "──────────────────────────────────────────────────────"

    for NAME in "${!TARGETS[@]}"; do
        local TARGET="${TARGETS[$NAME]}"
        local HOST="${TARGET%%:*}"
        local PORT="${TARGET##*:}"

        local TOTAL=0 COUNT=0 FAIL=0
        for _ in {1..20}; do
            local MS
            MS=$(curl -o /dev/null -s -w "%{time_connect}" \
                --connect-timeout 3 --max-time 5 \
                "http://${HOST}:${PORT}/" 2>/dev/null)
            if [[ $? -eq 0 && -n "$MS" && "$MS" != "0.000000" ]]; then
                local MS_INT
                MS_INT=$(python3 -c "print(int(float('${MS}') * 1000))" 2>/dev/null)
                TOTAL=$((TOTAL + MS_INT))
                COUNT=$((COUNT + 1))
            else
                FAIL=$((FAIL + 1))
            fi
        done

        if [[ $COUNT -eq 0 ]]; then
            printf "${RED}%-15s${NC} %-30s ${RED}%-12s${NC} ${RED}%s${NC}\n" \
                "$NAME" "$TARGET" "超时" "全部失败"
        else
            local AVG LOSS_PCT
            AVG=$((TOTAL / COUNT))
            LOSS_PCT=$(( FAIL * 100 / 20 ))

            if [[ $AVG -lt 80 ]]; then
                printf "${GREEN}%-15s${NC} %-30s ${GREEN}%-12s${NC} ${GREEN}丢包:${LOSS_PCT}%%${NC}\n" \
                    "$NAME" "$TARGET" "${AVG}ms"
            elif [[ $AVG -lt 150 ]]; then
                printf "${YELLOW}%-15s${NC} %-30s ${YELLOW}%-12s${NC} ${YELLOW}丢包:${LOSS_PCT}%%${NC}\n" \
                    "$NAME" "$TARGET" "${AVG}ms"
            else
                printf "${RED}%-15s${NC} %-30s ${RED}%-12s${NC} ${RED}丢包:${LOSS_PCT}%%${NC}\n" \
                    "$NAME" "$TARGET" "${AVG}ms"
            fi
        fi
    done

    echo ""
    echo -e "${GREEN}<80ms${NC} 优秀  ${YELLOW}80-150ms${NC} 一般  ${RED}>150ms${NC} 较差"
}

optimize_menu() {
    title "网络优化"
    echo ""
    echo -e "  ${GREEN}1.${NC} 开启 BBR（推荐，提升吞吐量）"
    echo -e "  ${GREEN}2.${NC} TCP 参数优化（缓冲区/队列调优）"
    echo -e "  ${GREEN}3.${NC} 一键全部优化（BBR + TCP）"
    echo -e "  ${GREEN}4.${NC} 网络质量测试（延迟 + 丢包）"
    echo -e "  ${GREEN}0.${NC} 返回"
    echo ""
    read -rp "选择: " OPT
    case "$OPT" in
        1) enable_bbr ;;
        2) optimize_tcp ;;
        3) enable_bbr; optimize_tcp ;;
        4) network_test ;;
        0) return ;;
        *) warn "无效选项" ;;
    esac
}

# ============================================================
# 更新 Xray
# ============================================================
update_xray() {
    title "更新 Xray..."
    local CURRENT_VER NEW_VER

    CURRENT_VER=$($XRAY_BIN -version 2>/dev/null | awk 'NR==1{print $2}')
    info "当前版本: ${CURRENT_VER:-未知}"
    info "正在检查最新版本..."

    curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o /tmp/xray-install.sh
    bash /tmp/xray-install.sh install

    NEW_VER=$($XRAY_BIN -version 2>/dev/null | awk 'NR==1{print $2}')
    if [[ "$CURRENT_VER" == "$NEW_VER" ]]; then
        info "已是最新版本: ${NEW_VER}"
    else
        info "更新完成: ${CURRENT_VER:-未知} → ${NEW_VER:-未知}"
        restart_xray
    fi
}

# ============================================================
# 安装快捷命令
# ============================================================
install_shortcut() {
    local src target wrapper
    src=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
    target="/usr/local/bin/vless-manager"
    wrapper="/usr/local/bin/c"

    if [[ -n "$src" && -f "$src" ]]; then
        cp -f "$src" "$target"
        chmod +x "$target"

        cat > "$wrapper" <<'EOF'
#!/bin/bash
exec /usr/local/bin/vless-manager "$@"
EOF
        chmod +x "$wrapper"

        info "快捷命令已安装：vless-manager / c"
    else
        warn "当前脚本来源不可复制，跳过快捷命令安装"
    fi
}

# ============================================================
# CLI 模式（供 cron 调用）
# ============================================================
normalize_user_db
load_meta

if [[ "$1" == "--check-expire" ]]; then
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

        local XRAY_STATUS USER_COUNT MODE_STR
        XRAY_STATUS=$(systemctl is-active xray 2>/dev/null || echo inactive)
        USER_COUNT=$(get_total_users)
        MODE_STR="未配置"

        if has_reality && has_ws; then
            MODE_STR="Reality + WS+CF"
        elif has_reality; then
            MODE_STR="Reality"
        elif has_ws; then
            MODE_STR="WS+CF"
        fi

        echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║           VLESS 节点用户管理工具            ║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════╣${NC}"
        printf "${BLUE}║${NC} Xray: %-8b 模式: %-16s 用户: %-4s ${BLUE}║${NC}\n" \
            "$( [[ "$XRAY_STATUS" == "active" ]] && echo "${GREEN}运行中${NC}" || echo "${RED}停止${NC}" )" \
            "${MODE_STR}" "${USER_COUNT}"
        echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"

        echo -e " ${GREEN}1.${NC}  安装 Xray + 初始化配置"
        echo -e " ${GREEN}2.${NC}  切换协议（重新初始化）"
        echo -e " ${GREEN}3.${NC}  添加用户"
        echo -e " ${GREEN}4.${NC}  删除用户"
        echo -e " ${GREEN}5.${NC}  禁用用户"
        echo -e " ${GREEN}6.${NC}  启用用户"
        echo -e " ${GREEN}7.${NC}  重置到期时间"
        echo -e " ${GREEN}8.${NC}  查看所有用户"
        echo -e " ${GREEN}9.${NC}  检查到期用户"
        echo -e " ${GREEN}10.${NC} 查看节点信息"
        echo -e " ${GREEN}11.${NC} 设置自动到期检查（cron）"
        echo -e " ${GREEN}12.${NC} 更新 Xray"
        echo -e " ${GREEN}13.${NC} 网络优化（BBR / TCP / 测速）"
        echo -e " ${GREEN}15.${NC} 安装快捷命令（c）"
        echo -e " ${RED}14.${NC} 卸载 Xray"
        echo -e " ${RED}0.${NC}  退出"
        echo -e "${BLUE}──────────────────────────────────────────────${NC}"

        read -rp " 选择 [0-15]: " OPT

        case "$OPT" in
            1)  install_xray; init_config ;;
            2)  init_config ;;
            3)  add_user ;;
            4)  delete_user ;;
            5)  toggle_user disable ;;
            6)  toggle_user enable ;;
            7)  renew_user ;;
            8)  list_users ;;
            9)  check_expire ;;
            10) show_info ;;
            11) setup_cron ;;
            12) update_xray ;;
            13) optimize_menu ;;
            14) uninstall_xray ;;
            15) install_shortcut ;;
            0)  exit 0 ;;
            *)  warn "无效选项" ;;
        esac

        echo ""
        read -rp "按 Enter 继续..." _
    done
}

main_menu
