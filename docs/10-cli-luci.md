# 10 命令行、rpcd 与 LuCI

## 分层

```
LuCI（JS 视图） ──ubus──▶ rpcd 插件 `aetherproxy`（薄层，只做参数校验和转发）──exec──▶ aether-proxy <子命令> --json
init.d / hotplug / daemon ─────────────────────────────────────────────────▶ aether-proxy
```

**所有业务逻辑都在 `aether-proxy` 中**。rpcd 插件不实现任何逻辑。这样不论后端用什么语言，LuCI 这一层都不受影响，
命令行也能完成 LuCI 能做的所有事情（方便排障和自动化测试）。

## `aether-proxy` 约定

- 带 `--json` 时，向 stdout 输出**恰好一个** JSON 对象；人读信息走 stderr。
- 退出码：`0` 成功；`1` 运行时错误；`2` 配置错误；`3` 忙（拿不到锁或已有同类作业）；`4` 校验或验签失败。
  具体对应（T1.7 实现，2026-10-14 确认）：配置校验错误与规则数据缺失/非法 → `CONFIG_INVALID`，退出码 2；前置检查失败 → `PRECHECK_FAILED`，退出码 1；产物未通过 `nft -c` / `xray run -test` → `RENDER_INVALID`，退出码 4；参数用法错误 → JSON 中 `code` 为 `USAGE`（不是事件码，不写日志），退出码 2。
- `check` 找不到 Xray 时不算失败：在结果中注明跳过 `xray run -test`，并返回 `COMPONENT_MISSING` 警告；真正启动时（04 第 3 步）缺组件才是错误。
- 失败时的 JSON：`{"ok": false, "code": "<事件码>", "detail": "..."}`。

| 子命令 | 作用 | 是否长任务 |
|---|---|---|
| `daemon [--boot]` | procd 实例入口（[04](04-lifecycle.md)） | 常驻 |
| `check` | 校验配置并完成全部渲染，不改动系统状态 | 否 |
| `cleanup` | 幂等清理 | 否 |
| `status` | 输出 `state.json`，并附带 `probe.json` 摘要和 `updates_available` | 否 |
| `render <xray\|nft\|chinadns\|dnsmasq>` | 把渲染结果输出到 stdout（排障、测试用） | 否 |
| `probe nodes [<id>...]` | 节点 TCP 可达性检测 | 是 |
| `sub update [<sub>]` | 更新订阅（不带参数时更新全部） | 是 |
| `node import <uri>` | 导入单个 URI 作为手动节点 | 否 |
| `update check` | 检查新版本 | 是 |
| `update component <name> [--version v]` | 安装组件 | 是 |
| `update upload <name> <path>` | 安装手动上传的组件 | 是 |
| `update data` | 更新规则数据 | 是 |
| `job start <子命令...>` | 以后台作业方式运行一个长任务，立即返回 `{"job": "<id>"}` | 否 |
| `job status <id>` | 输出作业状态 | 否 |
| `events [--since ts] [--level l]` | 读取结构化事件 | 否 |
| `log [--source aether-proxy\|xray\|dns] [--lines n]` | 读取 logd 中的相关行 | 否 |

### 仅供测试的选项

`check` 与 `render` 接受下列选项，用于在宿主机上脱离真实系统运行测试。rpcd 插件**不准**传递这些选项：

| 选项 | 作用 |
|---|---|
| `--confdir <目录>` | UCI 配置目录（默认 `/etc/config`），其中的文件名为 `aetherproxy` |
| `--data-dir <目录>` / `--baseline-dir <目录>` / `--custom-dir <目录>` | 覆盖规则数据、包内基线、自定义列表目录 |
| `--run-dir <目录>` | 覆盖 `/var/run/aether-proxy`（staging 与 `boot.txt` 所在位置） |
| `--no-precheck` | 跳过前置检查与外部工具校验（`nft -c`、`xray run -test`），只做配置校验与渲染 |

## 作业机制

LuCI 发起的长任务**必须**通过 `job start` 执行，原因：

- uhttpd 默认 `network_timeout` 为 30 秒，`max_requests` 为 3。长请求会被掐断，并发请求会排队。
- LuCI 25.12 起 `XHR.get/post` 落到 `LuCI.prototype.poll()`，该 promise 链没有 `.catch()`：请求失败（超时、连接中断）时回调永远不会执行，长请求一断，界面就会永久卡住。

