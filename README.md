# singbox

Linux sing-box 多协议节点管理脚本，提供节点管理、服务控制、核心更新和本地流量统计

管理脚本版本：`1.3.8`

## 安装

使用 `root` 在 Linux 系统执行，缺少的运行依赖由系统包管理器安装

```sh
(curl -LfsS https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -o /usr/local/bin/s || wget -q https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -O /usr/local/bin/s) && chmod +x /usr/local/bin/s && s
```

管理命令为 `s`。安装管理脚本不会自动安装核心；脚本优先使用已检测到的 sing-box，首次安装或更新核心使用菜单 `[10]` 或 `s --update`

## 协议与节点

| 协议 | 默认配置 | 默认端口 | 默认节点名称 |
| --- | --- | --- | --- |
| Vless | TCP、Reality、Vision | `443/TCP` | `Vless-端口` |
| Shadowsocks 2022 | `2022-blake3-aes-128-gcm` | `8080/TCP、UDP` | `SS2022-端口` |
| AnyTLS | 自签名 TLS、核心默认填充方案 | `443/TCP` | `AnyTLS-端口` |
| Hysteria2 | 自签名 TLS、Salamander 混淆 | `8080/UDP` | `Hysteria2-端口` |

支持节点的添加、查看、分项修改、删除和清空。服务器地址支持 IPv4、IPv6 和域名，端口与节点名称均可自定义；端口冲突按 TCP、UDP 分别检查。Vless 默认伪装域名为 `www.bing.com`

UUID、Reality 密钥、Short ID、密码和 TLS 证书由脚本自动生成。Hysteria2、AnyTLS 需要 sing-box 1.12.0 或更新版本，Hysteria2 需要核心包含 QUIC 支持

Hysteria2、AnyTLS 的默认 SNI 取创建时的服务器地址，每个节点使用有效期 10 年的独立自签名证书，证书和私钥内嵌于 `config.json`。分享链接包含 `insecure=1`，Hysteria2 另含 `pinSHA256` 指纹；客户端按其支持的参数执行证书校验

新建 Hysteria2 节点自动生成独立的 Salamander 混淆密码。节点编辑保留现有证书、SNI 和混淆设置。服务器防火墙和 NAT 映射需放行对应端口及传输协议

生成 `vless://`、`ss://`、`anytls://`、`hysteria2://` 单节点分享链接，支持 IPv6 地址格式化和参数 URI 编码

## 管理菜单

| 编号 | 操作 |
| --- | --- |
| 1 | 添加节点 |
| 2 | 查看节点 |
| 3 | 修改节点 |
| 4 | 删除节点 |
| 5 | 清空节点 |
| 6 | 流量统计 |
| 7 | 启动 sing-box |
| 8 | 停止 sing-box |
| 9 | 重启 sing-box |
| 10 | 安装/更新核心 |
| 11 | 更新管理脚本 |
| 12 | 一键卸载 |
| 0 | 退出脚本 |

支持 systemd、OpenRC 和 direct 服务管理，配置变更经过校验与事务备份，应用失败时回滚。启动和重启在 systemd/OpenRC 下启用开机自启，停止时关闭自启

核心与管理脚本独立更新。菜单更新完成后按回车返回或加载最新脚本；交互输入支持 `q` / `Q` 取消，删除和卸载使用 `Y` / `N` 确认

## 本地流量统计

统计默认关闭，通过菜单 `[6]` 开启，提供查看、开启、停止、清空和卸载操作。独立组件 `stats.py` 使用 Python 3.9 或更新版本及标准库 SQLite，需要 sing-box 1.14.0 或更新版本

首次开启会配置带随机密钥的本机 API 和域名识别规则，并重启托管服务。API 仅监听 `127.0.0.1`，默认端口 `9090`，冲突时可指定其他端口；Web 面板关闭。API 监听与采集进程相互独立，菜单显示实际采集状态，开启中断后可重试并复用本组件的接口

systemd/OpenRC 使用独立统计服务，direct 模式在管理脚本运行时恢复已开启的采集。SQLite 按节点和域名/IP 保存上传流量、下载流量及连接数量；日期记录按 365 天保留期清理，累计汇总保留至清空或卸载

### 查询

菜单 `[6] → [1]` 选择今日、昨日、本月、最近 30 天、全部累计或自定义日期，再选择节点；节点输入留空时查询全部节点

```sh
s --stats today
s --stats all --limit 1000
s --stats month --node 1
s --stats all --target example.com
s --stats custom --start 2026-11-01 --end 2026-11-02
```

默认按流量排序显示前 20 个目标，命令行 `--limit` 支持 `1–1000`。`--node` 支持节点序号、名称或 tag，`--target` 筛选指定域名及子域名或 IP。流量显示为 `B / KB / MB / GB / TB`，按 1024 逐级换算

统计覆盖开启采集后的代理有效载荷，域名通过 HTTP、TLS、QUIC 嗅探获取，无法识别时按目标 IP 汇总。结果是累计统计，不是逐连接历史访问日志，也不包含 HTTPS 完整 URL 或系统其他程序的流量；采集停止或异常期间可能产生记录缺口

停止采集保留历史数据并撤销本组件的 API 与域名识别规则，卸载统计删除其服务、设置和数据库。删除节点保留对应历史统计，主脚本一键卸载同时清理统计组件

## 默认路径

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/s` | 管理脚本 |
| `/usr/local/bin/sing-box` | 托管核心 |
| `/usr/local/etc/sing-box/config.json` | 核心配置及 TLS 证书、私钥 |
| `/usr/local/etc/sing-box/nodes.json` | 节点元数据 |
| `/usr/local/etc/sing-box/stats.py` | 统计组件 |
| `/usr/local/etc/sing-box/stats/settings.json` | 统计设置 |
| `/usr/local/etc/sing-box/stats/traffic.db` | 统计数据库 |
| `/etc/systemd/system/sing-box.service` | systemd 核心服务 |
| `/etc/systemd/system/singbox-stats.service` | systemd 统计服务 |
| `/etc/init.d/sing-box` | OpenRC 核心服务 |
| `/etc/init.d/singbox-stats` | OpenRC 统计服务 |
| `/var/log/sing-box.log` | OpenRC/direct 核心日志 |
| `/var/log/singbox-stats.log` | OpenRC/direct 统计日志 |

## 命令行

```sh
s                 # 打开管理菜单
s --update        # 安装或更新核心
s --update-script # 更新管理脚本
s --stats all     # 查询全部时间范围的累计统计
s --version       # 显示管理脚本版本
s --uninstall     # 卸载托管服务、节点、统计组件和管理脚本
```

## 维护与卸载

文件日志在管理脚本启动时检查，sing-box 日志还在服务启动或重启前检查。活动日志超过 10 MB 时轮转，保留最近 5 MB 及最多 3 份归档；systemd 日志由 journald 管理。脚本启动时清理超过 24 小时的已知临时文件，配置和回滚备份保留

一键卸载验证服务归属，停止托管服务并取消自启，清理默认路径核心、配置、证书、备份、统计数据、服务文件、独立日志、锁、临时文件和管理命令。配置损坏时可使用 `s --uninstall`；未识别文件、外部路径核心及系统共享依赖保留
