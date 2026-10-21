# 11 实施计划

## 前置条件

D1 已定为 ucode（[ADR-0002](adr/0002-backend-language.md)），实现规范见 [12-ucode.md](12-ucode.md)。M0、M1 的任务卡已拆好，见 [tasks/](tasks/README.md)。

## 里程碑

| 里程碑 | 内容 | 依赖 | 完成标志 |
|---|---|---|---|
| M0 | 仓库骨架、两个包的 Makefile、宿主机测试环境、CI 用 SDK 24.10 / 25.12 出 ipk 与 apk；探针 S1–S6 | — | CI 出包，装到 x86 虚拟机上 `aether-proxy version` 可运行；探针结论已写回设计 |
| M1 | 配置读取、校验、四个渲染器（纯函数）与 golden 测试 | M0 | 测试全部通过；CI 中对渲染出的 Xray 配置执行真实的 `xray run -test`，对 nft 文件执行 `nft -c -f` |
| M2 | daemon、启停、cleanup、数据面；单个手动节点；`bypass_cn` 模式；DNS 固定 T2 | M1 | 设备验收 A |
| M3 | 代理健康检测、DNS 级别切换、故障放行、chinadns 失效保护、monitor 自检、hotplug | M2 | 设备验收 B |
| M4 | 主机策略、游戏模式、QUIC 拒绝、DNS 劫持、`gfw` / `global` 模式、自定义列表、动态集合导出恢复 | M2 | 设备验收 C |
| M5 | URI 解析、订阅、身份匹配、原子应用、stale | M1 | 解析与匹配的单元测试全部通过；设备上用真实订阅验证 |
| M6 | 作业机制、节点 TCP 检测 | M2 | `aether-proxy job start probe nodes` 能出结果 |
| M7 | 发布通道 CI（数据 + 组件 + 签名）、设备端下载/验签/安装/回滚 | M6 | 设备验收 D |
| M8 | LuCI 全部页面与 rpcd 插件 | M3–M7 | 每个页面的功能逐项手测 |
| M9 | 事件翻译、用户文档、完整测试矩阵 | 全部 | 矩阵全绿 |
| M10 | 前端体验：按仓库所有者逐页看页面的意见改界面（2026-10-20 起）；前端加载体验（backlog B11） | M8 | 每张卡复审通过；改过的页面在真机上看过 |

M4 与 M5、M6 可以并行。

### 进度（2026-10-20）

M2 实际做的范围比上表大：M3 的全部功能和 M4 的大部分功能都在 M2 中实现，并在真机上验证（[04](04-lifecycle.md)「真机验证」，以及 02、03 中的探针记录）。各里程碑的任务卡与状态见 [tasks/](tasks/README.md)。

| 里程碑 | 状态 | 剩余 |
|---|---|---|
| M0、M1、M2 | 完成（M2 真机验收 A 于 2026-10-15 通过） | — |
| M3 | 完成：验收 B 通过（2026-10-15 两次窗口）。PPPoE 重拨在 DHCP 线路上以 `ifup wan` 代替 | — |
| M4 | 完成：验收 C 通过（三种主机策略、两种 `unlisted_policy`、MAC 匹配、游戏模式 UDP、QUIC 拒绝、DNS 劫持、自定义名单、模式切换不重启 Xray） | — |
| M5 | 完成：T5.1–T5.3；真实订阅在设备上验证（7 个节点，二次更新不变）；daemon 内的定时更新随 M6 的 T6.3 完成 | — |
| M6 | 完成：T6.1 节点检测、T6.2 作业机制、T6.3 订阅定时更新 | — |
| M7 | 完成：发布通道 channel-stable（2026-10-16 首发，数据每天更新）；验收 D 于 2026-10-20 用官方通道在真机上做（T7.7，[backlog](backlog.md) B12），篡改清单、Xray 更新、数据实际变化三项以宿主机测试为准，不另建测试通道 | — |
| M8 | 完成：全部页面、rpcd 插件与 Dashboard；逐页手测在 2026-10-19 的两次真机窗口完成（问题见 backlog B10，已全部修复）；真机发现的问题修到 T8.23 | 前端加载体验（backlog B11）移入 M10 |
| M9 | 事件翻译已在 M8 完成（T8.10）并加全局闸门（T9.1）；CI 安装冒烟矩阵六格全绿（T9.3）；矩阵结果见下方「测试矩阵」（T9.4）；用户文档初稿已推送（T9.2）；M10 回归发现的后端问题已修（T9.5，backlog B13） | 用户文档由仓库所有者审定 |
| M10 | 进行中（2026-10-20 起）：T10.1 翻译上下文已完成；T10.2 显示名已完成；T10.3 概览页重排已完成；T10.4 概览页真机修正已完成；T10.5 概览页第二轮修正已完成；T10.6 概览页第三轮修正已完成；T10.7 data status 提速已完成；T10.8 命令行按需加载已完成；T10.9 概览页第四轮修正已完成；T10.10 规则与 DNS 页先出页面已完成；T10.11 切换节点未生效提示已完成；T10.12 页面脚本过期检测已完成；T10.13 概览页第五轮修正已完成；T10.14 确认框改用 ui.showModal 已完成；T10.15 长作业进度与失败恢复已完成；T10.16 各页先出页面已完成；T10.17 概览页先出页面已完成；T10.18–T10.20 已完成，T10.21 已发，T10.22、T10.23 依次待发 | 其余页面等仓库所有者的意见 |

