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
| `status` | 输出 `state.json`，并附带 `probe`（`probe.json` 摘要：`{ "at", "total", "reachable" }`，没有就为 `null`）、`updates_available`（`updates.json` 内容）和 `notices`（见「概览页」） | 否 |
| `render <xray\|nft\|chinadns\|dnsmasq>` | 把渲染结果输出到 stdout（排障、测试用） | 否 |
| `probe nodes [<id>...]` | 节点 TCP 可达性检测 | 是 |
| `probe results` | 读取最近的节点检测结果（[07](07-probe.md)） | 否 |
| `sub update [<sub>]` | 更新订阅（不带参数时更新全部） | 是 |
| `sub status` | 读取各订阅最近一次更新的记录（`sub.json`） | 否 |
| `node import <uri>` | 导入单个 URI 作为手动节点 | 否 |
| `update check` | 检查新版本 | 是 |
| `update package <包> [--previous]` | 从发布通道安装软件包（`xray-core`、`aether-proxy`、`luci-app-aether-proxy`），`--previous` 安装上一个版本（[08](08-updates.md)） | 是 |
| `update data` | 更新规则数据 | 是 |
| `job start <子命令...>` | 以后台作业方式运行一个长任务，立即返回 `{"job": "<id>"}` | 否 |
| `job status <id>` | 输出作业状态 | 否 |
| `events [--since ts] [--level l]` | 读取结构化事件。`--since` 包含边界（`ts >= since`）；`--level` 表示**该等级及以上**（例如 `warn` 返回 warn 与 error） | 否 |
| `log [--source aether-proxy\|xray\|dns] [--lines n]` | 读取 logd 中的相关行 | 否 |
| `custom get <名称>` / `custom set <名称> --content <文本>` | 读取 / 校验并保存自定义列表（`direct_domain`、`proxy_domain`、`direct_ip`、`proxy_ip`） | 否 |

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

### `log`、`node import`、`custom`（2026-10-16 定，T8.2）

**`log [--source all|aether-proxy|xray|dns] [--lines n]`**
- 执行 `logread`（`sys.run`，10 秒），只保留标签为 `aether-proxy` 的行（`<日期> <设施>.<等级> aether-proxy[<pid>]: <消息>`）。
  Xray 与 chinadns-ng 继承 daemon 的输出、共用这个标签（[09](09-logging.md)「子进程日志」），按消息内容区分来源：
  消息匹配 `^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9:.]+ \[(Debug|Info|Warning|Error)\]` → `xray`；匹配 `\[[A-Za-z0-9_]+\.zig:[0-9]+` → `dns`；其余 → `aether-proxy`。
  两个格式按上游源码推定，**真机验收（T8.13）时核对**，不符就改这两条规则。
- `--source` 默认 `all`；`--lines` 为 1–2000，默认 200，取过滤后的**最后** n 行，按时间先后排列。
- 输出：`{ "ok": true, "source": "<来源>", "lines": [ { "source": "xray", "text": "<原始整行>" }, … ] }`。没有 `logread` 或它失败 → `CMD_FAILED`，退出码 1。

**`node import <uri>`**（手动添加一个节点）
- 用订阅同一套解析（`lib/uri.uc` 的 `parse_line`）。解析不了或协议不支持 → `{"ok": false, "code": "CONFIG_INVALID", "detail": "<原因：malformed、unsupported_scheme 等>"}`，退出码 2，不写任何东西。
- 已有节点（不论来源）用 `identity.keys()` 现算的 strong 键与它相同（不读存储的 `match_strong`：手填的节点可能没有）→ 不重复添加：`{"ok": true, "node": "<已有段名>", "duplicate": true}`。
- 否则新建段 `n_<32 位十六进制>`（与订阅相同的生成方式），`source manual`，字段取解析结果，`match_strong`/`match_weak` 由 `lib/identity.uc` 计算；
  `label` 取 URI 的 `#名称`，没有就用 `<地址>:<端口>`。写入方式与订阅相同（在工作目录里用改名的包修改，提交后**仅当原文件期间未变**时整体替换，见 [06](06-nodes-subscription.md)），
  原文件期间被改过 → `CONFIG_INVALID`（detail 说明「配置被同时修改，请重试」），退出码 2。
  成功：`{"ok": true, "node": "<新段名>", "duplicate": false}`。解析时的警告（例如 `NODE_INSECURE_IGNORED`）照常记事件。
