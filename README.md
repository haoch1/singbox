# singbox

一个面向 Linux VPS 的轻量 sing-box 管理脚本。第一版只管理 `VLESS + TCP + Reality + Vision`，菜单和交互风格参考 [haoch1/realm](https://github.com/haoch1/realm)，节点配置流程参考 [0xdabiaoge/singbox-lite](https://github.com/0xdabiaoge/singbox-lite)。

## 功能

- 节点增删查改和清空
- VLESS + TCP + Reality + Vision
- 默认端口 `8443`
- 默认伪装域名 `www.bing.com`
- 默认节点名 `VLESS-TCP-REALITY-VISION-端口`
- 自动生成 UUID、Reality 密钥和 Short ID
- 输出可复制的 `vless://` 链接
- systemd、Alpine OpenRC、无 init direct 模式
- sing-box 核心安装/更新
- 管理脚本更新
- 配置检查、实时日志和一键卸载

## 一键安装

```sh
(curl -LfsS https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -o /usr/local/bin/sb || wget -q https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh -O /usr/local/bin/sb) && chmod +x /usr/local/bin/sb && sb
```

脚本需要 root 权限，会自动安装 `bash`、`curl`、`jq`、`tar`、`flock`、`ss` 等依赖。第一次添加节点时才下载 sing-box 核心。

## 菜单

```text
节点管理
[1] 添加节点       [2] 查看节点
[3] 修改节点       [4] 删除节点
[5] 清空所有节点

服务管理
[6] 启动 sing-box  [7] 停止 sing-box
[8] 重启 sing-box  [9] 查看运行状态
[10] 查看实时日志

更新与维护
[11] 更新核心      [12] 更新管理脚本
[13] 检查配置      [14] 一键卸载

[0] 退出脚本
```

添加节点时服务器地址会先尝试自动探测公网 IP，也可以手动填写域名或 IP。修改节点默认保留 UUID 和 Reality 凭据；需要更换凭据时在修改流程中选择重新生成。

## 文件

| 文件 | 用途 |
| --- | --- |
| `/usr/local/bin/sb` | 管理脚本命令 |
| `/usr/local/bin/sing-box` | sing-box 核心 |
| `/usr/local/etc/sing-box/config.json` | sing-box 服务配置，包含私钥 |
| `/usr/local/etc/sing-box/nodes.json` | 节点元数据和客户端公开参数 |
| `/var/log/sing-box.log` | OpenRC/direct 日志 |

配置和元数据默认使用 `700/600` 权限，管理脚本通过文件锁避免并发修改。

## 命令行

```sh
sb                 # 打开菜单
sb --update        # 更新 sing-box 核心
sb --update-script # 更新管理脚本
sb --version       # 查看脚本版本
sb --uninstall     # 卸载
```

## 测试

在 Linux 环境执行：

```sh
bash tests/smoke.sh
```

测试会进行 Bash 语法检查、关键默认值检查、菜单选项检查和配置字段静态检查。若安装了 ShellCheck，也会自动运行 ShellCheck。

