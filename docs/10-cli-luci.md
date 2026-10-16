# 10 命令行、rpcd 与 LuCI

## 分层

```
LuCI（JS 视图） ──ubus──▶ rpcd 插件 `aetherproxy`（薄层，只做参数校验和转发）──exec──▶ aether-proxy <子命令> --json
init.d / hotplug / daemon ─────────────────────────────────────────────────▶ aether-proxy
```

**所有业务逻辑都在 `aether-proxy` 中**。rpcd 插件不实现任何逻辑。这样不论后端用什么语言，LuCI 这一层都不受影响，
命令行也能完成 LuCI 能做的所有事情（方便排障和自动化测试）。

## `aether-proxy` 约定

- 带 `--json` 时，stdout 输出**恰好一个** JSON 对象，**stderr 为空**（事件照常写 syslog）；不带 `--json` 时输出人读文本。
- 退出码：`0` 成功；`1` 运行时错误；`2` 配置错误；`3` 忙（拿不到锁或已有同类作业）；`4` 校验或验签失败。
  具体对应（T1.7 实现，2026-10-14 确认）：配置校验错误与规则数据缺失/非法 → `CONFIG_INVALID`，退出码 2；前置检查失败 → `PRECHECK_FAILED`，退出码 1；产物未通过 `nft -c` / `xray run -test` → `RENDER_INVALID`，退出码 4；参数用法错误 → JSON 中 `code` 为 `USAGE`（不是事件码，不写日志），退出码 2。
- `check` 找不到 Xray 时不算失败：在结果中注明跳过 `xray run -test`，并返回 `COMPONENT_MISSING` 警告；真正启动时（04 第 3 步）缺组件才是错误。
- 失败时的 JSON：`{"ok": false, "code": "<事件码>", "detail": "..."}`。

| 子命令 | 作用 | 是否长任务 |
|---|---|---|
| `daemon [--boot]` | procd 实例入口（[04](04-lifecycle.md)） | 常驻 |
| `check` | 校验配置并完成全部渲染，不改动系统状态 | 否 |
| `cleanup` | 幂等清理 | 否 |
| `status` | 输出 `state.json`，并附带 `probe`（`probe.json` 摘要：`{ "at", "total", "reachable" }`，没有就为 `null`）和 `updates_available`（M7 之前恒为 `null`） | 否 |
| `render <xray\|nft\|chinadns\|dnsmasq>` | 把渲染结果输出到 stdout（排障、测试用） | 否 |
| `probe nodes [<id>...]` | 节点 TCP 可达性检测 | 是 |
| `sub update [<sub>]` | 更新订阅（不带参数时更新全部） | 是 |
| `node import <uri>` | 导入单个 URI 作为手动节点 | 否 |
| `update check` | 检查新版本 | 是 |
| `update package <包> [--previous]` | 从发布通道安装软件包（`xray-core`、`aether-proxy`、`luci-app-aether-proxy`），`--previous` 安装上一个版本（[08](08-updates.md)） | 是 |
| `update data` | 更新规则数据 | 是 |
| `job start <子命令...>` | 以后台作业方式运行一个长任务，立即返回 `{"job": "<id>"}` | 否 |
| `job status <id>` | 输出作业状态 | 否 |
| `events [--since ts] [--level l]` | 读取结构化事件。`--since` 包含边界（`ts >= since`）；`--level` 表示**该等级及以上**（例如 `warn` 返回 warn 与 error） | 否 |
| `log [--source aether-proxy\|xray\|dns] [--lines n]` | 读取 logd 中的相关行 | 否 |

### 仅供测试的选项

`check`、`render`、`status`、`events`、`probe`、`daemon`、`cleanup` 接受下列选项中与自己相关的部分，用于在宿主机上脱离真实系统运行测试。rpcd 插件**不准**传递这些选项：

| 选项 | 作用 |
|---|---|
| `--confdir <目录>` | UCI 配置目录（默认 `/etc/config`），其中的文件名为 `aetherproxy` |
| `--data-dir <目录>` / `--baseline-dir <目录>` / `--custom-dir <目录>` | 覆盖规则数据、包内基线、自定义列表目录 |
| `--run-dir <目录>` | 覆盖 `/var/run/aether-proxy`（staging 与 `boot.txt` 所在位置） |
| `--no-precheck` | 跳过前置检查与外部工具校验（`nft -c`、`xray run -test`），只做配置校验与渲染 |
| `--sys-root <目录>` | 系统路径前缀（`/etc/init.d/*`、`/var/etc`、`/tmp/dnsmasq.d`、`/proc/net/tcp`、`/sys/class/net`、`/var/lock`、`/etc/aether-proxy/state`），即 T2.3 的 `ctx.root`。用于 `daemon`、`cleanup`、`sub`、`job`、`probe` |
| `--bin-dir <目录>` | 外部命令从该目录取（命令替身），即 T2.3 的 `ctx.bin_dir`；子进程（xray、chinadns-ng）的可执行文件同样从这里找。用于 `daemon`、`cleanup`、`check`、`sub`、`job`、`probe` |

