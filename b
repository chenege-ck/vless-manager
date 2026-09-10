#!/bin/bash
# VLESS Reality 极简管理脚本 (sing-box) - Alpine Linux 专用
# 仅保留：安装单个 VLESS+Reality 节点 / 创建用户（带到期时间）/ 删除 / 续期 / 列表 / 到期自动禁用

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
META="${SBOX_DIR}/meta-reality.conf"
INIT_SCRIPT="/etc/init.d/sing-box"
CRON_JOB="/etc/periodic/15min/sbox-check-expire"
SELF_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0")"

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
check_port() { ss -tlnp 2>/dev/null | grep -q ":${1} " && return 1 || return 0; }

# ============== 服务控制（OpenRC） ==============
_start_sbox() {
    "$SBOX_BIN" check -c "$SBOX_CONFIG" >/tmp/sbox_check.log 2>&1
    if [[ $? -ne 0 ]]; then
        error "sing-box 配置校验失败:"
        cat /tmp/sbox_check.log
        return 1
    fi
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
    info "依赖安装完成"
}

# ============================================================
# 安装 sing-box（从 GitHub Releases 下载静态二进制）
# ============================================================
install_sbox() {
    title "安装 sing-box..."
    if [[ -f "$SBOX_BIN" ]]; then
        warn "sing-box 已安装，跳过安装步骤"
        return 0
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
    VER=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
          | python3 -c "import json,sys; print(json.load(sys.stdin).get('tag_name','').lstrip('v'))" 2>/dev/null)
    [[ -z "$VER" ]] && { error "无法获取 sing-box 最新版本"; return 1; }

    local URL="https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${ARCH}.tar.gz"
    info "下载: ${URL}"
    curl -fsSL "$URL" -o /tmp/sing-box.tar.gz || { error "下载失败"; return 1; }
    tar -xzf /tmp/sing-box.tar.gz -C /tmp/
    local DIR_NAME="sing-box-${VER}-linux-${ARCH}"
    cp "/tmp/${DIR_NAME}/sing-box" "$SBOX_BIN"
    chmod +x "$SBOX_BIN"
    rm -rf /tmp/sing-box.tar.gz "/tmp/${DIR_NAME}"

    [[ -x "$SBOX_BIN" ]] || { error "sing-box 安装失败"; return 1; }
    mkdir -p "$SBOX_DIR"

    # 创建 OpenRC 服务
    cat > "$INIT_SCRIPT" <<'EOF'
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
    chmod +x "$INIT_SCRIPT"

    info "sing-box 安装成功: $($SBOX_BIN version 2>/dev/null | head -1)"
}

