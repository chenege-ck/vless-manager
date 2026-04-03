#!/bin/bash

XRAY_CONFIG="/usr/local/etc/xray/config.json"
USER_DB="/usr/local/etc/xray/users.db"
XRAY_BIN="/usr/local/bin/xray"

mkdir -p /usr/local/etc/xray
touch $USER_DB

green(){ echo -e "\033[32m$1\033[0m"; }

get_ip(){
curl -s4 ip.sb || curl -s4 ifconfig.me
}

# ================= 安装 =================
install_xray(){
bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)
}

# ================= BBR =================
enable_bbr(){
modprobe tcp_bbr
cat >> /etc/sysctl.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl -p
green "BBR 已开启"
}

# ================= 证书 =================
gen_cert(){
mkdir -p /usr/local/etc/xray/ssl
openssl req -x509 -nodes -newkey rsa:2048 \
-keyout /usr/local/etc/xray/ssl/key.pem \
-out /usr/local/etc/xray/ssl/cert.pem \
-days 3650 \
-subj "/CN=bing.com"
}

# ================= Reality =================
init_reality(){
read -p "端口(默认443): " PORT
PORT=${PORT:-443}

KEY=$($XRAY_BIN x25519)
PRIVATE=$(echo "$KEY"|grep Private|awk '{print $2}')
PUBLIC=$(echo "$KEY"|grep Public|awk '{print $2}')
SHORTID=$(openssl rand -hex 4)

cat > $XRAY_CONFIG <<EOF
{
"inbounds":[
{
"port":$PORT,
"protocol":"vless",
"settings":{"clients":[],"decryption":"none"},
"streamSettings":{
"network":"tcp",
"security":"reality",
"realitySettings":{
"dest":"www.microsoft.com:443",
"serverNames":["www.microsoft.com"],
"privateKey":"$PRIVATE",
"shortIds":["$SHORTID"]
}
}
}
],
"outbounds":[{"protocol":"freedom"}]
}
EOF

systemctl restart xray
green "Reality 完成"

echo ""
echo "公钥: $PUBLIC"
}

# ================= WS =================
init_ws(){
read -p "监听端口: " PORT
read -p "WS路径(默认/vless): " PATH
PATH=${PATH:-/vless}

gen_cert

cat > $XRAY_CONFIG <<EOF
{
"inbounds":[
{
"port":$PORT,
"protocol":"vless",
"settings":{"clients":[],"decryption":"none"},
"streamSettings":{
"network":"ws",
"security":"tls",
"tlsSettings":{
"certificates":[
{
"certificateFile":"/usr/local/etc/xray/ssl/cert.pem",
"keyFile":"/usr/local/etc/xray/ssl/key.pem"
}
]
},
"wsSettings":{
"path":"$PATH"
}
}
}
],
"outbounds":[{"protocol":"freedom"}]
}
EOF

systemctl restart xray
green "WS 完成"
}

# ================= 添加用户（已加分享链接） =================
add_user(){
read -p "用户名: " NAME
read -p "天数: " DAYS

UUID=$(cat /proc/sys/kernel/random/uuid)
EXPIRE=$(date -d "+$DAYS days" +%F)

echo "$NAME:$UUID:$EXPIRE" >> $USER_DB

python3 <<EOF
import json
cfg=json.load(open("$XRAY_CONFIG"))
for i in cfg["inbounds"]:
    i["settings"]["clients"].append({"id":"$UUID"})
json.dump(cfg,open("$XRAY_CONFIG","w"),indent=2)
EOF

systemctl restart xray

IP=$(get_ip)

green "用户已添加"
echo "UUID: $UUID"
echo "到期: $EXPIRE"

# ===== 自动判断模式输出链接 =====
if grep -q reality $XRAY_CONFIG; then
PBK=$(grep privateKey $XRAY_CONFIG | awk -F '"' '{print $4}' | xargs -I{} $XRAY_BIN x25519 -i {} 2>/dev/null | grep Public | awk '{print $2}')
SID=$(grep shortIds -A1 $XRAY_CONFIG | tail -n1 | tr -d ' ",[]')

echo ""
echo "===== Reality 链接 ====="
echo "vless://${UUID}@${IP}:443?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${PBK}&sid=${SID}&type=tcp&flow=xtls-rprx-vision#${NAME}"
fi

if grep -q wsSettings $XRAY_CONFIG; then
PORT=$(grep '"port"' $XRAY_CONFIG | head -n1 | grep -o '[0-9]\+')
PATH=$(grep '"path"' $XRAY_CONFIG | head -n1 | awk -F '"' '{print $4}')

echo ""
echo "===== WS 链接 ====="
echo "vless://${UUID}@${IP}:${PORT}?type=ws&security=tls&path=${PATH}&encryption=none#${NAME}"
fi
}

# ================= 删除 =================
del_user(){
read -p "用户名: " NAME
UUID=$(grep "^$NAME:" $USER_DB|cut -d: -f2)

sed -i "/^$NAME:/d" $USER_DB

python3 <<EOF
import json
cfg=json.load(open("$XRAY_CONFIG"))
for i in cfg["inbounds"]:
    i["settings"]["clients"]=[c for c in i["settings"]["clients"] if c["id"]!="$UUID"]
json.dump(cfg,open("$XRAY_CONFIG","w"),indent=2)
EOF

systemctl restart xray
green "已删除"
}

# ================= 卸载 =================
uninstall(){
systemctl stop xray
bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) remove
rm -rf /usr/local/etc/xray
green "已卸载"
}

# ================= 快捷命令 =================
install_c(){
cat > /usr/local/bin/c <<EOF
#!/bin/bash
bash <(curl -Ls 你的github地址)
EOF
chmod +x /usr/local/bin/c
}

# ================= 菜单 =================
menu(){
while true;do
clear
echo "1 安装"
echo "2 Reality"
echo "3 WS"
echo "4 加用户"
echo "5 删用户"
echo "6 BBR"
echo "7 卸载"
echo "0 退出"
read -p "选: " n

case $n in
1) install_xray ;;
2) init_reality ;;
3) init_ws ;;
4) add_user ;;
5) del_user ;;
6) enable_bbr ;;
7) uninstall ;;
0) exit ;;
esac

read -p "回车继续"
done
}

install_c
menu
