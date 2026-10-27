# 02 数据面

## 机制选择

- TCP 和 UDP **都用 TPROXY**，在 `prerouting` 的 mangle 优先级拦截。只有一套机制、一个 Xray 入站
  （`tunnel` + `followRedirect`），不需要 nat 表里的 REDIRECT。
- 只拦截从 LAN 接口进入的流量（`iifname`）。**OUTPUT 不挂规则**（[01](01-architecture.md) 原则 1）。
- 策略路由：`ip rule add fwmark 0x80000/0x80000 lookup 233 pref 900`，
  `ip route add local default dev lo table 233`。

## 判定顺序（规范）

数据包按下面的顺序判定，**先命中先生效**：

| # | 条件 | 动作 | 说明 |
|---|---|---|---|
| 0 | 不是从 `lan_ifaces` 进入，或不是 IPv4，或不是 TCP/UDP | 直连 | inet 表也会看到 IPv6 包；首版只处理 IPv4，必须在进入 TPROXY 规则前放行 |
| 1 | 已有透明 socket（`socket transparent 1`） | 打标记并接受 | 已建立连接的快路径 |
| 2 | 目的地址是本机（`fib daddr type local`） | 直连 | |
| 3 | 目的端口 53 且开启了 DNS 劫持 | 直连 | 交给 nat 链的劫持规则，避免被 TPROXY 抢走 |
| 4 | 目的地址属于保留地址 `reserved4` | 直连 | 内网、组播、CGNAT 等 |
| 5 | 目的地址是节点服务器 `node_ip4` | 直连 | |
| 6 | 目的地址命中用户直连 `direct_ip4` / `udirect4` | 直连 | **目的地例外优先于主机策略**（含强制代理主机） |
| 7 | 源主机策略 = `direct` | 直连 | |
| 8 | 源主机策略 = `proxy` | 代理 | 不看模式 |
| 9 | 源主机策略 = `follow`；或未列出且 `unlisted_policy=follow` | 按模式判定 ↓ | |
| 10 | 未列出且 `unlisted_policy=direct` | 直连 | |

**按模式判定**（只对第 9 条生效）：

| 先 | 目的地址命中用户代理 `proxy_ip4` / `uproxy4` → 代理 |
|---|---|
| `gfw` | 命中 `gfw4`（DNS 动态填充）或 `gfw_static4` → 代理；否则直连。`gfw_static4` 含 Telegram 网段与常见境外公共 DNS 的 IP（08「数据格式」）：局域网设备写死 IP 的 DoH/DoT（如 `1.1.1.1`）不经 DNS 填充，GFW 模式下要靠它走代理（2026-10-22，对照 helloworld 默认「WAN 强制代理 IP」中的 8.8.8.8、1.1.1.1） |
| `bypass_cn` | 命中 `chnroute4` → 直连；否则代理 |
| `global` | 代理 |

**「代理」动作**：

- TCP：一律 TPROXY。
- UDP：源主机开启了游戏模式（`host_udp4` / `host_udp_mac`）→ TPROXY；
  否则如果 `quic_block=1` 且目的端口是 443 → `reject`（让浏览器立即回落到 TCP，不必等 QUIC 超时）；
  否则直连。

## 主机策略模型（替代多张名单）

每台主机在 UCI 里只有一个 `host` 段（[05](05-config.md)）：

- `policy`：`follow`（跟随默认模式 `main.mode`）／ `direct`（不走代理）／ `bypass_cn`（这台设备按绕过大陆）／ `gfw`（这台设备只代理被墙网站）／ `proxy`（全局：这台设备所有流量走代理）。
  `bypass_cn`、`gfw` 为 2026-10-22 加（r12 窗口，仓库所有者定：设备覆盖可以跳出默认模式）。**DNS 只有一套，按默认模式解析**（03）；设备的模式与默认模式不同时，
  走代理的 HTTP/TLS 流量由 Xray 嗅探出域名、节点按域名连接（`sniffing`，`routeOnly=false`），基本不受影响；只有嗅探不出域名的流量按本地解析的 IP 连接。
  `gfw` 设备依赖 `gfw4` 集合，所以只要有启用的 `gfw` 设备，chinadns-ng 在任何默认模式下都写这个集合（03「各模式的分流」）。