- 不 reload：新节点不是当前节点，运行中的配置不受影响。设为当前节点由 LuCI 改 `main.node` 后走正常的保存并应用。
- 与订阅更新共用订阅锁（两者都整体替换同一个配置文件）：拿不到锁 → `BUSY`，退出码 3，不写任何东西（T8.2 复审确认，2026-10-16）。

**`custom get <名称>` / `custom set <名称> --content <文本>`**
- 名称与文件：`direct_domain` → `direct_domain.txt`、`proxy_domain` → `proxy_domain.txt`、`direct_ip` → `direct_ip.txt`、`proxy_ip` → `proxy_ip.txt`，目录 `/etc/aether-proxy/custom/`（`--custom-dir` 可替换）。
- `get`：`{"ok": true, "name": "<名称>", "content": "<文件内容>"}`；文件不存在时 `content` 为空字符串。
- `set`：内容不超过 65536 字节（超过 → `USAGE`）。按 [05](05-config.md)「列表文件的解析规则」逐行校验（域名类 `data.parse_domains`，IP 类 `data.parse_cidrs`）。
  有非法行 → `{"ok": false, "code": "CONFIG_INVALID", "detail": "…", "errors": [ { "line": <行号>, "text": "<原文>" }, … ]}`（最多 20 条），退出码 2，文件不变。
  合法：将要写入的内容（补上末尾换行之后）与现有文件相同 → 不写（不写 flash），也不 reload；否则 `sys.write_atomic` 写入（内容末尾补一个换行）。
  写入后服务在运行（`state` 为 `starting`/`running`/`degraded`）→ 执行一次 `/etc/init.d/aether-proxy reload`（失败不回滚文件，`reload` 字段报告）。
  输出 `{"ok": true, "name": "<名称>", "changed": <bool>, "reload": <true|false|"failed">}`。
- 内容经命令行参数传递（rpcd 不写临时文件）：65536 字节远小于 Linux 单个参数的上限（131072）。

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
| `probe_results` | — | `probe results`（read） |
| `sub_status` | — | `sub status`（read） |
| `log` | `source: all\|aether-proxy\|xray\|dns`、`lines`（1–2000），都可省略 | `log` |
| `node_import` | `uri`（≤ 4096 字节，须以 `<协议>://` 开头，防止被当作命令行选项） | `node import <uri>` |
| `list_file` / `save_file` | `name: direct_domain\|proxy_domain\|direct_ip\|proxy_ip`；`save_file` 另有 `content`（≤ 65536 字节） | `custom get <name>` / `custom set <name> --content <content>`（校验与保存都在命令行） |

ACL：`/usr/share/rpcd/acl.d/luci-app-aether-proxy.json`。读方法（`status`、`events`、`log`、`job_status`、`list_file`）归 read，
其余归 write；同时授予 UCI `aetherproxy` 配置的读写权限。

文件上传使用 LuCI 自带的 `cgi-upload`，目标路径固定在 `/tmp/aether-proxy-upload/`。

实现约定（2026-10-16 定，T8.1）：

- **转发**：执行 `/usr/bin/aether-proxy <子命令…> --json`（`sys.run`，参数数组，不经 shell）。stdout 能解析为 JSON 对象 → **原样返回，不论退出码**
  （命令行的 JSON 已带 `ok`/`code`，例如 `job start` 忙时的 `{"ok": false, "code": "BUSY", "job": …}`）；
  否则返回 `{"ok": false, "code": "CMD_FAILED", "detail": "exit <退出码>: <stderr 前 512 字节>"}`，超时的 `detail` 为 `timeout after <秒>s`。