`job start` 把这些选项原样转给子命令，同时经环境变量 `AETHER_PROXY_JOB_RUN_DIR`、`AETHER_PROXY_JOB_SYS_ROOT`、`AETHER_PROXY_JOB_BIN_DIR` 交给后台的 `job run`（它自己的作业文件位置要跟着变）。
若干测试专用的环境变量只用于缩短集成测试中的等待：`AETHER_PROXY_TEST_RETRY_DELAY`（启动重试间隔）、`AETHER_PROXY_TEST_SCHEDULE_INTERVAL_MS`、`AETHER_PROXY_TEST_SCHEDULE_HOUR_SECS`（订阅调度）；正式环境不设置。

## 作业机制

LuCI 发起的长任务**必须**通过 `job start` 执行，原因：

- uhttpd 默认 `network_timeout` 为 30 秒，长请求会被掐断；`max_requests 3` 只限制 cgi/ucode/lua 脚本请求（超出的排队），经 `/ubus` 的 rpcd 调用不计入，但 rpcd 串行处理调用，长调用会挡住其他调用。
- LuCI 25.12 起 `XHR.get/post` 落到 `LuCI.prototype.poll()`，该 promise 链没有 `.catch()`：请求失败（超时、连接中断）时回调永远不会执行，长请求一断，界面就会永久卡住。

作业状态文件 `/var/run/aether-proxy/jobs/<id>.json`：

```json
{"id": "j_1760400000_1234", "cmd": "sub update", "state": "running|ok|failed", "started": 0, "finished": 0, "result": {}, "error": null}
```

- 同一时间每种作业只允许运行一个（订阅、检测、更新各自互斥）。重复发起返回退出码 3，并附带正在运行的作业 ID。
- 前端每 2 秒轮询一次 `job status`。轮询使用 settle-once 写法：回调、`.catch()`、硬超时三条路径谁先到谁生效。
- 作业文件保留 1 小时。

实现约定（2026-10-15 定，T6.2）：

- **允许的作业**（`job start` 后面跟的子命令，按前两个词识别种类）：`probe nodes [<id>...]` → 种类 `probe_nodes`；`sub update [<sub>]` → `sub_update`。
  M7 再加 `update check` → `update_check`、`update package …` → `update_package`、`update data` → `update_data`（三者共用一把「更新」锁，同时只跑一个）。其他子命令一律拒绝（`USAGE`，退出码 2）。
- **作业 ID**：`j_<启动时间秒>_<发起进程 pid>`，满足正则 `^j_[0-9]+_[0-9]+$`。
- **作业文件**在 `<run-dir>/jobs/<id>.json`，字段：`id`、`kind`、`cmd`（显示用字符串）、`argv`（数组，工作进程据此执行，不经 shell 拼接）、`state`、`pid`（工作进程）、
  `started`、`finished`、`exit`（子命令退出码）、`result`（子命令 `--json` 输出解析后的对象）、`error`（失败时的 `code`，没有就为 `CMD_FAILED`）。全部经 `sys.write_atomic` 写。
- **启动**：`job start` 先检查同种类是否有 `running` 且 pid 仍存活（核对 `/proc/<pid>/cmdline` 含 `job run`）的作业，有就退出码 3（`{"ok": false, "code": "BUSY", "job": "<id>"}`）；
  否则写作业文件（`running`），以 `sh -c '"$@" </dev/null >/dev/null 2>&1 &' sh <自身> job run <id>` 的方式放到后台后**立即返回** `{"job": "<id>"}`。
  后台进程被 init 收养，不依赖发起者存活（rpcd 调用结束、daemon 重启都不影响）。
- **工作进程** `job run <id>`（内部子命令，不出现在用法说明里）：取种类锁 `/var/lock/aether-proxy-job-<kind>.lock`（拿不到 → 作业记为 `failed`、`error: BUSY`），
  把自身 pid 写进作业文件，经 `sys.run` 执行 `<自身> <argv…> --json`（超时 600 秒，作业进程不受 daemon 的 10 秒限制），解析输出，写 `ok`/`failed`。
- **自身路径**：`/usr/bin/aether-proxy`；指定了 `--bin-dir` 时用 `<bin-dir>/aether-proxy`（测试放一个包装脚本）。`job start` 收到的测试选项（`--confdir`、`--run-dir`、`--sys-root`、`--bin-dir`）原样传给子命令。
- **工作进程消失**：`job status` 读到 `running` 但 pid 已不存在（或命令行不再匹配）→ 改写为 `failed`、`error: JOB_LOST`，记 WARN `JOB_LOST`。
- **清理**：每次 `job start` 删除 `finished` 早于 1 小时的作业文件；内容损坏的作业文件（原子写入下只可能来自外部破坏）记 `FS_FAILED` 后删除，不阻止新作业。
- `job status <id>`：输出作业文件（`--json` 时原样，否则人读格式）；ID 格式不对 → `USAGE`（退出码 2）；文件不存在 → `JOB_NOT_FOUND`（退出码 2，不是事件码）。

