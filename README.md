# sing-box V2.0 双协议管理器（测试候选版）

**状态：本地 Bash 语法通过；尚未在真实 Debian/Ubuntu VPS 上做端到端安装、节点连通性、升级回滚测试。请先在全新、可快照恢复的测试 VPS 使用，不建议直接部署生产节点。**

## 环境与启动

支持 Ubuntu/Debian、root、systemd、x86_64/arm64（取决于官方发行包）。准备一个指向服务器公网 IP 的域名和该域名的**可信 TLS 证书与私钥 PEM 文件**，用于 HY2；Reality 无须自有域名。云防火墙需放行 TCP 443、UDP 443，开启跳跃时还需相应 UDP 范围。先确认 SSH 端口开放。

上传 `singbox-v2.sh` 到 VPS：

```bash
chmod 700 singbox-v2.sh
sudo bash ./singbox-v2.sh
```

**注意**：本工具拒绝覆盖现存 `/etc/sing-box/config.json`、由本工具生成的状态或正在占用的 443 端口。第一次安装需阅读法律与隐私声明并输入 YES。官方 sing-box 安装器会安装程序/软件包并创建 service；本工具为全新安装覆盖创建一个明确调用 `/usr/local/bin/sing-box` 的服务单元，原有安装绝不要尝试。

## 新增：新服务器初始化（菜单 14）

首次登录全新 Ubuntu/Debian VPS 后运行脚本，选择 **14 新服务器初始化**。明确输入 `YES` 后，使用 apt 更新软件索引、升级已安装软件并安装常见诊断工具（包括 curl、openssl、ca-certificates、ufw、chrony、iproute2、dnsutils、mtr、jq、git、python3、util-linux、nftables 等）；检查时间同步、GitHub DNS/HTTPS、SSH 监听和 UFW 状态。**不自动启用防火墙、不改 SSH 端口、不设置 BBR、不执行 reboot。** 但系统升级本身可能升级 SSH、内核等服务，请预先做 VPS 快照、保持服务商控制台可用。时间同步尽可能沿用现有服务，避免强制切换。若检查失败，报告错误而不强行修改 DNS。该功能可重复运行，但每次都需手动确认。

## 功能范围

- Reality/Vision TCP 443 + HY2 UDP 443。
- HY2 默认**不跳过证书验证**。客户端使用域名作 SNI，但可以连接 VPS IP。
- 节点 URI、sing-box 出站 JSON **片段**导出，保存在 `/etc/singbox-v2/`。导出文件不是完整的 sing-box 配置；Mihomo YAML、二维码、远程订阅还未实现。
- BBR+FQ 可选；将影响全局 TCP 配置。
- HY2 IPv4 UDP 跳跃可选、默认关闭，nftables 专属表由 systemd 服务持久化；默认范围建议 20000–30000。须在客户端单独填写 `server_ports` 与 `hop_interval=30s`，并放行服务商安全组。关闭跳跃后如使用 UFW，范围放行规则须自行删除。
- 手动/每周自动更新：官方稳定版，备份、配置检查、启动检查、尝试回滚。**无法验证端到端客户端握手；无法保证全部安装器副作用可回滚。开启之前请做 VPS 快照。**
- 简单 IP 信息检查：访问 ipinfo.io，并保存本地 JSON；不是 IP 风险评估或流媒体解锁测试。基础网络测试只检查路由、DNS、HTTPS 延迟与端口监听，并**不提供 UDP 丢包/三网回程/吞吐量实测**。
- 报告本地目录 `/etc/singbox-v2/reports`，30 天自动删除；备份不自动删除。
- 法律与隐私披露在菜单中查看；不向作者服务器上传任何配置或遥测。第三方服务会看到请求来源 IP。

## 重要限制与安全提醒

- 第三方安装器属于远程代码执行；建议阅读 https://sing-box.sagernet.org/installation/package-manager/ 和下载脚本源码再运行。
- 安装过程会更改 systemd unit 和 UFW 443 放行规则，仅适合全新 VPS。请提前备份/快照。
- 官方安装脚本升级时可能改变包文件和 service，二进制回滚不等于完全回滚软件包。需要先在测试机验证。
- 如果你的证书通过 ACME 自动续期，更新证书后可能需要重启 sing-box 才能读取新 PEM。
- 端口跳跃和 DNS 检查仅面向 IPv4；多协议、多用户、云防火墙等复杂场景需要人工适配。
- 不能保证所有 Shadowrocket / v2rayN / OpenClash / Mihomo 版本都支持对应 URI，跨客户端应核对字段。

## 参考官方文档

- https://sing-box.sagernet.org/configuration/inbound/vless/
- https://sing-box.sagernet.org/configuration/inbound/hysteria2/
- https://sing-box.sagernet.org/configuration/outbound/hysteria2/
- https://sing-box.sagernet.org/configuration/shared/tls/
- https://sing-box.sagernet.org/installation/package-manager/

法律声明：仅供合法学习和服务器管理用途，遵守当地法律和服务条款。软件按现状提供；这不排除依法不可免除的责任。

## 双语界面 / Bilingual interface

首次交互式运行会显示 `1 简体中文 / 2 English`。选择保存在 `/etc/singbox-v2/language.conf`，文件权限为 `600`；以后自动沿用该设置。主菜单 **15** 可随时切换语言。定时自动更新不会停下来询问语言。中文、英文主菜单、法律/隐私声明、主要确认提示与初始化流程均支持切换。**当前仍有部分原始功能的诊断信息、少数错误提示和第三方命令输出保持原始语言；尚不能称为 100% 全界面翻译。**

升级旧版脚本时，语言设置文件与 sing-box 节点配置相互独立，不会更改 UUID、密码和端口。此版本仅经过 Bash 语法检查与菜单输入模拟，**没有**经过真实 VPS 端到端验证。

## 新版安装模式（测试版）
菜单 1 支持 1 Reality 单协议、2 HY2 单协议、3 双协议。HY2 可以选择自动生成自签名 IP 证书或输入已有证书。自签名证书必须安全地传到客户端并配置证书信任，直接复制 HY2 URI 不保证正常连接；不得默认关闭证书验证。菜单绿色加粗，确认 YES 不区分大小写。

**重要：此版本只完成 Bash 静态语法检查，尚未在真实 Ubuntu/Debian VPS 上完成部署、客户端验证、自动更新及回滚测试。请勿直接在生产 VPS 使用。**
