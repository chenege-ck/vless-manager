#!/bin/bash
# VLESS+Reality 一键管理脚本
# 支持：安装xray、添加用户、删除用户、到期禁用、查看节点信息

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

XRAY_CONFIG="/usr/local/etc/xray/config.json"
USER_DB="/usr/local/etc/xray/users.db"
XRAY_BIN="/usr/local/bin/xray"

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }
title() { echo -e "\n${CYAN}$1${NC}"; }

# ============================================================
# 检查 root
# ============================================================
[[ $EUID -ne 0 ]] && error "请用 root 运行此脚本" && exit 1

# ============================================================
# 安装 xray
# ============================================================
install_xray() {
    title "安装 Xray..."
    if [[ -f "$XRAY_BIN" ]]; then
        warn "Xray 已安装，跳过"
        return
    fi
    apt-get update -qq
    apt-get install -y -qq unzip curl
    curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o /tmp/xray-install.sh
    bash /tmp/xray-install.sh install
    [[ $? -ne 0 ]] && error "安装失败，请检查网络" && exit 1
    info "Xray 安装成功"
}

# ============================================================
# 生成初始配置（Reality）
# ============================================================
init_config() {
    title "初始化配置..."

    mkdir -p /usr/local/etc/xray
    touch "$USER_DB"

    # 生成 Reality 密钥对
    PRIVATE_KEY=$($XRAY_BIN x25519 | grep "Private" | awk '{print $3}')
    PUBLIC_KEY=$($XRAY_BIN x25519 -i "$PRIVATE_KEY" | grep "Public" | awk '{print $3}')

    read -rp "监听端口 [默认 443]: " PORT
    PORT=${PORT:-443}

    read -rp "伪装域名 [默认 www.microsoft.com]: " SNI
    SNI=${SNI:-www.microsoft.com}

    # 写入配置
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
          "shortIds": ["$(openssl rand -hex 4)"]
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

    # 保存公钥和配置元数据
    echo "PUBLIC_KEY=${PUBLIC_KEY}" > /usr/local/etc/xray/meta.conf
    echo "SNI=${SNI}" >> /usr/local/etc/xray/meta.conf
    echo "PORT=${PORT}" >> /usr/local/etc/xray/meta.conf

    systemctl enable xray
    systemctl restart xray
    info "配置完成，Xray 已启动"
    info "公钥: ${PUBLIC_KEY}"
}

# ============================================================
# 读取元数据
# ============================================================
load_meta() {
    [[ -f /usr/local/etc/xray/meta.conf ]] && source /usr/local/etc/xray/meta.conf
}

# ============================================================
# 添加用户
# ============================================================
add_user() {
    title "添加用户"
    load_meta

    read -rp "用户名（备注用）: " USERNAME
    [[ -z "$USERNAME" ]] && error "用户名不能为空" && return

    # 检查重复
    if grep -q "^${USERNAME}:" "$USER_DB" 2>/dev/null; then
        error "用户 ${USERNAME} 已存在"
        return
    fi

    read -rp "到期天数 [默认 30 天]: " DAYS
    DAYS=${DAYS:-30}
    EXPIRE=$(date -d "+${DAYS} days" +%Y-%m-%d)

    UUID=$(cat /proc/sys/kernel/random/uuid)

    # 写入 users.db
    echo "${USERNAME}:${UUID}:${EXPIRE}:active" >> "$USER_DB"

    # 注入到 xray config
    _inject_user "$UUID" "$USERNAME" "$EXPIRE"

    systemctl restart xray

    # 输出节点信息
    SERVER_IP=$(curl -s4 ip.sb || curl -s4 ifconfig.me)
    SHORTID=$(python3 -c "import json; d=json.load(open('$XRAY_CONFIG')); print(d['inbounds'][0]['streamSettings']['realitySettings']['shortIds'][0])" 2>/dev/null)

    echo ""
    echo -e "${GREEN}===== 节点信息 =====${NC}"
    echo -e "用户名 : ${USERNAME}"
    echo -e "UUID   : ${UUID}"
    echo -e "到期   : ${EXPIRE}"
    echo -e "地址   : ${SERVER_IP}"
    echo -e "端口   : ${PORT}"
    echo -e "公钥   : ${PUBLIC_KEY}"
    echo -e "SNI    : ${SNI}"
    echo -e "ShortID: ${SHORTID}"
    echo ""
    LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORTID}&type=tcp&flow=xtls-rprx-vision#${USERNAME}"
    echo -e "${CYAN}分享链接:${NC}"
    echo "$LINK"
    echo ""
}

