#!/bin/bash
# VLESS 一键管理脚本 v5.0
# 支持：VLESS+Reality 和 VLESS+WS+CF 两种模式，可同时运行

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
# 兼容旧版单节点 meta.conf
META="/usr/local/etc/xray/meta.conf"

info()  { echo -e "${GREEN}  ✓${NC}  $1"; }
warn()  { echo -e "${YELLOW}  ⚠${NC}  $1"; }
error() { echo -e "${RED}  ✗${NC}  $1"; }
title() { echo -e "\n${BLUE}┌─${NC} ${CYAN}$1${NC}"; echo -e "${BLUE}└────────────────────────────${NC}"; }

[[ $EUID -ne 0 ]] && error "请用 root 运行此脚本" && exit 1

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
    apt-get install -y -qq curl unzip openssl python3
    info "依赖安装完成"
}

# ============================================================
# 安装 xray
# ============================================================
install_xray() {
    title "安装 Xray..."
    if [[ -f "$XRAY_BIN" ]]; then
        warn "Xray 已安装，跳过"
        return
    fi
    install_deps
    # 备份已有配置
    [[ -f "$XRAY_CONFIG" ]] && cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak"
    curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o /tmp/xray-install.sh
    bash /tmp/xray-install.sh install
    [[ $? -ne 0 ]] && error "安装失败，请检查网络" && exit 1
    # 恢复配置
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
    crontab -l 2>/dev/null | grep -v "check-expire" | grep -v "truncate.*xray" | crontab -
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
            rebuild_config; _inject_all_users; _start_xray
            info "Reality 节点已移除"
            ;;
        4)
            has_ws || { error "WS+CF 节点未启用"; return; }
            read -rp "确认移除 WS+CF 节点？[y/N]: " C
            [[ "$C" != "y" && "$C" != "Y" ]] && warn "已取消" && return
            rm -f "$META_WS"
            rebuild_config; _inject_all_users; _start_xray
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

    read -rp "伪装域名 [默认 www.microsoft.com]: " REALITY_SNI
    REALITY_SNI=${REALITY_SNI:-www.microsoft.com}
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

    # 自动生成自签证书
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
    echo -e "2. CF SSL 模式设为 ${GREEN}完全（Full）${NC}（不要用严格模式）"
    echo -e "3. 客户端配置："
    echo -e "   地址   : ${WS_DOMAIN}"
    echo -e "   端口   : ${WS_PORT}"
    echo -e "   WS路径 : ${WS_PATH}"
    echo -e "   TLS    : 开启"
    echo -e "   SNI    : ${WS_DOMAIN}"
    echo ""
}

# ============================================================
# 根据已有 meta 重建 config.json（支持双节点）
# ============================================================
rebuild_config() {
    local INBOUNDS=""

    if has_reality; then
        source "$META_REALITY"
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
        source "$META_WS"
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

    # 去掉最后一个逗号
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
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" },
  ]
}
EOF
}

# ============================================================
# 启动 xray
# ============================================================
_start_xray() {
    systemctl enable xray
    systemctl restart xray
    sleep 1
    if systemctl is-active --quiet xray; then
        info "Xray 已启动"
    else
        error "Xray 启动失败，运行 journalctl -u xray -n 20 查看日志"
    fi
}

# ============================================================
# 读取元数据（支持双节点）
# ============================================================
load_meta() {
    # 优先加载新版双节点配置
    [[ -f "$META_REALITY" ]] && source "$META_REALITY"
    [[ -f "$META_WS" ]] && source "$META_WS"
    # 兼容旧版单节点
    [[ ! -f "$META_REALITY" && ! -f "$META_WS" && -f "$META" ]] && source "$META"
}

# 检查哪些节点已启用
has_reality() { [[ -f "$META_REALITY" ]]; }
has_ws()      { [[ -f "$META_WS" ]]; }

