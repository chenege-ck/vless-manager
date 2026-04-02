#!/bin/bash
# VLESS 一键管理脚本 v4.0
# 支持：VLESS+Reality 和 VLESS+WS+CF 两种模式

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

XRAY_CONFIG="/usr/local/etc/xray/config.json"
USER_DB="/usr/local/etc/xray/users.db"
XRAY_BIN="/usr/local/bin/xray"
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
    title "初始化配置..."
    mkdir -p /usr/local/etc/xray
    touch "$USER_DB"

    echo ""
    echo "请选择协议模式："
    echo -e "  ${GREEN}1.${NC} VLESS + Reality（直连，抗封锁）"
    echo -e "  ${GREEN}2.${NC} VLESS + WS + CF（套 Cloudflare CDN）"
    echo ""
    read -rp "选择 [1/2]: " MODE
    case $MODE in
        1) init_reality ;;
        2) init_ws_cf ;;
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
        read -rp "监听端口 [默认 443]: " PORT
        PORT=${PORT:-443}
        check_port "$PORT" && break || warn "端口 ${PORT} 已被占用，请换一个"
    done

    read -rp "伪装域名 [默认 www.microsoft.com]: " SNI
    SNI=${SNI:-www.microsoft.com}
    SHORTID=$(openssl rand -hex 4)

    cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": ["${SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORTID}"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

    cat > "$META" <<EOF
MODE=reality
PUBLIC_KEY=${PUBLIC_KEY}
SNI=${SNI}
PORT=${PORT}
SHORTID=${SHORTID}
EOF

    _start_xray
    info "Reality 配置完成"
    info "公钥: ${PUBLIC_KEY}"
}

