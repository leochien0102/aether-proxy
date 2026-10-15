# 03 DNS

## 链路

```
LAN 客户端 ─53─▶ dnsmasq（系统实例）─▶ chinadns-ng 127.0.0.1:31053
                                         ├─ china 组 ──▶ 国内 DNS（UDP，直连）
                                         ├─ trust 组 ──▶ 按 DNS 级别：T1 / T2 / T3
                                         ├─ 自定义组 boot ──▶ 直连境外 DNS（引导解析节点域名）
                                         ├─ 自定义组 udirect ──▶ 国内 DNS，结果写入 udirect4
                                         └─ 自定义组 uproxy  ──▶ 同 trust，结果写入 uproxy4
路由器本机（resolveip、curl）走 /etc/resolv.conf → dnsmasq → 同一条链路
```

已核实的 ChinaDNS-NG 行为（zfl9/chinadns-ng README，2025.08.09 构建为 wolfssl 版）：

- 同一组内的多个上游**并发查询、取最先到达的应答**，没有顺序回退。
- 上游写法 `proto://[host@]ip[#port]`，`tls://` 即 DoT（需要 wolfssl 构建，helloworld 打包的正是该版本）。
- `tag:none`（不在任何列表中的域名）会同时查询 china 组和 trust 组，china 组应答的 IP 在 `ipset-name4` 中就采用它，否则采用 trust 组的应答。
- 最多 6 个自定义组，**后声明的优先级高**；nft 集合名写作 `inet@aetherproxy@<set>`。
- `no-ipv6` 不带参数时过滤全部 AAAA；`filter-qtype 65` 过滤 HTTPS 记录。

**结论**：评审中「经节点 → 直连 → 国内」这条回退链不能交给 chinadns-ng 完成，改由 monitor 根据健康状态**切换 trust 组的上游**（DNS 级别）。
三级上游绝不放进同一组并发查询，否则被污染的抢答会赢得竞争。

## 各模式的分流

| 模式 | gfwlist | chnlist | default-tag | add-taggfw-ip |
|---|---|---|---|---|
| `gfw` | gfw 域名 | — | `chn` | `inet@aetherproxy@gfw4` |
| `bypass_cn` | gfw 域名 | 国内加速域名 + Apple 域名 | `none`（按 chnroute4 判定） | — |
| `global` | — | Apple 域名 | `gfw` | — |

三种模式共用的自定义组（声明顺序 = 优先级从低到高）：

| 组 | 域名来源 | 上游 | group-ipset |
|---|---|---|---|
| `uproxy` | `/etc/aether-proxy/custom/proxy_domain.txt` | 与 trust 相同（随 DNS 级别切换） | `inet@aetherproxy@uproxy4` |
| `udirect` | `/etc/aether-proxy/custom/direct_domain.txt` | china_dns | `inet@aetherproxy@udirect4` |
| `boot` | 所有节点的域名（渲染时生成 `/var/run/aether-proxy/boot.txt`） | direct_dns | — |

Apple 域名在全局模式下放进 chnlist，用国内 DNS 解析，但**不会写入任何直连集合**，流量照常走代理——
与需求一致（Apple 库只决定解析结果，不改变路由）。

## DNS 级别（trust 组上游）

| 级别 | trust 组上游 | 进入条件 |
|---|---|---|
| T1 代理 | `tcp://127.0.0.1#31082`、`tcp://127.0.0.1#31083`（Xray tunnel，固定转发到 `trust_dns[0..1]`:53，出站走节点） | 代理健康 |
| T2 直连 | `direct_dns` 列表（默认 `tcp://8.8.8.8`、`tcp://1.1.1.1`；可写 `tls://dns.google@8.8.8.8`） | 启动预热中，或代理不健康 |
| T3 国内 | `china_dns` 列表 | T2 也失败，且 `allow_china_fallback=1` |

切换规则（由 monitor 执行，见 [04](04-lifecycle.md)、[07](07-probe.md)）：

