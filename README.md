# singbox

面向 Linux VPS 的轻量 sing-box 节点管理脚本，支持 VLESS + Reality + Vision 和 Shadowsocks 2022

当前管理脚本版本：`1.2.2`

## 功能

- 添加、查看、修改、删除和清空节点
- 支持 VLESS + Reality + Vision
- 支持 Shadowsocks 2022，固定加密方式为 `2022-blake3-aes-128-gcm`
- 自动生成 UUID、Reality 密钥、Short ID 和 Shadowsocks 2022 密码
- 输出 VLESS 和 Shadowsocks 2022 节点链接
- 保留 `::` 双栈入站，不限制代理流量的 IPv4 或 IPv6 出站
- 支持 systemd、OpenRC 和 direct 服务管理
- 支持 sing-box 核心安装更新、管理脚本更新和一键卸载
- OpenRC/direct 日志自动轮转，启动时清理过期临时文件

## 安装

使用 `root` 执行：

```sh
(curl -LfsS https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -o /usr/local/bin/s || wget -q https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -O /usr/local/bin/s) && chmod +x /usr/local/bin/s && s
```

安装脚本不会自动下载核心。核心需要通过菜单 `[9] 安装/更新核心` 或 `s --update` 手动安装

首次运行会自动迁移旧配置，移除旧的 IPv4 出站限制并保留现有节点、端口和凭据

## 管理菜单

```text
sing-box 管理（当前节点：0 个）
sing-box 状态：未安装
sing-box 版本：未安装
管理脚本版本：v1.2.2

基础功能
[1]  添加节点
[2]  查看节点
[3]  修改节点
[4]  删除节点
[5]  清空所有节点

服务管理
[6]  启动 sing-box
[7]  停止 sing-box
[8]  重启 sing-box

更新与维护
[9]  安装/更新核心
[10] 更新管理脚本
[11] 一键卸载

[0]  退出脚本
```

## 主要路径

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/s` | 管理脚本命令 |
| `/usr/local/bin/sing-box` | 默认核心路径 |
| `/usr/local/etc/sing-box/config.json` | sing-box 配置 |
| `/usr/local/etc/sing-box/nodes.json` | 节点元数据 |
| `/var/log/sing-box.log` | OpenRC/direct 日志 |

## 命令行

```sh
s                 # 打开管理菜单
s --update        # 安装或更新 sing-box 核心
s --update-script # 更新管理脚本
s --version       # 查看管理脚本版本
s --uninstall     # 卸载 sing-box
```

一键卸载只清理本项目创建的配置、核心、服务、日志、锁、临时文件和管理命令
