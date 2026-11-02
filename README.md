# singbox

Linux sing-box 节点管理脚本，提供节点管理、本地流量统计、服务控制、核心更新和卸载功能

管理脚本版本：`1.3.7`

## 功能与协议

- Vless
- Shadowsocks 2022，使用 `2022-blake3-aes-128-gcm`
- AnyTLS，使用核心默认流量填充方案
- Hysteria2
- 节点的添加、查看、修改、删除、清空和分享链接生成
- UUID、Reality 密钥、Short ID、密码和 TLS 自签名证书生成
- systemd / OpenRC / direct 服务管理
- 配置校验、事务备份和失败回滚
- 按节点、域名/IP 和日期查询流量记录，SQLite 本地存储

| 协议 | 默认监听端口 | 默认节点名称 |
| --- | --- | --- |
| Vless | `443/TCP` | `Vless-端口` |
| Shadowsocks 2022 | `8080/TCP、UDP` | `SS2022-端口` |
| AnyTLS | `443/TCP` | `AnyTLS-端口` |
| Hysteria2 | `8080/UDP` | `Hysteria2-端口` |

监听端口支持自定义，空输入采用表中默认值。端口冲突按 TCP、UDP 分别检查；现有节点的端口保持不变。Vless 默认 SNI 为 `www.bing.com`

## TLS 节点

Hysteria2、AnyTLS 使用 sing-box 1.12.0 或更新版本；Hysteria2 需要包含 QUIC 支持的核心。官方标准构建包含所需功能

节点创建仅需服务器地址、监听端口和节点名称，三项均提供默认值。密码使用 32 字节随机数据，以 64 位十六进制字符串保存。TLS SNI 初始值采用服务器地址，每个节点由核心独立生成有效期为 10 年的自签名证书及私钥

证书与私钥内嵌于 `config.json`，随节点删除或卸载清理。分享链接包含 `insecure=1`，客户端不执行常规证书信任链校验；Hysteria2 链接另含 `pinSHA256` 证书指纹，支持该参数的客户端可执行指纹校验

修改菜单包含节点名称、客户端连接地址、监听端口和密码。密码支持自定义或随机生成；节点编辑保留现有证书及 SNI

新建 Hysteria2 节点默认启用 Salamander 混淆，独立生成 32 字节随机混淆密码，并将 `obfs=salamander`、`obfs-password` 写入分享链接。节点编辑保留混淆设置；已有未启用混淆的节点不自动变更。未启用端口跳跃或固定带宽

TLS 节点不使用 ACME 申请证书。服务器防火墙及 NAT 映射应与实际监听端口和传输协议一致，Hysteria2 的监听端口使用 UDP

## 分享链接

输出 `vless://`、`ss://`、`hysteria2://`、`anytls://` 单节点链接，支持 IPv4、IPv6 地址及名称、密码的 URI 编码。SS2022 使用 `Base64(method:password)` 格式；Hysteria2 链接包含证书指纹及实际启用的混淆参数

链接用于支持对应协议的客户端单节点导入，不是订阅地址或完整配置文件

## 安装

适用于 Linux 系统，使用 `root` 执行。脚本需要 Bash，缺少的运行依赖由系统包管理器安装

```sh
(curl -LfsS https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -o /usr/local/bin/s || wget -q https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -O /usr/local/bin/s) && chmod +x /usr/local/bin/s && s
```

管理命令为 `s`。安装管理脚本不会自动安装 sing-box 核心。已有核心由脚本探测；未安装时，使用菜单 `[10]` 或 `s --update` 安装

## 管理菜单

| 编号 | 操作 |
| --- | --- |
| 1 | 添加节点 |
| 2 | 查看节点 |
| 3 | 修改节点 |
| 4 | 删除节点 |
| 5 | 清空所有节点 |
| 6 | 流量统计 |
| 7 | 启动 sing-box |
| 8 | 停止 sing-box |
| 9 | 重启 sing-box |
| 10 | 安装/更新核心 |
| 11 | 更新管理脚本 |
| 12 | 一键卸载 |
| 0 | 退出脚本 |

核心更新完成后按回车返回菜单；管理脚本更新完成后按回车加载脚本。交互输入支持 `q` / `Q` 取消，删除和卸载确认支持 `Y` / `N`

## 本地流量统计

菜单 `[6]` 提供查询、开启、停止、清空和卸载操作。统计组件独立维护于 `stats.py`，首次进入时安装至管理目录；需要包含 SQLite 支持的 Python 3.9 或更新版本，不使用第三方 Python 包。统计默认关闭，开启时要求 sing-box 1.14.0 或更新版本，并应用配置及重启托管服务

采集使用带随机密钥的内核 API，仅绑定 `127.0.0.1`，默认端口 `9090`，冲突时可另选端口。Web 面板关闭，不提供公网统计入口。systemd/OpenRC 下由独立服务管理采集进程，direct 模式随管理脚本启动恢复采集

API 由 sing-box 内核监听，与采集进程独立运行；端口监听不代表正在记录流量。菜单按采集进程和连接状态显示结果，开启流程中断时可再次选择“开启统计”，复用本组件已配置的接口

记录上传、下载字节数和连接次数，支持按节点、域名/IP、今日、昨日、本月、最近 30 天或自定义日期查询。每日记录保留 365 天，总累计保留至清空或卸载。节点改名沿用原有统计，已删除节点的历史记录仍可查询

域名通过 HTTP、TLS、QUIC 嗅探获取，无法识别时按目标 IP 记录，不记录 HTTPS 完整 URL、页面内容或系统其他程序的流量。统计为代理有效载荷计数，不等同于网卡或运营商计费流量；采集停止、核心重启或异常断连可能产生记录缺口，开启前的流量无法追溯

停止统计保留历史数据并撤销本组件的 API 和嗅探配置，卸载统计删除其服务、数据库和设置。主脚本一键卸载同时清理统计组件

## 文件路径

以下为默认路径

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/s` | 管理脚本 |
| `/usr/local/bin/sing-box` | 托管核心 |
| `/usr/local/etc/sing-box/config.json` | 核心配置及自动生成的 TLS 证书、私钥 |
| `/usr/local/etc/sing-box/nodes.json` | 节点元数据 |
| `/usr/local/etc/sing-box/stats.py` | 独立统计组件 |
| `/usr/local/etc/sing-box/stats/` | 统计设置与 SQLite 数据库 |
| `/etc/systemd/system/singbox-stats.service` | systemd 统计服务 |
| `/etc/init.d/singbox-stats` | OpenRC 统计服务 |
| `/var/log/singbox-stats.log` | OpenRC/direct 统计日志 |
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
s --stats today   # 今日全部节点流量
s --stats all --node 1 --target example.com
s --stats custom --start 2026-11-01 --end 2026-11-02
```

## 卸载与维护

卸载前验证服务归属、停止服务并取消自启，清理默认路径核心、配置、备份、服务及自启文件、独立日志、锁、临时文件和管理命令。清理失败时报告具体路径，管理命令在其他清理完成后删除。配置损坏时仍可使用 `s --uninstall`

管理目录中的未识别文件保留并提示。外部路径的核心、其他项目文件及系统共享依赖保留

OpenRC/direct 日志在脚本启动、服务启动和重启时检查：活动日志超过 10 MiB 时轮转，保留最近 5 MiB 及最多 3 份轮转文件。脚本启动时清理超过 24 小时的已知临时文件，配置与回滚备份不参与自动清理。systemd 日志由 journald 管理，卸载不清理共享 journal
