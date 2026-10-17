#!/bin/bash
# sing-box 精简节点管理脚本（NAT 小鸡版） v2.0-lite
# Reality + SS + WS(TLS) + Hysteria2 + AnyTLS
# 系统: Alpine(OpenRC) 为主, Debian/Ubuntu/CentOS(systemd) 兼容

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
META="${SBOX_DIR}/meta.conf"
META_REALITY="${SBOX_DIR}/meta-reality.conf"
META_SS="${SBOX_DIR}/meta-ss.conf"
META_WS="${SBOX_DIR}/meta-ws.conf"
META_HY2="${SBOX_DIR}/meta-hy2.conf"
META_ANYTLS="${SBOX_DIR}/meta-anytls.conf"
SERVICE_NAME="sing-box"

HY_BIN="/usr/local/bin/hysteria"
HY_SERVICE="hysteria-server"
HY_DIR="/etc/hysteria"
HY_CONF="${HY_DIR}/config.yaml"
HY_CERT_F="${HY_DIR}/server.crt"
HY_KEY_F="${HY_DIR}/server.key"

SCRIPT_URL="https://raw.githubusercontent.com/chenege-ck/vless-manager/main/b"
SCRIPT_PATH="/usr/local/bin/singbox_manager.sh"
VERSION="v2.0-lite"

# ============== 默认端口（NAT 请按商家分配的端口段输入） ==============
REALITY_PORT_DEFAULT=8443
SS_PORT_DEFAULT=8668
WS_PORT_DEFAULT=8445
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

_new_uuid() { cat /proc/sys/kernel/random/uuid; }

_urlencode() {
    python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1"
}

# IPv6 地址加方括号
fmt_host() {
    [[ "$1" == *:* && "$1" != \[*\] ]] && echo "[$1]" || echo "$1"
}

# 有 IPv6 就监听 ::，否则监听 0.0.0.0（部分 NAT 容器未开 IPv6，监听 :: 会失败）
_listen_addr() {
    if [[ -s /proc/net/if_inet6 ]] && [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != "1" ]]; then
        echo "::"
    else
        echo "0.0.0.0"
    fi
}

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

# ============== 端口检查（ss 优先，回退 netstat） ==============
_port_listening() {
    local proto="$1" port="$2" flag="-tln"
    [[ "$proto" == "udp" ]] && flag="-uln"
    if command -v ss >/dev/null 2>&1; then
        ss $flag 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    else
        netstat $flag 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    fi
}

# 用法: ask_port 变量名 提示 默认端口 tcp|udp [当前端口(重新配置时跳过占用检查)]
ask_port() {
    local __var="$1" __label="$2" __def="$3" __proto="${4:-tcp}" __cur="${5:-}" __p
    while true; do
        read -rp "${__label} [默认 ${__def}]: " __p
        __p=${__p:-$__def}
        if ! [[ "$__p" =~ ^[0-9]+$ ]] || (( __p < 1 || __p > 65535 )); then
            warn "端口必须是 1-65535"; continue
        fi
        if [[ "$__p" != "$__cur" ]] && _port_listening "$__proto" "$__p"; then
            warn "端口 ${__p} 已被占用"; continue
        fi
        printf -v "$__var" '%s' "$__p"
        return 0
    done
}

# ============== 初始化系统（systemd / OpenRC） ==============
INIT_SYS=""
detect_init() {
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        INIT_SYS="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYS="openrc"
    else
        INIT_SYS="none"
    fi
}

svc_exists() {
    case "$INIT_SYS" in
        systemd) [[ -f "/etc/systemd/system/$1.service" || -f "/lib/systemd/system/$1.service" || -f "/usr/lib/systemd/system/$1.service" ]] ;;
        openrc)  [[ -f "/etc/init.d/$1" ]] ;;
        *) return 1 ;;
    esac
}

svc_enable() {
    case "$INIT_SYS" in
        systemd) systemctl enable "$1" >/dev/null 2>&1 ;;
        openrc)  rc-update add "$1" default >/dev/null 2>&1 ;;
    esac
}

svc_disable() {
    case "$INIT_SYS" in
        systemd) systemctl disable "$1" >/dev/null 2>&1 ;;
        openrc)  rc-update del "$1" default >/dev/null 2>&1 ;;
    esac
}

svc_restart() {
    case "$INIT_SYS" in
        systemd) systemctl restart "$1" >/dev/null 2>&1 ;;
        openrc)  rc-service "$1" restart >/dev/null 2>&1 ;;
    esac
}

svc_stop() {
    case "$INIT_SYS" in
        systemd) systemctl stop "$1" >/dev/null 2>&1 ;;
        openrc)  rc-service "$1" stop >/dev/null 2>&1 ;;
    esac
}

svc_active() {
    case "$INIT_SYS" in
        systemd) systemctl is-active --quiet "$1" ;;
        openrc)  rc-service "$1" status >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

svc_log_hint() {
    case "$INIT_SYS" in
        systemd) echo "journalctl -u $1 -n 20 --no-pager" ;;
        openrc)  echo "tail -n 20 /var/log/$1.log" ;;
    esac
}

# 用法: write_service 名称 描述 二进制 参数
write_service() {
    local NAME="$1" DESC="$2" BIN="$3" ARGS="$4"
    case "$INIT_SYS" in
        systemd)
            cat > "/etc/systemd/system/${NAME}.service" <<EOF
[Unit]
Description=${DESC}
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${BIN} ${ARGS}
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            ;;
        openrc)
            cat > "/etc/init.d/${NAME}" <<EOF
#!/sbin/openrc-run
name="${NAME}"
description="${DESC}"
command="${BIN}"
command_args="${ARGS}"
command_background=true
pidfile="/run/${NAME}.pid"
output_log="/var/log/${NAME}.log"
error_log="/var/log/${NAME}.log"

depend() {
    need net
    after firewall
}
EOF
            chmod +x "/etc/init.d/${NAME}"
            ;;
    esac
}

remove_service() {
    local NAME="$1"
    svc_stop "$NAME"
    svc_disable "$NAME"
    rm -f "/etc/systemd/system/${NAME}.service" "/etc/init.d/${NAME}" "/var/log/${NAME}.log"
    [[ "$INIT_SYS" == "systemd" ]] && { systemctl daemon-reload; systemctl reset-failed >/dev/null 2>&1; }
    return 0
}

