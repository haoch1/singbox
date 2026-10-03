# singbox

Linux sing-box 节点管理脚本，提供节点管理、服务控制、核心更新和卸载功能

管理脚本版本：`1.2.8`

## 功能

- VLESS + TCP + Reality + Vision
- Shadowsocks 2022，使用 `2022-blake3-aes-128-gcm`
- 节点的添加、查看、修改、删除、清空和分享链接生成
- UUID、Reality 密钥、Short ID 和 Shadowsocks 密码生成
- systemd / OpenRC / direct 服务管理
- 配置校验、事务备份和失败回滚

VLESS 默认端口为 `8443`，默认 SNI 为 `www.bing.com`；Shadowsocks 2022 默认端口为 `8388`

## 安装

适用于 Linux 系统，使用 `root` 执行。脚本需要 Bash，缺少的运行依赖由系统包管理器安装

```sh
(curl -LfsS https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -o /usr/local/bin/s || wget -q https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -O /usr/local/bin/s) && chmod +x /usr/local/bin/s && s
```

管理命令为 `s`。安装管理脚本不会自动安装 sing-box 核心。已有核心由脚本探测；未安装时，使用菜单 `[9]` 或 `s --update` 安装

## 管理菜单

| 编号 | 操作 |
| --- | --- |
| 1 | 添加节点 |
| 2 | 查看节点 |
| 3 | 修改节点 |
| 4 | 删除节点 |
| 5 | 清空所有节点 |
| 6 | 启动 sing-box |
| 7 | 停止 sing-box |
| 8 | 重启 sing-box |
| 9 | 安装/更新核心 |
| 10 | 更新管理脚本 |
| 11 | 一键卸载 |
| 0 | 退出脚本 |

核心更新完成后按回车返回菜单；管理脚本更新完成后按回车加载脚本。交互输入支持 `q` / `Q` 取消，删除和卸载确认支持 `Y` / `N`

## 文件路径

以下为默认路径

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/s` | 管理脚本 |
| `/usr/local/bin/sing-box` | 托管核心 |
| `/usr/local/etc/sing-box/config.json` | 核心配置 |
| `/usr/local/etc/sing-box/nodes.json` | 节点元数据 |
| `/etc/systemd/system/sing-box.service` | systemd 服务 |
| `/etc/init.d/sing-box` | OpenRC 服务 |
| `/run/sing-box/sing-box.pid` | direct 进程记录 |
| `/var/log/sing-box.log` | OpenRC/direct 日志 |
| `/run/lock/singbox-manager.lock` | 管理锁 |
| `/run/lock/singbox-manager.pid` | 管理进程记录 |

## 命令行

```sh
s                 # 打开管理菜单
s --update        # 安装或更新 sing-box 核心
s --update-script # 更新管理脚本
s --version       # 显示管理脚本版本
s --uninstall     # 卸载托管服务、节点和管理脚本
```

## 卸载与维护

卸载前验证服务归属、停止服务并取消自启，清理默认路径核心、配置、备份、服务及自启文件、独立日志、锁、临时文件和管理命令。清理失败时报告具体路径，管理命令在其他清理完成后删除。配置损坏时仍可使用 `s --uninstall`

管理目录中的未识别文件保留并提示。外部路径的核心、其他项目文件及系统共享依赖保留

OpenRC/direct 日志在脚本启动、服务启动和重启时检查：活动日志超过 10 MiB 时轮转，保留最近 5 MiB 及最多 3 份轮转文件。脚本启动时清理超过 24 小时的已知临时文件，配置与回滚备份不参与自动清理。systemd 日志由 journald 管理，卸载不清理共享 journal