- **参数错误**：不执行任何命令，返回 `{"ok": false, "code": "USAGE", "detail": "…"}`。缺省的可选参数等同于不传。
- **超时**：`check`、`save_file` 30 秒（`save_file` 可能触发 reload），其余 10 秒（rpcd 串行处理调用，每个调用必须很快；长任务一律走 `job_start`）。
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
- 每个方法在插件中声明 `args`。**值是示例，rpcd 按值的类型生成 ubus 参数规则**（`''` 字符串、`0` int32、`[]` 数组、`{}` 对象、`true` 布尔；rpcd `ucode.c`），
  写成 `'int'`、`'array'` 这样的字符串会被当作字符串类型。类型不符或参数名不在声明中 → rpcd 直接返回 `INVALID_ARGUMENT`，不进插件（T8.1 复审时核对源码，2026-10-16）。
  插件里仍按上面的规则再校验一遍。
- **仅供测试**：环境变量 `AETHER_PROXY_TEST_RPCD_CLI`、`AETHER_PROXY_TEST_RPCD_INIT` 分别替换命令行与 init 脚本的路径（与其他 `AETHER_PROXY_TEST_*` 一样，生产环境不设置）。
- `log`、`node_import`、`list_file`/`save_file` 在 T8.2 加入（命令行先实现 `log`、`node import`、`custom`，见上方「`log`、`node import`、`custom`」）；ACL：`log`、`list_file` 归 read，`node_import`、`save_file` 归 write。

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

### 公共模块与菜单（2026-10-16 定，T8.3）

页面共用的逻辑放在一个 LuCI 类模块里：`htdocs/luci-static/resources/aether-proxy/common.js`，页面用 `'require aether-proxy.common as ap'` 引入。
页面里不再直接 `rpc.declare`，也不直接用 LuCI 的 `poll`（它的 promise 链没有 `.catch()`，见上方「作业机制」）。

- **`ap.call(method, params)`**：声明并调用 rpcd 插件的方法（10「rpcd 插件」表中的全部 11 个）。**永不 reject**，只 resolve 一次（settle-once）：
  rpc 的结果、rpc 的失败、硬超时三者谁先到用谁，后到的忽略。失败 → `{ ok: false, code: "RPC_FAILED", detail: "<错误信息>" }`；
  超时 → `{ ok: false, code: "TIMEOUT", detail: "<方法> did not answer in <秒>s" }`。硬超时：`check`、`save_file` 35 秒，其余 15 秒（比插件的 30/10 秒各多 5 秒），
  取自 `ap.TIMEOUTS`（对象，测试可改小）。
- **同时在途 ≤ 2**：模块内对 `ap.call` 计数，超出的调用按先后排队；一个调用 settle 后（包括超时），队首的下一个才发出（UI 规则「同时发出的请求不超过 2 个」）。
- **`ap.poll(fn, interval_ms)`** → `{ stop() }`：每隔 `interval_ms`（小于 2000 按 2000）调用一次 `fn`（返回 promise）。
  上一次还没 settle → 本次跳过；`document.hidden` 为真时暂停，变为可见后立即执行一次再继续；`stop()` 之后不再调用。
- **`ap.run_job(kind, args, on_update)`** → promise：`job_start` 后每 2 秒 `job_status`，直到 `state` 为 `ok`/`failed`，resolve 最终的作业对象；每次拿到状态都调用 `on_update(job)`。
  `job_start` 返回 `BUSY` 且带 `job` → 改为轮询那个正在运行的作业（结果中 `attached: true`），不报错；
  其他失败（`USAGE`、`RPC_FAILED`、`TIMEOUT`、`job_status` 返回 `JOB_NOT_FOUND` 等）→ resolve 该失败对象并停止；总时长超过 `ap.TIMEOUTS.job`（默认 620 秒，作业上限 600 秒）→ `{ ok: false, code: "TIMEOUT" }`。
- **菜单**：服务 → aether-proxy 为父节点（`firstchild`），下设 8 个子页面：概览 `overview`、节点 `nodes`、订阅 `subscriptions`、访问控制 `access`、
  规则与 DNS `rules`、更新 `updates`、日志 `logs`、高级 `advanced`（顺序同 10「LuCI 页面」表），视图 `aether-proxy/<名称>`，都依赖 ACL `luci-app-aether-proxy`。
  T8.3 只建空页面（标题 + 「此页面尚未实现」），各页面的卡再填内容；概览保留现在的版本显示，改用 `ap.call('version')`。
- 写法跟随 LuCI 自身代码（`'use strict'`、`'require …'`、`baseclass.extend`/`view.extend`）。界面文字一律 `_()`，中文翻译写进 `po/zh_Hans/aether-proxy.po`。