# ============== 包管理器 / 依赖 ==============
PKG=""
detect_pkg() {
    if command -v apk >/dev/null 2>&1; then PKG="apk"
    elif command -v apt-get >/dev/null 2>&1; then PKG="apt"
    elif command -v dnf >/dev/null 2>&1; then PKG="dnf"
    elif command -v yum >/dev/null 2>&1; then PKG="yum"
    else PKG=""; fi
}

install_deps() {
    title "检查依赖"
    local missing=0 c
    for c in curl openssl python3 tar; do
        command -v "$c" >/dev/null 2>&1 || missing=1
    done
    command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1 || missing=1
    if [[ $missing -eq 0 ]]; then
        info "依赖已齐全"; return 0
    fi
    info "正在安装依赖（包管理器: ${PKG:-未知}）..."
    case "$PKG" in
        apk)
            apk update -q >/dev/null 2>&1
            apk add -q bash curl openssl python3 iproute2 ca-certificates tar gzip ;;
        apt)
            apt-get update -qq >/dev/null 2>&1 || warn "apt 更新失败，仍尝试安装"
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl openssl python3 iproute2 ca-certificates tar gzip ;;
        dnf)
            dnf install -y -q curl openssl python3 iproute ca-certificates tar gzip ;;
        yum)
            yum install -y -q curl openssl python3 iproute ca-certificates tar gzip ;;
        *)
            error "无法识别包管理器，请手动安装: curl openssl python3 tar iproute2"; return 1 ;;
    esac
    [[ $? -ne 0 ]] && { error "依赖安装失败"; return 1; }
    info "依赖安装完成"
}

# ============== 节点元数据 ==============
load_meta() {
    REALITY_PRIVATE_KEY=""  REALITY_PUBLIC_KEY=""  REALITY_SNI=""
    REALITY_PORT=""  REALITY_SHORTID=""  REALITY_UUID=""
    SS_PORT=""  SS_METHOD=""  SS_PASSWORD=""
    WS_PORT=""  WS_PATH=""  WS_DOMAIN=""  WS_UUID=""  CERT_DIR=""
    HY2_PORT=""  HY2_PASSWORD=""  HY2_SNI=""
    ANYTLS_PORT=""  ANYTLS_PASSWORD=""  ANYTLS_SNI=""
    ANYTLS_PRIVATE_KEY=""  ANYTLS_PUBLIC_KEY=""  ANYTLS_SHORTID=""

    if [[ -f "$META_REALITY" ]]; then
        REALITY_PRIVATE_KEY=$(read_kv "$META_REALITY" "REALITY_PRIVATE_KEY")
        REALITY_PUBLIC_KEY=$(read_kv "$META_REALITY" "REALITY_PUBLIC_KEY")
        REALITY_SNI=$(read_kv "$META_REALITY" "REALITY_SNI")
        REALITY_PORT=$(read_kv "$META_REALITY" "REALITY_PORT")
        REALITY_SHORTID=$(read_kv "$META_REALITY" "REALITY_SHORTID")
        REALITY_UUID=$(read_kv "$META_REALITY" "REALITY_UUID")
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
        WS_UUID=$(read_kv "$META_WS" "WS_UUID")
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

has_reality()     { [[ -f "$META_REALITY" ]]; }
has_shadowsocks() { [[ -f "$META_SS" ]]; }
has_ws()          { [[ -f "$META_WS" ]]; }
has_hy2()         { [[ -f "$META_HY2" ]]; }
has_anytls()      { [[ -f "$META_ANYTLS" ]]; }
has_singbox_inbound() { has_reality || has_shadowsocks || has_ws || has_anytls; }

# ============== sing-box 二进制 ==============
detect_sbox_bin() {
    local candidate
    for candidate in /usr/local/bin/sing-box /usr/bin/sing-box "$(command -v sing-box 2>/dev/null)"; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        if "$candidate" version >/dev/null 2>&1; then
            SBOX_BIN="$candidate"
            return 0
        fi
    done
    return 1
}

_sbox_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv7)  echo "armv7" ;;
        i386|i686)     echo "386" ;;
        *) return 1 ;;
    esac
}