- `udp`：游戏模式开关。**只在 policy ≠ direct 时有效**，`direct` + `udp=1` 是配置错误，保存时拒绝。
- 匹配依据：`ip`（IP 或 CIDR，可多个）和/或 `mac`（可多个）。

helloworld 的三种访问控制方式对应如下，不再单独建名单：

| helloworld | aether-proxy 配置 |
|---|---|
| 停用 | `unlisted_policy=follow`，不建 host |
| 仅允许列表内主机 | `unlisted_policy=direct`，列表内主机 `policy=follow` |
| 列表外也允许（列表内主机禁用） | `unlisted_policy=follow`，列表内主机 `policy=direct` |

**冲突校验**（渲染前做，失败就是配置错误，退出码 2）：同一个 IP、CIDR 或 MAC 出现在两个 host 段中即报错。
CIDR 之间互相包含（如 `192.168.1.0/24` 和 `192.168.1.10`）**允许**，按 nft 集合的判定顺序
`direct` → `proxy` → `bypass_cn` → `gfw` → `follow` 生效（代理范围大的在前），并在 LuCI 中提示。

MAC 匹配用 `ether saddr`，只对在二层直连 LAN 网桥的主机有效（经过另一台路由器的主机看到的是那台路由器的 MAC）。

## 节点不健康时的分流降级（2026-10-27 定，backlog B19）

背景：节点被封时 Xray 仍在运行，monitor 判为代理不健康、DNS 降到 T2/T3，但拦截规则不变。绕过大陆（或全局）下**所有**境外流量仍进代理而全部失败；
其中没被墙的境外站点直连本来是通的。所以不健康期间改为只把被墙目标送代理（反正打不开、节点一恢复就最先恢复），其余直连。

- **开关**：`main.degrade_gfw`（默认 1，[05](05-config.md)）。为 0 时行为同以前。
- **进入**：monitor 的代理健康检测从健康（或从未健康）变为**不健康**（连续 `fail_threshold` 次失败，[07](07-probe.md)），且 Xray 存活、不在 `failsafe`。启动以来从未健康过的情形同样适用（节点开机即不通时网络不至于全断）。
- **退出**：健康检测恢复为健康（连续 `recover_threshold` 次成功）；用户停止服务；开关在运行中改为 0（随该次重载退出）。
- **作用范围**（降级期间的**实际生效**模式，配置不变）：
  - 默认模式为 `bypass_cn` 或 `global` → 按 `gfw` 渲染 `by_mode`；默认模式本来就是 `gfw` → 不变。
  - 设备覆盖为 `bypass_cn` 或 `global` 的主机 → 按 `gfw` 处理（`bypass_cn` 覆盖走 `mode_gfw`；`global` 覆盖原本直接 `goto proxy`，降级期间同样改走 `mode_gfw`）。
  - 主机策略 `proxy`（强制代理）与 `direct` **不变**：用户明确要求它们一律走代理 / 直连。
  - 目的地例外（`direct_ip4`/`udirect4`/`proxy_ip4`/`uproxy4`）、游戏模式、QUIC 拒绝不变。
  - 没有任何目标需要改变（默认 `gfw`、没有 `bypass_cn`/`global` 覆盖）时什么都不做、不记事件。
- **实现**：同「切换默认模式」的重载路径（nft 整表替换 + 必要时重启 chinadns-ng，不重启 Xray，约 2 秒），渲染上下文多一个运行时覆盖 `degraded_mode: "gfw"`，**不写 UCI**。
  降级期间用户的重载、切换节点、切换模式照常进行，渲染时继续带着覆盖，直到退出条件成立。拿不到全局锁时本轮跳过、下一轮再试（同 04「monitor 循环」）。
- **状态**：`state.json`/`status` 增加 `degraded_mode`（`"gfw"` 或 `null`）与 `degraded_since`。**`mode` 仍是配置并已应用的默认模式**——概览页靠 `mode` ≠ `main.mode` 判断「正在切换」，降级不能改它（10「概览页：默认模式下拉」）。
- **事件**：进入记 WARN `MODE_DEGRADED {from: <默认模式>, to: "gfw"}`，退出记 NOTICE `MODE_RESTORED {mode: <默认模式>}`。事件码与 LuCI 文案随前端卡一起加进 [09](09-logging.md) 目录（目录里每个码都要有页面模板，先加会让 LuCI 测试失败）。
- **DNS**：不改。T2/T3 的切换照旧（[03](03-dns.md)）；T3 期间被墙域名可能解析到污染地址，只影响本来就打不开的那部分。

