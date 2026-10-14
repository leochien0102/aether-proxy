# ADR-0002 后端实现语言

- 状态：**已定：ucode**（2026-10-14，用户确认）。实现规范见 [12-ucode.md](../12-ucode.md)。
- 背景：所有接口（UCI schema、渲染产物、`aether-proxy` 命令与 JSON、rpcd 方法、文件布局）都已与语言无关。语言只影响 `aether-proxy` 的内部实现、
  测试运行器和打包方式。

## 后端需要的能力

| 能力 | 用在哪里 |
|---|---|
| JSON 生成与解析 | Xray 配置、state、事件、清单、作业 |
| 读写 UCI | 全部 |
| Base64、URL 解码 | 订阅 |
| SHA-256 | 身份匹配键（可以调用 `sha256sum`） |
| 不依赖 DNS、可计时的 TCP connect | 节点检测、开机等待 |
| 子进程监督（拉起、退避重启、转发 stdout） | daemon |
| 信号与定时器 | daemon |

## 选项

| | ucode（推荐） | shell | Go |
|---|---|---|---|
| 设备体积 | 0（系统自带）+ 几个模块包 | 0 | +5–10MB，每种架构一份 |
| JSON / UCI | 原生模块 | 只能靠 `jsonfilter`、`jshn`，生成复杂 JSON 很脆弱 | 标准库 |
| TCP 计时 | `ucode-mod-socket` | 没有可靠工具 | 标准库 |
| 子进程监督 | `ucode-mod-uloop`（process、timer、signal） | 可以做，但很难写对 | 标准库 |
| 包架构 | `all`，一次构建适用所有设备 | `all` | 按架构构建，CI 成本高，aether-proxy 本身也成了一个需要分发的组件 |
| 宿主机测试 | 需要在宿主机编译 ucode（简单） | 直接运行 | `go test` |
| 交给便宜 agent 实现 | 中：资料少，但语法类似 JS，有 fw4 和 LuCI 的大量代码可以参考 | 容易写，难写对（ssr-plus 的教训） | 容易写对，生态资料最多 |
| 与 OpenWrt 生态一致 | 高（fw4、rpcd、LuCI 后端都用 ucode） | 高 | 低 |

**推荐 ucode**：零体积、架构无关，rpcd 插件本来就用 ucode，能力也全部覆盖。
## 核实结果（2026-10-14）

| 检查项 | 官方 24.10.8 | 官方 25.12.5 | 自建 lede |
|---|---|---|---|
| ucode 版本 | 2025.07.18（`3f64c808`） | 2026.01.16（`85922056`） | 2026.07.09 |
| `ucode-mod-socket` / `uloop` / `uci` / `fs` | 都有 | 都有 | socket、uci、fs 已选中；uloop 在源码树中可选 |
| `ucode-mod-digest`（SHA-256） | 有 | 有 | — |
| `ucode-mod-resolv`（DNS 客户端，可直接向指定服务器查询） | 有 | 有 | — |
| `uloop.process` / `signal` / `timer` / `interval` | 有 | 有 | — |
| `rpcd-mod-ucode` | 有 | 有 | — |
| `usign` | 有 | 有 | — |

能力表中的每一项都有对应模块。唯一的缺口：`uloop.process` 不能重定向子进程的 stdio，影响「按来源打日志标签」，
有替代方案（[09](../09-logging.md)「子进程日志」），由 M0 的探针任务 S1 确认。

参考实现：ImmortalWrt 的 homeproxy（sing-box）同样是 ucode 后端加 JS 前端（[backlog](../backlog.md) B1 也列了它）。

**不推荐 shell**：本项目最复杂的部分（JSON 渲染、订阅解析、身份匹配、子进程监督）正是 shell 最不擅长的，也正是 ssr-plus 缺陷集中的地方。
