# singbox

面向 Linux VPS 的轻量 sing-box 管理脚本。当前版本提供 `VLESS + TCP + Reality + Vision` 节点的增删查改、服务控制和配置管理，脚本结构保留了后续扩展其他协议的空间。

当前管理脚本版本为 `0.3.2`

## 功能

- 节点增删查改和清空
- VLESS + TCP + Reality + Vision
- 默认监听端口 `8443`
- 默认伪装域名 `www.bing.com`
- 默认节点名 `VLESS-TCP-REALITY-VISION-端口`
- 自动生成 UUID、Reality 密钥和 Short ID
- 输出可复制的 `vless://` 链接
- 支持 systemd、Alpine OpenRC 和无 init 环境
- sing-box 核心安装、更新和配置检查
- 管理脚本更新、实时日志和一键卸载
- Realm 端口转发快捷入口，沿用 Realm 原项目路径和代码
- Realm 风格单列交互，日志默认显示最近 20 行并可按 Ctrl+C 返回主菜单

## 一键安装

使用 `root` 执行：

```sh
(curl -LfsS https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -o /usr/local/bin/s || wget -q https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -O /usr/local/bin/s) && chmod +x /usr/local/bin/s && s
```

安装命令只下载管理脚本，不会自动下载 sing-box 核心。脚本启动时会先检查系统内已有的 `sing-box`，优先使用 PATH 中的核心，也会检查常见安装路径。

脚本会自动补齐 `curl`、`jq`、`tar`、`flock`、`ss` 等管理依赖。核心需要手动处理：

- 在菜单中选择 `[10] 安装/更新核心`
- 在菜单中选择 `[6] 端口转发` 可安装并打开 Realm 管理脚本
- 或执行 `s --update`

如果系统中没有核心，添加节点、启动、重启和配置检查会提示先完成核心安装。

## 管理菜单

```text
sing-box 管理（当前节点：0 个）
sing-box 状态：未安装
sing-box 版本：未安装
管理脚本版本：v0.3.2

基础功能
[1]  添加节点
[2]  查看节点
[3]  修改节点
[4]  删除节点
[5]  清空所有节点
[6]  端口转发

服务管理
[7]  启动 sing-box
[8]  停止 sing-box
[9]  重启 sing-box

更新与维护
[10] 安装/更新核心
[11] 更新管理脚本
[12] 查看实时日志
[13] 检查配置
[14] 一键卸载

[0]  退出脚本
```

默认监听端口为 `8443`，默认伪装域名为 `www.bing.com`，节点名格式为 `VLESS-TCP-REALITY-VISION-端口`。查看节点只显示摘要和 VLESS 链接，日志默认显示最近 20 行，按 `Ctrl+C` 返回菜单。`[6]` 使用 `/usr/local/bin/r` 进入 Realm，首次使用会自动安装管理脚本。`[14]` 会同时清理两个项目创建的服务、配置、核心、备份、日志、锁、临时文件和管理命令，系统预先存在的外部核心和共享依赖会保留。

## 文件

| 文件 | 用途 |
| --- | --- |
| `/usr/local/bin/s` | 管理脚本命令 |
| `/usr/local/bin/sing-box` | 默认核心安装路径 |
| `/usr/local/bin/r` | Realm 端口转发管理脚本 |
| `/usr/local/etc/sing-box/config.json` | sing-box 服务配置，包含私钥 |
| `/usr/local/etc/sing-box/nodes.json` | 节点元数据和客户端公开参数 |
| `/root/realm` | Realm 核心、规则和备份目录 |
| `/var/log/sing-box.log` | OpenRC/direct 日志 |

配置和元数据默认使用 `700/600` 权限，管理脚本通过文件锁避免并发修改。

## 命令行

```sh
s                 # 打开菜单
s --update        # 手动安装或更新 sing-box 核心
s --update-script # 更新管理脚本
s --version       # 查看脚本版本
s --uninstall     # 卸载
```
