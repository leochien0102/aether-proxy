# 01 架构总览

## 组件与进程

```
LAN 客户端
  │ DNS(53)                         │ TCP/UDP 业务流量
  ▼                                 ▼
dnsmasq ──server=──▶ chinadns-ng    nft table inet aetherproxy（prerouting / mangle）
（系统自带，LAN DNS 入口）   │          │ 命中「代理」 → TPROXY → xray :31080
                         │          │ 其余 → 放行（直连）
          ┌──────────────┼──────────┐
          ▼              ▼          ▼
     国内 DNS     T1: xray tunnel   T2: 直连境外 DNS（tcp:// 或 tls://）
     (china)      :31082/:31083     T3: 国内 DNS
                  → 节点 → 境外 DNS
                         ▲
aether-proxy daemon（常驻）── 探测代理健康 → 切换 DNS 级别 / 故障放行 / 重新解析节点 IP / 自检 nft 表
```

| 进程 | 托管方式 | 说明 |
|---|---|---|
| `aether-proxy daemon` | procd 唯一实例，respawn | 监督进程：按顺序启动、拉起并重启子进程、monitor 循环，见 [04](04-lifecycle.md) |
| `xray` | daemon 的子进程 | 只用于透明代理、DNS 隧道、本机 HTTP 代理入站 |
| `chinadns-ng` | daemon 的子进程 | 只监听 127.0.0.1 |
| `dnsmasq` | 系统自带 | 只通过 conf-dir 片段对接，不改 UCI |

**一次性命令**（start、stop、reload、订阅、更新、检测）都通过 `aether-proxy <子命令>` 执行，
由 init 脚本、cron、rpcd 调用。所有修改系统状态的子命令都要先拿全局锁 `/var/lock/aether-proxy.lock`（flock）。

## 设计原则

1. **不拦截路由器本机流量**（OUTPUT 链不挂任何规则）。Xray 自身的出站天然不会被重定向，
   不需要防环 mark。代价：路由器上其他程序（opkg、ntp 等）全部直连。aether-proxy 自己需要走代理的下载
   （订阅、更新）显式使用 Xray 的本机 HTTP 入站 `127.0.0.1:31081`。
2. **独立 nft 表**。fw4 的 start/reload 只重建 `inet fw4`，不影响其他表（已在 firewall4
   `18fc0ead` 源码核实：`fw4 stop` 只删 `inet fw4`，只有手动 `fw4 flush` 会删全部表）。
   因此**不使用** `/usr/share/nftables.d/ruleset-post` 持久化规则集（ssr-plus 那套缓存是 U7/U8 缺陷的来源）。
   monitor 每轮检查表是否存在，丢失即重建。
3. **易失优先**：所有运行时生成物放在 `/var/run/aether-proxy/`（tmpfs）。断电或崩溃后重启即回到干净状态，
   dnsmasq 片段放 tmpfs，重启后自然消失，不会把用户的 DNS 永久改坏。
4. **渲染与应用分离**：先把所有配置渲染到 staging 目录并校验（`xray run -test`、`nft -c -f`），
   全部通过后才开始改系统状态。

## 常量（唯一来源，代码中集中定义）

| 名称 | 值 | 用途 |
|---|---|---|
| `NFT_TABLE` | `inet aetherproxy` | 唯一的 nft 表 |
| `TPROXY_PORT` | `31080` | Xray tunnel 透明代理入站（TCP+UDP） |
| `HTTP_PORT` | `31081` | Xray HTTP 入站，仅 127.0.0.1，供 aether-proxy 自身下载与健康检测 |
| `DNS_TUNNEL_PORTS` | `31082`、`31083` | Xray tunnel 入站，分别固定转发到 trust_dns[0]、trust_dns[1] 的 53/TCP |
| `CHINADNS_PORT` | `31053` | chinadns-ng 监听 127.0.0.1 |
| `FWMARK` | `0x00080000/0x00080000` | TPROXY 标记（单独一位，避开 mwan3 默认的 `0x3F00`） |
| `QUIC_MARK` | `0x00100000` | 待拒绝的 QUIC 包（prerouting 打标记，forward 中 reject） |
| `ROUTE_TABLE` | `233` | `local default dev lo` |
| `RULE_PREF` | `900` | `ip rule` 优先级，排在 mwan3（1000+）之前 |
| `RESERVED4` | `0.0.0.0/8`、`10.0.0.0/8`、`100.64.0.0/10`、`127.0.0.0/8`、`169.254.0.0/16`、`172.16.0.0/12`、`192.0.0.0/24`、`192.0.2.0/24`、`192.88.99.0/24`、`192.168.0.0/16`、`198.18.0.0/15`、`198.51.100.0/24`、`203.0.113.0/24`、`224.0.0.0/4`、`240.0.0.0/4` | nft `reserved4` 集合的内容（IANA 特殊用途地址；`240.0.0.0/4` 已包含广播地址）。顺序即渲染顺序 |
| `XRAY_MIN_VERSION` | `26.9.30` | 渲染器所针对的 Xray 版本；低于它拒绝启动（[06](06-nodes-subscription.md)） |
| `CHINADNS_MIN_VERSION` | `2025.08.09` | 同上，针对 chinadns-ng |