作业状态文件 `/var/run/aether-proxy/jobs/<id>.json`：

```json
{"id": "j_1760400000_1234", "cmd": "sub update", "state": "running|ok|failed", "started": 0, "finished": 0, "result": {}, "error": null}
```

- 同一时间每种作业只允许运行一个（订阅、检测、更新各自互斥）。重复发起返回退出码 3，并附带正在运行的作业 ID。
- 前端每 2 秒轮询一次 `job status`。轮询使用 settle-once 写法：回调、`.catch()`、硬超时三条路径谁先到谁生效。
- 作业文件保留 1 小时。

## rpcd 插件

形式：`/usr/share/rpcd/ucode/aetherproxy.uc`（rpcd 的 ucode 插件机制，与后端语言选择无关，24.10 起可用）。
插件只做两件事：校验参数（白名单 + 正则），然后执行 `aether-proxy … --json` 并原样返回。

| ubus 方法 | 参数 | 对应命令 |
|---|---|---|
| `status` | — | `status` |
| `service` | `action: start\|stop\|restart` | `/etc/init.d/aether-proxy <action>` |
| `check` | — | `check` |
| `job_start` | `kind: probe_nodes\|sub_update\|update_check\|update_component\|update_data`，`args`（按 kind 校验） | `job start …` |
| `job_status` | `id`（正则 `^j_[0-9]+_[0-9]+$`） | `job status` |
| `events` | `since`、`level` | `events` |
| `log` | `source`、`lines`（1–2000） | `log` |
| `node_import` | `uri`（≤ 4096 字节） | `node import` |
| `upload_component` | `name`、`path`（必须位于 `/tmp/aether-proxy-upload/` 下） | `job start update upload …` |
| `list_file` / `save_file` | `name: direct_domain\|proxy_domain\|direct_ip\|proxy_ip`，`content` | 读写 `/etc/aether-proxy/custom/<name>.txt`（保存前逐行校验） |

ACL：`/usr/share/rpcd/acl.d/luci-app-aether-proxy.json`。读方法（`status`、`events`、`log`、`job_status`、`list_file`）归 read，
其余归 write；同时授予 UCI `aetherproxy` 配置的读写权限。

文件上传使用 LuCI 自带的 `cgi-upload`，目标路径固定在 `/tmp/aether-proxy-upload/`。

## LuCI 页面

菜单路径：服务 → aether-proxy。全部使用 JS 视图（`form.Map` + `uci`），禁止 Lua。

| 页面 | 内容 |
|---|---|
| 概览 | 状态（`state`、DNS 级别、当前节点、最近一次健康检测、各组件版本）、启停按钮、待处理提示（组件缺失、有可用更新、IPv6 提示、dnsmasq 额外上游）。每 5 秒刷新 |
| 节点 | 节点表格（名称、地址、协议/传输/安全层、来源、stale 标记、TCP 可达/延迟）；设为当前节点；检测（选中的/全部）；编辑节点；导入 URI |
| 订阅 | 订阅列表与编辑；「立即更新」；最近一次结果（时间、节点数、按原因统计的跳过数） |
| 访问控制 | `unlisted_policy`；主机表（名称、IP、MAC、策略、游戏模式）。MAC 输入框提供 DHCP 租约下拉。冲突在保存前校验 |
| 规则与 DNS | 模式；自定义直连/代理的域名与 IP（四个 textarea）；DNS 设置；数据版本与「立即更新」 |
| 更新 | 组件版本（当前、previous、最新）、安装/回滚按钮、手动上传、更新策略 |
| 日志 | 事件页（默认）+ 原始日志页（[09](09-logging.md)） |
| 高级 | `lan_ifaces`、`quic_block`、`dns_hijack`、`ipv6_filter`、`filter_https_rr`、`fail_open`、`sniffing`、日志等级、开机等待、健康检测参数、二进制路径 |

UI 规则：

- 破坏性按钮（删除节点、删除订阅、回滚组件）使用 `cbi-button-remove`，并要求确认；不要使用 `cbi-button-reset`（那是中性的「撤销表单修改」）。
- 前端同时发出的请求不超过 2 个（为 uhttpd 的 `max_requests 3` 留出余量）。
- 翻译包 `luci-i18n-aether-proxy-zh-cn` 与功能包分开生成。修改 po 后两个包要一起安装。