发布：0.2.0-r6 是当前版本（2026-10-20，channel-stable，上一版 0.2.0-r5）；许可证 GPL-3.0-or-later（D4，2026-10-19）。


## 任务卡模板（派给 agent 时使用）

```
任务：<一句话>
必读：docs/README.md 的「给实现者的规则」+ <相关文档章节>
输入：<文件、夹具>
产出：<文件列表>
不准：修改 docs/ 之外的设计；修改 /etc/config/{dhcp,firewall,network}；使用 2>/dev/null 吞错误
验收：<可执行的检查命令及其预期输出>
遇到文档没覆盖的情况：在 PR 描述中列出问题，按最保守的方式实现，代码中标注 TODO(design)
```

**一张卡只对应一个渲染器、一个子命令或一个页面。** 跨模块的改动拆成多张卡。

## 测试分层

### 第 1 层：golden 测试（宿主机运行，每次提交都跑）

```
tests/
├── fixtures/<用例名>/
│   ├── config            UCI 配置（uci -c 能读取的格式）
│   ├── custom/           自定义列表
│   ├── data/             精简的规则数据
│   ├── runtime.json      渲染所需的运行态输入（节点 IP、DNS 级别、恢复的集合）
│   └── expected/         xray.json、aether-proxy.nft、chinadns.conf、dnsmasq.conf
（URI 解析的用例写在 tests/unit/uri.uc 里的表中，不另设 uri/ 目录：用例多为单行 URI，内嵌更便于对照。）
```

必备用例（M1、M4、M5 各自补齐）：

- 三种模式各一个；`unlisted_policy` 两种取值；主机的三种策略各一个，加 MAC 匹配、游戏模式。
- `dns_hijack`、`quic_block` 开与关。
- DNS 级别 T1 / T2 / T3 各一个 chinadns 配置。
- 协议 × 传输 × 安全层：vless+raw+reality+vision、vless+xhttp+tls、vless+ws+tls、vmess+ws+tls、vmess+raw+none、
  trojan+raw+tls、trojan+grpc+tls、ss（AEAD）、ss（2022）。
- 校验失败用例：主机冲突、`direct`+`udp`、缺少字段，期望得到退出码 2 和对应的 `field`。
- 身份匹配：凭据轮换、换 IP（label 不变）、同一 `IP:端口` 下多个节点、节点消失但被引用、节点重新出现。

CI 中额外执行：用真实 Xray 二进制对每个 `expected/xray.json` 执行 `run -test`；用 `nft -c -f` 检查每个 `expected/aether-proxy.nft`
（需要 root 或网络命名空间，用 `unshare -rn` 即可）。

### 第 2 层：网络命名空间集成测试（推荐，M3 之后）

在 Ubuntu CI 中用 netns 搭建「LAN 客户端 ↔ 路由器 ↔ 假节点（本地 Xray 服务端）↔ 假互联网」，加载渲染出的 nft 和 Xray 配置，
验证：被代理目标确实经过假节点，直连目标确实不经过，杀掉 Xray 后故障放行生效。这一层不覆盖 fw4、dnsmasq 和 procd。

### 第 3 层：设备验收

**先在 x86 虚拟机上做，承担实际出口的生产设备放在最后。** 在生产设备上测试必须遵守
「成批、限时、自动回退」：事先写好脚本，用 trap 加外部定时器保证到时恢复，安排在低峰时段，
提前告知会影响可用性多久。不准零散地反复试。

**验收 A（M2）**
- 启用后 `nft list table inet aetherproxy` 存在，`ip rule` 中有 pref 900 的规则
- LAN 客户端访问境外站点走代理（节点侧可以看到连接），访问国内站点直连
- `/etc/init.d/aether-proxy stop` 后：表、rule、dnsmasq 片段全部消失，`/etc/config/dhcp` 无变化（对比 md5）
- 对 daemon 执行 `kill -9` 后再执行 `/etc/init.d/aether-proxy stop`：清理完整
- 断电重启（未启用状态）：没有任何残留

**验收 B（M3）**
- 拔掉节点（在节点侧 NSG 拒绝入站）：约 90 秒内进入 `degraded`，DNS 降到 T2，国内站点不受影响；恢复后回到 `running`/T1，dnsmasq 缓存被清空
- `kill -9` Xray 且让它无法重启（临时把二进制改名）：进入 `failsafe`，规则被摘除，境外非被墙站点可以直连访问
- `kill -9` chinadns-ng 且让它无法重启：DNS 回到 ISP，网络可用
- `fw4 reload`：表不受影响；`fw4 flush`：30 秒内表被重建
- PPPoE 重拨（x86 测试环境）：不触发重启，健康检测恢复正常