端口全部低于 32768，避开 Linux 默认的临时端口范围。首版不开放修改，冲突时只改常量。

## 设备上的目录

| 路径 | 介质 | 内容 |
|---|---|---|
| `/etc/config/aetherproxy` | flash | UCI 配置（[05](05-config.md)） |
| `/etc/aether-proxy/custom/*.txt` | flash | 用户自定义域名/IP 列表 |
| `/etc/aether-proxy/data/` | flash | 已更新的规则数据（覆盖包内基线） |
| `/etc/aether-proxy/keys/` | flash（包内） | usign 公钥 |
| `/etc/aether-proxy/state/` | flash | 少量需要跨重启的状态：节点 LKG IP、订阅最后成功时间。**只在值变化时写** |
| `/usr/share/aether-proxy/data/` | ROM（包内） | 规则数据基线快照 |
| `/usr/share/aether-proxy/bin/<组件>/<版本>/` | overlay | aether-proxy 自己下载的组件二进制 |
| `/usr/share/aether-proxy/bin/<组件>/current` | overlay | 指向当前版本的符号链接 |
| `/usr/share/nftables.d/chain-pre/input/30-aether-proxy.nft` | 包内静态文件 | 放行带 FWMARK 的入站（见 [02](02-dataplane.md)） |
| `/var/run/aether-proxy/` | tmpfs | 渲染产物、`state.json`、`events.jsonl`、`jobs/`、staging |
| `/tmp/aether-proxy-dl/` | tmpfs | 下载临时目录 |

## 组件二进制的查找顺序

1. UCI `aetherproxy.main.xray_bin` / `chinadns_bin` 显式指定的路径（高级选项）
2. `/usr/share/aether-proxy/bin/<组件>/current/<组件>`（aether-proxy 管理的版本）
3. 系统 `PATH` 中的同名程序（feed 安装的 `xray-core`、`chinadns-ng` 包）
4. 都没有：start 失败，事件 `COMPONENT_MISSING`，LuCI 引导用户下载或上传

## 包拆分

| 包 | 内容 | 架构 | 依赖 |
|---|---|---|---|
| `aether-proxy` | `aether-proxy`、init 脚本、hotplug、默认配置、数据基线、公钥、fw4 include | `all` | `firewall4`、`kmod-nft-tproxy`、`kmod-nft-socket`、`ip-full`、`curl`、`ca-bundle`、`resolveip`、`usign`、`dnsmasq`（任一变体均可，`dnsmasq-full` 等变体声明了 `PROVIDES:=dnsmasq`），以及下面的 ucode 模块 |
| `luci-app-aether-proxy` | JS 视图、rpcd 插件、ACL、菜单 | `all` | `aether-proxy`、`luci-base`、`rpcd-mod-ucode` |
| `luci-i18n-aether-proxy-zh-cn` | 翻译（luci.mk 自动生成） | `all` | — |

**不硬依赖** `xray-core` / `chinadns-ng`：官方 OpenWrt feed 里没有 chinadns-ng，aether-proxy 会自行下载
（[08](08-updates.md)）。feed 里有的发行版（lede、ImmortalWrt）可以装上，当作基线兜底。

ucode 模块依赖：`ucode`、`ucode-mod-fs`、`ucode-mod-uci`、`ucode-mod-socket`、`ucode-mod-uloop`、`ucode-mod-digest`、`ucode-mod-log`、`ucode-mod-resolv`（与 [12](12-ucode.md) 一致）。
官方 24.10.8 与 25.12.5 的 base feed 中均已提供（2026-10-14 核对下载目录）。`luci-app-aether-proxy` 另需 `rpcd-mod-ucode`。

## 仓库布局（独立 feed 仓库）

公开的 GitHub 仓库 `leochien0102/aether-proxy`。在固件构建的 `feeds.conf` 中以 feed 名 `aetherproxy` 接入（`src-git aetherproxy https://github.com/leochien0102/aether-proxy.git;main`）。

```
aether-proxy/
├── docs/                      本目录
├── aether-proxy/              后端包
│   ├── Makefile
│   ├── files/                 init.d、hotplug、默认 uci、keys、nftables.d include
│   └── src/                   命令 aether-proxy 的 ucode 源码（布局见 12）
├── luci-app-aether-proxy/
│   ├── Makefile
│   ├── htdocs/luci-static/resources/view/aether-proxy/*.js
│   ├── root/usr/share/rpcd/{acl.d,ucode}/
│   ├── root/usr/share/luci/menu.d/luci-app-aether-proxy.json
│   └── po/zh_Hans/aether-proxy.po
├── tests/                     golden 测试与夹具（[11](11-plan.md)）
└── .github/workflows/         包构建（SDK 24.10 / 25.12）+ 更新通道发布（[08](08-updates.md)）
```
