# 05 配置模型

UCI 文件 `/etc/config/aetherproxy`。下面是**完整的字段表**，渲染器和 LuCI 只能使用这里列出的字段。
新增字段要先改本文档。

类型约定：`bool` 为 `0/1`；`list` 为 UCI list；`enum(a|b)` 表示只能取列出的值；校验失败即配置错误（退出码 2）。

## `config global 'main'`

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `enabled` | bool | `0` | |
| `mode` | enum(`gfw`\|`bypass_cn`\|`global`) | `bypass_cn` | **默认模式**（页面用语，2026-10-22 定）：绕过大陆 / 仅代理被墙网站（GFW）/ 全局（所有流量走代理）。全局只有这一个，换节点不改变它；访问控制的设备覆盖可以另选模式（02「主机策略模型」） |
| `node` | 节点段名 | — | 当前节点。为空则无法启用 |
| `lan_ifaces` | list | `br-lan` | 拦截哪些入接口（L3 设备名） |
| `unlisted_policy` | enum(`follow`\|`direct`) | `follow` | 未列出主机的策略：跟随默认模式 / 直连（[02](02-dataplane.md)） |
| `quic_block` | bool | `1` | 代理目标的 UDP 443 拒绝（非游戏模式主机） |
| `dns_hijack` | bool | `1` | 劫持 LAN 的 53 端口到路由器（direct 主机除外） |
| `ipv6_filter` | bool | `1` | 过滤 AAAA |
| `filter_https_rr` | bool | `1` | 过滤 HTTPS RR（qtype 65） |
| `fail_open` | bool | `1` | Xray 不可用时摘除拦截规则 |
| `degrade_gfw` | bool | `1` | 节点不健康（Xray 存活、代理健康检测判为不健康）时，把绕过大陆与全局临时按「仅被墙」分流，恢复健康后还原；不写配置（[02](02-dataplane.md)「节点不健康时的分流降级」，2026-10-27 定） |
| `sniffing` | bool | `1` | Xray 入站嗅探 http/tls/quic，`routeOnly=false`（由节点按域名连接） |
| `log_level` | enum(`error`\|`warn`\|`notice`\|`info`\|`debug`) | `notice` | aether-proxy 自身的日志等级（[09](09-logging.md)） |
| `xray_log_level` | enum(`error`\|`warning`\|`info`\|`debug`) | `warning` | |
| `boot_wait_timeout` | int 秒，0–600 | `120` | 0 = 开机不等待 |
| `boot_check_targets` | list `ip:port` | `223.5.5.5:53` `114.114.114.114:53` | |
| `xray_bin` / `chinadns_bin` | 路径 | 空 | 高级选项：显式指定二进制 |

## `config dns 'dns'`

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `china_dns` | list：chinadns-ng 上游写法，或字面值 `wan` | `wan` `114.114.114.114` | `wan` = 运营商下发的 DNS（WAN 口取得的 IPv4 DNS，[03](03-dns.md)「运营商下发的 DNS」）。2026-10-22 起默认值由 `223.5.5.5` `114.114.114.114` 改为此值（仓库所有者定：运营商 DNS 离用户最近，国内 CDN 更准）；已安装设备的配置文件保留原值，不自动改。2026-10-15 起不再默认使用 `119.29.29.29`：真机上 chinadns-ng 走 TCP 访问它时被反复重置（03「真机验证」） |
| `trust_dns` | list：IPv4，可带 `tcp://` 或 `udp://` 前缀，**最多 2 个** | `8.8.8.8` `1.1.1.1` | T1：经节点访问 53 端口。不带前缀 = `tcp://`（默认，任何节点都能用）；`udp://` 用于不支持 TCP 查询的 DNS，**要求节点支持 UDP 转发**（节点那一端替你发出 UDP，客户端无法代替）。两项可以协议不同，互为备份（2026-10-22 定，[03](03-dns.md)「DNS 级别」） |
| `direct_dns_enabled` | bool | `0` | 是否启用直连境外 DNS（T2 与节点域名的引导解析）。**默认关**（2026-10-23 仓库所有者定，r13 窗口；已安装设备升级后同样为关）：直连境外 DNS 在国内多数网络里被重置，作用有限（[03](03-dns.md)「直连境外 DNS（可选）」） |
| `direct_dns` | list chinadns-ng 上游写法 | `tcp://9.9.9.9` | 只在 `direct_dns_enabled=1` 时使用（2026-10-23 起默认只留 `tcp://9.9.9.9`）。T2 与节点引导解析。原默认值 `tcp://9.9.9.9` `tcp://8.8.8.8` 的依据 2026-10-19 H28K 实测（[03](03-dns.md)「DNS 级别」）：直连 `tcp://9.9.9.9` 9 次成功 8 次且应答未被污染，`tcp://8.8.8.8` 1/9、`tcp://1.1.1.1` 0/9，DoT（8.8.8.8、1.1.1.1、9.9.9.9）全部不通 |
| `allow_china_fallback` | bool | `1` | 是否允许降到 T3 |
| `dns_probe_domain` | 域名 | `www.google.com` | T2/T3 探测用 |
| `dnsmasq_instance` | 字符串 | 空（自动） | 指定 dnsmasq 实例 |

