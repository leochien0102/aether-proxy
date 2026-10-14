# 05 配置模型

UCI 文件 `/etc/config/aetherproxy`。下面是**完整的字段表**，渲染器和 LuCI 只能使用这里列出的字段。
新增字段要先改本文档。

类型约定：`bool` 为 `0/1`；`list` 为 UCI list；`enum(a|b)` 表示只能取列出的值；校验失败即配置错误（退出码 2）。

## `config global 'main'`

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `enabled` | bool | `0` | |
| `mode` | enum(`gfw`\|`bypass_cn`\|`global`) | `bypass_cn` | |
| `node` | 节点段名 | — | 当前节点。为空则无法启用 |
| `lan_ifaces` | list | `br-lan` | 拦截哪些入接口（L3 设备名） |
| `unlisted_policy` | enum(`follow`\|`direct`) | `follow` | 未列出主机的策略（[02](02-dataplane.md)） |
| `quic_block` | bool | `1` | 代理目标的 UDP 443 拒绝（非游戏模式主机） |
| `dns_hijack` | bool | `1` | 劫持 LAN 的 53 端口到路由器（direct 主机除外） |
| `ipv6_filter` | bool | `1` | 过滤 AAAA |
| `filter_https_rr` | bool | `1` | 过滤 HTTPS RR（qtype 65） |
| `fail_open` | bool | `1` | Xray 不可用时摘除拦截规则 |
| `sniffing` | bool | `1` | Xray 入站嗅探 http/tls/quic，`routeOnly=false`（由节点按域名连接） |
| `log_level` | enum(`error`\|`warn`\|`notice`\|`info`\|`debug`) | `notice` | aether-proxy 自身的日志等级（[09](09-logging.md)） |
| `xray_log_level` | enum(`error`\|`warning`\|`info`\|`debug`) | `warning` | |
| `boot_wait_timeout` | int 秒，0–600 | `120` | 0 = 开机不等待 |
| `boot_check_targets` | list `ip:port` | `223.5.5.5:53` `119.29.29.29:53` | |
| `xray_bin` / `chinadns_bin` | 路径 | 空 | 高级选项：显式指定二进制 |

## `config dns 'dns'`

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `china_dns` | list chinadns-ng 上游写法 | `223.5.5.5` `119.29.29.29` | |
| `trust_dns` | list IPv4，**最多 2 个** | `8.8.8.8` `1.1.1.1` | T1：经节点访问，固定 53/TCP |
| `direct_dns` | list chinadns-ng 上游写法 | `tcp://8.8.8.8` `tcp://1.1.1.1` | T2 与节点引导解析；可写 `tls://dns.google@8.8.8.8` |
| `allow_china_fallback` | bool | `1` | 是否允许降到 T3 |
| `dns_probe_domain` | 域名 | `www.google.com` | T2/T3 探测用 |
| `dnsmasq_instance` | 字符串 | 空（自动） | 指定 dnsmasq 实例 |

## `config host`（匿名段，可多个）

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `enabled` | bool | `1` | |
| `name` | 字符串 | — | 仅用于显示 |
| `ip` | list IPv4 或 CIDR | — | `ip` 和 `mac` 至少填一个 |
| `mac` | list MAC | — | 统一转为小写冒号格式 |
| `policy` | enum(`follow`\|`direct`\|`proxy`) | `follow` | |
| `udp` | bool | `0` | 游戏模式。`policy=direct` 时必须为 0 |

## `config subscription`（命名段 `s_<8位十六进制>`，可多个）

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `enabled` | bool | `1` | |
| `name` | 字符串 | — | |
| `url` | URL | — | 必填 |
| `user_agent` | 字符串 | `aether-proxy/<版本>` | 部分机场按 UA 决定返回格式，可改 |
| `fetch_via` | enum(`auto`\|`direct`\|`proxy`) | `auto` | `auto` = 先直连，失败再经代理（[06](06-nodes-subscription.md)） |
| `interval_hours` | int | `24` | 0 = 只手动更新 |

## `config node`（命名段 `n_<32位十六进制>`）

段名就是节点身份（UUID v4 去掉连字符），首次落地时生成，之后**永不改变**（[06](06-nodes-subscription.md)）。

| 字段 | 类型 | 说明 |
|---|---|---|
| `label` | 字符串 | 显示名（订阅的 `#name` 或手填） |
| `source` | `manual` 或订阅段名 | |
| `stale` | bool | 订阅中已消失、但仍被引用而保留 |
| `match_strong` / `match_weak` | 字符串 | 身份匹配键（[06](06-nodes-subscription.md)），用户不可见 |
| `protocol` | enum(`vless`\|`vmess`\|`trojan`\|`shadowsocks`) | |
| `address` | 域名或 IPv4 | |
| `port` | 1–65535 | |
| `uuid` | 字符串 | vless / vmess |
| `password` | 字符串 | trojan / shadowsocks |
| `method` | 字符串 | shadowsocks 加密方式；vmess 的 `security`（默认 `auto`） |
| `flow` | 字符串 | vless，如 `xtls-rprx-vision` |
| `encryption` | 字符串 | vless，默认 `none` |
| `transport` | enum(`raw`\|`ws`\|`grpc`\|`httpupgrade`\|`xhttp`) | 默认 `raw`；URI 中的 `tcp` 映射为 `raw` |
| `host` / `path` | 字符串 | ws、httpupgrade、xhttp |
| `service_name` | 字符串 | grpc |
| `xhttp_mode` | 字符串 | xhttp |
| `header_type` | 字符串 | raw 的 `http` 伪装（首版只透传 `none`/`http`） |
| `security` | enum(`none`\|`tls`\|`reality`) | |
| `sni` / `alpn`(list) / `fingerprint` | 字符串 | tls / reality |
| `pinned_cert_sha256` | 字符串 | tls：证书 SHA-256 指纹固定（逗号分隔，可多个），渲染为 `pinnedPeerCertSha256` |
| `verify_name` | 字符串 | tls：按指定名称校验证书，渲染为 `verifyPeerCertByName` |
| `reality_pbk` / `reality_sid` / `reality_spx` | 字符串 | reality |