### 页面卡的写法（2026-10-16 定，T8.4 起）

- 页面要显示的内容由**纯函数**计算：每个页面一个模型模块 `resources/aether-proxy/model/<页面>.js`（`baseclass.extend`，不发请求、不碰 DOM），
  输入是 rpc 的返回值与 UCI 数据，输出是页面直接渲染的「视图模型」（文字已翻译、状态已分类、按钮是否可用已算好）。用 `tests/luci/` 的加载器在 node 中测试。
- 视图 `view/aether-proxy/<页面>.js` 只做三件事：取数据（经 `ap`）、调用模型、用 LuCI 的 `E()`/`ui` 渲染。视图里不写判断业务含义的逻辑。
- 自动刷新一律 `ap.poll`，长任务一律 `ap.run_job`，所有 rpc 经 `ap.call`。

### 概览页（2026-10-16 定，T8.4）

**`status` 新增 `notices`**（命令行在每次调用时现场检测，只读、不记事件；`status` 为此读取配置，接受 `--confdir`、`--sys-root`、`--bin-dir` 测试选项）：
`notices` 是数组，每项 `{ "code": "<事件码>", "args": { … } }`，没有就是空数组：

| code | 条件 | args |
|---|---|---|
| `COMPONENT_MISSING` | `xray` 或 `chinadns-ng` 按 01「组件二进制的查找顺序」找不到（与 `check` 用同一个查找函数） | `component` |
| `UPDATE_AVAILABLE` | `updates.json` 中某个包 `newer == true`；`xray-core` 在 `update.xray_auto == 'off'` 时不提示 | `package`、`available` |
| `IPV6_PRESENT` | `main.lan_ifaces` 中某个接口在 `/proc/net/if_inet6` 有全局地址（scope 字段为 `00`） | `iface` |
| `DNSMASQ_EXTRA_SERVERS` | dnsmasq 生成的配置与 confdir 中（除自己的片段外）存在 `server=` 行——与启动时 `apply` 的检测相同，把检测部分抽成不记事件的共用函数 | `servers`（数组） |

`notices` 沿用已有的事件码（`UPDATE_AVAILABLE` 原本是 `update check` 的事件），但 `status` 只返回、不写事件日志；`notices` 中的 args 以上表为准。

**页面内容**（模型 `model/overview.js` 计算，视图渲染）：
- 状态：`state` 的中文名（`stopped` 已停止、`starting` 启动中——`waiting_network` 为真时显示「等待网络」、`running` 运行中、`degraded` 降级、`failsafe` 故障放行、`error` 启动失败），
  `dns_failsafe` 为真时另显示「DNS 已回退到原配置」；进入当前状态的时间（`since`，显示为「x 分钟前」之类的相对时间）；`last_error` 不为空时显示事件码。
- DNS 级别 `dns_tier`；当前节点：用 UCI 中该节点的 `label`，找不到就显示段名，另附 `node_ip`。
- 最近一次健康检测：`last_probe.ok` 为真显示「正常，<latency_ms> ms」，为假显示「失败」，没有就显示「尚未检测」，附相对时间。
- 组件版本：`components` 中每项的名称、版本、路径；以及 aether-proxy 自身版本（`version` 方法，页面加载时取一次）。
- 待处理提示：`notices` 每项一条中文提示（`IPV6_PRESENT` 用 03 的原话；其余各写一句并带上 args）。
- 按钮：启动、重启、停止，按状态决定是否可用（`stopped`/`error` 时只有启动可用；其他状态启动不可用）。停止用 `cbi-button-negative` 并要求确认（「停止后所有流量直连」）。
  点击后经 `ap.call('service', …)`，1.5 秒后立即刷新一次，其余靠定时刷新；返回 `ok: false` 时用 `ui.addNotification` 显示 `code` 与 `detail`。
- 每 5 秒经 `ap.poll` 刷新 `status`；`version` 与 UCI 只在页面加载时取一次。
- 本页之后会被 Dashboard（B2）取代为首页，所以不做历史曲线、流量统计。

### 节点页（2026-10-16 定，T8.5）