# ============================================================
# 卸载
# ============================================================
uninstall_sbox() {
    title "卸载 sing-box..."
    read -rp "确认卸载？将删除所有配置和用户数据 [y/N]: " CONFIRM
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && warn "已取消" && return

    rc-service sing-box stop 2>/dev/null
    rc-update del sing-box default 2>/dev/null
    rm -f "$SBOX_BIN" "$INIT_SCRIPT" "$CRON_JOB"
    rm -rf "$SBOX_DIR"
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
# 加载 Reality 元数据
# ============================================================
load_meta() {
    REALITY_PRIVATE_KEY="" REALITY_PUBLIC_KEY="" REALITY_SNI=""
    REALITY_PORT="" REALITY_SHORTID=""
    if [[ -f "$META" ]]; then
        REALITY_PRIVATE_KEY=$(read_kv "$META" "REALITY_PRIVATE_KEY")
        REALITY_PUBLIC_KEY=$(read_kv "$META" "REALITY_PUBLIC_KEY")
        REALITY_SNI=$(read_kv "$META" "REALITY_SNI")
        REALITY_PORT=$(read_kv "$META" "REALITY_PORT")
        REALITY_SHORTID=$(read_kv "$META" "REALITY_SHORTID")
    fi
}

has_reality() { [[ -f "$META" ]]; }

# ============================================================
# 重建 config.json（仅 VLESS+Reality 一个入站）
# ============================================================
rebuild_config() {
    load_meta
    [[ -z "$REALITY_PORT" ]] && { error "Reality 节点尚未初始化"; return 1; }

    export SBOX_CONFIG REALITY_PORT REALITY_SNI REALITY_PRIVATE_KEY REALITY_SHORTID
    python3 - <<'PYEOF'
import json, os

cfg = {
    "log": {"level": "warn", "timestamp": True},
    "inbounds": [{
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
    }],
    "outbounds": [{"type": "direct", "tag": "direct"}, {"type": "block", "tag": "block"}],
    "route": {
        "rules": [
            {"protocol": "dns", "action": "hijack-dns"},
            {"action": "sniff"}
        ],
        "final": "direct"
    }
}

with open(os.environ["SBOX_CONFIG"], "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF
}

# ============================================================
# 注入单个用户到 config.json
# ============================================================
_inject_user() {
    local UUID=$1 NAME=$2
    INJECT_UUID="$UUID" INJECT_NAME="$NAME" INJECT_CONFIG="$SBOX_CONFIG" python3 - <<'PYEOF'
import json, os
uuid = os.environ["INJECT_UUID"]
name = os.environ["INJECT_NAME"]
cfg_path = os.environ["INJECT_CONFIG"]

with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

for inbound in cfg.get("inbounds", []):
    if inbound.get("tag") != "inbound-reality":
        continue
    users = inbound.get("users", [])
    users = [u for u in users if u.get("uuid") != uuid]
    users.append({"name": name, "uuid": uuid, "flow": "xtls-rprx-vision"})
    inbound["users"] = users

with open(cfg_path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF
}

# ============================================================
# 重建后把所有 active 用户重新注入
# ============================================================
_inject_all_users() {
    [[ ! -f "$USER_DB" ]] && return
    while IFS=: read -r NAME UUID EXPIRE STATUS; do
        [[ "$STATUS" != "active" ]] && continue
        _inject_user "$UUID" "$NAME"
    done < "$USER_DB"
}

# ============================================================
# 初始化 Reality 节点
# ============================================================
init_reality() {
    title "配置 VLESS + Reality"
    if has_reality; then
        warn "Reality 节点已存在，重新配置将生成新密钥，所有用户需重新获取链接"
        read -rp "确认继续？[y/N]: " C
        [[ "$C" != "y" && "$C" != "Y" ]] && return
    fi

    gen_keypair
    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        error "密钥生成失败"; return 1
    fi

    local REALITY_PORT REALITY_SNI REALITY_SHORTID
    while true; do
        read -rp "监听端口 [默认 8443]: " REALITY_PORT
        REALITY_PORT=${REALITY_PORT:-8443}
        check_port "$REALITY_PORT" && break || warn "端口 ${REALITY_PORT} 已被占用"
    done

    read -rp "伪装域名 [默认 www.microsoft.com]: " REALITY_SNI
    REALITY_SNI=${REALITY_SNI:-www.microsoft.com}
    REALITY_SHORTID=$(openssl rand -hex 8)

    mkdir -p "$SBOX_DIR"
    cat > "$META" <<EOF
REALITY_PRIVATE_KEY=${PRIVATE_KEY}
REALITY_PUBLIC_KEY=${PUBLIC_KEY}
REALITY_SNI=${REALITY_SNI}
REALITY_PORT=${REALITY_PORT}
REALITY_SHORTID=${REALITY_SHORTID}
EOF
    chmod 600 "$META"

    rebuild_config || return 1
    _inject_all_users
    _start_sbox || return 1
    info "Reality 节点配置完成"
    info "公钥: ${PUBLIC_KEY}"
}

# ============================================================
# 单独修改监听端口（不改密钥，不影响已有用户）
# ============================================================
change_port() {
    title "修改监听端口"
    has_reality || { error "尚未安装 Reality 节点，请先执行安装"; return; }
    load_meta

    echo -e "当前端口: ${CYAN}${REALITY_PORT}${NC}"
    local NEW_PORT
    while true; do
        read -rp "新端口: " NEW_PORT
        [[ -z "$NEW_PORT" ]] && { warn "已取消"; return; }
        if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || (( NEW_PORT < 1 || NEW_PORT > 65535 )); then
            error "端口必须是 1-65535 的数字"; continue
        fi
        if [[ "$NEW_PORT" == "$REALITY_PORT" ]]; then
            warn "新端口与当前端口相同"; return
        fi
        check_port "$NEW_PORT" && break || warn "端口 ${NEW_PORT} 已被占用，请换一个"
    done

    sed -i "s|^REALITY_PORT=.*|REALITY_PORT=${NEW_PORT}|" "$META"
    rebuild_config || return 1
    _inject_all_users
    _start_sbox || return 1
    info "端口已修改为 ${NEW_PORT}，请通知所有用户更新链接（用户名/UUID 不变，可用「查看用户分享链接」重新获取）"
}

# ============================================================
# 打印用户分享链接
# ============================================================
_print_link() {
    local USERNAME=$1 UUID=$2 EXPIRE=$3
    load_meta
    local SERVER_IP EXPIRE_SHOW
    SERVER_IP=$(get_public_ip)
    EXPIRE_SHOW=$(expire_display "$EXPIRE")

    local LINK="vless://${UUID}@${SERVER_IP}:${REALITY_PORT}/?type=tcp&encryption=none&flow=xtls-rprx-vision&sni=${REALITY_SNI}&fp=chrome&security=reality&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORTID}#${USERNAME}-reality"

    echo ""
    echo -e "${GREEN}===== 用户信息 =====${NC}"
    echo -e "用户名 : ${USERNAME}"
    echo -e "UUID   : ${UUID}"
    echo -e "到期   : ${EXPIRE_SHOW}"
    echo -e "地址   : ${SERVER_IP}"
    echo -e "端口   : ${REALITY_PORT}"
    echo -e "公钥   : ${REALITY_PUBLIC_KEY}"
    echo -e "SNI    : ${REALITY_SNI}"
    echo -e "ShortID: ${REALITY_SHORTID}"
    echo -e "${CYAN}分享链接:${NC}"
    echo "$LINK"
    echo ""
}

# ============================================================
# 添加用户
# ============================================================
add_user() {
    title "创建用户"
    has_reality || { error "尚未安装 Reality 节点，请先执行安装"; return; }

    read -rp "用户名（备注用）: " USERNAME
    validate_username "$USERNAME" || return
    if user_exists "$USERNAME"; then
        error "用户 ${USERNAME} 已存在"; return
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

    echo "${USERNAME}:${UUID}:${EXPIRE}:active" >> "$USER_DB"
    _inject_user "$UUID" "$USERNAME"
    _start_sbox || { error "启动失败，请检查配置"; return 1; }

    _print_link "$USERNAME" "$UUID" "$EXPIRE"
}

# ============================================================
# 删除用户
# ============================================================
delete_user() {
    title "删除用户"
    list_users_brief
    read -rp "输入要删除的用户名: " USERNAME
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
# 续期用户
# ============================================================
renew_user() {
    title "续期用户"
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

    local UUID NEW_EXPIRE
    UUID=$(get_user_field "$USERNAME" 2)
    validate_uuid "$UUID" || return
    NEW_EXPIRE=$(expire_noon_str "$DAYS")

    sed -i "s|^${USERNAME}:${UUID}:.*|${USERNAME}:${UUID}:${NEW_EXPIRE}:active|" "$USER_DB"
    _inject_user "$UUID" "$USERNAME"
    _start_sbox
    info "用户 ${USERNAME} 到期时间已更新为 $(expire_display "$NEW_EXPIRE")"
}

# ============================================================
# 列表
# ============================================================
list_users() {
    title "用户列表"
    [[ ! -s "$USER_DB" ]] && warn "暂无用户" && return

    printf "  %-15s %-38s %-20s %-8s\n" "用户名" "UUID" "到期时间" "状态"
    echo "  ─────────────────────────────────────────────────────────────────────"
    while IFS=: read -r NAME UUID EXPIRE STATUS; do
        local COLOR=$NC
        [[ "$STATUS" == "active" ]] && COLOR=$GREEN || COLOR=$RED
        printf "  ${COLOR}%-15s %-38s %-20s %-8s${NC}\n" "$NAME" "$UUID" "$(expire_display "$EXPIRE")" "$STATUS"
    done < "$USER_DB"
    echo ""
}

list_users_brief() {
    echo ""
    [[ ! -s "$USER_DB" ]] && echo "  （暂无用户）" && echo "" && return
    while IFS=: read -r NAME UUID EXPIRE STATUS; do
        printf "  %-15s %s  [%s]\n" "$NAME" "$(expire_display "$EXPIRE")" "$STATUS"
    done < "$USER_DB"
    echo ""
}

show_user_link() {
    title "查看用户分享链接"
    list_users_brief
    read -rp "输入用户名: " USERNAME
    [[ -z "$USERNAME" ]] && return
    if ! user_exists "$USERNAME"; then
        error "用户不存在"; return
    fi
    local UUID EXPIRE
    UUID=$(get_user_field "$USERNAME" 2)
    EXPIRE=$(get_user_field "$USERNAME" 3)
    _print_link "$USERNAME" "$UUID" "$EXPIRE"
}

# ============================================================
# 到期检查（供 crond 调用）
# ============================================================
check_expire() {
    [[ ! -f "$USER_DB" ]] && exit 0
    local NOW_TS CHANGED=0 EXPIRED_UUIDS=""
    NOW_TS=$(now_shanghai_ts)

    while IFS=: read -r NAME UUID EXPIRE STATUS; do
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
        parts[3] = "disabled"
    out.append(":".join(parts))
p.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PYEOF
        rebuild_config
        _inject_all_users
        "$SBOX_BIN" check -c "$SBOX_CONFIG" >/dev/null 2>&1 && rc-service sing-box restart >/dev/null 2>&1
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
# 一键安装
# ============================================================
full_install() {
    check_system
    set_shanghai_timezone
    install_sbox || return 1
    init_reality || return 1
    setup_cron
    info "安装完成，可通过菜单「创建用户」添加节点用户"
}

# ============================================================
# 主菜单
# ============================================================
main_menu() {
    while true; do
        echo ""
        echo -e "${CYAN}========== VLESS Reality 管理（Alpine）==========${NC}"
        echo -e "  ${GREEN}1.${NC} 一键安装 / 重新配置 Reality 节点"
        echo -e "  ${GREEN}2.${NC} 创建用户"
        echo -e "  ${GREEN}3.${NC} 删除用户"
        echo -e "  ${GREEN}4.${NC} 续期用户"
        echo -e "  ${GREEN}5.${NC} 用户列表"
        echo -e "  ${GREEN}6.${NC} 查看用户分享链接"
        echo -e "  ${GREEN}7.${NC} 手动执行到期检查"
        echo -e "  ${GREEN}8.${NC} 卸载"
        echo -e "  ${GREEN}0.${NC} 退出"
        echo -e "${CYAN}=================================================${NC}"
        read -rp "选择: " CHOICE
        case "$CHOICE" in
            1) full_install ;;
            2) add_user ;;
            3) delete_user ;;
            4) renew_user ;;
            5) list_users ;;
            6) show_user_link ;;
            7) check_expire; info "到期检查已执行" ;;
            8) uninstall_sbox ;;
            0) exit 0 ;;
            *) error "无效选择" ;;
        esac
    done
}

# ============== 入口 ==============
if [[ "$1" == "check-expire" ]]; then
    check_expire
    exit 0
fi

check_system
main_menu