> Xray 26.9.30 已**移除** `allowInsecure`（配置中出现即报错，2026-10-14 核实 `infra/conf/transport_security.go`），所以节点没有「跳过证书校验」字段。

必填与默认值：`protocol`、`address`、`port` 必填；`security` 默认 `none`；`stale` 默认 `0`；`source` 未设置时视为 `manual`。

运行时状态（检测结果、最后错误）**不写 UCI**，放在 `/var/run/aether-proxy/`，避免反复写 flash。

## `config update 'update'`

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `channel_urls` | list URL | 项目发布地址 + 可选镜像 | 清单下载地址，按顺序尝试（[08](08-updates.md)） |
| `data_auto` | bool | `1` | 自动更新规则数据 |
| `data_hour` | 0–23 | `4` | 每天几点检查 |
| `data_minute` | 0–59 | 空 | 安装时由 uci-defaults 随机生成并写入，用于把各设备的请求错开；为空时按 `30` 处理 |
| `xray_auto` | enum(`off`\|`notify`\|`auto`) | `notify` | |
| `chinadns_auto` | enum(`off`\|`notify`) | `notify` | **不提供 auto**（[08](08-updates.md)） |

## `config probe 'probe'`

| 字段 | 默认值 | 说明 |
|---|---|---|
| `url` | `https://www.gstatic.com/generate_204` | 代理健康检测 |
| `expect_code` | `204` | |
| `timeout` | `5` | 秒 |
| `fail_threshold` | `3` | 连续失败几次判为不健康 |
| `recover_threshold` | `2` | 连续成功几次判为健康 |
| `node_timeout` | `3` | 节点 TCP 检测超时，秒 |
| `node_concurrency` | `8` | |

## 文件

| 路径 | 格式 |
|---|---|
| `/etc/aether-proxy/custom/direct_domain.txt`、`proxy_domain.txt` | 每行一个域名（后缀匹配），`#` 开头为注释 |
| `/etc/aether-proxy/custom/direct_ip.txt`、`proxy_ip.txt` | 每行一个 IPv4 或 CIDR |
| `/etc/aether-proxy/data/*.txt`、`/usr/share/aether-proxy/data/*.txt` | 见 [08](08-updates.md) 数据格式 |

LuCI 用 textarea 编辑这些文件，保存前做逐行校验，非法行直接拒绝保存并标出行号。

列表文件的解析规则（`data.uc`，T1.2 实现，2026-10-14 确认）：

- 只有以 `#` 开头的整行是注释；**行内注释**（如 `1.2.3.4 # x`）是非法行。
- 容忍 UTF-8 BOM 和 CRLF 换行。域名统一转小写、去掉首尾的点；域名列表中形如 IPv4 地址的行是非法行。
- CIDR 带主机位为非法；`/32` 输出为裸地址 `1.2.3.4`，其余输出 `a.b.c.d/len`；IP 按网络地址、再按前缀长度数值排序，域名按字典序，规范化后去重。
- 任何文件中出现非法行，整次读取失败并报告行号，不会悄悄丢弃。
- 自定义列表文件不存在视为空列表；规则数据文件在 `/etc/aether-proxy/data/` 与包内基线中**都不存在**时报错（空的 chnroute4 会让所有流量走代理，不能静默接受）；文件存在但读取失败时报错，不回退到基线；`/etc/aether-proxy/data/` 中的空文件仍然优先于基线。

## 校验规则（`aether-proxy check` 必须全部实现）

1. `enabled=1` 时 `node` 必须指向存在的节点。指向 stale 节点**允许**，但要在结果的 `warnings` 中返回 `NODE_STALE_IN_USE`，由调用方记录。
2. host：`ip` 和 `mac` 至少一个；`direct` + `udp=1` 报错；不同 host 之间 IP、CIDR、MAC 完全相同报错。
3. `trust_dns` 1–2 个合法 IPv4。
4. 所有 list 中的 IPv4/CIDR/MAC/域名语法合法。
5. `lan_ifaces` 中的接口存在（这一项属于前置检查，在 `check` 中同样执行）。
6. 节点字段按协议检查必填项：vless/vmess 需要 `uuid`；trojan/ss 需要 `password`；ss 需要 `method` 在 Xray 支持列表内；
   `reality` 需要 `reality_pbk` 和 `sni`。

## 默认配置文件（随包安装）

```
config global 'main'
	option enabled '0'
	option mode 'bypass_cn'
	list lan_ifaces 'br-lan'
	option unlisted_policy 'follow'

config dns 'dns'
	list china_dns '223.5.5.5'
	list china_dns '119.29.29.29'
	list trust_dns '8.8.8.8'
	list trust_dns '1.1.1.1'
	list direct_dns 'tcp://8.8.8.8'
	list direct_dns 'tcp://1.1.1.1'

config update 'update'
	option data_auto '1'
	option xray_auto 'notify'
	option chinadns_auto 'notify'

config probe 'probe'
```
其余字段取上表默认值，不写入文件。
