# singbox

面向 Linux VPS 的轻量 sing-box 管理脚本。当前版本提供 `VLESS + TCP + Reality + Vision` 节点的增删查改、服务控制和配置管理，脚本结构保留了后续扩展其他协议的空间。

当前管理脚本版本为 `0.2.0`

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
- Realm 风格单列交互，日志默认显示最近 20 行并可按 Ctrl+C 返回主菜单

## 一键安装

使用 `root` 执行：

```sh
(curl -LfsS https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -o /usr/local/bin/s || wget -q https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -O /usr/local/bin/s) && chmod +x /usr/local/bin/s && s
```

安装命令只下载管理脚本，不会自动下载 sing-box 核心。脚本启动时会先检查系统内已有的 `sing-box`，优先使用 PATH 中的核心，也会检查常见安装路径。

脚本会自动补齐 `curl`、`jq`、`tar`、`flock`、`ss` 等管理依赖。核心需要手动处理：

- 在菜单中选择 `[10] 安装/更新核心`
- 或执行 `s --update`

如果系统中没有核心，添加节点、启动、重启和配置检查会提示先完成核心安装。

## 管理菜单

```text
sing-box 管理（当前节点：0 个）
sing-box 状态：未安装
sing-box 版本：未安装
管理脚本版本：v0.2.0

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
[9]  查看实时日志

更新与维护
[10] 安装/更新核心
[11] 更新管理脚本
[12] 检查配置
[13] 一键卸载

[0]  退出脚本
```

添加节点时服务器地址会先尝试自动探测公网 IP，也可以手动填写域名或 IP。端口默认使用 `8443`，伪装域名默认使用 `www.bing.com`。修改节点时默认保留 UUID 和 Reality 凭据，需要更换凭据时可以选择重新生成。

查看节点会为每个节点显示序号，节点之间保留空行，只显示节点名称、协议、端口和 VLESS 链接，不生成聚合订阅。修改节点时直接回车保持原端口不会触发自身端口冲突提示，可以分别修改名称、客户端连接地址、监听端口、UUID、SNI 或重新生成 Reality 凭据。查看实时日志默认显示最近 20 行，按 `Ctrl+C` 返回主菜单。

## 文件

| 文件 | 用途 |
| --- | --- |
| `/usr/local/bin/s` | 管理脚本命令 |
| `/usr/local/bin/sing-box` | 默认核心安装路径 |
| `/usr/local/etc/sing-box/config.json` | sing-box 服务配置，包含私钥 |
| `/usr/local/etc/sing-box/nodes.json` | 节点元数据和客户端公开参数 |
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
