# singbox

面向 Linux VPS 的轻量 sing-box 管理脚本，当前支持 `VLESS + TCP + Reality + Vision` 节点增删查改、服务管理和配置检查

当前管理脚本版本：`1.0.6`

## 功能

- 默认监听端口 `8443`，默认伪装域名 `www.bing.com`
- 自动生成 UUID、Reality 密钥和 Short ID，并输出 `vless://` 节点链接
- 支持 systemd、Alpine OpenRC 和无 init 环境
- 支持核心安装更新、管理脚本更新、日志查看、配置检查和卸载
- OpenRC/direct 日志超过 10 MiB 时自动轮转，保留最近 5 MiB 和最多 3 个轮转文件
- 启动时清理超过 24 小时的更新临时文件，不删除配置和节点数据

## 安装

使用 `root` 执行：

```sh
(curl -LfsS https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -o /usr/local/bin/s || wget -q https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -O /usr/local/bin/s) && chmod +x /usr/local/bin/s && s
```

安装命令只下载管理脚本，不会自动安装 sing-box 核心。脚本会先检查系统内已有核心，并自动补齐 `curl`、`jq`、`tar`、`flock`、`ss` 等管理依赖。核心需要通过菜单 `[9] 安装/更新核心` 或 `s --update` 手动处理

## 管理菜单

```text
sing-box 管理（当前节点：0 个）
sing-box 状态：未安装
sing-box 版本：未安装
管理脚本版本：v1.0.6

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
[11] 查看实时日志
[12] 检查配置
[13] 一键卸载

[0]  退出脚本
```

日志默认显示最近 20 行，按 `Ctrl+C` 返回主菜单。卸载只清理本项目创建的 sing-box 配置、核心、服务、日志、锁、临时文件和管理命令，系统预先存在的外部核心和共享依赖会保留

## 主要路径

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/s` | 管理脚本命令 |
| `/usr/local/bin/sing-box` | 默认核心安装路径 |
| `/usr/local/etc/sing-box/config.json` | 服务配置 |
| `/usr/local/etc/sing-box/nodes.json` | 节点元数据 |
| `/var/log/sing-box.log` | OpenRC/direct 日志 |

## 命令行

```sh
s                 # 打开菜单
s --update        # 手动安装或更新 sing-box 核心
s --update-script # 更新管理脚本
s --version       # 查看脚本版本
s --uninstall     # 卸载 sing-box
```