# ============================================================
# 初始化 WS+CF
# ============================================================
init_ws_cf() {
    while true; do
        read -rp "监听端口 [默认 8080]: " PORT
        PORT=${PORT:-8080}
        check_port "$PORT" && break || warn "端口 ${PORT} 已被占用，请换一个"
    done

    read -rp "WS 路径 [默认 /ray]: " WS_PATH
    WS_PATH=${WS_PATH:-/ray}

    read -rp "你的域名（已在 CF 解析的域名）: " DOMAIN
    [[ -z "$DOMAIN" ]] && error "域名不能为空" && return

    cat > "$XRAY_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": ${PORT},
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "${WS_PATH}"
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http","tls"] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

    cat > "$META" <<EOF
MODE=ws
PORT=${PORT}
WS_PATH=${WS_PATH}
DOMAIN=${DOMAIN}
EOF

    _start_xray
    info "WS+CF 配置完成"
    echo ""
    echo -e "${YELLOW}═══ Cloudflare 配置说明 ═══${NC}"
    echo -e "1. CF 域名解析：${DOMAIN} → 本机 IP，开启橙云代理"
    echo -e "2. CF SSL 模式设为 ${GREEN}弹性（Flexible）${NC} 或 ${GREEN}完全（Full）${NC}"
    echo -e "3. 客户端配置："
    echo -e "   地址   : ${DOMAIN}"
    echo -e "   端口   : 443"
    echo -e "   WS路径 : ${WS_PATH}"
    echo -e "   TLS    : 开启"
    echo ""
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
# 读取元数据
# ============================================================
load_meta() {
    [[ -f "$META" ]] && source "$META"
}

# ============================================================
# 注入用户到 config.json
# ============================================================
_inject_user() {
    local UUID=$1
    local NAME=$2
    local EXPIRE=$3
    load_meta

    python3 - <<PYEOF
import json
with open("$XRAY_CONFIG", "r") as f:
    cfg = json.load(f)
clients = cfg["inbounds"][0]["settings"]["clients"]
clients = [c for c in clients if c.get("id") != "$UUID"]
# Reality 模式必须设置 flow，WS 模式不需要
flow = "xtls-rprx-vision" if "$MODE" == "reality" else ""
clients.append({
    "id": "$UUID",
    "flow": flow,
    "email": "$NAME",
    "comment": "$EXPIRE"
})
cfg["inbounds"][0]["settings"]["clients"] = clients
with open("$XRAY_CONFIG", "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
}

# ============================================================
# 打印节点分享链接
# ============================================================
_print_link() {
    local USERNAME=$1
    local UUID=$2
    local EXPIRE=$3
    load_meta

    echo ""
    echo -e "${GREEN}===== 节点信息 =====${NC}"
    echo -e "用户名 : ${USERNAME}"
    echo -e "UUID   : ${UUID}"
    echo -e "到期   : ${EXPIRE}"
    echo -e "模式   : ${MODE}"

    if [[ "$MODE" == "reality" ]]; then
        local SERVER_IP
        SERVER_IP=$(curl -s4 --max-time 5 ip.sb 2>/dev/null || curl -s4 --max-time 5 ifconfig.me 2>/dev/null)
        local SHORTID
        SHORTID=$(python3 -c "import json; d=json.load(open('$XRAY_CONFIG')); print(d['inbounds'][0]['streamSettings']['realitySettings']['shortIds'][0])" 2>/dev/null)
        echo -e "地址   : ${SERVER_IP}"
        echo -e "端口   : ${PORT}"
        echo -e "公钥   : ${PUBLIC_KEY}"
        echo -e "SNI    : ${SNI}"
        echo -e "ShortID: ${SHORTID}"
        echo ""
        local LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORTID}&type=tcp&flow=xtls-rprx-vision#${USERNAME}"
        echo -e "${CYAN}分享链接:${NC}"
        echo "$LINK"
    else
        echo -e "域名   : ${DOMAIN}"
        echo -e "端口   : 443"
        echo -e "WS路径 : ${WS_PATH}"
        echo -e "TLS    : 开启"
        echo ""
        local ENCODED_PATH
        ENCODED_PATH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${WS_PATH}'))")
        local LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&path=${ENCODED_PATH}&host=${DOMAIN}#${USERNAME}"
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

    if grep -q "^${USERNAME}:" "$USER_DB" 2>/dev/null; then
        error "用户 ${USERNAME} 已存在"
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
    echo "${USERNAME}:${UUID}:${EXPIRE}:active" >> "$USER_DB"
    _inject_user "$UUID" "$USERNAME" "$EXPIRE"

    sleep 1
    systemctl restart xray
    if systemctl is-active --quiet xray; then
        _print_link "$USERNAME" "$UUID" "$EXPIRE"
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
    sed -i "/^${USERNAME}:/d" "$USER_DB"

    python3 - <<PYEOF
import json
with open("$XRAY_CONFIG", "r") as f:
    cfg = json.load(f)
clients = cfg["inbounds"][0]["settings"]["clients"]
clients = [c for c in clients if c.get("id") != "$UUID"]
cfg["inbounds"][0]["settings"]["clients"] = clients
with open("$XRAY_CONFIG", "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF

    systemctl restart xray
    info "用户 ${USERNAME} 已删除"
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

    if [[ "$ACTION" == "disable" ]]; then
        python3 - <<PYEOF
import json
with open("$XRAY_CONFIG", "r") as f:
    cfg = json.load(f)
clients = cfg["inbounds"][0]["settings"]["clients"]
clients = [c for c in clients if c.get("id") != "$UUID"]
cfg["inbounds"][0]["settings"]["clients"] = clients
with open("$XRAY_CONFIG", "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
        sed -i "s/^${USERNAME}:\(.*\):active$/${USERNAME}:\1:disabled/" "$USER_DB"
        info "用户 ${USERNAME} 已禁用"
    else
        EXPIRE=$(grep "^${USERNAME}:" "$USER_DB" | cut -d: -f3)
        _inject_user "$UUID" "$USERNAME" "$EXPIRE"
        sed -i "s/^${USERNAME}:\(.*\):disabled$/${USERNAME}:\1:active/" "$USER_DB"
        info "用户 ${USERNAME} 已启用"
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

    [[ ! -f "$USER_DB" ]] && info "暂无用户" && return

    while IFS=: read -r NAME UUID EXPIRE STATUS; do
        [[ "$STATUS" != "active" ]] && continue
        if [[ "$EXPIRE" < "$TODAY" ]]; then
            warn "用户 ${NAME} 已到期（${EXPIRE}），自动禁用"
            python3 - <<PYEOF
import json
with open("$XRAY_CONFIG", "r") as f:
    cfg = json.load(f)
clients = cfg["inbounds"][0]["settings"]["clients"]
clients = [c for c in clients if c.get("id") != "$UUID"]
cfg["inbounds"][0]["settings"]["clients"] = clients
with open("$XRAY_CONFIG", "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
            sed -i "s/^${NAME}:${UUID}:${EXPIRE}:active$/${NAME}:${UUID}:${EXPIRE}:disabled/" "$USER_DB"
            CHANGED=1
        fi
    done < "$USER_DB"

    [[ $CHANGED -eq 1 ]] && systemctl restart xray && info "已重启 Xray"
    [[ $CHANGED -eq 0 ]] && info "没有到期用户"
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
        echo -e " ${GREEN}2.${NC}  添加用户"
        echo -e " ${GREEN}3.${NC}  删除用户"
        echo -e " ${GREEN}4.${NC}  禁用用户"
        echo -e " ${GREEN}5.${NC}  启用用户"
        echo -e " ${GREEN}6.${NC}  重置到期时间"
        echo -e " ${GREEN}7.${NC}  查看所有用户"
        echo -e " ${GREEN}8.${NC}  检查到期用户"
        echo -e " ${GREEN}9.${NC}  查看节点信息"
        echo -e " ${GREEN}10.${NC} 设置自动到期检查（cron）"
        echo -e " ${RED}11.${NC} 卸载 Xray"
        echo -e " ${RED}0.${NC}  退出"
        echo -e "${BLUE}──────────────────────────────────${NC}"
        read -rp " 选择 [0-11]: " OPT

        case $OPT in
            1)  install_xray; init_config ;;
            2)  add_user ;;
            3)  delete_user ;;
            4)  toggle_user disable ;;
            5)  toggle_user enable ;;
            6)  renew_user ;;
            7)  list_users ;;
            8)  check_expire ;;
            9)  show_info ;;
            10) setup_cron ;;
            11) uninstall_xray ;;
            0)  exit 0 ;;
            *)  warn "无效选项" ;;
        esac

        echo ""
        read -rp "按 Enter 继续..." _
    done
}

main_menu
