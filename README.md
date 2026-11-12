# singbox

Linux sing-box 节点管理脚本，支持 Vless、Shadowsocks 2022、AnyTLS、Hysteria2、Snell 和端口跳跃，提供服务控制与核心更新

管理脚本版本：`2.0.0`

## 安装与运行

脚本运行于 Linux，需使用 Bash 并具有 root 权限。所需依赖通过系统包管理器安装

```sh
(curl -LfsS https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -o /usr/local/bin/s || wget -q https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -O /usr/local/bin/s) && chmod +x /usr/local/bin/s && s
```

安装后使用 `s` 打开管理菜单。管理脚本与 sing-box 核心独立安装和更新，核心通过菜单 `[9] 安装/更新核心` 或 `s --update` 安装。系统已有核心时，脚本优先复用检测到的路径

## 支持协议

| 协议 | 默认配置 | 默认端口（文档示例） | 默认节点名称 |
| --- | --- | --- | --- |
| Vless | TCP、Reality、Vision | `1080/TCP` | `Vless-端口` |
| Shadowsocks 2022 | `2022-blake3-aes-128-gcm` | `8080/TCP、UDP` | `SS2022-端口` |
| AnyTLS | 自签名 TLS、核心默认填充方案 | `1080/TCP` | `AnyTLS-端口` |
| Hysteria2 | 自签名 TLS、Salamander 混淆 | `8080/UDP` | `Hysteria2-端口` |
| Snell | v5 入站、自动生成 PSK | `1080/TCP` | `Snell-端口` |

提供节点添加、查看、分项修改、删除和清空功能。连接地址支持 IPv4、IPv6 和域名，监听端口与节点名称可自定义，端口冲突按 TCP、UDP 分别检查。查看节点显示编号、摘要和分享链接

Vless 默认伪装域名为 `www.bing.com`。UUID、Reality 密钥、Short ID、节点密码和 TLS 证书由脚本生成

Hysteria2、AnyTLS 使用有效期 10 年的独立自签名证书，SNI 取创建时的服务器地址。证书和私钥内嵌于 `config.json`。分享链接包含 `insecure=1`，Hysteria2 另携带 `pinSHA256` 证书指纹，实际校验行为由客户端支持情况及配置决定

Hysteria2、AnyTLS 要求 sing-box 1.12.0 或更新版本，Hysteria2 还要求核心包含 QUIC 支持。新建 Hysteria2 节点自动生成独立的 Salamander 混淆密码

Snell 要求 sing-box 1.14.0 或更新版本，入站和分享链接统一使用 v5 参数，TCP 和 UDP 代理流量均通过 TCP 连接传输。添加节点时设置连接地址、监听端口与节点名称，PSK 自动生成。修改节点提供名称、地址、端口和 PSK 四项设置

脚本生成 `vless://`、`ss://`、`anytls://`、`hysteria2://`、`snell://` 单节点分享链接，支持 IPv6 地址格式化和 URI 参数编码。服务器防火墙、云防火墙及上游 NAT 需要允许相应端口与传输协议

### Snell 客户端配置

Clash/Mihomo 使用 `version: 5` 和 `udp: true`。Clash Verge 2.5.8、2.5.10 的链接解析器尚未支持 `snell://`，可在本地订阅配置中添加以下节点，地址、端口与 PSK 按节点链接填写

```yaml
proxies:
  - name: Snell
    type: snell
    server: server.example.com
    port: 1080
    psk: "替换为节点 PSK"
    version: 5
    udp: true
```

## Hysteria2 端口跳跃

新建 Hysteria2 节点默认启用端口跳跃，添加流程提供以下两项设置，回车采用默认值

| 设置 | 默认值 |
| --- | --- |
| 跳跃端口 | `20000-29999/UDP` |
| 切换间隔 | `30` 秒 |

端口输入 `0` 关闭跳跃。已有节点通过 `[3] 修改节点` → `[5] 端口跳跃` 调整。默认范围与已有节点或监听端口重叠时，脚本在预设分组中选择另一组可用的 10000 个端口，并校验 UDP 转发规则冲突

