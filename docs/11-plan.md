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

M4 与 M5、M6 可以并行。

### 进度（2026-10-15）

M2 实际做的范围比上表大：M3 的全部功能和 M4 的大部分功能都已在 M2 中实现，并在真机上验证（[04](04-lifecycle.md)「真机验证」，以及 02、03 中的探针记录）。剩下的工作：

| 里程碑 | 状态 | 剩余 |
|---|---|---|
| M0、M1、M2 | 完成 | — |
| M3 | 功能完成；验收 B 部分通过（节点不通降级与恢复、`fw4 reload`、WAN 重拨） | 真机补测：Xray 无法重启 → `failsafe`；chinadns-ng 无法重启 → DNS 回落；`fw4 flush` 后重建；启动失败的退避重试 |
| M4 | 大部分完成；验收 C 部分通过（MAC 匹配、游戏模式 UDP、QUIC 拒绝、三种模式切换不重启 Xray、集合导出恢复） | 核对并补测：三种主机策略与两种 `unlisted_policy` 逐一验证、DNS 劫持（客户端手动指定 8.8.8.8）、自定义列表 |
| M5 | T5.1（URI 解析）、T5.2（身份匹配）完成 | T5.3 `sub update`（下载、匹配、原子应用）；之后 daemon 内的定时更新随作业机制（M6）一起做 |
| M6 | T6.1（同步版节点检测）完成 | 作业机制（`job start/status`），把检测和订阅包装成作业 |
| M7 | 未开始 | 先定 D3（签名密钥） |
| M8、M9 | 未开始 | — |

M3、M4 的真机补测合并成一次窗口，在 T5.3 之后安排。

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
└── uri/<用例名>.txt + .expected.json      URI 解析
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

ssr-plus 与 aether-proxy **不得同时启用**（两者都会接管 dnsmasq 和 TPROXY）。aether-proxy 启动前检测到 ssr-plus、passwall、openclash
处于运行状态时直接拒绝启动（`PRECHECK_FAILED missing=conflict:<名称>`）。