## nft 规则模板

渲染产物 `/var/run/aether-proxy/aether-proxy.nft`，用 `nft -f` **整表原子替换**。`{{ }}` 为渲染变量，`{% %}` 为条件。

```nft
table inet aetherproxy
delete table inet aetherproxy

table inet aetherproxy {
	set reserved4   { type ipv4_addr; flags interval; auto-merge; elements = { {{RESERVED4}} } }
	set node_ip4    { type ipv4_addr; flags interval; auto-merge; {{elements node_ip4}} }
	set chnroute4   { type ipv4_addr; flags interval; auto-merge; {{elements chnroute4}} }
	set gfw_static4 { type ipv4_addr; flags interval; auto-merge; {{elements gfw_static4}} }
	set direct_ip4  { type ipv4_addr; flags interval; auto-merge; {{elements direct_ip4}} }
	set proxy_ip4   { type ipv4_addr; flags interval; auto-merge; {{elements proxy_ip4}} }
	set gfw4 { type ipv4_addr; flags interval; auto-merge; {{restored gfw4}} }      # chinadns-ng add-taggfw-ip
	set udirect4 { type ipv4_addr; flags interval; auto-merge; {{restored udirect4}} }  # chinadns-ng group-ipset
	set uproxy4 { type ipv4_addr; flags interval; auto-merge; {{restored uproxy4}} }   # chinadns-ng group-ipset

	set host_direct4    { type ipv4_addr;  flags interval; auto-merge; ... }
	set host_direct_mac { type ether_addr; ... }
	set host_proxy4     { type ipv4_addr;  flags interval; auto-merge; ... }
	set host_proxy_mac  { type ether_addr; ... }
	set host_follow4    { type ipv4_addr;  flags interval; auto-merge; ... }
	set host_follow_mac { type ether_addr; ... }
{% for p in host_modes %}                      # 只有启用的主机用到的覆盖模式：bypass_cn、gfw（顺序同下）
	set host_{{p}}4    { type ipv4_addr;  flags interval; auto-merge; ... }
	set host_{{p}}_mac { type ether_addr; ... }
{% endfor %}
	set host_udp4       { type ipv4_addr;  flags interval; auto-merge; ... }
	set host_udp_mac    { type ether_addr; ... }

	chain prerouting {
		type filter hook prerouting priority mangle; policy accept;
		iifname != { {{LAN_IFACES}} } return
		meta nfproto != ipv4 return
		meta l4proto != { tcp, udp } return
		meta l4proto tcp socket transparent 1 meta mark set meta mark | 0x00080000 accept
		fib daddr type local return
{% if dns_hijack %}
		th dport 53 return
{% endif %}
		ip daddr @reserved4 return
		ip daddr @node_ip4 return
		ip daddr @direct_ip4 return
		ip daddr @udirect4 return
		jump host_policy
	}

	chain host_policy {
		ip saddr @host_direct4 return
		ether saddr @host_direct_mac return
		ip saddr @host_proxy4 goto proxy
		ether saddr @host_proxy_mac goto proxy
{% for p in host_modes %}
		ip saddr @host_{{p}}4 goto mode_{{p}}
		ether saddr @host_{{p}}_mac goto mode_{{p}}
{% endfor %}
		ip saddr @host_follow4 goto by_mode
		ether saddr @host_follow_mac goto by_mode
{% if unlisted_policy == "follow" %}
		goto by_mode
{% endif %}
	}

	chain by_mode {
		ip daddr @proxy_ip4 goto proxy
		ip daddr @uproxy4 goto proxy
{% if mode == "gfw" %}
		ip daddr @gfw4 goto proxy
		ip daddr @gfw_static4 goto proxy
{% elif mode == "bypass_cn" %}
		ip daddr @chnroute4 return
		goto proxy
{% elif mode == "global" %}
		goto proxy
{% endif %}
	}

{% for p in host_modes %}                      # 设备覆盖的模式：与 by_mode 中该模式的规则相同
	chain mode_{{p}} {
		ip daddr @proxy_ip4 goto proxy
		ip daddr @uproxy4 goto proxy
		（p == gfw：ip daddr @gfw4 goto proxy；ip daddr @gfw_static4 goto proxy）
		（p == bypass_cn：ip daddr @chnroute4 return；goto proxy）
	}
{% endfor %}

	chain proxy {
		meta l4proto tcp meta mark set meta mark | 0x00080000 tproxy ip to :31080 accept
		meta l4proto udp ip saddr @host_udp4 meta mark set meta mark | 0x00080000 tproxy ip to :31080 accept
		meta l4proto udp ether saddr @host_udp_mac meta mark set meta mark | 0x00080000 tproxy ip to :31080 accept
{% if quic_block %}
		udp dport 443 meta mark set meta mark | 0x00100000
{% endif %}
	}

{% if quic_block %}
	# reject 在 prerouting 钩子上不一定可用（取决于内核版本），所以在 prerouting 打标记、到 forward 里再拒绝
	chain quic_reject {
		type filter hook forward priority filter - 1; policy accept;
		meta mark & 0x00100000 == 0x00100000 reject
	}
{% endif %}

	# 只允许经 TPROXY 进入内部端口；从 LAN/WAN 直接连这些端口一律丢弃
	chain input_guard {
		type filter hook input priority filter - 1; policy accept;
		iifname "lo" accept
		fib daddr type local th dport { 31080, 31081, 31082, 31083, 31053 } drop
	}

{% if dns_hijack %}
	chain dns_hijack {
		type nat hook prerouting priority dstnat - 5; policy accept;
		iifname != { {{LAN_IFACES}} } return
		ip saddr @host_direct4 return
		ether saddr @host_direct_mac return
		fib daddr type local return
		meta l4proto { tcp, udp } th dport 53 redirect to :53
	}
{% endif %}
}
```