nftables 按需安装，通过专用 `inet singbox_hy2` 表将跳跃范围重定向至节点主监听端口，同时处理 IPv4、IPv6。脚本自动维护 systemd/OpenRC 启动恢复配置，direct 模式通过管理脚本启动或重启时恢复规则。云防火墙及上游 NAT 需允许实际使用的 UDP 范围

分享链接通过 `mport` 携带跳跃范围，Clash Verge 导入后使用客户端默认的 30 秒切换间隔。链接另通过 `hop_interval` 提供自定义间隔，供支持该参数的客户端使用。Mihomo 原生配置对应 `ports` 和 `hop-interval`

## 管理菜单

| 编号 | 操作 |
| --- | --- |
| 1 | 添加节点 |
| 2 | 查看节点 |
| 3 | 修改节点 |
| 4 | 删除节点 |
| 5 | 清空节点 |
| 6 | 启动 sing-box |
| 7 | 停止 sing-box |
| 8 | 重启 sing-box |
| 9 | 安装/更新核心 |
| 10 | 更新管理脚本 |
| 11 | 一键卸载 |
| 0 | 退出脚本 |

服务管理支持 systemd、OpenRC 和 direct 模式。systemd/OpenRC 下，启动和重启会启用开机自启，停止会关闭自启。配置变更经过校验与事务备份，应用失败时尝试恢复原配置和服务状态

sing-box 与 Realm 管理脚本采用相同的菜单编号与交互约定：

- 添加、修改、服务控制和核心更新完成后显示结果，按回车返回菜单。节点修改保存后按回车返回修改菜单，可继续修改其他项
- 单项删除选择序号后立即执行，输入提示注明“选中即删除”；仅清空全部和卸载保留一次 `[y/N]` 确认，回车或 `n` 取消，输入错误时重新提示
- 输入 `q` / `Q` 取消当前操作并返回主菜单，在主菜单输入 `q` / `Q` 退出；序号选择时输入 `0` 或直接回车返回
- 操作结果和分享链接停留显示，按回车返回，回到主菜单时清屏。进入修改菜单时保留主菜单内容。选择返回或取消直接回到上级菜单。更新管理脚本成功后按回车加载新版并清屏

## 默认路径

| 路径 | 用途 |
| --- | --- |
| `/usr/local/bin/s` | 管理脚本 |
| `/usr/local/bin/sing-box` | 托管核心 |
| `/usr/local/etc/sing-box/config.json` | 核心配置及 TLS 证书、私钥 |
| `/usr/local/etc/sing-box/nodes.json` | 节点元数据 |
| `/usr/local/etc/sing-box/hy2-hopping.nft` | Hy2 端口跳跃规则 |
| `/etc/systemd/system/sing-box.service` | systemd 核心服务 |
| `/etc/init.d/sing-box` | OpenRC 核心服务 |
| `/var/log/sing-box.log` | OpenRC/direct 核心日志 |

systemd 下，启用端口跳跃后还会生成 `/etc/systemd/system/sing-box.service.d/50-singbox-hy2.conf`。OpenRC 的规则恢复钩子写入托管的服务脚本

## 命令行

```sh
s                 # 打开管理菜单
s --update        # 安装或更新核心
s --update-script # 更新管理脚本
s --version       # 显示管理脚本版本
s --help          # 显示命令行帮助
s --uninstall     # 卸载托管服务、节点和管理脚本
```

## 维护与清理

- 管理脚本启动、服务启动或重启时检查文件日志，超过 10 MB 时执行轮转，活动日志保留最近 5 MB，最多保留 3 份归档。systemd 日志由系统 journald 管理
- 管理脚本启动时清理超过 24 小时的已知下载和配置临时文件。失败事务的 `.recovery.*` 恢复备份保留
- 删除节点时清理入站配置、元数据、内嵌证书、私钥及关联跳跃规则。最后一组跳跃规则删除后，清理对应规则文件和启动恢复配置。共享日志、历史恢复备份和手动备份按各自策略保留
- 执行一键卸载时，脚本验证服务归属，停止托管服务并关闭自启，清理默认托管核心、配置、内嵌证书、已知备份、服务文件、跳跃规则、独立日志、锁、临时文件和管理命令。外部路径核心、系统共享依赖及未识别文件采用保留策略

配置文件损坏时，可通过 `s --uninstall` 执行卸载。云防火墙规则由对应云平台维护