# ============================================================
# 注入用户到 config.json（指定节点类型）
# ============================================================
_inject_user() {
    local UUID=$1
    local NAME=$2
    local EXPIRE=$3
    local NODE=$4   # reality | ws | both

    python3 - <<PYEOF
import json
with open("$XRAY_CONFIG", "r") as f:
    cfg = json.load(f)

node = "$NODE"
for inbound in cfg["inbounds"]:
    tag = inbound.get("tag", "")
    if "clients" not in inbound.get("settings", {}):
        continue
    clients = inbound["settings"]["clients"]
    clients = [c for c in clients if c.get("id") != "$UUID"]
    if node == "both" or (node == "reality" and tag == "inbound-reality") or (node == "ws" and tag == "inbound-ws"):
        flow = "xtls-rprx-vision" if tag == "inbound-reality" else ""
        clients.append({"id": "$UUID", "flow": flow, "email": "$NAME", "comment": "$EXPIRE"})
    inbound["settings"]["clients"] = clients

with open("$XRAY_CONFIG", "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
}

# 重建后将所有 active 用户按其节点类型重新注入
_inject_all_users() {
    [[ ! -f "$USER_DB" ]] && return
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

    echo ""
    echo -e "${GREEN}===== 节点信息 =====${NC}"
    echo -e "用户名 : ${USERNAME}"
    echo -e "UUID   : ${UUID}"
    echo -e "到期   : ${EXPIRE}"
    echo -e "节点   : ${NODE}"

    if [[ "$NODE" == "reality" || "$NODE" == "both" ]] && has_reality; then
        source "$META_REALITY"
        local SERVER_IP
        SERVER_IP=$(curl -s4 --max-time 5 ip.sb 2>/dev/null || curl -s4 --max-time 5 ifconfig.me 2>/dev/null)
        local SHORTID
        SHORTID=$(python3 -c "import json; d=json.load(open('$XRAY_CONFIG')); [print(i['streamSettings']['realitySettings']['shortIds'][0]) for i in d['inbounds'] if i.get('tag')=='inbound-reality']" 2>/dev/null)
        echo ""
        echo -e "${CYAN}── Reality 节点 ──${NC}"
        echo -e "地址   : ${SERVER_IP}"
        echo -e "端口   : ${REALITY_PORT}"
        echo -e "公钥   : ${REALITY_PUBLIC_KEY}"
        echo -e "SNI    : ${REALITY_SNI}"
        echo -e "ShortID: ${SHORTID}"
        local LINK="vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${SHORTID}&type=tcp&flow=xtls-rprx-vision#${USERNAME}-reality"
        echo -e "${CYAN}分享链接:${NC}"
        echo "$LINK"
    fi

    if [[ "$NODE" == "ws" || "$NODE" == "both" ]] && has_ws; then
        source "$META_WS"
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
        echo -e "TLS    : $( [[ "$WS_TLS" == "tls" ]] && echo "开启" || echo "关闭" )"
        echo -e "SNI    : ${WS_DOMAIN}"
        local LINK="vless://${UUID}@${WS_DOMAIN}:${WS_CF_PORT}/?type=ws&encryption=none&flow=&host=${WS_DOMAIN}&path=${ENCODED_PATH}&security=${WS_TLS}&sni=${WS_DOMAIN}#${ENCODED_NAME}"
        echo -e "${CYAN}分享链接:${NC}"
        echo "$LINK"
    fi
    echo ""
}

# ============================================================
# 添加用户
# ============================================================
add_user() {
    title "添加用户"
    load_meta

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

    # 节点选择
    local NODE="both"
    if has_reality && has_ws; then
        echo ""
        echo "请选择加入的节点："
        echo -e "  ${GREEN}1.${NC} 两个节点都加入"
        echo -e "  ${GREEN}2.${NC} 仅 Reality"
        echo -e "  ${GREEN}3.${NC} 仅 WS+CF"
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
    EXPIRE=$(date -d "+${DAYS} days" +%Y-%m-%d)

    UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "${USERNAME}:${UUID}:${EXPIRE}:active:${NODE}" >> "$USER_DB"
    _inject_user "$UUID" "$USERNAME" "$EXPIRE" "$NODE"

    sleep 1
    systemctl restart xray
    if systemctl is-active --quiet xray; then
        _print_link "$USERNAME" "$UUID" "$EXPIRE" "$NODE"
    else
        error "Xray 重启失败，请检查配置"
    fi
}

# ============================================================
# 删除用户
# ============================================================
delete_user() {
    title "删除用户"
    list_users_brief

    read -rp "输入要删除的用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return

    if ! grep -q "^${USERNAME}:" "$USER_DB" 2>/dev/null; then
        error "用户不存在"
        return
    fi

    UUID=$(grep "^${USERNAME}:" "$USER_DB" | cut -d: -f2)
    local USER_NODE
    USER_NODE=$(grep "^${USERNAME}:" "$USER_DB" | cut -d: -f5)
    USER_NODE=${USER_NODE:-both}

    # 选择删除哪个节点
    local DEL_NODE="both"
    if has_reality && has_ws && [[ "$USER_NODE" == "both" ]]; then
        echo ""
        echo "删除哪个节点的权限？"
        echo -e "  ${GREEN}1.${NC} 两个节点都删除（彻底删除用户）"
        echo -e "  ${GREEN}2.${NC} 仅删除 Reality 权限"
        echo -e "  ${GREEN}3.${NC} 仅删除 WS+CF 权限"
        read -rp "选择 [1/2/3，默认1]: " DEL_SEL
        case ${DEL_SEL:-1} in
            2) DEL_NODE="reality" ;;
            3) DEL_NODE="ws" ;;
            *) DEL_NODE="both" ;;
        esac
    fi

    # 从对应节点移除
    python3 - <<PYEOF
