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
| 0 | 不是从 `lan_ifaces` 进入，或不是 TCP/UDP | 直连 | |
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
| `gfw` | 命中 `gfw4`（DNS 动态填充）或 `gfw_static4` → 代理；否则直连 |
| `bypass_cn` | 命中 `chnroute4` → 直连；否则代理 |
| `global` | 代理 |

**「代理」动作**：

- TCP：一律 TPROXY。
- UDP：源主机开启了游戏模式（`host_udp4` / `host_udp_mac`）→ TPROXY；
  否则如果 `quic_block=1` 且目的端口是 443 → `reject`（让浏览器立即回落到 TCP，不必等 QUIC 超时）；
  否则直连。

## 主机策略模型（替代多张名单）

每台主机在 UCI 里只有一个 `host` 段（[05](05-config.md)）：

- `policy`：`follow`（跟随模式）／ `direct`（不走代理）／ `proxy`（强制代理）
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
`direct` → `proxy` → `follow` 生效，并在 LuCI 中提示。

MAC 匹配用 `ether saddr`，只对在二层直连 LAN 网桥的主机有效（经过另一台路由器的主机看到的是那台路由器的 MAC）。

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
	set gfw4        { type ipv4_addr; {{restored gfw4}} }      # chinadns-ng add-taggfw-ip
	set udirect4    { type ipv4_addr; {{restored udirect4}} }  # chinadns-ng group-ipset
	set uproxy4     { type ipv4_addr; {{restored uproxy4}} }   # chinadns-ng group-ipset

	set host_direct4    { type ipv4_addr;  flags interval; auto-merge; ... }
	set host_direct_mac { type ether_addr; ... }
	set host_proxy4     { type ipv4_addr;  flags interval; auto-merge; ... }
	set host_proxy_mac  { type ether_addr; ... }
	set host_follow4    { type ipv4_addr;  flags interval; auto-merge; ... }
	set host_follow_mac { type ether_addr; ... }
	set host_udp4       { type ipv4_addr;  flags interval; auto-merge; ... }
	set host_udp_mac    { type ether_addr; ... }

	chain prerouting {
		type filter hook prerouting priority mangle; policy accept;
		iifname != { {{LAN_IFACES}} } return
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

- 开头的 `table … / delete table …` 两行让同一份文件既能首次加载，也能整体替换，并且在一个事务里完成，
  替换过程中不会出现规则缺口。
- `input_guard` 能工作的原因：经过 TPROXY 的包目的地址仍是远端 IP，`fib daddr type local` 不成立；
  只有直接连路由器内部端口的包才会被丢弃。Xray 的 tunnel 入站因此可以按官方透明代理教程监听 `0.0.0.0`。
- QUIC 拒绝用第二个标记位 `QUIC_MARK=0x00100000`（加入 [01](01-architecture.md) 常量表）。
  `reject` 用于 UDP 时默认回 ICMP port-unreachable，正好是 QUIC 回落需要的信号。
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
随包放入的静态文件，运行时不修改它。安装或卸载后需要执行一次 `fw4 reload`（写在包的 postinst / prerm 中）。

## 内核与模块前提

启动前检查，缺少任一项都直接失败（`PRECHECK_FAILED`，附带缺失项）：

- `nft` 可用，且 `nft -c -f` 能通过包含 `tproxy`、`socket` 表达式的测试规则（等价于检查 `kmod-nft-tproxy`、`kmod-nft-socket`）
- `ip rule` 支持 fwmark/mask（`ip-full`）
- `lan_ifaces` 中的每个接口都存在

## 已知限制（写进用户文档）

- GFW 模式依赖 DNS 填充 `gfw4`：客户端如果绕过路由器 DNS（浏览器内置 DoH、Android 严格模式私有 DNS），
  这些域名不会进入集合，会走直连。开启 DNS 劫持只能覆盖明文 53 端口。首版不封锁 853 端口
  （封锁会让 Android 严格模式直接断网），在 LuCI 中说明。
- 开机后 `gfw4` 为空，而客户端里仍缓存着旧解析结果，在 TTL 过期前这部分访问会走直连。服务重启时有导出/恢复
  机制兜底，整机重启没有。
- 硬件流量卸载（flow offload）只影响直连的转发流量，TPROXY 流量走本机 input，不受影响。
  首版需要在开启软件、硬件卸载两种情况下各做一次实测（[11](11-plan.md) 测试矩阵）。