# 从 GitHub release 下载最新 sing-box 官方二进制（静态编译，Alpine/musl 可直接运行）
_download_sbox() {
    local ARCH VER URL TMPD SRC
    ARCH=$(_sbox_arch) || { error "不支持的架构: $(uname -m)"; return 1; }
    VER=$(curl -fsSL -L --max-time 15 -o /dev/null -w '%{url_effective}' \
          "https://github.com/SagerNet/sing-box/releases/latest" 2>/dev/null \
          | sed -nE 's#^.*/tag/v([0-9]+\.[0-9]+\.[0-9]+)$#\1#p' | head -n 1)
    [[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { error "无法获取 sing-box 最新版本（GitHub 不通？IPv6 单栈机器通常访问不了 github.com）"; return 1; }
    URL="https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${ARCH}.tar.gz"
    TMPD=$(mktemp -d) || { error "创建临时目录失败"; return 1; }
    info "下载 sing-box v${VER} (${ARCH})..."
    if ! curl -fsSL --retry 2 --max-time 180 "$URL" -o "${TMPD}/sb.tar.gz"; then
        error "下载失败: $URL"; rm -rf "$TMPD"; return 1
    fi
    tar -xzf "${TMPD}/sb.tar.gz" -C "$TMPD" || { error "解压失败"; rm -rf "$TMPD"; return 1; }
    SRC=$(find "$TMPD" -type f -name sing-box | head -n 1)
    [[ -n "$SRC" ]] || { error "压缩包中未找到 sing-box"; rm -rf "$TMPD"; return 1; }
    chmod +x "$SRC"
    "$SRC" version >/dev/null 2>&1 || { error "下载的二进制无法运行（架构不匹配？）"; rm -rf "$TMPD"; return 1; }
    mkdir -p "$(dirname "$SBOX_BIN")"
    cp "$SRC" "${SBOX_BIN}.new" && chmod +x "${SBOX_BIN}.new" && mv -f "${SBOX_BIN}.new" "$SBOX_BIN" \
        || { error "写入 ${SBOX_BIN} 失败"; rm -rf "$TMPD"; return 1; }
    rm -rf "$TMPD"
    return 0
}

install_sbox() {
    title "安装 sing-box"
    if detect_sbox_bin; then
        warn "sing-box 已安装，跳过安装步骤"
        return 0
    fi
    install_deps || return 1
    _download_sbox || return 1
    detect_sbox_bin || { error "sing-box 安装失败"; return 1; }
    mkdir -p "$SBOX_DIR"
    write_service "$SERVICE_NAME" "sing-box service" "$SBOX_BIN" "run -c ${SBOX_CONFIG}"
    info "sing-box 安装成功: $("$SBOX_BIN" version 2>/dev/null | head -1)"
}

update_sbox() {
    title "更新 sing-box"
    detect_sbox_bin || { error "sing-box 未安装"; return 1; }
    local OLD NEW
    OLD=$("$SBOX_BIN" version 2>/dev/null | head -1 | awk '{print $NF}')
    info "当前版本: ${OLD:-未知}"
    _download_sbox || return 1
    NEW=$("$SBOX_BIN" version 2>/dev/null | head -1 | awk '{print $NF}')
    if [[ "$OLD" == "$NEW" ]]; then
        info "已是最新版本: ${NEW:-未知}"
    else
        info "更新完成: ${OLD:-未知} → ${NEW:-未知}"
    fi
    if has_singbox_inbound; then _start_sbox; fi
}

validate_sbox_config() {
    [[ ! -f "$SBOX_CONFIG" ]] && error "配置文件不存在: $SBOX_CONFIG" && return 1
    if ! python3 -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8'))" "$SBOX_CONFIG" >/dev/null 2>&1; then
        error "config.json 不是合法 JSON"; return 1
    fi
    if [[ ! -x "$SBOX_BIN" ]]; then
        detect_sbox_bin || { error "未找到 sing-box 可执行文件"; return 1; }
    fi
    local OUT
    OUT=$("$SBOX_BIN" check -c "$SBOX_CONFIG" 2>&1)
    if [[ $? -ne 0 ]]; then
        error "sing-box 配置校验失败:"
        echo "$OUT" | while IFS= read -r line; do echo -e "  ${RED}${line}${NC}"; done
        return 1
    fi
    return 0
}

_start_sbox() {
    validate_sbox_config || return 1
    svc_exists "$SERVICE_NAME" || write_service "$SERVICE_NAME" "sing-box service" "$SBOX_BIN" "run -c ${SBOX_CONFIG}"
    svc_enable "$SERVICE_NAME"
    svc_restart "$SERVICE_NAME"
    sleep 1
    if svc_active "$SERVICE_NAME"; then
        info "sing-box 已启动"; return 0
    fi
    error "sing-box 启动失败，查看日志: $(svc_log_hint "$SERVICE_NAME")"
    return 1
}

# ============== Reality 密钥对 ==============
gen_keypair() {
    PRIVATE_KEY=""; PUBLIC_KEY=""
    detect_sbox_bin || { error "找不到 sing-box，请先执行「安装 sing-box 并配置节点」"; return 1; }
    local OUTPUT
    OUTPUT=$("$SBOX_BIN" generate reality-keypair 2>&1)
    [[ $? -ne 0 ]] && { error "密钥生成失败: ${OUTPUT}"; return 1; }
    PRIVATE_KEY=$(printf '%s\n' "$OUTPUT" | awk 'tolower($0) ~ /privatekey:/ {sub(/\r$/,""); sub(/^[^:]*:[ \t]*/,""); print; exit}')
    PUBLIC_KEY=$(printf '%s\n' "$OUTPUT" | awk 'tolower($0) ~ /publickey:/ {sub(/\r$/,""); sub(/^[^:]*:[ \t]*/,""); print; exit}')
    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" || "$PRIVATE_KEY" == "$PUBLIC_KEY" ]]; then
        error "无法解析 Reality 密钥输出: ${OUTPUT}"; return 1
    fi
}

# ============== IPv4 / IPv6 优先级 ==============
_read_ip_priority() {
    local ds=""
    [[ -f "$META" ]] && ds=$(read_kv "$META" "IP_PRIORITY")
    echo "$ds"
}

_get_ip_priority_desc() {
    case "$(_read_ip_priority)" in
        prefer_ipv4) echo "IPv4 优先（v4失败自动切v6）" ;;
        prefer_ipv6) echo "IPv6 优先（v6失败自动切v4）" ;;
        ipv4_only)   echo "仅 IPv4" ;;
        ipv6_only)   echo "仅 IPv6" ;;
        *)           echo "系统默认" ;;
    esac
}

_save_ip_priority() {
    local ds="$1"
    mkdir -p "$SBOX_DIR"; touch "$META"
    if grep -q "^IP_PRIORITY=" "$META" 2>/dev/null; then
        sed -i "s|^IP_PRIORITY=.*|IP_PRIORITY=${ds}|" "$META"
    else
        echo "IP_PRIORITY=${ds}" >> "$META"
    fi
}

ip_priority_menu() {
    title "网络优先级（IPv4/IPv6）"
    echo ""
    echo -e "当前模式：${CYAN}$(_get_ip_priority_desc)${NC}"
    echo -e "${YELLOW}（对 sing-box 的出站统一生效）${NC}"
    echo ""
    echo -e "  ${GREEN}1.${NC} IPv4 优先   — 优先走 v4，v4 不通自动切 v6"
    echo -e "  ${GREEN}2.${NC} IPv6 优先   — 优先走 v6，v6 不通自动切 v4"
    echo -e "  ${GREEN}3.${NC} 仅 IPv4     — 强制只走 v4"
    echo -e "  ${GREEN}4.${NC} 仅 IPv6     — 强制只走 v6"
    echo -e "  ${GREEN}5.${NC} 系统默认"
    echo -e "  ${GREEN}0.${NC} 返回"
    echo ""
    read -rp "选择: " OPT
    local DS="" DESC=""
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
    if has_singbox_inbound; then
        _apply_config || { error "配置应用失败，设置已保存但尚未生效"; return 1; }
    fi
    info "已保存：${DESC}"
}