## rpcd 插件

形式：`/usr/share/rpcd/ucode/aetherproxy.uc`（rpcd 的 ucode 插件机制，与后端语言选择无关，24.10 起可用）。
插件只做两件事：校验参数（白名单 + 正则），然后执行 `aether-proxy … --json` 并原样返回。

| ubus 方法 | 参数 | 对应命令 |
|---|---|---|
| `version` | — | `version` |
| `status` | — | `status` |
| `service` | `action: start\|stop\|restart` | `/etc/init.d/aether-proxy <action>` |
| `check` | — | `check` |
| `job_start` | `kind: probe_nodes\|sub_update\|update_check\|update_package\|update_data`，`args`（按 kind 校验） | `job start …` |
| `job_status` | `id`（正则 `^j_[0-9]+_[0-9]+$`） | `job status` |
| `events` | `since`、`level` | `events` |
| `log` | `source`、`lines`（1–2000） | `log` |
| `node_import` | `uri`（≤ 4096 字节） | `node import` |
| `list_file` / `save_file` | `name: direct_domain\|proxy_domain\|direct_ip\|proxy_ip`，`content` | 读写 `/etc/aether-proxy/custom/<name>.txt`（保存前逐行校验） |

ACL：`/usr/share/rpcd/acl.d/luci-app-aether-proxy.json`。读方法（`status`、`events`、`log`、`job_status`、`list_file`）归 read，
其余归 write；同时授予 UCI `aetherproxy` 配置的读写权限。

文件上传使用 LuCI 自带的 `cgi-upload`，目标路径固定在 `/tmp/aether-proxy-upload/`。

实现约定（2026-10-16 定，T8.1）：

- **转发**：执行 `/usr/bin/aether-proxy <子命令…> --json`（`sys.run`，参数数组，不经 shell）。stdout 能解析为 JSON 对象 → **原样返回，不论退出码**
  （命令行的 JSON 已带 `ok`/`code`，例如 `job start` 忙时的 `{"ok": false, "code": "BUSY", "job": …}`）；
  否则返回 `{"ok": false, "code": "CMD_FAILED", "detail": "exit <退出码>: <stderr 前 512 字节>"}`，超时的 `detail` 为 `timeout after <秒>s`。
- **参数错误**：不执行任何命令，返回 `{"ok": false, "code": "USAGE", "detail": "…"}`。缺省的可选参数等同于不传；传了未知参数名，按 rpcd 的规则忽略。
- **超时**：`check` 30 秒，其余 10 秒（rpcd 串行处理调用，每个调用必须很快；长任务一律走 `job_start`）。
- **`service`**：重启可能超过 30 秒（停止要等子进程退出），所以放到后台执行后立即返回 `{"ok": true, "action": "<action>"}`：
  `sh -c '"$0" "$1" </dev/null >/dev/null 2>&1 &' /etc/init.d/aether-proxy <action>`。结果由前端轮询 `status` 得知。
- **`job_start` 的参数**（`args` 为字符串数组，缺省为空数组）：

  | `kind` | `args` | 执行 |
  |---|---|---|
  | `probe_nodes` | 0–256 个节点段名（`^n_[0-9a-f]{32}$`，不得重复） | `job start probe nodes [<id>…]` |
  | `sub_update` | 空，或 1 个订阅段名（`^s_[0-9a-f]{8}$`） | `job start sub update [<sub>]` |
  | `update_check`、`update_data` | 必须为空 | `job start update check` / `job start update data` |
  | `update_package` | `[<包>]` 或 `[<包>, "--previous"]`，包名属于 `xray-core`、`aether-proxy`、`luci-app-aether-proxy`、`luci-i18n-aether-proxy-zh-cn` | `job start update package <包> [--previous]` |

- **`events`**：`since` 为非负整数，`level` 为 `error|warn|notice|info|debug`，都可省略。
- 每个方法在插件中声明 `args`（rpcd 据此做类型检查），类型不符时 rpcd 直接拒绝，插件里仍按上面的规则再校验一遍。
- **仅供测试**：环境变量 `AETHER_PROXY_TEST_RPCD_CLI`、`AETHER_PROXY_TEST_RPCD_INIT` 分别替换命令行与 init 脚本的路径（与其他 `AETHER_PROXY_TEST_*` 一样，生产环境不设置）。
- `log`、`node_import`、`list_file`/`save_file` 要等命令行实现对应子命令（T8.2）后再加，T8.1 不提供。

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