要点：

- **设备覆盖的模式**（2026-10-22）：`host_modes` 为启用的主机中出现过的 `bypass_cn`、`gfw`（按这个顺序），没有就为空——此时输出与之前**逐字节相同**（黄金样本不变）。
  `mode_<p>` 的内容与默认模式为 `<p>` 时 `by_mode` 的内容相同（由同一个函数生成）。全局（`proxy`）直接 `goto proxy`，不需要单独的链。游戏模式（`host_udp*`）在 `proxy` 链里判断，对所有覆盖模式都有效。
- 开头的 `table … / delete table …` 两行让同一份文件既能首次加载，也能整体替换，并且在一个事务里完成，
  替换过程中不会出现规则缺口。
- `input_guard` 能工作的原因：经过 TPROXY 的包目的地址仍是远端 IP，`fib daddr type local` 不成立；
  只有直接连路由器内部端口的包才会被丢弃。Xray 的 tunnel 入站因此可以按官方透明代理教程监听 `0.0.0.0`。
- QUIC 拒绝用第二个标记位 `QUIC_MARK=0x00100000`（加入 [01](01-architecture.md) 常量表）。
  `reject` 用于 UDP 时默认回 ICMP port-unreachable，正好是 QUIC 回落需要的信号。
- **chinadns-ng 写入的三个动态集合（`gfw4`、`udirect4`、`uproxy4`）必须带 `flags interval`**：chinadns-ng 总是把每个 IP 作为区间（起点 + `NFT_SET_ELEM_INTERVAL_END` 终点）写入（源码 `src/ipset.c` 的 `add_ip_nftset()`），写进普通集合会被内核以 EINVAL 拒绝。2026-10-15 真机窗口中 `gfw` 模式因此完全失效（`gfw4` 始终为空），CI 的 chinadns-ng 校验只启动进程、不写集合，没能发现。同日在设备上用一张不挂钩子的临时表对照验证：chinadns-ng 2025.06.20 向普通集合写入报 EINVAL、集合为空；向带 `flags interval; auto-merge;` 的集合写入成功。
- 动态集合（`gfw4`、`udirect4`、`uproxy4`）在整表替换前先导出，替换时写回（`{{restored …}}`），
  详见 [04](04-lifecycle.md)。