# ============== 重建 sing-box config.json ==============
rebuild_config() {
    load_meta
    mkdir -p "$SBOX_DIR"
    IP_PRIO=$(_read_ip_priority)
    LISTEN_ADDR=$(_listen_addr)
    HAS_REALITY=0; has_reality && HAS_REALITY=1
    HAS_SS=0; has_shadowsocks && HAS_SS=1
    HAS_WS=0; has_ws && HAS_WS=1
    HAS_ANYTLS=0; has_anytls && HAS_ANYTLS=1

    export SBOX_CONFIG LISTEN_ADDR IP_PRIO HAS_REALITY HAS_SS HAS_WS HAS_ANYTLS
    export REALITY_PORT REALITY_SNI REALITY_PRIVATE_KEY REALITY_SHORTID REALITY_UUID
    export SS_PORT SS_METHOD SS_PASSWORD
    export WS_PORT WS_PATH WS_UUID CERT_DIR
    export ANYTLS_PORT ANYTLS_PASSWORD ANYTLS_SNI ANYTLS_PRIVATE_KEY ANYTLS_SHORTID

    python3 - <<'PYEOF'
import json, os
E = os.environ
LISTEN = E.get("LISTEN_ADDR", "::")
cfg = {"log": {"level": "warn", "timestamp": True}, "inbounds": [], "outbounds": []}

if E.get("HAS_REALITY") == "1":
    cfg["inbounds"].append({
        "type": "vless", "tag": "inbound-reality",
        "listen": LISTEN, "listen_port": int(E["REALITY_PORT"]),
        "users": [{"name": "reality", "uuid": E["REALITY_UUID"], "flow": "xtls-rprx-vision"}],
        "tls": {
            "enabled": True, "server_name": E["REALITY_SNI"],
            "reality": {
                "enabled": True,
                "handshake": {"server": E["REALITY_SNI"], "server_port": 443},
                "private_key": E["REALITY_PRIVATE_KEY"],
                "short_id": [E["REALITY_SHORTID"]]
            }
        }
    })

if E.get("HAS_SS") == "1":
    cfg["inbounds"].append({
        "type": "shadowsocks", "tag": "inbound-shadowsocks",
        "listen": LISTEN, "listen_port": int(E["SS_PORT"]),
        "method": E["SS_METHOD"], "password": E["SS_PASSWORD"]
    })

if E.get("HAS_WS") == "1":
    cfg["inbounds"].append({
        "type": "vless", "tag": "inbound-ws",
        "listen": LISTEN, "listen_port": int(E["WS_PORT"]),
        "users": [{"name": "ws", "uuid": E["WS_UUID"]}],
        "tls": {
            "enabled": True,
            "certificate_path": E["CERT_DIR"] + "/ws.crt",
            "key_path": E["CERT_DIR"] + "/ws.key"
        },
        "transport": {
            "type": "ws", "path": E["WS_PATH"],
            "max_early_data": 2048,
            "early_data_header_name": "Sec-WebSocket-Protocol"
        }
    })

if E.get("HAS_ANYTLS") == "1":
    cfg["inbounds"].append({
        "type": "anytls", "tag": "inbound-anytls",
        "listen": LISTEN, "listen_port": int(E["ANYTLS_PORT"]),
        "users": [{"name": "shared", "password": E["ANYTLS_PASSWORD"]}],
        "tls": {
            "enabled": True, "server_name": E["ANYTLS_SNI"],
            "reality": {
                "enabled": True,
                "handshake": {"server": E["ANYTLS_SNI"], "server_port": 443},
                "private_key": E["ANYTLS_PRIVATE_KEY"],
                "short_id": [E["ANYTLS_SHORTID"]]
            }
        }
    })

ds = E.get("IP_PRIO", "")
outbound = {"type": "direct", "tag": "direct"}
if ds and ds != "AsIs":
    cfg["dns"] = {"servers": [{"type": "local", "tag": "local"}]}
    outbound["domain_resolver"] = {"server": "local", "strategy": ds}

cfg["outbounds"] = [outbound]
cfg["route"] = {
    "rules": [
        {"protocol": "dns", "action": "hijack-dns"},
        {"action": "sniff"}
    ],
    "final": "direct"
}

with open(E["SBOX_CONFIG"], "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)
PYEOF
    local RC=$?
    [[ $RC -eq 0 ]] && chmod 600 "$SBOX_CONFIG"
    return $RC
}

# 重建配置并应用；没有任何 sing-box 节点时停止服务
_apply_config() {
    rebuild_config || { error "配置生成失败"; return 1; }
    if has_singbox_inbound; then
        _start_sbox
    else
        svc_stop "$SERVICE_NAME"; svc_disable "$SERVICE_NAME"
        warn "已无 sing-box 节点，服务已停止"
    fi
}

# ============== 节点链接输出 ==============
print_reality() {
    has_reality || return 1
    load_meta
    local IP="${1:-$(get_public_ip)}" H
    H=$(fmt_host "$IP")
    echo ""
    echo -e "${CYAN}── VLESS + Reality ──${NC}"
    echo -e "地址   : ${IP}"
    echo -e "端口   : ${REALITY_PORT}"
    echo -e "UUID   : ${REALITY_UUID}"
    echo -e "公钥   : ${REALITY_PUBLIC_KEY}"
    echo -e "SNI    : ${REALITY_SNI}"
    echo -e "ShortID: ${REALITY_SHORTID}"
    echo -e "${CYAN}分享链接:${NC}"
    echo "vless://${REALITY_UUID}@${H}:${REALITY_PORT}/?type=tcp&encryption=none&flow=xtls-rprx-vision&sni=${REALITY_SNI}&fp=chrome&security=reality&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORTID}#Reality-${REALITY_PORT}"
}

print_ss() {
    has_shadowsocks || return 1
    load_meta
    local IP="${1:-$(get_public_ip)}" H USERINFO
    H=$(fmt_host "$IP")
    USERINFO=$(printf '%s' "${SS_METHOD}:${SS_PASSWORD}" | base64 | tr -d '\n')
    echo ""
    echo -e "${CYAN}── Shadowsocks ──${NC}"
    echo -e "地址   : ${IP}"
    echo -e "端口   : ${SS_PORT}"
    echo -e "加密   : ${SS_METHOD}"
    echo -e "密码   : ${SS_PASSWORD}"
    echo -e "${CYAN}分享链接:${NC}"
    echo "ss://${USERINFO}@${H}:${SS_PORT}#Shadowsocks-${SS_PORT}"
}

print_ws() {
    has_ws || return 1
    load_meta
    local EP EN
    EP=$(_urlencode "$WS_PATH")
    EN=$(_urlencode "WS-${WS_PORT}")
    echo ""
    echo -e "${CYAN}── VLESS + WS + TLS ──${NC}"
    echo -e "域名   : ${WS_DOMAIN}"
    echo -e "端口   : ${WS_PORT}"
    echo -e "UUID   : ${WS_UUID}"
    echo -e "WS路径 : ${WS_PATH}"
    echo -e "${CYAN}分享链接:${NC}"
    echo "vless://${WS_UUID}@${WS_DOMAIN}:${WS_PORT}/?type=ws&encryption=none&host=${WS_DOMAIN}&path=${EP}&security=tls&sni=${WS_DOMAIN}#${EN}"
}

hy2_share_link() {
    local SERVER=$1 PORT=$2 PASS=$3 SNI=$4
    printf 'hy2://%s@%s:%s/?sni=%s&insecure=1&obfs=salamander&obfs-password=%s#Hysteria2-%s\n' \
        "$PASS" "$(fmt_host "$SERVER")" "$PORT" "$SNI" "$PASS" "$PORT"
}

print_hy2() {
    has_hy2 || return 1
    load_meta
    local IP="${1:-$(get_public_ip)}"
    echo ""
    echo -e "${CYAN}── Hysteria2 ──${NC}"
    echo -e "状态   : $(svc_active "$HY_SERVICE" && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}已停止${NC}")"
    echo -e "地址   : ${IP}"
    echo -e "端口   : ${HY2_PORT} (UDP)"
    echo -e "密码   : ${HY2_PASSWORD}"
    echo -e "SNI    : ${HY2_SNI}"
    echo -e "说明   : 自签证书，客户端需 insecure=1；Salamander 混淆（密码同值）"
    echo -e "${CYAN}分享链接:${NC}"
    hy2_share_link "$IP" "$HY2_PORT" "$HY2_PASSWORD" "$HY2_SNI"
}