**验收 C（M4）**
- 三种主机策略、两种 `unlisted_policy`、MAC 匹配逐一验证
- 游戏模式主机：UDP 经过节点（节点侧可以看到 UDP）；非游戏模式主机的 QUIC 被拒绝，浏览器正常回落
- 客户端手动指定 DNS 为 8.8.8.8：被劫持到路由器（`direct` 主机除外）
- 三种模式切换时只做整表替换，不重启 Xray（看 Xray 的 pid）

**验收 D（M7）**
- 用测试通道（单独的 tag + 测试密钥）完成数据更新和 Xray 更新
- 篡改清单内容：验签失败，没有任何改动
- 发布一个「坏的」Xray（例如试运行输出的版本号不对）：安装被拒绝
- 模拟安装后健康检测失败：自动回滚到 previous
- overlay 空间不足：给出 `NO_SPACE`，不下载

### 测试矩阵（M9）

| 维度 | 取值 |
|---|---|
| 固件 | 自建 lede（luci 25.12，opkg/ipk，内核 6.18）、OpenWrt 24.10（ipk）、OpenWrt 25.12（apk）、ImmortalWrt（当前稳定版，按其实际包格式） |
| 架构 | x86_64、aarch64（如 rk3528）；mipsel 只做安装和渲染冒烟（如果有设备） |
| 流量卸载 | 关闭、软件卸载、硬件卸载（仅支持的设备） |
| 共存 | 同时装有 ssr-plus 但未启用；mwan3 已启用 |

**结果（2026-10-20，T9.4）**：分两层。真机只有一台（H28K）；其余组合在 CI 中用官方 rootfs 容器做安装冒烟（T9.3，`.github/workflows/build.yml` 的 `smoke` 作业，每次改包或冒烟脚本都跑）。

| 组合 | 方式 | 覆盖 | 结果 |
|---|---|---|---|
| 自建 lede：OpenWrt 24.10.5、rockchip/armv8（`aarch64_generic`）、opkg、内核 6.18 | 真机（H28K） | 数据面全部：验收 A–C（M2–M4）、逐页手测（T8.13）、更新与回滚（T7.7，服务运行与不启用两种） | 通过 |
| OpenWrt 24.10.8 x86_64 / aarch64（qemu） | CI 容器 | 软件源解析全部依赖并安装三个包、版本、包内文件、默认配置与 sample 的 `check --no-precheck`、四个渲染产物与宿主机 golden 逐字节一致、rpcd 插件加载、卸载无残留文件 | 通过（各 33 项） |
| OpenWrt 25.12.5 x86_64 / aarch64（qemu），apk | CI 容器 | 同上 | 通过 |
| ImmortalWrt 24.10.6 x86_64 / aarch64（qemu） | CI 容器 | 同上 | 通过 |
| 流量卸载：软件卸载开启 | 真机（H28K 一直开着 `flow_offloading`） | 上面的全部真机测试都在开启状态下通过 | 通过 |
| 流量卸载：关闭 | — | 没有专门测；它是最简单的情况（02「已知限制」：卸载只影响直连转发） | 未测 |
| 流量卸载：硬件卸载 | — | 没有确认支持硬件卸载的设备（H28K 也设了 `flow_offloading_hw`，是否真正生效未核实，所以不算覆盖） | 无环境 |
| 共存：装有 ssr-plus 但未启用 | 真机 | H28K 上与 ssr-plus 交替启用（T8.13、T7.7 的窗口：停 ssr-plus → 启用 aether-proxy → 恢复 ssr-plus）；启用冲突时拒绝启动由宿主机测试覆盖 | 通过 |
| 共存：mwan3 已启用 | — | 没有装 mwan3 的设备；设计上 `FWMARK` 与 `ip rule` 优先级已避开 mwan3 默认值（01「常量」） | 无环境 |
| mipsel 等其他架构 | — | 没有设备；发布通道的 `xray-core`、`chinadns-ng` 只编 `aarch64_generic` 与 `x86_64`（aether-proxy 本身与架构无关） | 无环境 |

容器覆盖不到的：procd/ubus/内核模块（服务启停、nft 与 TPROXY 的实际效果）与安装脚本（容器中按设计屏蔽，postinst/postrm 只在真机上跑过）。这些都只有 H28K 一台真机的证据。

ssr-plus 与 aether-proxy **不得同时启用**（两者都会接管 dnsmasq 和 TPROXY）。aether-proxy 启动前检测到 ssr-plus、passwall、openclash
处于运行状态时直接拒绝启动（`PRECHECK_FAILED missing=conflict:<名称>`）。
