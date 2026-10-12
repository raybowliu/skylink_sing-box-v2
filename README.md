# SKYBYTE Manager V2.1

基于 Bash 的 Ubuntu/Debian VPS 管理工具，提供简体中文和 English 界面。

YouTube：[SKYBYTE9119](https://www.youtube.com/@SKYBYTE9119) · [English](README_EN.md)

主菜单包含 SKYBYTE ASCII logo；菜单绿色加粗、节点链接红色加粗、警告黄色加粗、错误红色加粗。支持 ANSI 的交互终端显示颜色，`NO_COLOR=1` 可关闭。所有 `YES` 确认不区分大小写。

## 安装入口

需要 root、Ubuntu/Debian、systemd 和公网 IPv4；支持 x86_64/arm64。保留 `install.sh` 一键入口：

```bash
curl -fsSL https://raw.githubusercontent.com/skylink9119/sing-box-v2/main/install.sh -o install.sh
sudo bash install.sh
```

开发分支未合并时，上述命令仍安装 main 版本。测试当前分支可先克隆仓库并切换到对应分支，再运行 `sudo bash ./singbox-v2.sh`。建议先审阅下载的脚本。

脚本安装 sing-box 官方稳定版二进制，按 GitHub Release API 的 SHA-256 摘要检查下载，不执行远程软件包安装脚本。首次启动选择语言，保存于 `/etc/singbox-v2/language.conf`，菜单 **21** 切换语言。

**已有节点配置、状态、sing-box 二进制、服务或对应端口占用时，安装会拒绝覆盖。** 普通管理与更新不会重建 UUID、密码和配置。新协议部署使用 TCP 443 / UDP 443；云防火墙需另行设置。

## 菜单与功能

| 菜单 | 功能 |
| --- | --- |
| 1 / 2 / 3 | VLESS + Reality + Vision / Hysteria2 / 双协议 |
| 4 / 5 | 节点链接 / 本地订阅导出 |
| 6 / 7 | UFW 安装、启停、规则管理 / UDP 规则检查 |
| 8 | 服务状态、启动、停止、重启、开机自启、配置检查 |
| 9 | vnStat VPS 网卡每日、每月流量和实时网速 |
| 10 | BBR + FQ；先检查内核是否支持 BBR |
| 11 | HY2 IPv4 UDP 端口跳跃，专属 nftables 表与 systemd 服务 |
| 12 / 13 | 手动更新 / 可选每周自动更新 |
| 14 / 15 | 配置、证书、二进制备份 / 确认后恢复 |
| 16 / 17 / 18 | IP 信息 / 基础网络诊断 / 日志 |
| 19 / 20 / 21 | 法律隐私声明 / 新服务器初始化 / 语言切换 |
| 22 | HY2 / 小火箭连接诊断：配置、服务、实际 UDP 端口、证书和 UFW |

初始化更新 apt 索引、升级软件、安装常用工具，检查时间同步、DNS、HTTPS、SSH 和 UFW。保留已有运行中的时间同步服务；不自动开启 UFW、改变 SSH 端口、设置 BBR 或重启。系统升级可能重启相关服务，应保留 VPS 控制台。

开启 UFW 前，从 sshd 监听、`sshd -T` 和当前 `SSH_CONNECTION` 识别 SSH 端口，再要求人工核实；已识别端口与确认端口均会放行。同时按实际配置放行协议端口与已启用的 HY2 跳跃范围。菜单 7 检查 UDP 443 和跳跃范围规则；复杂 UFW 规则可能需要人工判断，无法读取云安全组。

vnStat 显示 **VPS 网卡总流量**，不能当作 Reality/HY2 各自流量；历史统计从 vnStat 开始采集时起算。

## HY2 与安全证书验证

HY2 可以选择：

- **无域名自动自签名**：生成带公网 IPv4 SAN 的证书，默认有效期 365 天。客户端必须信任对应公开证书。
- **已有 TLS 证书**：输入证书域名、完整证书链和私钥路径。安装检查有效期、域名/IP 和私钥是否匹配；证书还须能在客户端建立可信证书链。不会改写提供的文件。

服务端密码与客户端密码保持一致，URI 对特殊字符进行编码。保持 TLS 验证开启；自签名证书不受客户端系统默认信任，单独复制 URI 不能解决信任问题。

菜单 5 导出：

| 文件 | 使用方式 |
| --- | --- |
| `nodes.txt` / `subscription-base64.txt` | Shadowrocket、v2rayN 等支持相应协议的客户端；导入后核实 TLS 信任设置 |
| `mihomo-proxies.yaml` | Mihomo/OpenClash 配置片段，合并 `proxies` 及自签名所需的 `tls.custom-certifactes`（字段拼写为上游格式） |
| `outbounds.json` | 包含 `outbounds` 的 sing-box JSON 配置片段；合并到已有客户端配置 |
| `hy2-client-ca.pem` | 自签名部署的公开证书，供手动建立信任 |
| `hy2-client-ca.cer` / `hy2-client-ca.mobileconfig` | DER 公开证书 / iOS 信任描述文件；描述文件仅为 CA 证书生成，需手动安装并启用信任 |
| `subscription-notes.txt` | 信任说明、证书 SHA-256 指纹及跳跃提示 |

协议从实际 `config.json` 自动识别。自签名 sing-box JSON 内嵌公开证书；Mihomo YAML 内嵌信任证书并提供指纹，`skip-cert-verify: false`。HY2 URI 包含 `insecure=0` 和自签名证书指纹，但不同客户端是否支持 URI 指纹、私有 CA 和跳跃字段存在差异。

Shadowrocket/v2rayN 使用自签名证书时：通过可信 SSH/SFTP 通道取回 `hy2-client-ca.pem`，在服务器运行 `openssl x509 -in /etc/sing-box/hy2-selfsigned.crt -noout -fingerprint -sha256` 并通过可信通道核对指纹；按客户端/所用核心支持的方式导入信任证书，保持证书验证开启。无法配置可信 CA 的客户端应使用受信任 CA 签发的已有证书。**不要传输或导入服务端私钥。**

导出文件包含节点凭据，目录 700、文件 600，仅保存在 `/etc/singbox-v2/`，不部署公共 HTTP 订阅服务。不要上传公共仓库或粘贴进公开 issue。证书续期/替换后重启服务；自签名证书更换后重新导出并更新客户端信任。

## 端口跳跃、更新与恢复

节点信息按协议逐个显示，并用虚线隔开；订阅文件仍保留原始 URI 格式。

**“无域名”不等于“无证书”。** 默认链接保留 `insecure=0`；只导入链接并不能建立自签名证书信任。TLS 开启也不表示信任已建立。

iPhone 可安装导出的 `hy2-client-ca.mobileconfig`，再进入 **设置 → 通用 → 关于本机 → 证书信任设置**，手动开启该证书的完全信任。只安装从自己 VPS 经可信 SSH/SFTP 通道取得、指纹一致的证书。描述文件增加系统根证书信任，停用后可删除；不包含节点密码或服务端私钥。已有证书不是 CA 时不会生成根证书描述文件，也不会替换已有服务端证书。系统信任能否被小火箭的 HY2 实现采用，需要用实际连接日志验证；不支持时使用受信任 CA 证书。参考 [Apple 手动信任证书说明](https://support.apple.com/en-us/102390)。

菜单 **22** 检查配置、服务、实际 UDP 监听和证书，并提供只读抓包命令。本机 UDP 正常监听不能证明云防火墙或手机网络已放行 UDP。小火箭应测试实际连接或 URL，普通 ICMP 延迟不能验证 HY2。

HY2 跳跃默认关闭，范围限制为 1024–65535、最多 10001 个端口，只操作 `ip singbox_v2_hop` 专属表。开启时检查现有表冲突，使用 systemd 持久化 IPv4 UDP 转发到 443，并放行已启用的 UFW。sing-box/Mihomo 导出包含跳跃范围与 30 秒间隔，普通 URI 保留基本端口；云防火墙仍需放行范围。关闭后不擅自删除可能被其他应用使用的 UFW 规则，必要时人工清理。

更新先备份，再下载并检查候选二进制，配置检查通过后替换、重启并检查服务状态；启动失败恢复旧二进制。手动更新需要确认，每周自动更新默认关闭，时间为**服务器时区周日 04:00**，最多随机延迟 15 分钟。服务状态不等于端到端可达。

新备份使用 `config/`、`state.json`、`sing-box.bin` 独立路径，包含已有外部证书/私钥的快照。恢复前备份当前配置，失败尝试回滚。恢复后关闭托管跳跃并更新状态，需要时重新开启；不会替换其他 nftables 表。旧版目录/二进制同名备份格式不能直接恢复。备份不自动删除，请保护磁盘空间和私钥。

## 测试与范围

```bash
bash -n install.sh singbox-v2.sh
shellcheck install.sh singbox-v2.sh
python3 -m unittest discover -s tests -v
```

设置 `SING_BOX_BIN`、`MIHOMO_BIN` 后，测试包含实际 sing-box 三种服务端配置检查、Mihomo YAML 检查，以及 sing-box/Mihomo 客户端连接 HY2 服务端的本地转发。Mihomo 测试需要 PyYAML。凭据与证书在临时目录运行时生成，不提交仓库。

GitHub Actions 在 Ubuntu 24.04 和 Debian 12 容器执行检查。详见 [审计与测试记录](docs/TESTING.md)。本地握手不能代替真实 VPS 的云防火墙、UDP NAT、systemd 启动和 Shadowrocket/v2rayN 图形客户端导入测试；这些项目须在有快照和控制台的 VPS 上验证。

## 隐私、法律与参考

仅供合法网络技术学习和服务器管理，遵守当地法律及服务条款。安装、更新和可选诊断会访问 GitHub、api.ipify.org、ipinfo.io 等第三方，第三方可看到来源 IP；无开发者遥测，不上传节点凭据。报告本地保存，30 天后清理。软件按现状提供，部署前备份。

- [sing-box HY2](https://sing-box.sagernet.org/configuration/outbound/hysteria2/)
- [sing-box TLS](https://sing-box.sagernet.org/configuration/shared/tls/)
- [Hysteria URI 格式](https://v2.hysteria.network/docs/developers/URI-Scheme/)
- [Mihomo TLS](https://wiki.metacubex.one/en/config/proxies/tls/)
