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

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
title() { echo -e "\n${CYAN}$1${NC}"; }

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
    curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o /tmp/xray-install.sh
    bash /tmp/xray-install.sh install
    [[ $? -ne 0 ]] && error "安装失败，请检查网络" && exit 1
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
    info "Xray 已完全卸载"
    exit 0
}

# ============================================================
# 生成密钥对
# ============================================================
gen_keypair() {
    local OUTPUT
    OUTPUT=$($XRAY_BIN x25519 2>/dev/null)
    PRIVATE_KEY=$(echo "$OUTPUT" | grep -i "PrivateKey\|Private" | awk '{print $NF}')
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
        read -rp "监听端口 [默认 8080]: " WS_PORT
        WS_PORT=${WS_PORT:-8080}
        check_port "$WS_PORT" && break || warn "端口 ${WS_PORT} 已被占用，请换一个"
    done

    read -rp "WS 路径 [默认 /ray]: " WS_PATH
    WS_PATH=${WS_PATH:-/ray}

    read -rp "你的域名（已在 CF 解析的域名）: " WS_DOMAIN
    [[ -z "$WS_DOMAIN" ]] && error "域名不能为空" && return

    cat > "$META_WS" <<EOF
WS_PORT=${WS_PORT}
WS_PATH=${WS_PATH}
WS_DOMAIN=${WS_DOMAIN}
EOF
    chmod 600 "$META_WS"

    rebuild_config
    _inject_all_users
    _start_xray
    info "WS+CF 节点配置完成"
    echo ""
    echo -e "${YELLOW}═══ Cloudflare 配置说明 ═══${NC}"
    echo -e "1. CF 域名解析：${WS_DOMAIN} → 本机 IP，开启橙云代理"
    echo -e "2. CF SSL 模式设为 ${GREEN}完全（Full）${NC}"
    echo -e "3. 客户端配置："
    echo -e "   地址   : ${WS_DOMAIN}"
    echo -e "   端口   : 443"
    echo -e "   WS路径 : ${WS_PATH}"
    echo -e "   TLS    : 开启"
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
        INBOUNDS="${INBOUNDS}
    {
      \"port\": ${WS_PORT},
      \"listen\": \"127.0.0.1\",
      \"protocol\": \"vless\",
      \"settings\": { \"clients\": [], \"decryption\": \"none\" },
      \"streamSettings\": {
        \"network\": \"ws\",
        \"security\": \"none\",
        \"wsSettings\": { \"path\": \"${WS_PATH}\" }
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
  "inbounds": [${INBOUNDS}
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
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
        local ENCODED_PATH
        ENCODED_PATH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${WS_PATH}'))")
        echo ""
        echo -e "${CYAN}── WS+CF 节点 ──${NC}"
        echo -e "域名   : ${WS_DOMAIN}"
        echo -e "端口   : 443"
        echo -e "WS路径 : ${WS_PATH}"
        echo -e "TLS    : 开启"
        local LINK="vless://${UUID}@${WS_DOMAIN}:443?encryption=none&security=tls&type=ws&path=${ENCODED_PATH}&host=${WS_DOMAIN}#${USERNAME}-ws"
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

    echo "到期方式："
    echo "  1. 输入天数（如 30）"
    echo "  2. 输入具体日期（如 2026-12-31）"
    read -rp "选择 [1/2，默认1]: " EXPIRE_MODE
    EXPIRE_MODE=${EXPIRE_MODE:-1}

    if [[ "$EXPIRE_MODE" == "2" ]]; then
        read -rp "到期日期 (YYYY-MM-DD): " EXPIRE
        if ! date -d "$EXPIRE" +%Y-%m-%d &>/dev/null; then
            error "日期格式错误"
            return
        fi
        EXPIRE=$(date -d "$EXPIRE" +%Y-%m-%d)
    else
        read -rp "到期天数 [默认 30 天]: " DAYS
        DAYS=${DAYS:-30}
        EXPIRE=$(date -d "+${DAYS} days" +%Y-%m-%d)
    fi

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

    echo "到期方式："
    echo "  1. 输入天数（如 30）"
    echo "  2. 输入具体日期（如 2026-12-31）"
    read -rp "选择 [1/2，默认1]: " EXPIRE_MODE
    EXPIRE_MODE=${EXPIRE_MODE:-1}

    if [[ "$EXPIRE_MODE" == "2" ]]; then
        read -rp "新到期日期 (YYYY-MM-DD): " NEW_EXPIRE
        if ! date -d "$NEW_EXPIRE" +%Y-%m-%d &>/dev/null; then
            error "日期格式错误"
            return
        fi
        NEW_EXPIRE=$(date -d "$NEW_EXPIRE" +%Y-%m-%d)
    else
        read -rp "续期天数 [默认 30 天]: " DAYS
        DAYS=${DAYS:-30}
        NEW_EXPIRE=$(date -d "+${DAYS} days" +%Y-%m-%d)
    fi

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
clients = cfg["inbounds"][0]["settings"]["clients"]
clients = [c for c in clients if c.get("id") not in expired]
cfg["inbounds"][0]["settings"]["clients"] = clients
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
    ACTIVE=$(grep -c ":active$" "$USER_DB" 2>/dev/null || echo 0)
    DISABLED=$(grep -c ":disabled$" "$USER_DB" 2>/dev/null || echo 0)
    echo -e "共 ${TOTAL} 个用户  ${GREEN}活跃: ${ACTIVE}${NC}  ${RED}禁用: ${DISABLED}${NC}"
    echo ""
    printf "%-15s %-38s %-12s %-10s\n" "用户名" "UUID" "到期日" "状态"
    echo "----------------------------------------------------------------------"
    while IFS=: read -r NAME UUID EXPIRE STATUS; do
        COLOR=$NC
        [[ "$STATUS" == "disabled" ]] && COLOR=$RED
        [[ "$STATUS" == "active" ]] && COLOR=$GREEN
        printf "${COLOR}%-15s %-38s %-12s %-10s${NC}\n" "$NAME" "$UUID" "$EXPIRE" "$STATUS"
    done < "$USER_DB"
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
# 查看节点信息
# ============================================================
show_info() {
    title "节点信息"
    load_meta
    local XRAY_STATUS USER_COUNT ACTIVE_COUNT
    XRAY_STATUS=$(systemctl is-active xray)
    USER_COUNT=0; [[ -f "$USER_DB" ]] && USER_COUNT=$(wc -l < "$USER_DB")
    ACTIVE_COUNT=0; [[ -f "$USER_DB" ]] && ACTIVE_COUNT=$(grep -c ":active$" "$USER_DB" 2>/dev/null || echo 0)

    echo -e "状态   : $( [[ "$XRAY_STATUS" == "active" ]] && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}已停止${NC}" )"
    echo -e "模式   : ${MODE}"
    echo -e "用户数 : 共 ${USER_COUNT} 个，活跃 ${ACTIVE_COUNT} 个"

    if [[ "$MODE" == "reality" ]]; then
        local SERVER_IP SHORTID
        SERVER_IP=$(curl -s4 --max-time 5 ip.sb 2>/dev/null || curl -s4 --max-time 5 ifconfig.me 2>/dev/null)
        SHORTID=$(python3 -c "import json; d=json.load(open('$XRAY_CONFIG')); print(d['inbounds'][0]['streamSettings']['realitySettings']['shortIds'][0])" 2>/dev/null)
        echo -e "IP     : ${SERVER_IP}"
        echo -e "端口   : ${PORT}"
        echo -e "公钥   : ${PUBLIC_KEY}"
        echo -e "SNI    : ${SNI}"
        echo -e "ShortID: ${SHORTID}"
        echo -e "协议   : VLESS+Reality+TCP"
    else
        echo -e "域名   : ${DOMAIN}"
        echo -e "端口   : 443（CF 侧）/ ${PORT}（本地监听）"
        echo -e "WS路径 : ${WS_PATH}"
        echo -e "协议   : VLESS+WS+TLS（CF CDN）"
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
# 安装快捷命令 c
# ============================================================
install_shortcut() {
    SCRIPT_URL="https://raw.githubusercontent.com/chenege-ck/vless-manager/main/vless.sh"
    cat > /usr/local/bin/c <<EOF
#!/bin/bash
bash <(curl -sL ${SCRIPT_URL})
EOF
    chmod +x /usr/local/bin/c
    info "快捷命令已安装，输入 c 即可进入面板"
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
        local XRAY_STATUS USER_COUNT MODE_STR
        XRAY_STATUS=$(systemctl is-active xray 2>/dev/null)
        USER_COUNT=0; [[ -f "$USER_DB" ]] && USER_COUNT=$(wc -l < "$USER_DB")
        [[ "$MODE" == "ws" ]] && MODE_STR="WS+CF" || MODE_STR="Reality"

        echo -e "${BLUE}╔══════════════════════════════════╗${NC}"
        echo -e "${BLUE}║     VLESS 节点用户管理工具       ║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════╣${NC}"
        printf "${BLUE}║${NC} Xray: %-8s 模式: %-8s 用户: %s\n" \
            "$( [[ "$XRAY_STATUS" == "active" ]] && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}停止${NC}" )" \
            "${MODE_STR}" "${USER_COUNT}"
        echo -e "${BLUE}╚══════════════════════════════════╝${NC}"
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
        echo -e " ${RED}12.${NC} 卸载 Xray"
        echo -e " ${RED}0.${NC}  退出"
        echo -e "${BLUE}──────────────────────────────────${NC}"
        read -rp " 选择 [0-12]: " OPT

        case $OPT in
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
            12) uninstall_xray ;;
            0)  exit 0 ;;
            *)  warn "无效选项" ;;
        esac

        echo ""
        read -rp "按 Enter 继续..." _
    done
}

# 每次运行自动安装快捷命令 c
install_shortcut

main_menu
