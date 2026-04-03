#!/bin/bash
# VLESS 一键管理脚本 v6.1（完整版修复）

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

SSL_DIR="${XRAY_DIR}/ssl"

info(){ echo -e "${GREEN}[✓]${NC} $1"; }
warn(){ echo -e "${YELLOW}[!]${NC} $1"; }
error(){ echo -e "${RED}[✗]${NC} $1"; }
title(){ echo -e "\n${CYAN}$1${NC}"; }

[[ $EUID -ne 0 ]] && error "请用 root 运行" && exit 1

mkdir -p "$XRAY_DIR" "$SSL_DIR"
touch "$USER_DB"

# =========================
# 工具
# =========================
get_ip(){
curl -s4 ip.sb || curl -s4 ifconfig.me
}

has_reality(){ [[ -f "$META_REALITY" ]]; }
has_ws(){ [[ -f "$META_WS" ]]; }

# =========================
# 安装
# =========================
install_xray(){
title "安装 Xray"
if [[ -x "$XRAY_BIN" ]]; then warn "已安装"; return; fi
apt update -y
apt install -y curl unzip openssl python3
bash <(curl -Ls https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
}

# =========================
# Reality
# =========================
init_reality(){
KEY=$($XRAY_BIN x25519)
PRI=$(echo "$KEY"|awk '/Private/ {print $NF}')
PUB=$(echo "$KEY"|awk '/Public/ {print $NF}')

read -rp "端口[443]: " PORT
PORT=${PORT:-443}
read -rp "SNI[www.microsoft.com]: " SNI
SNI=${SNI:-www.microsoft.com}
SID=$(openssl rand -hex 4)

cat > "$META_REALITY" <<EOF
REALITY_PRIVATE_KEY=${PRI}
REALITY_PUBLIC_KEY=${PUB}
REALITY_PORT=${PORT}
REALITY_SNI=${SNI}
REALITY_SHORTID=${SID}
EOF

rebuild_config
restart_xray
info "Reality OK"
}

# =========================
# WS
# =========================
init_ws(){
read -rp "端口[443]: " PORT
PORT=${PORT:-443}
read -rp "域名: " DOMAIN
read -rp "路径[/vless]: " PATHX
PATHX=${PATHX:-/vless}

openssl req -x509 -nodes -newkey ec \
-pkeyopt ec_paramgen_curve:P-256 \
-keyout "$SSL_DIR/ws.key" \
-out "$SSL_DIR/ws.crt" \
-days 3650 \
-subj "/CN=${DOMAIN}" >/dev/null 2>&1

cat > "$META_WS" <<EOF
WS_PORT=${PORT}
WS_DOMAIN=${DOMAIN}
WS_PATH=${PATHX}
EOF

rebuild_config
restart_xray
info "WS OK"
}

# =========================
# 构建配置
# =========================
rebuild_config(){

INB=""

if has_reality; then
source "$META_REALITY"
INB="$INB
{\"port\":$REALITY_PORT,\"protocol\":\"vless\",\"settings\":{\"clients\":[],\"decryption\":\"none\"},
\"streamSettings\":{\"network\":\"tcp\",\"security\":\"reality\",
\"realitySettings\":{\"dest\":\"$REALITY_SNI:443\",\"serverNames\":[\"$REALITY_SNI\"],
\"privateKey\":\"$REALITY_PRIVATE_KEY\",\"shortIds\":[\"$REALITY_SHORTID\"]}},
\"tag\":\"reality\"},"
fi

if has_ws; then
source "$META_WS"
INB="$INB
{\"port\":$WS_PORT,\"protocol\":\"vless\",\"settings\":{\"clients\":[],\"decryption\":\"none\"},
\"streamSettings\":{\"network\":\"ws\",\"security\":\"tls\",
\"tlsSettings\":{\"certificates\":[{\"certificateFile\":\"$SSL_DIR/ws.crt\",\"keyFile\":\"$SSL_DIR/ws.key\"}]},
\"wsSettings\":{\"path\":\"$WS_PATH\",\"headers\":{\"Host\":\"$WS_DOMAIN\"}}},
\"tag\":\"ws\"},"
fi

INB="${INB%,}"

cat > "$XRAY_CONFIG" <<EOF
{
"log":{"loglevel":"warning"},
"inbounds":[${INB}],
"outbounds":[{"protocol":"freedom"}]
}
EOF
}

# =========================
# 用户
# =========================
add_user(){
title "添加用户"
read -rp "用户名: " NAME
UUID=$(cat /proc/sys/kernel/random/uuid)
EXPIRE=$(date -d "+30 days" +%F)

echo "$NAME:$UUID:$EXPIRE:active:both" >> "$USER_DB"

python3 - <<PY
import json
f="$XRAY_CONFIG"
cfg=json.load(open(f))
for i in cfg["inbounds"]:
 i["settings"]["clients"].append({"id":"$UUID"})
json.dump(cfg,open(f,"w"),indent=2)
PY

restart_xray
echo "UUID: $UUID"
}

# =========================
# 到期（已修复）
# =========================
check_expire(){
TODAY=$(date +%F)
while IFS=: read -r N U E S NODE; do
 [[ "$S" != "active" ]] && continue
 if [[ "$E" < "$TODAY" ]]; then
   warn "$N 到期"
   sed -i "s/^$N:$U:$E:active/$N:$U:$E:disabled/" "$USER_DB"
 fi
done < "$USER_DB"
}

# =========================
# BBR
# =========================
enable_bbr(){
title "BBR"
modprobe tcp_bbr
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p
info "BBR 已开启"
}

# =========================
# 测速（已恢复）
# =========================
network_test(){
title "网络测速"

declare -A TARGETS=(
["电信"]="v4-sc-ct.oojj.de:80"
["移动"]="v4-sc-cm.oojj.de:80"
)

for NAME in "${!TARGETS[@]}"; do
HOST=${TARGETS[$NAME]%%:*}
PORT=${TARGETS[$NAME]##*:}

TOTAL=0 COUNT=0 FAIL=0

for i in {1..20}; do
MS=$(curl -o /dev/null -s -w "%{time_connect}" http://$HOST:$PORT/)
if [[ $? -eq 0 ]]; then
MS_INT=$(python3 -c "print(int(float('$MS')*1000))")
TOTAL=$((TOTAL+MS_INT)); COUNT=$((COUNT+1))
else FAIL=$((FAIL+1)); fi
done

AVG=$((COUNT>0?TOTAL/COUNT:0))
LOSS=$((FAIL*100/20))

echo "$NAME 延迟:${AVG}ms 丢包:${LOSS}%"
done
}

# =========================
# 启动
# =========================
restart_xray(){
systemctl enable xray
systemctl restart xray
}

# =========================
# 查看节点
# =========================
show_info(){
title "节点信息"
has_reality && echo "Reality 已开启"
has_ws && echo "WS 已开启"
}

# =========================
# 菜单
# =========================
menu(){
while true; do
echo ""
echo "1 安装"
echo "2 Reality"
echo "3 WS"
echo "4 添加用户"
echo "5 查看节点"
echo "6 BBR"
echo "7 测速"
echo "0 退出"

read -rp "选择: " n

case $n in
1) install_xray ;;
2) init_reality ;;
3) init_ws ;;
4) add_user ;;
5) show_info ;;
6) enable_bbr ;;
7) network_test ;;
0) exit ;;
esac
done
}

menu