print_anytls() {
    has_anytls || return 1
    load_meta
    local IP="${1:-$(get_public_ip)}"
    echo ""
    echo -e "${CYAN}── AnyTLS + Reality ──${NC}"
    echo -e "地址   : ${IP}"
    echo -e "端口   : ${ANYTLS_PORT}"
    echo -e "密码   : ${ANYTLS_PASSWORD}"
    echo -e "SNI    : ${ANYTLS_SNI}"
    echo -e "公钥   : ${ANYTLS_PUBLIC_KEY}"
    echo -e "ShortID: ${ANYTLS_SHORTID}"
    echo -e "${CYAN}分享链接:${NC}"
    echo "anytls://${ANYTLS_PASSWORD}@$(fmt_host "$IP"):${ANYTLS_PORT}/?sni=${ANYTLS_SNI}&pbk=${ANYTLS_PUBLIC_KEY}&sid=${ANYTLS_SHORTID}&fp=chrome&security=reality#AnyTLS-${ANYTLS_PORT}"
}

# ============== 创建节点 ==============
init_reality() {
    title "配置 VLESS + Reality"
    load_meta
    gen_keypair || return 1
    local PORT SNI SID UUID
    ask_port PORT "监听端口" "$REALITY_PORT_DEFAULT" tcp "$REALITY_PORT"
    read -rp "伪装域名 [默认 www.swift.org]: " SNI
    SNI=${SNI:-www.swift.org}
    SID=$(openssl rand -hex 8)
    UUID=$(_new_uuid)
    cat > "$META_REALITY" <<EOF
REALITY_PRIVATE_KEY=${PRIVATE_KEY}
REALITY_PUBLIC_KEY=${PUBLIC_KEY}
REALITY_SNI=${SNI}
REALITY_PORT=${PORT}
REALITY_SHORTID=${SID}
REALITY_UUID=${UUID}
EOF
    chmod 600 "$META_REALITY"
    _apply_config || return 1
    info "Reality 节点配置完成"
    print_reality
}

init_shadowsocks() {
    title "配置 Shadowsocks"
    load_meta
    local C PORT PASS
    if has_shadowsocks; then
        warn "Shadowsocks 已存在，重新配置会生成新密码"
        read -rp "确认继续？[y/N]: " C
        [[ "$C" != "y" && "$C" != "Y" ]] && return
    fi
    ask_port PORT "监听端口" "$SS_PORT_DEFAULT" tcp "$SS_PORT"
    PASS=$(openssl rand -base64 16)
    [[ -n "$PASS" ]] || { error "密码生成失败"; return 1; }
    cat > "$META_SS" <<EOF
SS_PORT=${PORT}
SS_METHOD=2022-blake3-aes-128-gcm
SS_PASSWORD=${PASS}
EOF
    chmod 600 "$META_SS"
    _apply_config || return 1
    info "Shadowsocks 配置完成"
    print_ss
}

init_ws_cf() {
    title "配置 VLESS + WS + TLS"
    load_meta
    local PORT WPATH DOMAIN UUID
    echo -e "${YELLOW}提示：若使用 Cloudflare 橙云代理，端口需为 443/2053/2083/2087/2096/8443 之一${NC}"
    ask_port PORT "监听端口" "$WS_PORT_DEFAULT" tcp "$WS_PORT"
    read -rp "WS 路径 [默认 /vless]: " WPATH
    WPATH=${WPATH:-/vless}
    read -rp "你的域名（已在 CF 解析）: " DOMAIN
    [[ -z "$DOMAIN" ]] && { error "域名不能为空"; return 1; }

    local CD="/etc/sing-box/ssl"
    mkdir -p "$CD"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "${CD}/ws.key" -out "${CD}/ws.crt" \
        -days 3650 -subj "/CN=${DOMAIN}" \
        -addext "subjectAltName=DNS:${DOMAIN}" >/dev/null 2>&1 || { error "自签证书生成失败"; return 1; }
    chmod 640 "${CD}/ws.key"; chmod 644 "${CD}/ws.crt"

    UUID=$(_new_uuid)
    cat > "$META_WS" <<EOF
WS_PORT=${PORT}
WS_PATH=${WPATH}
WS_DOMAIN=${DOMAIN}
WS_UUID=${UUID}
CERT_DIR=${CD}
EOF
    chmod 600 "$META_WS"
    _apply_config || return 1
    info "WS 节点配置完成"
    echo -e "${YELLOW}CF 配置：${NC}${DOMAIN} 解析到本机并开启橙云，SSL 使用完全（Full）"
    print_ws
}

init_anytls() {
    title "配置 AnyTLS + Reality"
    load_meta
    local C PORT SNI PASS SID
    if has_anytls; then
        warn "AnyTLS 已存在，重新配置将生成新密码/密钥"
        read -rp "确认继续？[y/N]: " C
        [[ "$C" != "y" && "$C" != "Y" ]] && return
    fi
    ask_port PORT "监听端口" "$ANYTLS_PORT_DEFAULT" tcp "$ANYTLS_PORT"
    read -rp "伪装域名 [默认 www.swift.org]: " SNI
    SNI=${SNI:-www.swift.org}
    gen_keypair || return 1
    PASS=$(openssl rand -hex 16)
    SID=$(openssl rand -hex 8)
    cat > "$META_ANYTLS" <<EOF
ANYTLS_PORT=${PORT}
ANYTLS_PASSWORD=${PASS}
ANYTLS_SNI=${SNI}
ANYTLS_PRIVATE_KEY=${PRIVATE_KEY}
ANYTLS_PUBLIC_KEY=${PUBLIC_KEY}
ANYTLS_SHORTID=${SID}
EOF
    chmod 600 "$META_ANYTLS"
    _apply_config || return 1
    info "AnyTLS 配置完成"
    print_anytls
}