import json
del_node = "$DEL_NODE"
with open("$XRAY_CONFIG", "r") as f:
    cfg = json.load(f)
for inbound in cfg["inbounds"]:
    tag = inbound.get("tag", "")
    if "clients" not in inbound.get("settings", {}):
        continue
    if del_node == "both" or (del_node == "reality" and tag == "inbound-reality") or (del_node == "ws" and tag == "inbound-ws"):
        clients = inbound["settings"]["clients"]
        inbound["settings"]["clients"] = [c for c in clients if c.get("id") != "$UUID"]
with open("$XRAY_CONFIG", "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF

    if [[ "$DEL_NODE" == "both" ]]; then
        # 彻底删除用户
        sed -i "/^${USERNAME}:/d" "$USER_DB"
        info "用户 ${USERNAME} 已彻底删除"
    else
        # 只更新节点字段，保留用户记录
        local NEW_NODE
        if [[ "$DEL_NODE" == "reality" ]]; then
            NEW_NODE="ws"
        else
            NEW_NODE="reality"
        fi
        sed -i "s/^${USERNAME}:\(.*\):[^:]*$/${USERNAME}:\1:${NEW_NODE}/" "$USER_DB"
        info "用户 ${USERNAME} 的 ${DEL_NODE} 节点权限已移除，保留 ${NEW_NODE} 节点"
    fi

    systemctl restart xray
}

# ============================================================
# 重置到期时间
# ============================================================
renew_user() {
    title "重置到期时间"
    list_users_brief

    read -rp "输入用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return

    if ! grep -q "^${USERNAME}:" "$USER_DB" 2>/dev/null; then
        error "用户不存在"
        return
    fi

    read -rp "续期天数 [默认 30 天]: " DAYS
    DAYS=${DAYS:-30}
    NEW_EXPIRE=$(date -d "+${DAYS} days" +%Y-%m-%d)

    UUID=$(grep "^${USERNAME}:" "$USER_DB" | cut -d: -f2)
    sed -i "s/^${USERNAME}:${UUID}:.*$/${USERNAME}:${UUID}:${NEW_EXPIRE}:active/" "$USER_DB"
    _inject_user "$UUID" "$USERNAME" "$NEW_EXPIRE"
    systemctl restart xray
    info "用户 ${USERNAME} 到期时间已更新为 ${NEW_EXPIRE}"
}

