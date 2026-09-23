# singbox

面向 Linux VPS 的轻量 sing-box 管理脚本，支持 VLESS + Reality + Vision 和 Shadowsocks 2022 节点管理

当前管理脚本版本：`1.2.1`

实现边界、兼容性约束和优化说明见 [ABOUT.md](ABOUT.md)。

## 功能

- VLESS 默认监听端口 `8443`，默认伪装域名 `www.bing.com`
- Shadowsocks 2022 默认监听端口 `8388`
- Shadowsocks 2022 固定使用 `2022-blake3-aes-128-gcm`
- 自动生成协议凭据并输出对应节点链接
- VLESS 和 Shadowsocks 2022 保留 `::` 双栈入站，使用系统 DNS（可配合 aktools 等 DNS 解锁工具），代理目标和 Reality 握手只使用 IPv4 解析；IPv6 目标会被拒绝
- 支持 systemd、Alpine OpenRC 和无 init 环境
- 支持两种协议的添加、查看、修改、删除、清空、分享链接和服务管理
- 支持核心安装更新、管理脚本更新和卸载；事务失败会保留恢复备份并恢复服务状态
- OpenRC/direct 日志超过 10 MiB 时自动轮转，保留最近 5 MiB 和最多 3 个轮转文件
- 启动时清理超过 24 小时的更新临时文件，不删除配置和节点数据

## 实现约束与运行特性

- 配置写入采用临时文件、校验、原子替换和失败回滚流程；`config.json`、`nodes.json`、服务单元及服务状态在事务中保持一致。
- 命令行参数、菜单选项、提示文本、返回码、文件路径和 JSON 字段保持兼容；脚本不引入运行时第三方库。
- 节点字段在一次 `jq` 调用中以 NUL 分隔读取；节点输入校验已拒绝控制字符，因此不会改变受支持节点的字段边界。
- 临时文件清理在单次 `find` 遍历中完成；菜单宽度计算在同一进程内完成 ANSI 控制序列剥离和字符宽度计算。
- 以上优化只改变内部实现，不改变协议参数、配置结构、服务管理策略、异常处理路径或外部命令调用接口。

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
管理脚本版本：v1.2.1

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

添加节点时选择 VLESS + Reality + Vision 或 Shadowsocks 2022 协议。旧版 `nodes.json` 中没有 `protocol` 字段的节点按 VLESS + Reality + Vision 处理。卸载只清理本项目创建的 sing-box 配置、核心、服务、日志、锁、临时文件和管理命令，系统预先存在的外部核心和共享依赖会保留

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
