# aether-proxy 设计文档

## 命名（已定，2026-10-14）

名称中不绑定 Xray，为以后支持多个代理核心留出空间。分三种写法，**不准混用**：

| 写法 | 用在哪里 |
|---|---|
| `aether-proxy`（带连字符） | 仓库名、包名（`aether-proxy`、`luci-app-aether-proxy`、`luci-i18n-aether-proxy-zh-cn`）、命令 `aether-proxy`、init 脚本 `/etc/init.d/aether-proxy`、目录（`/etc/aether-proxy`、`/usr/share/aether-proxy`、`/var/run/aether-proxy`）、syslog 标签、LuCI 菜单与视图路径、po 文件名 |
| `aetherproxy`（不带连字符） | 机器标识符：UCI 配置 `/etc/config/aetherproxy`、nft 表 `inet aetherproxy`（nft 标识符不允许连字符）、ubus/rpcd 对象 `aetherproxy`、feeds.conf 中的 feed 名、ucode/shell 中的变量与常量前缀 |
| **显示名** `Aether Proxy`，中文「以太跃迁」（2026-10-20，仓库所有者定） | 只用于 LuCI 的菜单标题与页面标题。英文界面显示 `Aether Proxy`，中文界面显示「以太跃迁」（Aether 译作以太；「跃迁」代指越过网络限制，不直白地写「代理」「翻墙」） |

判断规则：会被 nft、UCI、ubus 当作**标识符解析**的地方用 `aetherproxy`，其余一律用 `aether-proxy`。
界面正文提到本服务时**不写名称**，写「服务」（如「停止服务后所有流量直连」）；指向具体程序的地方（包名、命令、日志来源、syslog 标签）仍用 `aether-proxy`。

状态：**可以开工**（2026-10-14）。设计已完成，M0、M1 任务卡已拆好。仓库将公开在 GitHub `leochien0102/aether-proxy`。实现预计交给其他 agent 完成，所以本目录要写到
**照着做就不需要再做设计决定**的程度。遇到文档没覆盖的问题，按「给实现者的规则」处理。

## 文档索引

| 文件 | 内容 | 实现前必读 |
|---|---|---|
| [01-architecture.md](01-architecture.md) | 组件、进程、设备上的目录、包拆分 | 全部任务 |
| [02-dataplane.md](02-dataplane.md) | nft 表、判定顺序、TPROXY、游戏模式、DNS 劫持 | M2、M4 |
| [03-dns.md](03-dns.md) | dnsmasq ↔ ChinaDNS-NG ↔ Xray，三级 DNS、引导解析 | M2、M3 |
| [04-lifecycle.md](04-lifecycle.md) | 启停顺序、状态机、故障放行、监控循环、开机等待 | M2、M3 |
| [05-config.md](05-config.md) | UCI schema 与文件布局 | 全部任务 |
| [06-nodes-subscription.md](06-nodes-subscription.md) | URI 解析、节点身份匹配、订阅原子更新、Xray 出站映射 | M1、M5 |
| [07-probe.md](07-probe.md) | 节点可达性检测、代理健康检测 | M3、M6 |
| [08-updates.md](08-updates.md) | 签名清单、组件与数据更新、回滚、CI 发布通道 | M7 |
| [09-logging.md](09-logging.md) | 日志等级、事件码、展示 | 全部任务 |
| [10-cli-luci.md](10-cli-luci.md) | `aether-proxy` 命令约定、rpcd/ubus 接口、LuCI 页面 | M8 |
| [11-plan.md](11-plan.md) | 里程碑、任务拆分、验收标准、测试方法 | 全部任务 |
| [12-ucode.md](12-ucode.md) | ucode 实现规范：目录布局、编码规则、测试、打包、协作流程 | 全部任务 |
| [tasks/](tasks/README.md) | 任务卡（当前：M0、M1） | 领卡时 |
| [adr/](adr/) | 架构决策记录 | 改动对应设计前 |
| [backlog.md](backlog.md) | 尚未设计的未来功能（如自定义分流），以及现有设计中要保持开放的地方 | 改动数据面、Xray 配置、订阅引用逻辑前 |

## 首版范围（已确定）

- 目标：OpenWrt 多平台多架构；**仅 fw4/nftables**（[ADR-0001](adr/0001-fw4-only.md)）。
- 固件：自建 lede + luci 25.12、OpenWrt 官方 24.10（opkg）、官方 25.12（apk）、ImmortalWrt。
  **包格式由发行版的编译配置（`CONFIG_USE_APK`）决定，与版本号无关**：自建 lede 的 LuCI 是 25.12 分支，但系统版本号为 24.10.5、
  用 opkg/ipk（2026-10-14 核对 lede 源码与构建配置），所以安装 24.10.8 SDK 编出的 ipk（包架构 `all`，按名称依赖，可通用）。