# ============================================================
# 禁用 / 启用用户
# ============================================================
toggle_user() {
    local ACTION=$1
    title "${ACTION} 用户"
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

    # 选择操作哪个节点
    local OP_NODE="both"
    if has_reality && has_ws && [[ "$USER_NODE" == "both" ]]; then
        echo ""
        echo "操作哪个节点？"
        echo -e "  ${GREEN}1.${NC} 两个节点"
        echo -e "  ${GREEN}2.${NC} 仅 Reality"
        echo -e "  ${GREEN}3.${NC} 仅 WS+CF"
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
with open("$XRAY_CONFIG", "r") as f:
    cfg = json.load(f)
for inbound in cfg["inbounds"]:
    tag = inbound.get("tag", "")
    if "clients" not in inbound.get("settings", {}):
        continue
    if op_node == "both" or (op_node == "reality" and tag == "inbound-reality") or (op_node == "ws" and tag == "inbound-ws"):
        clients = inbound["settings"]["clients"]
        inbound["settings"]["clients"] = [c for c in clients if c.get("id") != "$UUID"]
with open("$XRAY_CONFIG", "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
        sed -i "s/^${USERNAME}:\(.*\):active:\(.*\)$/${USERNAME}:\1:disabled:\2/" "$USER_DB"
        sed -i "s/^${USERNAME}:\(.*\):active$/${USERNAME}:\1:disabled/" "$USER_DB"
        info "用户 ${USERNAME} 已禁用（节点: ${OP_NODE}）"
    else
        local EXPIRE
        EXPIRE=$(grep "^${USERNAME}:" "$USER_DB" | cut -d: -f3)
        _inject_user "$UUID" "$USERNAME" "$EXPIRE" "$OP_NODE"
        sed -i "s/^${USERNAME}:\(.*\):disabled:\(.*\)$/${USERNAME}:\1:active:\2/" "$USER_DB"
        sed -i "s/^${USERNAME}:\(.*\):disabled$/${USERNAME}:\1:active/" "$USER_DB"
        info "用户 ${USERNAME} 已启用（节点: ${OP_NODE}）"
    fi

    systemctl restart xray
}

# ============================================================
# 到期检查
# ============================================================
check_expire() {
    title "检查到期用户..."
    TODAY=$(date +%Y-%m-%d)
    CHANGED=0
    EXPIRED_UUIDS=""

    [[ ! -f "$USER_DB" ]] && info "暂无用户" && return

    # 第一步：找出所有到期用户，更新 users.db
    while IFS=: read -r NAME UUID EXPIRE STATUS; do
        [[ "$STATUS" != "active" ]] && continue
        if [[ "$EXPIRE" < "$TODAY" ]]; then
            warn "用户 ${NAME} 已到期（${EXPIRE}），自动禁用"
            sed -i "s/^${NAME}:${UUID}:${EXPIRE}:active$/${NAME}:${UUID}:${EXPIRE}:disabled/" "$USER_DB"
            EXPIRED_UUIDS="${EXPIRED_UUIDS} ${UUID}"
            CHANGED=1
        fi
    done < "$USER_DB"

    # 第二步：一次性从 config.json 移除所有到期用户
    if [[ $CHANGED -eq 1 ]]; then
        python3 - <<PYEOF
import json
expired = "$EXPIRED_UUIDS".split()
with open("$XRAY_CONFIG", "r") as f:
    cfg = json.load(f)
for inbound in cfg["inbounds"]:
    if "clients" not in inbound.get("settings", {}):
        continue
    clients = inbound["settings"]["clients"]
    inbound["settings"]["clients"] = [c for c in clients if c.get("id") not in expired]
with open("$XRAY_CONFIG", "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
        systemctl restart xray
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
    [[ ! -s "$USER_DB" ]] && warn "暂无用户" && return

    local TOTAL ACTIVE DISABLED
    TOTAL=$(wc -l < "$USER_DB")
    ACTIVE=$(grep -c ":active" "$USER_DB" 2>/dev/null || echo 0)
    DISABLED=$((TOTAL - ACTIVE))
    echo -e "  总计 ${CYAN}${TOTAL}${NC} 个  ${GREEN}活跃 ${ACTIVE}${NC}  ${RED}禁用 ${DISABLED}${NC}\n"
    echo -e "  ${YELLOW}%-15s %-38s %-12s %-8s %-8s${NC}" "用户名" "UUID" "到期日" "状态" "节点"
    echo -e "  ──────────────────────────────────────────────────────────────────────────────────"
    while IFS=: read -r NAME UUID EXPIRE STATUS NODE; do
        NODE=${NODE:-both}
        local COLOR=$NC
        local STATUS_ICON="○"
        if [[ "$STATUS" == "active" ]]; then
            COLOR=$GREEN; STATUS_ICON="●"
        elif [[ "$STATUS" == "disabled" ]]; then
            COLOR=$RED; STATUS_ICON="○"
        fi
        printf "  ${COLOR}%-15s %-38s %-12s %-8s %-8s${NC}\n" \
            "$NAME" "$UUID" "$EXPIRE" "${STATUS_ICON} ${STATUS}" "$NODE"
    done < "$USER_DB"
    echo ""
}

list_users_brief() {
    echo ""
    [[ ! -s "$USER_DB" ]] && echo "  （暂无用户）" && echo "" && return
    while IFS=: read -r NAME UUID EXPIRE STATUS; do
        printf "  %-15s %s  [%s]\n" "$NAME" "$EXPIRE" "$STATUS"
    done < "$USER_DB"
    echo ""
}


# ============================================================
# 节点连通性检测
# ============================================================
check_nodes() {
    title "节点连通性检测"
    load_meta
    echo ""

    if has_reality; then
        source "$META_REALITY"
        echo -ne "  检测 Reality 节点 (${REALITY_PORT})... "
        if ss -tlnp | grep -q ":${REALITY_PORT} "; then
            echo -e "${GREEN}● 端口监听正常${NC}"
        else
            echo -e "${RED}● 端口未监听${NC}"
        fi
        # 测试伪装域名是否可达
        echo -ne "  检测伪装域名 (${REALITY_SNI})... "
        if curl -sk --max-time 5 "https://${REALITY_SNI}" -o /dev/null; then
            echo -e "${GREEN}● 可达${NC}"
        else
            echo -e "${YELLOW}● 不可达（可能影响伪装）${NC}"
        fi
    fi

    if has_ws; then
        source "$META_WS"
        echo -ne "  检测 WS 节点 (${WS_PORT})... "
        if ss -tlnp | grep -q ":${WS_PORT} "; then
            echo -e "${GREEN}● 端口监听正常${NC}"
        else
            echo -e "${RED}● 端口未监听${NC}"
        fi
        # 测试 TLS 握手
        echo -ne "  检测 TLS 证书... "
        local CERT_RESULT
        CERT_RESULT=$(echo | openssl s_client -connect "127.0.0.1:${WS_PORT}" \
            -servername "${WS_DOMAIN}" 2>/dev/null | grep "Verify return code")
        if [[ -n "$CERT_RESULT" ]]; then
            echo -e "${GREEN}● TLS 握手成功${NC}"
        else
            echo -e "${RED}● TLS 握手失败${NC}"
        fi
        # 测试域名解析
        echo -ne "  检测域名解析 (${WS_DOMAIN})... "
        local DOMAIN_IP
        DOMAIN_IP=$(curl -s --max-time 5 "https://1.1.1.1/dns-query?name=${WS_DOMAIN}&type=A" \
            -H "accept: application/dns-json" 2>/dev/null | \
            python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Answer'][0]['data'])" 2>/dev/null)
        if [[ -n "$DOMAIN_IP" ]]; then
            echo -e "${GREEN}● 解析到 ${DOMAIN_IP}${NC}"
        else
            echo -e "${RED}● 域名解析失败${NC}"
        fi
    fi

    echo ""
    echo -ne "  检测 Xray 进程... "
    if systemctl is-active --quiet xray; then
        local PID
        PID=$(systemctl show xray --property=MainPID | cut -d= -f2)
        echo -e "${GREEN}● 运行中 (PID: ${PID})${NC}"
    else
        echo -e "${RED}● 未运行${NC}"
    fi
    echo ""
}

# ============================================================
# 查看用户分享链接
# ============================================================
show_user_link() {
    title "查看用户分享链接"
    list_users_brief

    read -rp "输入用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return

    if ! grep -q "^${USERNAME}:" "$USER_DB" 2>/dev/null; then
        error "用户不存在"
        return
    fi

    local UUID EXPIRE NODE
    UUID=$(grep "^${USERNAME}:" "$USER_DB" | cut -d: -f2)
    EXPIRE=$(grep "^${USERNAME}:" "$USER_DB" | cut -d: -f3)
    NODE=$(grep "^${USERNAME}:" "$USER_DB" | cut -d: -f5)
    NODE=${NODE:-both}

    _print_link "$USERNAME" "$UUID" "$EXPIRE" "$NODE"
}

# ============================================================
# ============================================================
show_info() {
    title "节点信息"
    load_meta
    local XRAY_STATUS USER_COUNT ACTIVE_COUNT
    XRAY_STATUS=$(systemctl is-active xray)
    USER_COUNT=0; [[ -f "$USER_DB" ]] && USER_COUNT=$(wc -l < "$USER_DB")
    ACTIVE_COUNT=0; [[ -f "$USER_DB" ]] && ACTIVE_COUNT=$(grep -c ":active" "$USER_DB" 2>/dev/null || echo 0)

    echo -e "状态   : $( [[ "$XRAY_STATUS" == "active" ]] && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}已停止${NC}" )"
    echo -e "用户数 : 共 ${USER_COUNT} 个，活跃 ${ACTIVE_COUNT} 个"
    echo ""

    if has_reality; then
        source "$META_REALITY"
        local SERVER_IP SHORTID
        SERVER_IP=$(curl -s4 --max-time 5 ip.sb 2>/dev/null || curl -s4 --max-time 5 ifconfig.me 2>/dev/null)
        SHORTID=$(python3 -c "import json; d=json.load(open('$XRAY_CONFIG')); [print(i['streamSettings']['realitySettings']['shortIds'][0]) for i in d['inbounds'] if i.get('tag')=='inbound-reality']" 2>/dev/null)
        echo -e "${CYAN}── Reality 节点 ──${NC}"
        echo -e "IP     : ${SERVER_IP}"
        echo -e "端口   : ${REALITY_PORT}"
        echo -e "公钥   : ${REALITY_PUBLIC_KEY}"
        echo -e "SNI    : ${REALITY_SNI}"
        echo -e "ShortID: ${SHORTID}"
        echo -e "协议   : VLESS+Reality+TCP"
        echo ""
    fi

    if has_ws; then
        source "$META_WS"
        echo -e "${CYAN}── WS+CF 节点 ──${NC}"
        echo -e "域名   : ${WS_DOMAIN}"
        echo -e "端口   : ${WS_PORT}"
        echo -e "WS路径 : ${WS_PATH}"
        echo -e "TLS    : 开启（自签证书）"
        echo -e "协议   : VLESS+WS+TLS"
        echo ""
    fi

    if ! has_reality && ! has_ws; then
        warn "尚未配置任何节点，请选择菜单 1 或 2 初始化"
    fi
}

# ============================================================
# 设置 cron
# ============================================================
setup_cron() {
    SCRIPT_URL="https://raw.githubusercontent.com/chenege-ck/vless-manager/main/vless.sh"
    EXPIRE_CMD="0 1 * * * bash <(curl -sL ${SCRIPT_URL}) --check-expire >> /var/log/xray-expire.log 2>&1"
    LOG_CMD="0 3 * * 0 truncate -s 0 /var/log/xray/access.log /var/log/xray/error.log"
    (crontab -l 2>/dev/null | grep -v "check-expire" | grep -v "truncate.*xray"; echo "$EXPIRE_CMD"; echo "$LOG_CMD") | crontab -
    info "已设置每日 01:00 自动检查到期用户"
    info "已设置每周日 03:00 自动清理日志"

    # 配置 logrotate 自动轮转 xray-expire.log
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
    # 同时配置 xray 自身日志轮转
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
# 开启 BBR
# ============================================================
enable_bbr() {
    title "开启 BBR 拥塞控制..."

    # 检查内核是否支持 BBR
    if ! modinfo tcp_bbr &>/dev/null; then
        error "当前内核不支持 BBR，请升级内核（建议 4.9+）"
        return
    fi

    # 已经是 BBR 就跳过
    local CURRENT_CC
    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$CURRENT_CC" == "bbr" ]]; then
        info "BBR 已经是开启状态，无需重复设置"
        return
    fi

    # 加载模块
    modprobe tcp_bbr 2>/dev/null

    # 写入 sysctl 持久化
    cat >> /etc/sysctl.conf <<EOF

# BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    sysctl -p &>/dev/null
    local NEW_CC
    NEW_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$NEW_CC" == "bbr" ]]; then
        info "BBR 开启成功！"
    else
        error "BBR 开启失败，请手动检查内核版本"
    fi
}

# ============================================================
# TCP 智能优化（根据网络测试结果动态调整）
# ============================================================
optimize_tcp() {
    title "TCP 参数优化"
    echo ""
    echo -e "  请选择服务器所在区域："
    echo -e "  ${GREEN}1.${NC} 亚太低延迟（日本/香港/新加坡 → 国内，延迟 50-150ms）"
    echo -e "  ${GREEN}2.${NC} 美国高延迟（美西/美东 → 国内，延迟 150ms+）"
    echo -e "  ${GREEN}0.${NC} 返回"
    echo ""
    read -rp "选择: " SEL

    # 避免重复写入
    if grep -q "VLESS TCP优化" /etc/sysctl.conf 2>/dev/null; then
        warn "检测到已有 TCP 优化配置，先清除旧配置..."
        sed -i '/# VLESS TCP优化/,/^$/d' /etc/sysctl.conf
    fi

    case $SEL in
        1)
            cat >> /etc/sysctl.conf <<EOF

# VLESS TCP优化 - 亚太低延迟策略
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
EOF
            modprobe tcp_bbr 2>/dev/null
            sysctl -p &>/dev/null
            info "亚太低延迟 TCP 优化完成"
            ;;
        2)
            cat >> /etc/sysctl.conf <<EOF

# VLESS TCP优化 - 美国高延迟策略
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 8192
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.ip_local_port_range = 1024 65535
EOF
            modprobe tcp_bbr 2>/dev/null
            sysctl -p &>/dev/null
            info "美国高延迟 TCP 优化完成"
            ;;
        0) return ;;
        *) warn "无效选项" ;;
    esac
}