## `config host`（匿名段，可多个）

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `enabled` | bool | `1` | |
| `name` | 字符串 | — | 仅用于显示 |
| `ip` | list IPv4、CIDR 或地址范围 | — | `ip` 和 `mac` 至少填一个。地址范围写 `192.168.8.250-192.168.8.254`（起 ≤ 止，起 = 止时等同单个地址；2026-10-23 定，r14 窗口：小段连续地址按 CIDR 拆不直观）。nft 的主机集合本来就是区间集合，范围原样写入 |
| `mac` | list MAC | — | 统一转为小写冒号格式 |
| `policy` | enum(`follow`\|`direct`\|`bypass_cn`\|`gfw`\|`proxy`) | `follow` | 跟随默认模式 / 直连 / 绕过大陆 / 仅代理被墙网站 / 全局（`proxy`，所有流量走代理；值名沿用，旧配置不迁移）。`bypass_cn`、`gfw` 为 2026-10-22 加（r12 窗口，仓库所有者定：覆盖可以跳出默认模式），见 02 |
| `udp` | bool | `0` | 游戏模式。`policy=direct` 时必须为 0 |

## `config sub 'sub'`（订阅的通用设置，2026-10-22 加，r12 窗口）

各订阅没有单独设置时使用这里的值（仓库所有者定：通用设置，单个订阅可以覆盖）。段不存在（旧版升级上来的配置）时各项取默认值。
随包的默认配置**不写 `user_agent`**（不写与写空串都按默认值，即运行时版本的 `aether-proxy/<版本>`）：写死版本号会在升级后（配置文件保留）停在旧版本（2026-10-22 T9.17 复核定）。

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `user_agent` | 字符串 | `aether-proxy/<版本>` | 部分机场按 UA 决定返回格式，可改 |
| `fetch_via` | enum(`auto`\|`direct`\|`proxy`) | `auto` | `auto` = 先直连，失败再经代理；`proxy` 指**经当前节点**（本机 Xray 的 HTTP 入站），不是独立的代理（[06](06-nodes-subscription.md)） |
| `interval_hours` | int ≥ 0 | `24` | 0 = 只手动更新。LuCI 以下拉给出 0 / 12 / 24 / 72 / 168，命令行接受任意非负整数 |

## `config subscription`（命名段 `s_<8位十六进制>`，可多个）

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `enabled` | bool | `1` | |
| `name` | 字符串 | — | |
| `url` | URL | — | 必填 |
| `user_agent` | 字符串 | 空 = 跟随 `sub.user_agent` | 设了就只用于这个订阅 |
| `fetch_via` | enum(`auto`\|`direct`\|`proxy`) | 空 = 跟随 `sub.fetch_via` | 同上 |
| `interval_hours` | int ≥ 0 | 空 = 跟随 `sub.interval_hours` | 同上 |