- 启动时一律从 **T2** 开始，代理健康检测首次通过后升到 T1。这样 Xray 就绪之前 DNS 也能用。
- 代理不健康 → 降到 T2。
- 处于 T2 时，做 DNS 探测：经 dnsmasq 解析 `dns_probe_domain`（默认 `www.google.com`），
  连续 2 次失败或超时 → 降到 T3（仅当 `allow_china_fallback=1`）。
- 处于 T3 时，每 5 分钟尝试回到 T2 一次（切换后探测，失败则退回 T3）。
- 任何级别下，代理健康检测连续通过 `recover_threshold` 次 → 直接回到 T1。
- **每次切换级别**：重新渲染 chinadns-ng 配置并重启它（顺带清空它的缓存），然后向 dnsmasq 发送
  `SIGHUP`（清空 dnsmasq 缓存）。这样降级期间混入的污染应答不会在恢复后继续存留。
- T3 期间 `uproxy4`/`gfw4` 可能被写入污染 IP。污染 IP 只会被判为代理，造成的影响仅限代理这一侧，
  首版不做清理。

为什么接受 T3：T3 只在代理和直连境外 DNS 都不可用时才会进入，此时境外站点本来就打不开。T3 的作用是让
**国内站点照常解析**。

## chinadns-ng 配置模板

渲染产物 `/var/run/aether-proxy/chinadns.conf`，启动命令 `chinadns-ng -C /var/run/aether-proxy/chinadns.conf`。

```
bind-addr 127.0.0.1
bind-port 31053
china-dns {{china_dns | join(",")}}
trust-dns {{trust_upstreams_for_tier | join(",")}}
ipset-name4 inet@aetherproxy@chnroute4
ipset-name6 null
{% if mode == "gfw" %}
gfwlist-file {{data}}/gfwlist.txt
default-tag chn
add-taggfw-ip inet@aetherproxy@gfw4,null
{% elif mode == "bypass_cn" %}
gfwlist-file {{data}}/gfwlist.txt
chnlist-file {{data}}/chnlist.txt,{{data}}/apple.txt
default-tag none
{% else %}
chnlist-file {{data}}/apple.txt
default-tag gfw
{% endif %}
group uproxy
group-dnl /etc/aether-proxy/custom/proxy_domain.txt
group-upstream {{trust_upstreams_for_tier | join(",")}}
group-ipset inet@aetherproxy@uproxy4,null
group udirect
group-dnl /etc/aether-proxy/custom/direct_domain.txt
group-upstream {{china_dns | join(",")}}
group-ipset inet@aetherproxy@udirect4,null
group boot
group-dnl /var/run/aether-proxy/boot.txt
group-upstream {{direct_dns | join(",")}}
{% if ipv6_filter %}
no-ipv6
{% endif %}
{% if filter_https_rr %}
filter-qtype 65
{% endif %}
cache 4096
cache-stale 3600
verdict-cache 4096
```

实现时核实项（用随包附带的 chinadns-ng 版本跑 `chinadns-ng -C <file>` 验证）：

- ~~空的 `group-dnl` 文件能否被接受~~：已核实（2025.08.09 源码 `src/dnl.c`）。文件不存在只记 warning，空文件不加载任何域名，都不会退出。渲染时**总是创建**这些文件（可以为空），避免 warning。
- `cache-stale` 在 T3 → T1 切换时是否会把旧应答带回来。重启进程会清空缓存，理论上不会。
- `bypass_cn` 下 gfwlist 与 chnlist 的先后顺序：默认 gfwlist 优先，这里保持默认。

## dnsmasq 对接

- **只写一个易失的 conf-dir 片段**，绝不修改 `/etc/config/dhcp`：
  ```
  # /tmp/dnsmasq.<实例>.d/aether-proxy.conf
  no-resolv
  server=127.0.0.1#31053
  ```
- conf-dir 路径的确定方法：读取 `/var/etc/dnsmasq.conf.*` 中的 `conf-dir=` 行。有多个实例时，选择服务
  `lan_ifaces` 的那个实例。UCI `aetherproxy.dns.dnsmasq_instance` 可以显式指定。找不到时失败（`DNSMASQ_CONFDIR_NOT_FOUND`）。