- 代理核心只有 Xray；首版只支持 IPv4，IPv6 按「过滤 AAAA」处理，不实现代理。
- 功能：节点可达性检测、GFW／绕过大陆／全局三种模式、LAN 访问控制（含游戏模式）、
  启动前连通性检查、组件／规则／IP 数据更新、日志。
- 不做：自定义分流与固定节点（Netflix、AI 等）、Clash YAML 策略组、IPv6 代理、多节点自动切换、
  路由器本机流量代理。

## 待定事项

| 编号 | 事项 | 影响 | 状态 |
|---|---|---|---|
| D1 | 后端实现语言 | — | **已定**：ucode，见 [ADR-0002](adr/0002-backend-language.md)、[12-ucode.md](12-ucode.md) |
| D2 | 正式名称 | — | **已定**：`aether-proxy` / `aetherproxy`，见上方「命名」 |
| D3 | 更新通道签名密钥由谁持有、放在哪个仓库的 Secrets | M7 | **已定**（2026-10-15）：仓库所有者持有私钥；发布 CI 与私钥放在**单独的发布仓库** `aether-proxy-channel`；离线备份在所有者的密码管理器中。见 [08](08-updates.md)「签名」「发布仓库」 |
| D4 | 许可证与维护者（LICENSE、Makefile 中的 `PKG_LICENSE` / `PKG_MAINTAINER`） | 发布、复制第三方代码、接受外部贡献 | **已定**（2026-10-19，仓库所有者）：**GPL-3.0-or-later**，全文见仓库根目录 `LICENSE`；维护者 `leochien0102 <leochien0102@users.noreply.github.com>`（不公开真实邮箱）。随包的规则数据按各自许可证在 `files/data/SOURCES.md` 中注明并随包安装。理由：希望衍生版本（例如预装进固件再分发）保持开源；同类项目多为 GPL-3.0，选它才能在需要时合法引用 |

## 给实现者的规则

1. **不要自行做设计决定。** 文档没写清楚的地方，在 PR 描述里列成问题，按最保守的方式实现（失败时
   不改动系统状态），并在代码里标 `TODO(design):`。
2. **不准用 `2>/dev/null`、`|| true` 吞错误。** 每个外部命令失败都要带命令名和退出码记日志。
   这是 ssr-plus 一类缺陷的头号来源（见 [ADR-0001](adr/0001-fw4-only.md) 的背景）。
3. **只写自己的地盘。** 不准修改 `/etc/config/dhcp`、`/etc/config/firewall`、`/etc/config/network`。
   与 dnsmasq、fw4 的所有对接只通过本文档规定的易失文件（`/tmp`、`/var/run`）和固定 include 文件完成。
4. **LuCI 只用 JS 视图 + rpcd，不准用 Lua。** 官方 24.10 默认不带 Lua 运行时。
5. **渲染器必须是纯函数**：输入为配置快照加数据文件，输出为文本；不在渲染时调用外部命令或读取运行态。
   每个渲染器都要有 golden 测试（[11-plan.md](11-plan.md)）。
6. **变更检测比对的是渲染输出的哈希，不是输入。** 不准做「配置没变就从缓存恢复」那种快路径。
7. 所有端口、mark、表名都是 [01-architecture.md](01-architecture.md) 中的常量，不准散落硬编码。
8. **默认不复制其他项目的代码**，参考设计思路、自己写。本项目为 GPL-3.0-or-later（D4，2026-10-19），
   只有与之兼容的代码才可能引入（GPL-3.0、LGPL、MIT、BSD、Apache-2.0 等；**GPL-2.0-only 不兼容**，专有代码不行）。
   确实需要引入时，先停下来在报告中说明来源、许可证与理由，由设计负责人决定；引入的文件保留原版权声明，并在文件开头注明出处。
9. **不准根据版本号推断能力**：不要用 `/etc/openwrt_release` 的版本号判断包管理器、防火墙后端、ucode 能力等。
   自建 lede 报告 24.10.5，却带 25.12 的 LuCI、6.18 内核和更新的 ucode。需要判断时直接探测（命令是否存在、模块能否加载、`nft -c` 能否通过）。

## 术语

| 术语 | 含义 |
|---|---|
| 主机策略 | 每台 LAN 主机的 `follow` / `direct` / `proxy` 三选一，见 [02](02-dataplane.md) |
| 模式 | 全局运行模式 `gfw` / `bypass_cn` / `global`，只对 `follow` 主机生效 |
| DNS 级别 | T1 经代理、T2 直连境外、T3 国内兜底，见 [03](03-dns.md) |
| 故障放行 | Xray 不可用时摘除拦截规则，流量全部直连，见 [04](04-lifecycle.md) |
| LKG | last known good，最近一次已知可用的值（节点 IP、组件版本） |