# ============================================================
# 注入用户到 config.json
# ============================================================
_inject_user() {
    local UUID=$1
    local NAME=$2
    local EXPIRE=$3

    python3 - <<PYEOF
import json, datetime

with open("$XRAY_CONFIG", "r") as f:
    cfg = json.load(f)

clients = cfg["inbounds"][0]["settings"]["clients"]

# 移除同 UUID（防重复）
clients = [c for c in clients if c.get("id") != "$UUID"]

clients.append({
    "id": "$UUID",
    "flow": "xtls-rprx-vision",
    "email": "$NAME",
    "comment": "$EXPIRE"
})

cfg["inbounds"][0]["settings"]["clients"] = clients

with open("$XRAY_CONFIG", "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
}

# ============================================================
# 删除用户
# ============================================================
delete_user() {
    title "删除用户"
    list_users_brief

    read -rp "输入要删除的用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return

    if ! grep -q "^${USERNAME}:" "$USER_DB"; then
        error "用户不存在"
        return
    fi

    UUID=$(grep "^${USERNAME}:" "$USER_DB" | cut -d: -f2)

    # 从 db 删除
    sed -i "/^${USERNAME}:/d" "$USER_DB"

    # 从 config 删除
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
# 禁用 / 启用用户
# ============================================================
toggle_user() {
    local ACTION=$1  # disable | enable
    title "${ACTION} 用户"
    list_users_brief

    read -rp "输入用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return

    if ! grep -q "^${USERNAME}:" "$USER_DB"; then
        error "用户不存在"
        return
    fi

    UUID=$(grep "^${USERNAME}:" "$USER_DB" | cut -d: -f2)

    if [[ "$ACTION" == "disable" ]]; then
        # 从 config 移除（不删 db）
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
        # 重新注入
        EXPIRE=$(grep "^${USERNAME}:" "$USER_DB" | cut -d: -f3)
        _inject_user "$UUID" "$USERNAME" "$EXPIRE"
        sed -i "s/^${USERNAME}:\(.*\):disabled$/${USERNAME}:\1:active/" "$USER_DB"
        info "用户 ${USERNAME} 已启用"
    fi

    systemctl restart xray
}

# ============================================================
# 到期检查（可加入 cron）
# ============================================================
check_expire() {
    title "检查到期用户..."
    TODAY=$(date +%Y-%m-%d)
    CHANGED=0

    while IFS=: read -r NAME UUID EXPIRE STATUS; do
        [[ "$STATUS" != "active" ]] && continue
        if [[ "$EXPIRE" < "$TODAY" ]] || [[ "$EXPIRE" == "$TODAY" ]]; then
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
# 列出所有用户
# ============================================================
list_users() {
    title "用户列表"
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
    SERVER_IP=$(curl -s4 ip.sb || curl -s4 ifconfig.me)
    SHORTID=$(python3 -c "import json; d=json.load(open('$XRAY_CONFIG')); print(d['inbounds'][0]['streamSettings']['realitySettings']['shortIds'][0])" 2>/dev/null)

    echo -e "IP     : ${SERVER_IP}"
    echo -e "端口   : ${PORT}"
    echo -e "公钥   : ${PUBLIC_KEY}"
    echo -e "SNI    : ${SNI}"
    echo -e "ShortID: ${SHORTID}"
    echo -e "协议   : VLESS+Reality+TCP (xtls-rprx-vision)"
}

# ============================================================
# 设置 cron 自动到期检查
# ============================================================
setup_cron() {
    CRON_CMD="0 1 * * * bash $0 --check-expire >> /var/log/xray-expire.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "check-expire"; echo "$CRON_CMD") | crontab -
    info "已设置每日 01:00 自动检查到期用户"
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
        echo -e "${BLUE}╔══════════════════════════════════╗${NC}"
        echo -e "${BLUE}║   VLESS+Reality 用户管理工具     ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════╝${NC}"
        echo -e " ${GREEN}1.${NC} 安装 Xray + 初始化配置"
        echo -e " ${GREEN}2.${NC} 添加用户"
        echo -e " ${GREEN}3.${NC} 删除用户"
        echo -e " ${GREEN}4.${NC} 禁用用户"
        echo -e " ${GREEN}5.${NC} 启用用户"
        echo -e " ${GREEN}6.${NC} 查看所有用户"
        echo -e " ${GREEN}7.${NC} 检查到期用户"
        echo -e " ${GREEN}8.${NC} 查看节点信息"
        echo -e " ${GREEN}9.${NC} 设置自动到期检查（cron）"
        echo -e " ${RED}0.${NC} 退出"
        echo -e "${BLUE}──────────────────────────────────${NC}"
        read -rp " 选择 [0-9]: " OPT

        case $OPT in
            1) install_xray; init_config ;;
            2) add_user ;;
            3) delete_user ;;
            4) toggle_user disable ;;
            5) toggle_user enable ;;
            6) list_users ;;
            7) check_expire ;;
            8) show_info ;;
            9) setup_cron ;;
            0) exit 0 ;;
            *) warn "无效选项" ;;
        esac

        echo ""
        read -rp "按 Enter 继续..." _
    done
}

main_menu