# ============== Hysteria2（独立官方服务，不走 sing-box） ==============
detect_hyst_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "hysteria-linux-amd64" ;;
        aarch64|arm64) echo "hysteria-linux-arm64" ;;
        armv7l|armv6l) echo "hysteria-linux-arm" ;;
        riscv64)       echo "hysteria-linux-riscv64" ;;
        s390x)         echo "hysteria-linux-s390x" ;;
        i386|i686)     echo "hysteria-linux-386" ;;
        *) return 1 ;;
    esac
}

hy_installed_ver() {
    [[ -x "$HY_BIN" ]] || return 1
    "$HY_BIN" version 2>/dev/null | head -1 | sed -E 's/.*v([0-9]+\.[0-9]+\.[0-9]+).*/\1/'
}

install_hysteria() {
    title "安装官方 Hysteria"
    if [[ -x "$HY_BIN" ]]; then
        info "已安装 Hysteria: $(hy_installed_ver || echo 未知)"; return 0
    fi
    local FN
    FN=$(detect_hyst_arch) || { error "不支持的架构: $(uname -m)"; return 1; }
    info "下载: https://download.hysteria.network/app/latest/${FN}"
    curl -fsSL --max-time 120 "https://download.hysteria.network/app/latest/${FN}" -o "$HY_BIN" || { error "下载失败"; return 1; }
    chmod +x "$HY_BIN"
    "$HY_BIN" version >/dev/null 2>&1 || { error "hysteria 二进制无法运行"; rm -f "$HY_BIN"; return 1; }
    info "hysteria 安装成功: $("$HY_BIN" version | head -1)"
}

update_hysteria_binary() {
    title "更新 Hysteria 官方二进制"
    [[ -x "$HY_BIN" ]] || { error "hysteria 未安装（先在菜单里配置 Hysteria2 节点）"; return 1; }
    local FN NEW OLD_VER NEW_VER
    FN=$(detect_hyst_arch) || { error "不支持的架构"; return 1; }
    NEW="${HY_BIN}.new"
    curl -fsSL --max-time 120 "https://download.hysteria.network/app/latest/${FN}" -o "$NEW" \
        || { error "下载新版本失败"; rm -f "$NEW"; return 1; }
    chmod +x "$NEW"
    "$NEW" version >/dev/null 2>&1 || { error "下载的不是有效二进制"; rm -f "$NEW"; return 1; }
    OLD_VER=$(hy_installed_ver)
    NEW_VER=$("$NEW" version 2>/dev/null | head -1 | sed -E 's/.*v([0-9]+\.[0-9]+\.[0-9]+).*/\1/')
    if [[ "$OLD_VER" == "$NEW_VER" ]]; then
        info "已是最新版本: ${NEW_VER}"; rm -f "$NEW"; return 0
    fi
    mv -f "$NEW" "$HY_BIN"; chmod +x "$HY_BIN"
    info "更新完成: ${OLD_VER:-旧} → ${NEW_VER:-新}"
    if has_hy2; then svc_restart "$HY_SERVICE" && info "hysteria 服务已重启"; fi
}

_gen_hy2_cert() {
    local SNI="$1"
    mkdir -p "$HY_DIR"
    if [[ -s "$HY_CERT_F" && -s "$HY_KEY_F" ]]; then
        warn "证书已存在，保留现有证书"; return 0
    fi
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$HY_KEY_F" -out "$HY_CERT_F" \
        -days 3650 -subj "/CN=${SNI}" \
        -addext "subjectAltName=DNS:${SNI}" >/dev/null 2>&1
    [[ -s "$HY_CERT_F" && -s "$HY_KEY_F" ]] || { error "证书生成失败"; return 1; }
    chmod 644 "$HY_CERT_F"; chmod 600 "$HY_KEY_F"
}

_start_hy2_service() {
    svc_exists "$HY_SERVICE" || write_service "$HY_SERVICE" "Hysteria2 server (official)" "$HY_BIN" "server -c ${HY_CONF}"
    svc_enable "$HY_SERVICE"
    svc_restart "$HY_SERVICE"
    sleep 2
    if svc_active "$HY_SERVICE"; then
        info "hysteria 服务运行中"; return 0
    fi
    error "hysteria 启动失败，查看日志: $(svc_log_hint "$HY_SERVICE")"
    return 1
}

init_hy2() {
    title "配置 Hysteria2（独立官方 hysteria，BBR 不限速）"
    load_meta
    local C PORT SNI PASS
    if has_hy2; then
        warn "Hysteria2 已存在，重新配置将覆盖并重启服务"
        read -rp "确认继续？[y/N]: " C
        [[ "$C" != "y" && "$C" != "Y" ]] && { warn "已取消"; return; }
    fi
    ask_port PORT "监听端口(UDP)" "$HY2_PORT_DEFAULT" udp "$HY2_PORT"
    read -rp "伪装域名（SNI）[默认 www.bing.com]: " SNI
    SNI=${SNI:-www.bing.com}
    PASS=$(openssl rand -hex 16)
    [[ -n "$PASS" ]] || { error "密码生成失败"; return 1; }

    install_deps || return 1
    install_hysteria || return 1
    _gen_hy2_cert "$SNI" || return 1

    cat > "$HY_CONF" <<EOF
listen: :${PORT}
obfs:
  type: salamander
  salamander:
    password: ${PASS}
ignoreClientBandwidth: false
congestion:
  type: bbr
auth:
  type: password
  password: ${PASS}
masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true

tls:
  cert: ${HY_CERT_F}
  key: ${HY_KEY_F}
EOF
    cat > "$META_HY2" <<EOF
HY2_PORT=${PORT}
HY2_SNI=${SNI}
HY2_PASSWORD=${PASS}
EOF
    chmod 600 "$META_HY2" "$HY_CONF"

    write_service "$HY_SERVICE" "Hysteria2 server (official)" "$HY_BIN" "server -c ${HY_CONF}"
    _start_hy2_service || return 1
    info "Hysteria2 配置完成（UDP ${PORT}）"
    print_hy2
}

remove_hy2() {
    has_hy2 || { error "Hysteria2 未启用"; return 1; }
    local C
    read -rp "确认移除 Hysteria2（停止并删除服务/配置/证书）？[y/N]: " C
    [[ "$C" != "y" && "$C" != "Y" ]] && { warn "已取消"; return; }
    remove_service "$HY_SERVICE"
    rm -rf "$HY_DIR"
    rm -f "$META_HY2"
    info "Hysteria2 已移除（二进制保留，可用菜单更新）"
}