- 列表用 LuCI 的 `form.GridSection`（`aetherproxy` 的 `node` 段），一行一个节点，列：名称（`label`）、地址（`address:port`）、协议/传输/安全层（如 `vless / ws / tls`）、
  来源（`手动` 或订阅的 `name`，找不到订阅就显示段名）、标记（当前节点、`stale`）、**TCP 可达／延迟**（[07](07-probe.md) 的列名）。
  检测结果的文字：段名在 `pending` 中 → 「检测中」；有结果且 `ok > 0` → 「<median_ms> ms（<ok>/3）」；`ok == 0` → 按 `error` 显示「解析失败」「超时」「拒绝连接」「不可达」「其他错误」；没有结果 → 「未检测」。
- 每行的操作：「设为当前」（当前节点不显示）、「检测」（只测这一个）、编辑（GridSection 自带的模态框）、删除（`cbi-button-remove`，要确认；**当前节点不能删除**）。
  列表上方：「检测全部」、导入 URI。
- 设为当前：`uci.set('aetherproxy', 'main', 'node', <段名>)`、`uci.save()`，然后走 LuCI 标准的保存并应用（`ui.changes.apply()`，带回滚确认）。
- 检测：`ap.run_job('probe_nodes', [<段名>…])`（全部检测时为空数组）；作业进行中每次 `on_update` 后取一次 `probe_results` 并刷新检测列，同时显示进度「检测中 <done>/<total>」；
  作业期间两个检测按钮不可用。页面加载时取一次 `probe_results`。
- 编辑模态框：`label`、`protocol`、`address`、`port`，以及按 `protocol`、`transport`、`security` 显示的字段（05「`config node`」，用 `depends`）；`source`、`stale`、`match_*` 不显示、不可改。
  来自订阅的节点在模态框顶部提示「此节点来自订阅，下次更新订阅时修改会被覆盖」。保存走 `form.Map` 的标准流程。
- 导入 URI：一个多行文本框，每个非空行一个 URI，逐个调用 `ap.call('node_import', { uri })`（顺序执行），完成后汇总「新增 x 个，已存在 y 个，失败 z 个」，失败的列出行号与原因；
  有新增时重新加载页面数据。
- 模型 `model/nodes.js` 负责：每行的显示文字、标记、可用的操作（设为当前、删除是否允许）、检测列文字、进度文字、导入文本的拆行与结果汇总。

### 订阅页（2026-10-16 定，T8.6）

**`sub status`**：只读，输出 `{ "ok": true, "subs": { "<段名>": <sub.json 中该订阅的记录> } }`（[06](06-nodes-subscription.md) 第 7 步的格式）；
`sub.json` 不存在或损坏 → `{ "ok": true, "subs": {} }`，不记事件（页面会在更新后读取）。只输出配置中仍存在的订阅。

**页面**（模型 `model/subscriptions.js`，视图 `view/aether-proxy/subscriptions.js`）：
- 列表用 `form.GridSection`（`subscription` 段），列：名称（`name`，没有就显示段名）、地址（**只显示 `协议://主机/…`**，订阅地址里常带令牌，不在列表中明文显示）、启用、更新间隔
  （`interval_hours`，0 显示「仅手动」）、经由（`fetch_via`）、最近一次结果。
- 最近一次结果（来自 `sub_status`）：没有记录 →「尚未更新」；`error` 为空 →「成功，<nodes> 个节点」；否则显示事件码对应的文字（`SUB_FETCH_FAILED` 下载失败、`SUB_DECODE_FAILED` 解码失败、
  `SUB_FORMAT_UNSUPPORTED` 格式不支持、`SUB_NO_VALID_NODES` 没有可用节点、`SUB_APPLY_INVALID` 应用后配置无效、`SUB_PROXY_UNAVAILABLE` 代理不可用、`SUB_SHRANK` 节点数骤减；未知码原样显示）；
  附相对时间（`last_attempt`）。`skipped` 不为空时另起一行「跳过 <总数> 个：<原因> <数量>、…」，原因用中文（`malformed` 格式错误、`unsupported_scheme` 不支持的协议、
  `unsupported_transport` 不支持的传输、`unsupported_security` 不支持的安全层、`ss_plugin` 带插件的 SS、`vmess_alterid` VMess alterId 非 0；未知原因原样显示）。
