# singbox

Linux sing-box 多协议节点管理脚本，提供节点管理、服务控制和核心更新

管理脚本版本：`1.5.0`

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

端口跳跃按节点设置，默认关闭。开启后，核心继续监听节点原有的 UDP 端口，脚本通过 `nftables` 将所选 UDP 范围转发到该端口。只修改跳跃设置时无需重启核心，现有单端口链接仍可使用

首次使用时，在服务器已用于启动和完整重载的 nftables 配置中，于现有 `flush ruleset` 之后加入下列引用。默认检查 `/etc/nftables.conf`，也可用 `SINGBOX_NFT_CONFIG` 指定实际加载的配置文件。使用通配符是为了让没有跳跃节点时也能正常加载

```nft
include "/usr/local/etc/sing-box/hy2-hopping*.nft"
```

通过 `[3] 修改节点` 选择 Hysteria2 节点，再选择 `[5] 端口跳跃`。例如输入 `20000-20099`，间隔回车采用 `30` 秒，输入 `0` 可关闭。云防火墙或上游 NAT 需放行该 UDP 范围，并继续允许原监听端口供单端口客户端使用

`[2] 查看节点` 单独显示跳跃参数，客户端按下表设置，密码、证书和混淆参数沿用原节点

| 客户端 | 端口范围 | 切换间隔 |
| --- | --- | --- |
| sing-box | `server_ports: ["20000:20099"]` | `hop_interval: "30s"` |
| Mihomo | `ports: "20000-20099"` | `hop-interval: 30` |

sing-box 客户端设置 `server_ports` 时可移除原有的 `server_port`。普通客户端继续使用单端口链接

跳跃范围不能与其他 UDP 入站、监听端口、已有跳跃范围或转发规则重叠。遇到无法安全判断的外部 NAT 规则时，脚本会拒绝启用。关闭、删除节点或卸载时仅清理脚本维护的规则。`inet singbox_hy2` 表由脚本专用

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
| `/usr/local/etc/sing-box/hy2-hopping.nft` | 启用 Hy2 端口跳跃时生成的 nftables 规则 |
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