# ============== 节点配置菜单 ==============
init_config() {
    title "节点配置"
    mkdir -p "$SBOX_DIR"
    load_meta
    local C MODE_SEL

    echo ""
    echo "当前节点状态："
    has_reality     && echo -e "  ${GREEN}✓${NC} Reality 已启用"     || echo -e "  ${RED}✗${NC} Reality 未启用"
    has_shadowsocks && echo -e "  ${GREEN}✓${NC} Shadowsocks 已启用" || echo -e "  ${RED}✗${NC} Shadowsocks 未启用"
    has_ws          && echo -e "  ${GREEN}✓${NC} WS+TLS 已启用"      || echo -e "  ${RED}✗${NC} WS+TLS 未启用"
    has_hy2         && echo -e "  ${GREEN}✓${NC} Hysteria2 已启用"   || echo -e "  ${RED}✗${NC} Hysteria2 未启用"
    has_anytls      && echo -e "  ${GREEN}✓${NC} AnyTLS 已启用"      || echo -e "  ${RED}✗${NC} AnyTLS 未启用"
    echo ""
    echo -e "  ${GREEN}1.${NC} 配置 VLESS + Reality"
    echo -e "  ${GREEN}2.${NC} 配置 Shadowsocks"
    echo -e "  ${GREEN}3.${NC} 配置 VLESS + WS + TLS"
    echo -e "  ${GREEN}4.${NC} 配置 Hysteria2"
    echo -e "  ${GREEN}5.${NC} 配置 AnyTLS"
    has_reality     && echo -e "  ${RED}10.${NC} 移除 Reality"
    has_shadowsocks && echo -e "  ${RED}11.${NC} 移除 Shadowsocks"
    has_ws          && echo -e "  ${RED}12.${NC} 移除 WS+TLS"
    has_hy2         && echo -e "  ${RED}13.${NC} 移除 Hysteria2"
    has_anytls      && echo -e "  ${RED}14.${NC} 移除 AnyTLS"
    echo -e "  ${GREEN}0.${NC}  返回"
    echo ""
    read -rp "选择: " MODE_SEL
    case "$MODE_SEL" in
        1)
            if has_reality; then
                warn "Reality 已存在，重新配置将覆盖"
                read -rp "确认？[y/N]: " C
                [[ "$C" != "y" && "$C" != "Y" ]] && return
            fi
            init_reality ;;
        2) init_shadowsocks ;;
        3)
            if has_ws; then
                warn "WS 已存在，重新配置将覆盖"
                read -rp "确认？[y/N]: " C
                [[ "$C" != "y" && "$C" != "Y" ]] && return
            fi
            init_ws_cf ;;
        4) init_hy2 ;;
        5) init_anytls ;;
        10) has_reality || { error "Reality 未启用"; return; }
            read -rp "确认移除 Reality？[y/N]: " C
            [[ "$C" != "y" && "$C" != "Y" ]] && return
            rm -f "$META_REALITY"; _apply_config; info "Reality 已移除" ;;
        11) has_shadowsocks || { error "SS 未启用"; return; }
            read -rp "确认移除 Shadowsocks？[y/N]: " C
            [[ "$C" != "y" && "$C" != "Y" ]] && return
            rm -f "$META_SS"; _apply_config; info "Shadowsocks 已移除" ;;
        12) has_ws || { error "WS 未启用"; return; }
            read -rp "确认移除 WS+TLS？[y/N]: " C
            [[ "$C" != "y" && "$C" != "Y" ]] && return
            rm -f "$META_WS"; _apply_config; info "WS+TLS 已移除" ;;
        13) remove_hy2 ;;
        14) has_anytls || { error "AnyTLS 未启用"; return; }
            read -rp "确认移除 AnyTLS？[y/N]: " C
            [[ "$C" != "y" && "$C" != "Y" ]] && return
            rm -f "$META_ANYTLS"; _apply_config; info "AnyTLS 已移除" ;;
        0) return ;;
        *) error "无效选择" ;;
    esac
}

# ============== 节点信息与链接 ==============
show_info() {
    title "节点信息与链接"
    load_meta

    local PUBLIC_IP LOAD_INFO MEM_INFO SWAP_INFO UPTIME_INFO
    PUBLIC_IP=$(get_public_ip)
    LOAD_INFO=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
    MEM_INFO=$(free -m 2>/dev/null | awk '/^Mem:/ {printf "%d/%dMB", $3, $2}')
    SWAP_INFO=$(free -m 2>/dev/null | awk '/^Swap:/ {printf "%d/%dMB", $3, $2}')
    UPTIME_INFO=$(uptime -p 2>/dev/null | sed 's/^up //')
    [[ -z "$UPTIME_INFO" ]] && UPTIME_INFO=$(uptime 2>/dev/null | sed -E 's/.*up +([^,]*(,[^,]*)?),.*user.*/\1/')

    if has_singbox_inbound; then
        echo -e "sing-box: $(svc_active "$SERVICE_NAME" && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}已停止${NC}")"
    fi
    echo -e "公网IP : ${PUBLIC_IP}"
    echo -e "负载   : ${LOAD_INFO:-N/A}  内存 ${MEM_INFO:-N/A}  交换 ${SWAP_INFO:-N/A}"
    echo -e "在线   : ${UPTIME_INFO:-N/A}"

    has_reality     && print_reality "$PUBLIC_IP"
    has_shadowsocks && print_ss "$PUBLIC_IP"
    has_ws          && print_ws
    has_hy2         && print_hy2 "$PUBLIC_IP"
    has_anytls      && print_anytls "$PUBLIC_IP"

    if ! has_reality && ! has_shadowsocks && ! has_ws && ! has_hy2 && ! has_anytls; then
        echo ""
        warn "尚未配置任何节点"
    fi
    echo ""
}

# ============== 更新管理脚本 ==============
update_script() {
    title "更新管理脚本"
    local TMP="/tmp/singbox_new.sh"
    info "正在从 GitHub 拉取最新版本..."
    rm -f "$TMP"
    if ! curl -fsSL --max-time 30 "$SCRIPT_URL" -o "$TMP" 2>/dev/null || [[ ! -s "$TMP" ]]; then
        error "下载失败（网络不通或地址不存在），请稍后重试"; rm -f "$TMP"; return
    fi
    if ! head -1 "$TMP" | grep -q "^#!/bin/bash"; then
        error "下载内容不是合法脚本，取消更新"; rm -f "$TMP"; return
    fi
    if ! bash -n "$TMP" 2>/dev/null; then
        error "脚本语法错误，取消更新"; rm -f "$TMP"; return
    fi
    cp "$TMP" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"
    rm -f "$TMP"
    info "脚本已更新，正在重新启动..."
    sleep 1
    exec bash "$SCRIPT_PATH"
}