# ============================================================
# 一键优化菜单
# ============================================================
optimize_menu() {
    title "网络优化"
    echo ""
    echo -e "  ${GREEN}1.${NC} 开启 BBR（推荐，提升吞吐量）"
    echo -e "  ${GREEN}2.${NC} TCP 参数优化（选择区域策略）"
    echo -e "  ${GREEN}3.${NC} 一键全部优化（BBR + TCP）"
    echo -e "  ${GREEN}0.${NC} 返回"
    echo ""
    read -rp "选择: " OPT
    case $OPT in
        1) enable_bbr ;;
        2) optimize_tcp ;;
        3) enable_bbr; optimize_tcp ;;
        0) return ;;
        *) warn "无效选项" ;;
    esac
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
    # 备份配置
    [[ -f "$XRAY_CONFIG" ]] && cp "$XRAY_CONFIG" "${XRAY_CONFIG}.bak"
    curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o /tmp/xray-install.sh
    bash /tmp/xray-install.sh install
    # 恢复配置
    [[ -f "${XRAY_CONFIG}.bak" ]] && mv "${XRAY_CONFIG}.bak" "$XRAY_CONFIG" && info "已恢复原配置"
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
    # 验证脚本完整性
    if ! bash -n "$TMP_SCRIPT" 2>/dev/null; then
        error "脚本语法错误，取消更新"
        rm -f "$TMP_SCRIPT"
        return
    fi
    # 替换快捷命令
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
    local SCRIPT_URL="https://raw.githubusercontent.com/chenege-ck/vless-manager/main/vless.sh"
    # 首次或脚本不存在时下载到本地
    if [[ ! -f /usr/local/bin/vless_script.sh ]]; then
        curl -sL "$SCRIPT_URL" -o /usr/local/bin/vless_script.sh 2>/dev/null
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
    check_expire
    exit 0