## 与 fw4 的对接

LAN 区域的 `input` 策略如果不是 ACCEPT（例如访客网络区域），fw4 会在 **自己的** input 链里拒绝经 TPROXY
送到本机的包，而本表的 accept 拦不住其他表的 drop。所以包内附带一个静态 include：

`/usr/share/nftables.d/chain-pre/input/30-aether-proxy.nft`
```nft
meta mark & 0x00080000 == 0x00080000 accept comment "aether-proxy: tproxy delivered"
```

fw4 会把它插在 `inet fw4` 的 input 链最前面（firewall4 模板里的 `fw4.includes('chain-prepend', 'input')`）。
aether-proxy 未运行时没有包带这个标记，这条规则不起作用。**这是 aether-proxy 唯一写进 fw4 的东西**，并且是安装时
随包放入的静态文件，运行时不修改它。安装或卸载后需要执行一次 `fw4 reload`（写在包的 postinst / **postrm** 中：卸载时必须等 include 文件删除之后再 reload，放在 prerm 里摘不掉规则）。

## 内核与模块前提

启动前检查，缺少任一项都直接失败（`PRECHECK_FAILED`，附带缺失项）：

- `nft` 可用，且 `nft -c -f` 能通过包含 `tproxy`、`socket` 表达式的测试规则（等价于检查 `kmod-nft-tproxy`、`kmod-nft-socket`）
- `ip rule` 支持 fwmark/mask（`ip-full`）
- `lan_ifaces` 中的每个接口都存在

**真机核实（2026-10-14）**：在一台 aarch64 设备上（自建 lede，系统版本 24.10.5、内核 6.18.55、ip-full 6.18、Xray 26.9.30）运行 `aether-proxy check`，
三种模式生成的规则均通过 `nft -c`（含 `tproxy`、`socket transparent`、`fib`、`ether saddr`），生成的 Xray 配置均通过 `run -test`，
前置检查全部通过。这只验证了规则能被内核接受，规则加载后的实际行为仍待 S2/S3。

**加载后的行为（2026-10-15 同一设备的维护窗口，绕过大陆模式）**：整表加载与 `ip rule`/`ip route` 成功；`fw4 reload` 之后 `inet aetherproxy` 仍在；
LAN 客户端访问境外站点经节点（出口为节点 IP），访问国内站点直连（出口为本地运营商），视频站点正常。
第二次窗口（同日）：按 **MAC** 匹配的主机（`policy=proxy`、`udp=1`）全部流量经节点，**WebRTC/STUN 查到的公网 IP 为节点 IP**（游戏模式 UDP 经节点生效）；
从 LAN 访问路由器的 `31080` 端口超时（`input_guard` 丢弃生效）；整表原子替换成功。`gfw` 模式失败，原因见下方「动态集合必须带 `flags interval`」。
第三次窗口（同日，T1.12 修正后）：`gfw` 模式下解析被墙域名后 IP 写入 `gfw4`（3 分钟内随 LAN 访问增长到 49 个元素，chinadns-ng 零报错），被墙站点经节点、不在 gfwlist 中的站点直连，均符合设计。
尚未覆盖：QUIC 拒绝、动态集合导出后恢复（属于 M2 daemon 的行为，随 M2 验收）。

## 已知限制（写进用户文档）

- GFW 模式依赖 DNS 填充 `gfw4`：客户端如果绕过路由器 DNS（浏览器内置 DoH、Android 严格模式私有 DNS），
  这些域名不会进入集合，会走直连。开启 DNS 劫持只能覆盖明文 53 端口。首版不封锁 853 端口
  （封锁会让 Android 严格模式直接断网），在 LuCI 中说明。
- 开机后 `gfw4` 为空，而客户端里仍缓存着旧解析结果，在 TTL 过期前这部分访问会走直连。服务重启时有导出/恢复
  机制兜底，整机重启没有。
- 硬件流量卸载（flow offload）只影响直连的转发流量，TPROXY 流量走本机 input，不受影响。
  首版需要在开启软件、硬件卸载两种情况下各做一次实测（[11](11-plan.md) 测试矩阵）。