# ============== 卸载 ==============
uninstall_sbox() {
    title "卸载 sing-box"
    local CONFIRM
    read -rp "确认卸载？将删除所有节点配置 [y/N]: " CONFIRM
    [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { warn "已取消"; return; }

    remove_service "$SERVICE_NAME"
    remove_service "$HY_SERVICE"
    rm -f "$SBOX_BIN" /usr/local/bin/sing-box /usr/bin/sing-box "$HY_BIN" "$SCRIPT_PATH" /usr/local/bin/c
    rm -rf "$SBOX_DIR" "$HY_DIR"

    echo ""
    echo "残留自检："
    local leftover=0 f
    for f in /usr/local/bin/sing-box /usr/bin/sing-box "$HY_BIN" "$SCRIPT_PATH" /usr/local/bin/c \
             "$SBOX_DIR" "$HY_DIR" /etc/systemd/system/sing-box.service /etc/systemd/system/hysteria-server.service \
             /etc/init.d/sing-box /etc/init.d/hysteria-server; do
        [[ -e "$f" ]] && { echo "  残留: $f"; leftover=1; }
    done
    [[ $leftover -eq 0 ]] && info "无残留，已完全卸载" || warn "存在残留，请手动处理"
    exit 0
}

# ============== 快捷命令 c ==============
install_shortcut() {
    local SELF
    SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
    if [[ "$SELF" != "$SCRIPT_PATH" ]]; then
        if [[ -f "$0" && "$0" != /proc/* && "$0" != /dev/fd/* ]]; then
            cat "$0" > "$SCRIPT_PATH" 2>/dev/null
        else
            curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH" 2>/dev/null
        fi
        if [[ ! -s "$SCRIPT_PATH" ]]; then
            warn "未能保存脚本到 ${SCRIPT_PATH}，快捷命令 c 不可用"; return 0
        fi
        chmod +x "$SCRIPT_PATH"
    fi
    cat > /usr/local/bin/c <<EOF
#!/bin/bash
exec bash ${SCRIPT_PATH} "\$@"
EOF
    chmod +x /usr/local/bin/c
    info "快捷命令已安装: c"
}

# ============== 主菜单 ==============
main_menu() {
    while true; do
        clear 2>/dev/null
        load_meta

        local MODE_STR="" SB_TXT HY_TXT
        has_reality     && MODE_STR="Reality"
        has_shadowsocks && MODE_STR="${MODE_STR:+$MODE_STR+}SS"
        has_ws          && MODE_STR="${MODE_STR:+$MODE_STR+}WS"
        has_hy2         && MODE_STR="${MODE_STR:+$MODE_STR+}HY2"
        has_anytls      && MODE_STR="${MODE_STR:+$MODE_STR+}AT"
        [[ -z "$MODE_STR" ]] && MODE_STR="未配置"

        SB_TXT="${YELLOW}未配置${NC}"
        if has_singbox_inbound; then
            svc_active "$SERVICE_NAME" && SB_TXT="${GREEN}● 运行中${NC}" || SB_TXT="${RED}● 已停止${NC}"
        fi
        HY_TXT=""
        if has_hy2; then
            svc_active "$HY_SERVICE" && HY_TXT="  HY2 ${GREEN}● 运行中${NC}" || HY_TXT="  HY2 ${RED}● 已停止${NC}"
        fi

        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  ${CYAN}节点控制台 (sing-box) ${VERSION}${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "  sing-box ${SB_TXT}${HY_TXT}"
        echo -e "  模式 ${YELLOW}${MODE_STR}${NC}   系统 ${INIT_SYS}"
        echo -e "${BLUE}──────────────────────────────────────${NC}"
        echo -e "  ${GREEN}1.${NC} 安装 sing-box 并配置节点"
        echo -e "  ${GREEN}2.${NC} 添加 / 移除协议节点"
        echo -e "  ${GREEN}3.${NC} 查看节点信息与链接"
        echo -e "${BLUE}──────────────────────────────────────${NC}"
        echo -e "  ${GREEN}4.${NC} 更新 sing-box"
        echo -e "  ${GREEN}5.${NC} 更新管理脚本"
        echo -e "  ${GREEN}6.${NC} 更新 Hysteria"
        echo -e "  ${GREEN}7.${NC} IPv4/IPv6 优先级"
        echo -e "  ${RED}8.${NC} 卸载 sing-box"
        echo -e "  ${GREEN}0.${NC} 退出"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -ne " 请选择 » "
        read -r OPT

        case "$OPT" in
            1) install_sbox && init_config ;;
            2) init_config ;;
            3) show_info ;;
            4) update_sbox ;;
            5) update_script ;;
            6) update_hysteria_binary ;;
            7) ip_priority_menu ;;
            8) uninstall_sbox ;;
            0) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *) warn "无效选项" ;;
        esac

        echo ""
        echo -ne "${BLUE}按 Enter 返回菜单...${NC}"
        read -r _
    done
}

# ============== 入口 ==============
main() {
    [[ $EUID -ne 0 ]] && { error "请用 root 运行此脚本"; exit 1; }

    # bash <(curl ...) 方式运行时 $0 是管道，先把脚本落地再执行
    if [[ ! -f "$0" || "$0" == /proc/* || "$0" == /dev/fd/* ]]; then
        mkdir -p "$(dirname "$SCRIPT_PATH")" 2>/dev/null
        if curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH" 2>/dev/null \
           && [[ -s "$SCRIPT_PATH" ]] && head -1 "$SCRIPT_PATH" | grep -q "^#!/bin/bash"; then
            chmod +x "$SCRIPT_PATH"
            exec bash "$SCRIPT_PATH" "$@"
        fi
    fi

    detect_init
    detect_pkg
    if [[ "$INIT_SYS" == "none" ]]; then
        error "未检测到 systemd 或 OpenRC，无法管理服务"; exit 1
    fi
    mkdir -p "$SBOX_DIR"
    detect_sbox_bin >/dev/null 2>&1 || true
    install_shortcut
    main_menu
}

# 被 source 时不执行（便于测试）
[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