- 操作：每行「立即更新」（`ap.run_job('sub_update', [<段名>])`）、编辑、删除；列表上方「全部更新」（`ap.run_job('sub_update', [])`）。作业进行中两类更新按钮都不可用，
  结束后显示作业结果中每个订阅的「新增 / 更新 / 失效 / 恢复 / 移除」数量（[06](06-nodes-subscription.md) `sub update --json` 的字段），并重新读取 `sub_status` 与页面数据。
- 编辑模态框：`name`、`url`（`password` 样式，可点开查看）、`enabled`、`interval_hours`、`fetch_via`、`user_agent`。
- **新增**：GridSection 自带的添加会生成匿名段，不符合 `^s_[0-9a-f]{8}$`。改为自定义「添加」：用 `crypto.getRandomValues` 取 4 字节生成段名（与已有段名冲突就重取），新建段后打开编辑模态框。
  生成段名的逻辑在模型里（随机字节由视图传入，便于测试）。
- **删除**（`cbi-button-remove`，要确认，确认框写明会一并删除多少个节点）：同时删除 `source` 为该订阅的节点；其中被 `main.node` 引用的那个**不删**，改为 `source manual`、`stale 0`，
  并在确认框中说明。删除计划（要删的节点、要改为手动的节点）由模型计算，视图按计划调用 `uci.remove`/`uci.set`，之后由用户「保存并应用」。

### 访问控制页（2026-10-16 定，T8.7）

- 页面是一个 `form.Map('aetherproxy')`：上方 `main` 段的 `unlisted_policy`（「跟随全局模式」/「直连」），附 [02](02-dataplane.md)「主机策略模型」中与 helloworld 三种方式的对照说明；
  下方 `form.GridSection('host')`（匿名段，可增删），列：启用、名称、IP（`DynamicList`，IPv4 或 CIDR）、MAC（`DynamicList`）、策略（`follow` 跟随 / `direct` 直连 / `proxy` 代理）、游戏模式（`udp`，`policy` 为 `direct` 时不显示）。
- **MAC 下拉**：用 LuCI 的 `network.getHostHints()`（`'require network'`）取 DHCP 租约与邻居表，作为 MAC 输入框的候选（显示「MAC（主机名，IP）」）。ACL 的 read 增加 `luci-rpc` 的 `getHostHints`。
- **保存前校验**：LuCI 未应用的修改保存在 rpcd 的会话目录里，命令行看不到，所以页面自己做一次与命令行**相同规则**的预检；最终仍以命令行（daemon 启动、`check`）的校验为准。
  在「保存」「保存并应用」时先 `map.parse()`，再用 `uci.sections('aetherproxy', 'host')` 取全部主机交给模型；有错误就用 `ui.addNotification` 列出并**中止保存**。规则与 `lib/config.uc` 的 `check_hosts` 一致：
  1. `ip` 与 `mac` 至少填一个；2. `policy=direct` 时 `udp` 必须为 0；3. 不同主机之间出现完全相同的 IP/CIDR（`x` 与 `x/32` 视为相同）或 MAC（不区分大小写，`-` 与 `:` 视为相同）→ 错误；**停用的主机也参与**；
  4. 格式：IP 为 IPv4 或 CIDR（前缀 0–32），MAC 为 6 组十六进制。
- **重叠提示**（不阻止保存）：不同主机的 CIDR 互相包含、且策略不同 → 提示「<A> 与 <B> 重叠，按 直连 → 代理 → 跟随 的顺序生效」（02「冲突校验」）。
- 模型 `model/access.js` 负责：规则 1–4 的校验（返回带主机名称或序号、字段的错误列表）、重叠提示、MAC 候选的显示文字与去重、策略与 `unlisted_policy` 的中文。

UI 规则：

- 破坏性按钮（删除节点、删除订阅、回滚组件）使用 `cbi-button-remove`，并要求确认；不要使用 `cbi-button-reset`（那是中性的「撤销表单修改」）。
- 前端同时发出的请求不超过 2 个（为 uhttpd 的 `max_requests 3` 留出余量）。
- 翻译包 `luci-i18n-aether-proxy-zh-cn` 与功能包分开生成。修改 po 后两个包要一起安装。