**生效值**（2026-10-22）：这三项在读取配置时就合并为生效值（单独值，没有就用通用值，通用值没有就用上表默认值），调度、下载、`sub status` 等都只看生效值，不各自再判断一次。
2026-10-22 之前写下的显式值（LuCI 新建订阅时会写 `interval_hours='24'`、`fetch_via='auto'`）照旧生效，视为单独设置；页面可提供「改为跟随通用设置」（删除该选项）。

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
| `flow` | enum(`xtls-rprx-vision`\|`xtls-rprx-vision-udp443`)，可空 | vless。Xray v26.9.30 / v26.10.21 只接受空与这两个值（`infra/conf/vless.go`），其他值 Xray 拒绝启动（规则 7）；`-udp443` 另放行 UDP/443，其余与 Vision 相同（2026-10-22 改为枚举，r12 窗口） |
| `encryption` | 字符串 | vless，默认 `none` |
| `transport` | enum(`raw`\|`ws`\|`grpc`\|`httpupgrade`\|`xhttp`) | 默认 `raw`；URI 中的 `tcp` 映射为 `raw` |
| `host` / `path` | 字符串 | ws、httpupgrade、xhttp |
| `service_name` | 字符串 | grpc |
| `xhttp_mode` | 字符串 | xhttp |
| `header_type` | 字符串 | raw 的 `http` 伪装（首版只透传 `none`/`http`） |
| `security` | enum(`none`\|`tls`\|`reality`) | |
| `sni` / `alpn`(list) / `fingerprint` | 字符串 | tls / reality |
| `pinned_cert_sha256` | 字符串 | tls：证书 SHA-256 指纹固定（逗号分隔，可多个），原样渲染为 `pinnedPeerCertSha256`（Xray 自己按逗号拆分，已核实 v26.9.30 源码）。格式按校验规则 7 检查 |
| `verify_name` | 字符串 | tls：按指定名称校验证书，渲染为 `verifyPeerCertByName` |
| `reality_pbk` / `reality_sid` / `reality_spx` | 字符串 | reality |
| `reality_pqv` | 字符串 | reality：ML-DSA-65 公钥，渲染为 `realitySettings.mldsa65Verify`；分享链接参数 `pqv`（2026-10-22 加） |
| `ech_config_list` | 字符串 | tls：ECH 配置，原样渲染为 `tlsSettings.echConfigList`；分享链接参数 `ech`（2026-10-22 加） |
| `grpc_multi_mode` | bool | grpc：渲染为 `grpcSettings.multiMode`；分享链接 `mode=multi` 为真、`mode=gun` 或没有为假（2026-10-22 加） |
| `ws_heartbeat` | 整数（秒，1–3600） | ws：渲染为 `wsSettings.heartbeatPeriod`（2026-10-22 加）。**early data 不另设字段**：Xray 26 从 `path` 的 `?ed=<字节数>` 读取，写在 `path` 里即可 |
| `xhttp_extra` | 字符串（JSON 对象） | xhttp：原样作为 `xhttpSettings.extra`；必须能解析为 JSON 对象，否则配置无效；分享链接参数 `extra`（URL 编码的 JSON）（2026-10-22 加） |
| `mux` | bool | 渲染出站 `mux.enabled`；默认关。**与 `flow` 为 `xtls-rprx-vision` 或 `xtls-rprx-vision-udp443` 同时开 → 配置无效**（Vision 不支持 Mux；`-udp443` 在 Xray 中走同一段代码，r12 窗口补）（2026-10-22 加）。**只在 `protocol` 为 `vless` 时检查**（2026-10-24 补，r16 后 T10.54 复审发现：`flow` 只对 VLESS 渲染，节点从 VLESS 改成 Trojan 等协议后留下的 `flow` 不生效，不应让开 Mux 的节点判为无效；与 T9.14 定的「不在用的字段保留、不报错、不渲染」一致） |
| `mux_concurrency` / `mux_xudp_concurrency` | 整数（-1–1024） | `mux.concurrency` / `mux.xudpConcurrency`；不设则不渲染（用 Xray 的默认 8 / 16）；只在 `mux` 开时渲染 |
| `mux_xudp_udp443` | enum(`reject`\|`allow`\|`skip`) | `mux.xudpProxyUDP443`；不设则不渲染（Xray 默认 `reject`）；只在 `mux` 开时渲染 |
| `tcp_fast_open` / `tcp_mptcp` | bool | 渲染为出站 `streamSettings.sockopt.tcpFastOpen` / `tcpMptcp`；默认关，关时不渲染（2026-10-22 加） |

> 2026-10-22 新增的节点字段按 Xray **v26.9.30 与 v26.10.21** 的源码（`infra/conf/`）核实了 JSON 字段名；分享链接参数名与 helloworld（ssr-plus）的解析一致。
> 两处与 helloworld 不同：WebSocket 的 `maxEarlyData`/`earlyDataHeaderName` 在 Xray 26 已不存在（改为 `path` 中的 `?ed=`）；Shadowsocks 出站没有 `uot`、`ivCheck`（Xray 会静默忽略），所以不提供「UDP over TCP」。
> T9.14 复核定（2026-10-22）：① 字段属于没在用的传输或安全层时（例如 `ws_heartbeat` 而 `transport` 是 `grpc`）**保留、不报错、不渲染**，与已有字段一致；
> ② `ech_config_list`、`reality_pqv` 当作不透明字符串原样渲染，不校验编码（由 Xray 自己校验）；③ 分享链接 grpc 的 `mode` 只认 `multi` 与 `gun`，其他值 → 该链接跳过（`invalid_value`）。
> 注意 Xray 解析 JSON 时**忽略不认识的字段**，`xray run -test` 查不出字段名写错——新增字段必须对照源码，不能只靠 `run -test`。

> Xray 26.9.30 已**移除** `allowInsecure`（配置中出现即报错，2026-10-14 核实 `infra/conf/transport_security.go`），所以节点没有「跳过证书校验」字段。

必填与默认值：`protocol`、`address`、`port` 必填；`security` 默认 `none`；`stale` 默认 `0`；`source` 未设置时视为 `manual`。

运行时状态（检测结果、最后错误）**不写 UCI**，放在 `/var/run/aether-proxy/`，避免反复写 flash。