- 写入或删除片段之后执行 `/etc/init.d/dnsmasq restart`（conf-dir 变化需要重启，SIGHUP 不会重新读取配置）。
- 如果检测到 UCI 中已配置 `list server`，记一条 WARN（`DNSMASQ_EXTRA_SERVERS`）：这些服务器会和 aether-proxy 并行，
  可能导致 DNS 泄漏或污染。只提示，不去改它。
- 片段放在 tmpfs，整机重启后自然消失。aether-proxy 不随开机启动时，DNS 就是用户原来的配置。

## 引导解析（节点域名）

1. 渲染时把所有节点域名写入 `boot.txt`，chinadns-ng 对这些域名使用 `direct_dns`，不经过 Xray。
2. 启动流程中，chinadns-ng 和 dnsmasq 片段就位之后，用 `resolveip -4 -t 5 <域名>` 解析当前节点的域名
   （走系统解析器，最终落到 `boot` 组）。
3. 成功：把 IP 写进 Xray 出站的 `address`（域名保留在 `serverName` / `host` 中），并更新 LKG 文件
   `/etc/aether-proxy/state/node-ip.json`（值变化时才写）。
4. 失败：使用 LKG 中的 IP，记 WARN `NODE_RESOLVE_FALLBACK`。LKG 也没有：节点不可用，进入降级状态（`NODE_RESOLVE_FAILED`）。
5. monitor 每 10 分钟重新解析一次当前节点的域名。IP 变了就更新 `node_ip4` 集合、重新渲染并重启 Xray（`NODE_IP_CHANGED`）。

为什么把 IP 写进配置、而不是让 Xray 自己解析：Xray 自己解析会走系统解析器 → dnsmasq → chinadns-ng → T1，
T1 又依赖这个节点本身，形成死锁。

## 真机验证（2026-10-15，aarch64 / 自建 lede / 内核 6.18 / chinadns-ng 2025.06.20 / Xray 26.9.30）

在一次维护窗口中按 04 的启动顺序手工拉起各组件（绕过大陆模式）：

- chinadns-ng 2025.06.20 接受本文模板生成的全部配置项（低于设计最低版本 2025.08.09，但这些选项都已存在）。
- dnsmasq 默认实例的 conf-dir 为 `/tmp/dnsmasq.d`（`/var/etc/dnsmasq.conf.cfg01411c` 中的 `conf-dir=`）；放入片段并重启即改走 chinadns-ng，删除片段并重启即恢复。
- 国内域名解析到国内地址；AAAA 被过滤；`boot` 组成功解析节点域名；T1（经节点）解析被墙域名正常。
- **T2（直连境外 DNS）解析不了被墙域名**（`www.google.com` 无应答），但能解析未被墙的域名（节点域名）：GFW 针对被墙域名的 TCP DNS 查询做了干扰。
  这符合 T2 的定位（代理不可用时让未被墙的境外域名照常解析），但意味着**启动后到首次健康检测通过之间，被墙域名会短暂解析失败**，属预期行为，写进用户文档。
- **`china_dns` 中的 `119.29.29.29` 在 chinadns-ng 走 TCP 时被反复重置**（`recv(tcpi://119.29.29.29) failed: Connection reset by peer`），
  国内解析因另一个上游 `223.5.5.5` 正常而未受影响。默认值已改为 `223.5.5.5`、`114.114.114.114`（05，2026-10-15 决定）。
- 本次未覆盖：`gfw` 模式下 `gfw4` 的填充、`udirect4`/`uproxy4` 的填充、chinadns-ng 重启后缓存清空、dnsmasq SIGHUP 清缓存。

## IPv4-only 的泄漏处理

- `ipv6_filter=1`（默认）：chinadns-ng `no-ipv6`，所有 AAAA 查询返回 NODATA。
- `filter_https_rr=1`（默认）：过滤 HTTPS 记录（qtype 65），避免其中的 `ipv6hint` 让客户端走 IPv6。
- LAN 侧 RA/DHCPv6 不由 aether-proxy 修改。如果检测到 LAN 接口存在全局 IPv6 地址，在 LuCI 状态页提示（`IPV6_PRESENT`）：
  「客户端仍可能通过 IPv6 直连，建议关闭 LAN 的 IPv6 分配」。
