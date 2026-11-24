# VLESS 智能节点控制台 (sing-box)

一键安装、配置、管理 sing-box 节点的脚本，支持 Debian 11/12/13 和 Alpine。

## 一键安装

```bash
bash <(curl -sL https://raw.githubusercontent.com/chenege-ck/vless-manager/main/a)
```

第一次运行会显示功能简介和警告，回车或 Y 确认安装，装完直接进协议配置；已装过的机器直接进菜单。装好后敲 `c` 随时进菜单。

## 能做什么

- **建节点**：VLESS Reality、Shadowsocks、VLESS + WS + TLS、Hysteria2、AnyTLS
- **管用户**：新建、删除、禁用、启用、续期、列表，到期自动禁用
- **看链接**：每个用户的分享链接、节点运行信息
- **系统维护**：更新脚本、IPv4/IPv6 优先级、一键卸载

## 说明

- 需 root 运行。
- 首次建 VLESS 时自动创建用户（到期 999 天），并直接打印 Reality 链接。
- VLESS 默认端口 443，回车或 Y 确认，也可直接输其他端口。
- VLESS + WS 需域名 + CF 优选 IP；AnyTLS 需设备支持 sing-box 内核。