## `config update 'update'`

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `channel_urls` | list URL | `https://github.com/leochien0102/aether-proxy-channel/releases/download/channel-stable/` + 可选镜像 | 清单下载地址，按顺序尝试（[08](08-updates.md)「发布仓库」） |
| `data_auto` | bool | `1` | 自动更新规则数据 |
| `data_hour` | 0–23 | `4` | 每天几点检查 |
| `data_minute` | 0–59 | 空 | 安装时由 uci-defaults 随机生成并写入，用于把各设备的请求错开；为空时按 `30` 处理 |
| `xray_auto` | enum(`off`\|`notify`\|`auto`) | `notify` | `xray-core` 软件包的更新策略（[08](08-updates.md)「调度」）；`aether-proxy` 自身只提示。chinadns-ng 不进发布通道，没有对应选项 |

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
2. host：`ip` 和 `mac` 至少一个；`direct` + `udp=1` 报错；不同 host 之间 IP、CIDR、地址范围、MAC 完全相同报错（范围先规范化：起 = 止写成单个地址；只比完全相同，部分重叠不报错，与 CIDR 现在的做法一致）。生成 nft 集合时，覆盖同一段地址的不同写法（如 `10.0.0.0/24` 与 `10.0.0.0-10.0.0.255`）只写一次，保留先出现的写法（T9.33 复核定）。
3. `trust_dns` 1–2 项，每项为合法 IPv4，可带 `tcp://` 或 `udp://` 前缀（不接受端口与其他协议）；`china_dns` 每项为上游写法或字面值 `wan`。
4. 所有 list 中的 IPv4/CIDR/MAC/域名语法合法。
5. `lan_ifaces` 中的接口存在（这一项属于前置检查，在 `check` 中同样执行）。
6. 节点字段按协议检查必填项：vless/vmess 需要 `uuid`；trojan/ss 需要 `password`；ss 需要 `method` 在 Xray 支持列表内；
   `reality` 需要 `reality_pbk` 和 `sni`。
7. 节点取值必须是 Xray v26.9.30 启动时能接受的（2026-10-14 用真实 Xray 校验夹具时发现，规则对照 `infra/conf/xray.go`、`transport_security.go`）：
   - `reality_pbk`：无填充 base64url 编码的 32 字节（恰好 43 个字符 `[A-Za-z0-9_-]`），否则 `invalid_reality_key`
   - `reality_sid`：十六进制、长度为偶数且不超过 16，否则 `invalid_short_id`
   - `pinned_cert_sha256`：逗号分隔的每一项去掉冒号后是 64 位十六进制，否则 `invalid_cert_hash`
   - `uuid`（vless / vmess）：按字节计 1–30 字节的任意字符串（Xray 用 UUIDv5 换算），或 32–36 字节且去掉 `-` 后恰好 32 位十六进制（不查版本、不查横线位置），其余（31 字节、超过 36 字节、32–36 字节里有非十六进制字符）报 `invalid_uuid`；订阅中这样的节点按 `invalid_value` 跳过（2026-10-25 r18 窗口，在 H28K 上用 Xray 26.9.30 `run -test` 逐项实测，对照 `common/uuid` 的 `ParseString`）
   - vmess 的 `method`（即 `security`）：Xray 对不认识的值一律按 `auto` 处理、不报错（同日实测 `legacy`、`aes-256-gcm` 都能启动），后端不查；页面给下拉框 `auto`、`aes-128-gcm`、`chacha20-poly1305`、`none`、`zero`
   - `flow`：只能为空、`xtls-rprx-vision` 或 `xtls-rprx-vision-udp443`（2026-10-22，核对 v26.9.30 与 v26.10.21 的 `infra/conf/vless.go`），否则按 enum 报错；订阅中带其他值的节点按 `invalid_value` 跳过
   - **明文禁令**：`trojan`，以及 `encryption` 为空或 `none` 的 `vless`，当 `security=none` 时，`address` 必须是私有 IPv4
     （`10/8`、`100.64/10`、`127/8`、`169.254/16`、`172.16/12`、`192.168/16`），否则 `insecure_transport`。
     Xray 对私有**域名**也放行，但它的私有域名表在 geodata 中，这里一律按公网处理（保守）。

## 默认配置文件（随包安装）

```
config global 'main'
	option enabled '0'
	option mode 'bypass_cn'
	list lan_ifaces 'br-lan'
	option unlisted_policy 'follow'

config dns 'dns'
	list china_dns 'wan'
	list china_dns '114.114.114.114'
	list trust_dns '8.8.8.8'
	list trust_dns '1.1.1.1'
	list direct_dns 'tcp://9.9.9.9'

config sub 'sub'
	option fetch_via 'auto'
	option interval_hours '24'

config update 'update'
	option data_auto '1'
	option xray_auto 'notify'

config probe 'probe'
```
其余字段取上表默认值，不写入文件。
