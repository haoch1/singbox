# singbox

Linux sing-box 多协议节点管理脚本，提供节点管理、服务控制和核心更新

管理脚本版本：`1.5.2`

## 安装

使用 `root` 在 Linux 系统执行，缺少的运行依赖由系统包管理器安装

```sh
(curl -LfsS https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -o /usr/local/bin/s || wget -q https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -O /usr/local/bin/s) && chmod +x /usr/local/bin/s && s
```

管理命令为 `s`。安装管理脚本不会自动安装核心；脚本优先使用已检测到的 sing-box，首次安装或更新核心使用菜单 `[9]` 或 `s --update`

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

### Hysteria2 端口跳跃

新建 Hysteria2 节点时设置跳跃端口与切换间隔，默认范围为 `20000-29999`，间隔为 `30` 秒，两项均可回车采用默认值。范围被已有节点或监听端口占用时，自动选取下一组可用的 10000 个端口。端口输入 `0` 关闭跳跃。已有节点通过 `[3] 修改节点` → `[5] 端口跳跃` 设置

跳跃所需的 nftables 按需安装，通过专用规则将 UDP 范围重定向至节点主端口，兼容 IPv4、IPv6。脚本自动维护规则及 systemd/OpenRC 启动恢复配置，direct 模式通过管理脚本启动或重启时恢复。云防火墙及上游 NAT 需要放行对应 UDP 范围

开启跳跃后的分享链接包含 `mport` 端口范围，可直接导入 Clash Verge。Clash Verge 的链接导入使用客户端默认 `30` 秒间隔；自定义间隔通过链接的 `hop_interval` 提供给支持该参数的客户端，Mihomo 配置对应 `hop-interval`

关闭跳跃、删除节点或清空节点时同步清理对应规则，最后一组规则移除后清理规则文件和启动恢复配置。仅操作脚本维护的 `inet singbox_hy2` 表，范围冲突或权限不足时显示错误并回滚

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

支持 systemd、OpenRC 和 direct 服务管理，配置变更经过校验与事务备份，应用失败时回滚。启动和重启在 systemd/OpenRC 下启用开机自启，停止时关闭自启

核心与管理脚本独立更新。菜单更新完成后按回车返回或加载最新脚本；交互输入支持 `q` / `Q` 取消，删除和卸载使用 `Y` / `N` 确认

仓库保留独立文件 `stats.py`，当前管理脚本不加载、安装或运行该文件

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

## 命令行

```sh
s                 # 打开管理菜单
s --update        # 安装或更新核心
s --update-script # 更新管理脚本
s --version       # 显示管理脚本版本
s --uninstall     # 卸载托管服务、节点和管理脚本
```

## 维护与卸载

文件日志在管理脚本启动时检查，sing-box 日志还在服务启动或重启前检查。活动日志超过 10 MB 时轮转，保留最近 5 MB 及最多 3 份归档；systemd 日志由 journald 管理。脚本启动时清理超过 24 小时的已知临时文件，配置和回滚备份保留

一键卸载验证服务归属，停止托管服务并取消自启，清理默认路径核心、配置、证书、备份、服务文件、独立日志、锁、临时文件和管理命令。配置损坏时可使用 `s --uninstall`；未识别文件、外部路径核心及系统共享依赖保留