fi

# ============================================================
# 主菜单
# ============================================================
main_menu() {
    while true; do
        clear
        load_meta
        local XRAY_STATUS USER_COUNT
        XRAY_STATUS=$(systemctl is-active xray 2>/dev/null)
        USER_COUNT=0; [[ -f "$USER_DB" ]] && USER_COUNT=$(wc -l < "$USER_DB")
        local ACTIVE_COUNT=0
        [[ -f "$USER_DB" ]] && ACTIVE_COUNT=$(grep -c ":active" "$USER_DB" 2>/dev/null || echo 0)
        local MODE_STR=""
        has_reality && MODE_STR="Reality"
        has_ws && MODE_STR="${MODE_STR:+$MODE_STR+}WS"
        [[ -z "$MODE_STR" ]] && MODE_STR="未配置"

        local STATUS_COLOR=$RED
        local STATUS_TEXT="● 已停止"
        [[ "$XRAY_STATUS" == "active" ]] && STATUS_COLOR=$GREEN && STATUS_TEXT="● 运行中"

        echo -e "${BLUE}╔════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║${NC}    ${CYAN}VLESS 节点管理工具  v5.0${NC}       ${BLUE}║${NC}"
        echo -e "${BLUE}╠════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  状态 ${STATUS_COLOR}${STATUS_TEXT}${NC}  模式 ${YELLOW}${MODE_STR}${NC}"
        echo -e "${BLUE}║${NC}  用户 ${GREEN}${ACTIVE_COUNT}${NC} 活跃 / ${USER_COUNT} 总计"
        echo -e "${BLUE}╠════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}节点管理${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}1.${NC}  安装 Xray + 配置节点"
        echo -e "${BLUE}║${NC}   ${GREEN}2.${NC}  添加/移除节点"
        echo -e "${BLUE}║${NC}   ${GREEN}3.${NC}  节点连通性检测"
        echo -e "${BLUE}╠════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}用户管理${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}4.${NC}  添加用户"
        echo -e "${BLUE}║${NC}   ${GREEN}5.${NC}  删除用户"
        echo -e "${BLUE}║${NC}   ${GREEN}6.${NC}  禁用用户"
        echo -e "${BLUE}║${NC}   ${GREEN}7.${NC}  启用用户"
        echo -e "${BLUE}║${NC}   ${GREEN}8.${NC}  重置到期时间"
        echo -e "${BLUE}║${NC}   ${GREEN}9.${NC}  查看所有用户"
        echo -e "${BLUE}║${NC}   ${GREEN}10.${NC} 查看用户分享链接"
        echo -e "${BLUE}╠════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}系统工具${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}12.${NC} 检查到期用户"
        echo -e "${BLUE}║${NC}   ${GREEN}13.${NC} 查看节点信息"
        echo -e "${BLUE}║${NC}   ${GREEN}14.${NC} 设置自动到期检查"
        echo -e "${BLUE}║${NC}   ${GREEN}15.${NC} 更新 Xray"
        echo -e "${BLUE}║${NC}   ${GREEN}16.${NC} 更新管理脚本"
        echo -e "${BLUE}║${NC}   ${GREEN}17.${NC} 网络优化（BBR/TCP）"
        echo -e "${BLUE}╠════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}   ${RED}18.${NC} 卸载 Xray"
        echo -e "${BLUE}║${NC}   ${RED}0.${NC}  退出"
        echo -e "${BLUE}╚════════════════════════════════════╝${NC}"
        echo -ne " 请选择 » "
        read -r OPT

        case $OPT in
            1)  install_xray; init_config ;;
            2)  init_config ;;
            3)  check_nodes ;;
            4)  add_user ;;
            5)  delete_user ;;
            6)  toggle_user disable ;;
            7)  toggle_user enable ;;
            8)  renew_user ;;
            9)  list_users ;;
            10) show_user_link ;;
            12) check_expire ;;
            13) show_info ;;
            14) setup_cron ;;
            15) update_xray ;;
            16) update_script ;;
            17) optimize_menu ;;
            18) uninstall_xray ;;
            0)  echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *)  warn "无效选项，请重新选择" ;;
        esac

        echo ""
        echo -ne "${BLUE}按 Enter 返回菜单...${NC}"
        read -r _
    done
}

# 每次运行自动安装快捷命令 c
install_shortcut

main_menu
