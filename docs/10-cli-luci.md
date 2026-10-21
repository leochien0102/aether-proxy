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
- 未知的子命令，以及本表列出但尚未实现的子命令，一律按用法错误处理（`USAGE`，退出码 2），不另设「未实现」码（2026-10-17 定，backlog B9）。

| 子命令 | 作用 | 是否长任务 |
|---|---|---|
| `daemon [--boot]` | procd 实例入口（[04](04-lifecycle.md)） | 常驻 |
| `check` | 校验配置并完成全部渲染，不改动系统状态。渲染到**自己独占的临时目录** `<run-dir>/check.<pid>`，结束时删除；`<run-dir>/staging` 只归 daemon 的重载使用（2026-10-19 真机发现：init 的 reload 与 daemon 并发写同一个 staging，互相删文件，backlog B10） | 否 |
| `cleanup` | 幂等清理 | 否 |
| `status` | 输出 `state.json`，并附带 `probe`（`probe.json` 摘要：`{ "at", "total", "reachable" }`，没有就为 `null`）、`updates_available`（`updates.json` 内容；缓存过期时为 `null`，见 [08](08-updates.md)「检查」）和 `notices`（见「概览页」） | 否 |
| `components` | 现场查找 Xray、chinadns-ng 并读取版本（不依赖服务是否在运行；见下方「概览页真机修正」，2026-10-20，T10.4） | 否 |
| `render <xray\|nft\|chinadns\|dnsmasq>` | 把渲染结果输出到 stdout（排障、测试用） | 否 |
| `probe nodes [<id>...]` | 节点 TCP 可达性检测 | 是 |
| `probe results` | 读取最近的节点检测结果（[07](07-probe.md)） | 否 |
| `sub update [<sub>]` | 更新订阅（不带参数时更新全部） | 是 |
| `sub status` | 读取各订阅最近一次更新的记录（`sub.json`） | 否 |
| `node import <uri>` | 导入单个 URI 作为手动节点 | 否 |
| `node use <id>` | 切换当前节点：写 `main.node` 并提交，服务在运行时立即触发重载，**不等重载完成**（见下方「切换节点」，2026-10-21） | 否 |
| `probe url <站点>` | 经代理请求一个预设站点一次，返回耗时（「真实延迟」，[07](07-probe.md)「真实延迟」，2026-10-21） | 否 |
| `probe sites` | 列出 `probe url` 可用的预设站点 | 否 |
| `update check` | 检查新版本 | 是 |
| `update package <包> [--previous]` | 从发布通道安装软件包（`xray-core`、`aether-proxy`、`luci-app-aether-proxy`），`--previous` 安装上一个版本（[08](08-updates.md)） | 是 |
| `update data` | 更新规则数据 | 是 |
| `data status` | 各规则数据的来源、版本、行数与可用更新（见「规则与 DNS 页」） | 否 |
| `job start <子命令...>` | 以后台作业方式运行一个长任务，立即返回 `{"job": "<id>"}` | 否 |
| `job status <id>` | 输出作业状态 | 否 |
| `events [--since ts] [--level l]` | 读取结构化事件。`--since` 包含边界（`ts >= since`）；`--level` 表示**该等级及以上**（例如 `warn` 返回 warn 与 error） | 否 |
| `log [--source aether-proxy\|xray\|dns] [--lines n]` | 读取 logd 中的相关行 | 否 |
| `custom get <名称>` / `custom set <名称> --content <文本>` | 读取 / 校验并保存自定义列表（`direct_domain`、`proxy_domain`、`direct_ip`、`proxy_ip`） | 否 |

### 按子命令加载模块（2026-10-20 定，T10.8；跨页面问题 X5）

页面的每个 rpc 都是一次 `aether-proxy <子命令> --json` 进程。入口原来在文件开头静态 `import` 全部 16 个子命令模块，**任何子命令（包括 `version`）都要先把所有模块加载一遍**。
2026-10-20 在 H28K（aarch64）上实测：裸 `ucode` 启动 4 毫秒；只加载 `const` 10 毫秒；单个子命令模块连同它的依赖 55–85 毫秒（`status` 84、`custom` 84、`data` 78、`stats` 60、`events` 54）；
完整入口 254 毫秒。在 `/tmp` 里用下面的写法做的原型：`status` 从 278 毫秒降到 106 毫秒，输出不变。

- 入口只静态导入 `aetherproxy.const`（`version`、`--help` 用得到）。其余子命令用一张「子命令名 → 模块名」的表，**命中后才加载**：
  `loadstring("import * as m from '<模块名>'; return m;")()`（12「ucode 2025.07.18 的语法限制」第 3 条：`require()` 不能加载带 `export` 的模块），然后调用它的 `run(args)`。
  模块名只取自这张常量表，不拼接用户输入。
- 行为完全不变：同样的参数、输出、退出码、事件；`--help` 与 `version` 不加载任何子命令模块；未知子命令照旧是 `USAGE`、退出码 2。
- 附带的好处：某个子命令模块损坏（语法错误、缺依赖）时，只有这个子命令失败，`version`、`status` 等仍可用（原来整个命令行都无法运行）。加载失败时异常照常抛出（ucode 打印错误、非 0 退出），不另包装。
- daemon 进程照旧只加载一次，不受影响。子命令模块自身的依赖链（例如 `cmd.status` 依赖的模块）本次不动；还要更快时再看（例如预编译字节码），先量再定。

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
  消息匹配 `^[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9:.]+ \[(Debug|Info|Warning|Error)\]` → `xray`；匹配 `\[[A-Za-z0-9_]+\.(zig|c):[0-9]+` → `dns`；其余 → `aether-proxy`。
  （2026-10-19 真机核对：Xray 规则正确；chinadns-ng 也有来自 C 源文件的行，如 `[dnl.c:541 dnl_init]`，故 `dns` 规则加上 `.c`。chinadns-ng 的行带 ANSI 颜色码，匹配前先去掉 `\x1b[…m` 序列；`text` 字段原样保留。）
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

### 切换节点（`node use`，2026-10-21 定，r9 窗口）

r9 窗口中从点「使用此节点」到切换完成约 25 秒：页面先走 LuCI 的「应用」（`ui.changes.apply(true)`，带回滚确认，转圈约 10 秒），之后 daemon 重载约 15–18 秒。
切换节点不会让局域网连不上设备，LuCI 的回滚保护在这里没有作用；而 LuCI 的应用还会把会话里**所有**暂存的改动一起提交。所以改为由后端直接切换：

- `node use <id>`：`<id>` 必须是已存在的 `node` 段，否则 `USAGE`（退出码 2）。读当前 `main.node`；相同 → `{ "ok": true, "node": <id>, "previous": <id>, "reload": false }`，什么都不做。
  不同 → 用 `uci` 写 `main.node` 并 `commit aetherproxy`（只改这一个选项；LuCI 会话中暂存的改动在 rpcd 的会话目录里，不会被带上），
  服务在运行（`state.json` 的 `state` 为 `starting`/`running`/`degraded`/`failsafe`）时执行 `/etc/init.d/aether-proxy reload`（init 只发 SIGHUP，04「重载」），**不等重载完成**就返回
  `{ "ok": true, "node": <id>, "previous": <原值>, "reload": true }`；服务没在运行时只写配置，`reload: false`（下次启动用新节点）。不记事件（重载本身记 `RELOAD_APPLIED`，失败照 04 记）。
- 写配置失败 → `FS_FAILED`（`op: uci-commit`），退出码 1；发重载失败 → `CMD_FAILED`，退出码 1（配置已改，下次重载或启动会生效）。
- 页面（前端）：概览「使用此节点」、节点页「设为当前」改调 rpcd `node_use`，返回后重新读 UCI 与 `status`，「正在切换到…」的提示（「切换节点未生效时提示」）立即出现。

## rpcd 插件

形式：`/usr/share/rpcd/ucode/aetherproxy.uc`（rpcd 的 ucode 插件机制，与后端语言选择无关，24.10 起可用）。
插件只做两件事：校验参数（白名单 + 正则），然后执行 `aether-proxy … --json` 并原样返回。
**判断参数时一律忽略 `ubus_rpc_session`**：经 uhttpd 从 LuCI 发来的调用，uhttpd 会在参数里自动加上这个键（2026-10-21 r9 窗口发现：`components` 因「参数不为空」拒绝了页面的每一次调用，
概览页组件表从 T10.4 起就没显示过；测试和窗口脚本都只用 `'{}'` 调，没发现）。测试中每个方法都要有一条带 `ubus_rpc_session` 的调用。

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
| `components` | — | `components`（read，超时 15 秒，T10.4） |
| `node_use` | `id`（正则 `^n_[0-9a-f]{32}$`） | `node use <id>`（write，10 秒） |
| `probe_url` | `site`（`probe sites` 列出的名称之一，正则 `^[a-z0-9]{1,16}$`） | `probe url <site>`（write，超时 = `probe.timeout` + 5 秒） |
| `probe_sites` | — | `probe sites`（read） |
| `sub_status` | — | `sub status`（read） |
| `data_status` | — | `data status`（read） |
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
- **超时**：`check`、`save_file` 30 秒（`save_file` 可能触发 reload），`components` 15 秒（T10.4），其余 10 秒（rpcd 串行处理调用，每个调用必须很快；长任务一律走 `job_start`）。
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

菜单路径：服务 → Aether Proxy（中文界面为「以太跃迁」，显示名见 [README](README.md)「命名」）。全部使用 JS 视图（`form.Map` + `uci`），禁止 Lua。

| 页面 | 内容 |
|---|---|
| 概览 | 状态（`state`、DNS 级别、当前节点、最近一次健康检测、各组件版本）、启停按钮、待处理提示（组件缺失、有可用更新、IPv6 提示、dnsmasq 额外上游）。每 5 秒刷新 |
| 节点 | 节点表格（名称、地址、协议/传输/安全层、来源、stale 标记、TCP 可达/延迟）；设为当前节点；检测（选中的/全部）；编辑节点；导入 URI |
| 订阅 | 订阅列表与编辑；「立即更新」；最近一次结果（时间、节点数、按原因统计的跳过数） |
| 访问控制 | `unlisted_policy`；主机表（名称、IP、MAC、策略、游戏模式）。MAC 输入框提供 DHCP 租约下拉。冲突在保存前校验 |
| 规则与 DNS | 模式；自定义直连/代理的域名与 IP（四个 textarea）；DNS 设置；数据版本与「立即更新」 |
| 更新 | 组件版本（当前、previous、最新）、安装/回滚按钮、更新策略（不提供手动上传，见 [08](08-updates.md)「软件包安装」） |
| 日志 | 事件页（默认）+ 原始日志页（[09](09-logging.md)） |
| 高级 | `lan_ifaces`、`quic_block`、`dns_hijack`、`ipv6_filter`、`filter_https_rr`、`fail_open`、`sniffing`、日志等级、开机等待、健康检测参数、二进制路径 |

### 公共模块与菜单（2026-10-16 定，T8.3）

页面共用的逻辑放在一个 LuCI 类模块里：`htdocs/luci-static/resources/aether-proxy/common.js`，页面用 `'require aether-proxy.common as ap'` 引入。
页面里不再直接 `rpc.declare`，也不直接用 LuCI 的 `poll`（它的 promise 链没有 `.catch()`，见上方「作业机制」）。

- **`ap.call(method, params)`**：声明并调用 rpcd 插件的方法（10「rpcd 插件」表中的全部 11 个）。**永不 reject**，只 resolve 一次（settle-once）：
  rpc 的结果、rpc 的失败、硬超时三者谁先到用谁，后到的忽略。失败 → `{ ok: false, code: "RPC_FAILED", detail: "<错误信息>" }`；
  超时 → `{ ok: false, code: "TIMEOUT", detail: "<方法> did not answer in <秒>s" }`。硬超时：`check`、`save_file` 35 秒，`components` 20 秒（T10.4），其余 15 秒（比插件的 30/10 秒各多 5 秒），
  取自 `ap.TIMEOUTS`（对象，测试可改小）。
- **同时在途 ≤ 2**：模块内对 `ap.call` 计数，超出的调用按先后排队；一个调用 settle 后（包括超时），队首的下一个才发出（UI 规则「同时发出的请求不超过 2 个」）。
- **`ap.poll(fn, interval_ms)`** → `{ stop() }`：每隔 `interval_ms`（小于 2000 按 2000）调用一次 `fn`（返回 promise）。
  上一次还没 settle → 本次跳过；`document.hidden` 为真时暂停，变为可见后立即执行一次再继续；`stop()` 之后不再调用。
- **`ap.run_job(kind, args, on_update)`** → promise：`job_start` 后每 2 秒 `job_status`，直到 `state` 为 `ok`/`failed`，resolve 最终的作业对象；每次拿到状态都调用 `on_update(job)`。
  `job_start` 返回 `BUSY` 且带 `job` → 改为轮询那个正在运行的作业（结果中 `attached: true`），不报错；
  其他失败（`USAGE`、`RPC_FAILED`、`TIMEOUT`、`job_status` 返回 `JOB_NOT_FOUND` 等）→ resolve 该失败对象并停止；总时长超过 `ap.TIMEOUTS.job`（默认 620 秒，作业上限 600 秒）→ `{ ok: false, code: "TIMEOUT" }`。
- **菜单**：服务 → Aether Proxy（显示名，2026-10-20 起；之前为 `aether-proxy`）为父节点（`firstchild`），下设 8 个子页面：概览 `overview`、节点 `nodes`、订阅 `subscriptions`、访问控制 `access`、
  规则与 DNS `rules`、更新 `updates`、日志 `logs`、高级 `advanced`（顺序同 10「LuCI 页面」表），视图 `aether-proxy/<名称>`，都依赖 ACL `luci-app-aether-proxy`。
  T8.3 只建空页面（标题 + 「此页面尚未实现」），各页面的卡再填内容；概览保留现在的版本显示，改用 `ap.call('version')`。
- 写法跟随 LuCI 自身代码（`'use strict'`、`'require …'`、`baseclass.extend`/`view.extend`）。界面文字一律 `_()`，中文翻译写进 `po/zh_Hans/aether-proxy.po`。

### 页面脚本过期检测（2026-10-20 定，T10.12；跨页面问题 X9）

**问题**：LuCI 给 `L.require` 的模块地址加 `?v=<资源版本>`，uhttpd 对静态文件不发 `Cache-Control`。官方主题的资源版本含包数据库的修改时间，装包后会变；
第三方主题自己定这个参数（H28K 的 proton2025 写死主题版本，argon-plus 只用 luci 版本），**升级本应用后浏览器会继续用旧脚本**。
r8 窗口（2026-10-20）中概览页组件两行一直「–」、更新页「检查更新」一直置灰且请求没到 rpcd，都与旧脚本吻合（后端经 ubus 直接调用正常）。仓库所有者定（2026-10-20）：不绕过 LuCI 的缓存机制，**检测并提示**。

- **版本写进两个文件**：`luci-app-aether-proxy/Makefile` 定义 `Build/Prepare/luci-app-aether-proxy`（luci.mk 在 `Build/Prepare` 中调用 `Build/Prepare/$(LUCI_NAME)`，24.10 与 25.12 的 luci.mk 都有，2026-10-20 核对），
  在构建目录中把 `@@VERSION@@` 替换为 `$(PKG_VERSION)-r$(PKG_RELEASE)`，两个文件：`htdocs/luci-static/resources/aether-proxy/common.js`（模块常量）与新文件 `htdocs/luci-static/resources/aether-proxy/build.json`（`{ "version": "@@VERSION@@" }`）。
  源码里保留占位符（与 `aether-proxy` 包的 `const.uc` 同一做法）。
- **比较的是同一个包里的两个文件**，不和后端 `version` 比：更新页可以分别升级 `aether-proxy` 与 `luci-app-aether-proxy`，两者版本不同是正常的；而 `common.js` 与 `build.json` 总是一起安装，不一致只可能是浏览器缓存了旧的 `common.js`。
- **检测**（`common.js` 在模块加载时做一次，每次打开页面都会经过它，各页面不用改）：
  - 常量仍是占位符（源码直接拷贝、宿主机测试、开发预览）→ 不检测。
  - 否则用 `fetch(<build.json 的地址>, { cache: 'no-store' })` 取 `build.json`（静态文件，不经 rpcd，不占 `ap.call` 的并发名额；地址用 `L.resource('aether-proxy/build.json')`）。
  - 取不到、不是 JSON、没有 `version` → 不提示、不报错（只 `console.warn`）。
  - 两个版本不同 → `ui.addNotification(null, E('p', …), 'warning')` 一次：
    「页面脚本已过期：已安装 <build.json 的版本>，浏览器仍在使用 <常量的版本>。请清除浏览器缓存后刷新页面（部分第三方主题升级后不会自动更新页面脚本）。」
- 更新页升级 luci 包成功后的提示（「页面文件可能已变化，请刷新浏览器」）不变；刷新后若仍是旧脚本，本检测会给出上面的横幅。
- 检测代码本身在 `common.js` 里，所以**从带有它的版本开始**才有效：浏览器里缓存的若是 r8 及以前的 `common.js`，它没有这段代码，不会提示（这些版本升级时仍需手动清缓存）。
- 这只能发现 `common.js` 本身过期的情况；其他脚本单独过期而 `common.js` 是新的，概率很低（同一次升级、同一个缓存策略），不另做。

### 页面卡的写法（2026-10-16 定，T8.4 起）

- 页面要显示的内容由**纯函数**计算：每个页面一个模型模块 `resources/aether-proxy/model/<页面>.js`（`baseclass.extend`，不发请求、不碰 DOM），
  输入是 rpc 的返回值与 UCI 数据，输出是页面直接渲染的「视图模型」（文字已翻译、状态已分类、按钮是否可用已算好）。用 `tests/luci/` 的加载器在 node 中测试。
- 视图 `view/aether-proxy/<页面>.js` 只做三件事：取数据（经 `ap`）、调用模型、用 LuCI 的 `E()`/`ui` 渲染。视图里不写判断业务含义的逻辑。
- 自动刷新一律 `ap.poll`，长任务一律 `ap.run_job`，所有 rpc 经 `ap.call`。
- **先出页面，后填数据**（2026-10-20 定，跨页面问题 X4；T10.10 起逐页套用，看到哪一页改哪一页）。
  依据（H28K，规则与 DNS 页，DevTools 实测）：页面框架约 0.3 秒就绪，之后 `load()` 里的 5 个 rpc 分 4 轮依次完成，共约 1 秒才开始渲染；
  LuCI 会把同一时刻发出的 rpc 合成一个 HTTP 请求，但 rpcd 逐个处理，加上 `ap.call` 同时在途 ≤ 2，慢的调用会挡住整页。规则：
  1. `load()` 只取**决定页面结构与表单内容**的数据：UCI（`uci.load`）、少量必须先知道才能画出页面的值。其余 rpc（列表内容、状态表、清单之类）不放进 `load()`。
  2. `render()` 立即返回完整结构；每个后填的区域先放占位文字「读取中…」（与概览页组件表相同的 msgid）。`render()` 返回后再按**页面上从上到下的顺序**经 `ap.call` 取数，
     每个回复到达只更新自己的区域（不重建整页、不动用户正在操作的控件）。
  3. **依赖后填数据才能安全操作的控件**，在数据到达前不可用：例如名单的文本框与「保存名单」——还没读到原内容就保存，会用空内容覆盖用户已有的名单。读取失败时保持不可用，并在该区域显示失败文字（原有的错误显示），刷新页面可重试。
  4. 不依赖这些数据的控件（表单、作业按钮）照常立即可用。
  5. 占位文字、失败文字由模型给出；视图只负责「先放占位、回来再填」。


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
- 本页之后升级为 Dashboard（见下方「Dashboard：概览页升级」，2026-10-17 定），历史曲线不做。

**启用开关**（2026-10-16 补，T8.11a）：T8.4 漏了 `main.enabled`（默认 `0`）。init 的 `start_service` 在它为 `0` 时直接返回成功，所以全新安装后点「启动」没有任何效果，页面也没有提示。
- 状态区上方加「启用」开关（复选框或 `ui.Checkbox`），值取页面加载时读到的 UCI `main.enabled`。切换后 `uci.set('aetherproxy', 'main', 'enabled', '1'|'0')`、`uci.save()`、
  `ui.changes.apply(true)`（与节点页「设为当前」相同，带回滚确认）。init 已注册 reload 触发器：打开即启动、关闭即停止（04「重载」），页面不另调 `service`。
  开关下方一句说明：「启用后开机自动启动；关闭会立即停止服务，所有流量直连」。
- `enabled` 为 `0` 时「启动」「重启」不可用，状态区显示「服务未启用：打开上方的『启用』后会自动启动」；「停止」仍按状态决定（服务可能是在关闭开关前就在运行的）。
  `enabled` 为 `1` 时按钮规则与原来相同。
- 「停止」的确认文字改为：「停止后所有流量直连。这只是暂时停止：重启路由器或下次保存本服务的设置时会再次启动；要长期停用请关闭『启用』。」
  （服务没在运行时，reload 触发器会执行 `start`，见 04「重载」。）
- 模型的按钮函数增加 `enabled` 参数；提示文字与确认文字也由模型给出。

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

**`sub status`**：只读，输出 `{ "ok": true, "subs": { "<段名>": <sub.json 中该订阅的记录> } }`（[06](06-nodes-subscription.md) 第 7 步的格式）；读不到配置 → `{ "ok": false, "code": "CONFIG_INVALID", "detail": "cannot load configuration" }`，退出码 2（只输出配置中仍存在的订阅，没有配置就无从判断，2026-10-17 定）；
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

### 规则与 DNS 页（2026-10-16 定，T8.8）

**`data status`**：只读，不记事件。输出 `{ "ok": true, "checked": <updates.json 的 checked，没有为 null>, "items": { "<名称>": { … } } }`，五个数据项（[08](08-updates.md)「数据格式」）各一项：
`source`（`downloaded`：`/etc/aether-proxy/data/<名称>.txt` 存在；否则 `baseline`）、`version`（本机内容哈希的前 12 位，哈希按 08「本机数据的哈希」）、`lines`（非空、非注释行数）、
`updated_at`（`downloaded` 时为数据文件的修改时间，`baseline` 时为 `null`）、`changed`（`updates.json` 中该项有 `sha256` 时，**现场**比较本机数据的哈希（08「本机数据的哈希」那个函数）与它，不同为 `true`；
没有 `sha256`（旧版本写的文件）时退回该项的 `changed`；没有检查过为 `null`。2026-10-21 改，r9 窗口：原来只用检查时算好的 `changed`，数据更新后仍显示「有更新」）。

**先出页面**（2026-10-20 定，T10.10；按「页面卡的写法」中的「先出页面，后填数据」）：
- `load()` 只 `uci.load('aetherproxy')`。模式、DNS 表单照常渲染。
- 四个名单：文本框先不可用、占位文字「读取中…」，「保存名单」不可用；`list_file` 回来后填入内容、两者变为可用。失败 → 文本框与按钮保持不可用，按钮下显示原有的失败文字（`save_result` 的错误显示）。
- 规则数据表：先显示「读取中…」，`data_status` 回来后按原规则填表；「立即更新」按钮一开始就可用（作业结束后照旧重新取 `data_status`）。
- 取数顺序：`list_file` 四次（按页面顺序），然后 `data_status`（它最慢，约 0.4 秒，放最后不挡名单）。
- 预期（H28K）：页面约 0.4 秒出现，名单约 0.6 秒可编辑，规则数据表约 1.1 秒填好。

**`data status` 的行数改用 grep**（2026-10-20 定，T10.7）：仓库所有者反映本页载入慢。H28K 实测（0.2.0-r6，服务未启用）：`data_status` 约 1.45 秒，`list_file` 每次约 0.28 秒，
本页载入共约 2.6 秒（rpcd 串行处理）。`data_status` 的时间几乎全在用 ucode 逐行数 `chnlist.txt`（1.36 MB、约 10 万行，单这一项约 1 秒）；同一台机器上 `grep`/`wc -l` 约 40 毫秒、5 个文件的 `sha256sum` 共约 30 毫秒。
- 行数改为**一次** `sys.run`：`grep -H -c '^[ <TAB><CR>]*[^ <TAB><CR>#]' <5 个文件的完整路径>`（`<TAB>`、`<CR>` 是实际的制表符与回车字符；超时 5 秒、`quiet`）。
  直接匹配数据行，而不是 `-v -E '^[ <TAB><CR>]*(#|$)'`：busybox 的正则对后者慢一倍（H28K 上 chnlist 180 对 370 毫秒，T10.7 复审实测后改）。
  语义与原来相同：去掉行首的空格、制表符、回车后为空或以 `#` 开头的行不计（原实现是 `trim` 后判断；行尾的空白不影响结果）。
- 输出每行 `<路径>:<数>`，按路径对回各数据项（用 `-H`，单个文件时也带路径）。退出码 0、1 都是成功（1 表示所有文件都没有计入的行）；其他退出码、超时、输出缺项或不是数字 →
  整个调用返回 `{ "ok": false, "code": "CMD_FAILED", "detail": "grep exit <码>" }`（退出码 1，不记事件，与本命令其他失败一样只返回）。
- 其余字段（来源、版本、更新时间、`changed`）不变。H28K 实测（2026-10-20，T10.7 合并后）：`data status` 1.42 秒 → 0.76 秒（`-v -E` 写法），改为直接匹配后约 0.58 秒；
  剩下的主要是整个入口的模块加载（约 0.25 秒，X5）、5 个文件的哈希（约 0.1 秒）与 grep（约 0.2 秒）。
- 不合并 4 次 `list_file`（仓库所有者定，2026-10-20）：每次调用的固定开销由 X5 统一处理。

**页面**（`form.Map('aetherproxy')`，模型 `model/rules.js`）：
- **模式**：`main.mode`（`bypass_cn` 绕过大陆、`gfw` 仅代理被墙网站、`global` 全局代理），各附一句说明。
- **自定义名单**：四个文本框——直连域名、代理域名、直连 IP、代理 IP（`list_file` 读取）。每个文本框下有自己的「保存名单」按钮（`save_file`；与表单的保存分开，名单不进 UCI）。
  保存返回 `CONFIG_INVALID` 时，在该文本框下列出 `errors` 的行号与原文；成功时显示「已保存」或「内容未变化」，`reload` 为 `failed` 时提示「已保存，但重载失败」。
- **DNS**：`dns` 段的 `china_dns`、`trust_dns`（1–2 个）、`direct_dns`、`allow_china_fallback`、`dns_probe_domain`（`dnsmasq_instance` 放在高级页）。
  这几个字段用模型做与命令行**相同规则**的格式校验（`lib/config.uc` 的 `upstream`、`lib/net.uc` 的 `ipv4`、`domain`），作为 LuCI 选项的 `validate`；理由同访问控制页。
- **规则数据**：表格列出五项的名称（中文）、来源（「下载」/「包内」）、版本、行数、更新时间（相对时间）、状态（`changed` 为真 →「有更新」，假 →「最新」，`null` →「未检查」），以及上次检查时间；
  「立即更新」按钮 → `ap.run_job('update_data', [])`，结束后显示作业结果（`updated`/`unchanged`/`failed` 各项）并重新读取 `data_status`。

### 更新页（2026-10-16 定，T8.9b）

**`update check` 新增 `packages.<包>.previous`**：清单中该包 `previous` 对本机架构与包管理器有资产时为它的版本字符串，否则（`previous` 为 `null`、没有本机资产）为 `null`。
取法与 `update package --previous` 选资产相同（共用 `lib/update.uc` 已有的选资产函数），页面据此决定回滚按钮是否可用、显示回滚到哪个版本。

**数据来源**：只用已有接口，不加 rpcd 方法。页面加载时取一次 `status`（`updates_available` 即 `updates.json`，`components` 为运行中组件的版本）与 UCI；
每个作业结束后再取一次 `status`。不定时刷新。

**页面**（`form.Map('aetherproxy')`，模型 `model/updates.js`）：
- **软件包表**：`xray-core`、`aether-proxy`、`luci-app-aether-proxy`、`luci-i18n-aether-proxy-zh-cn` 四行，列：名称、已安装（`installed`，`null` 显示「未安装」）、最新（`available`）、上一版（`previous`，`null` 显示「–」）、状态、操作。
  - 状态：`updates_available` 为 `null` →「未检查」（其余列显示「–」）；该包不在 `packages` 中 →「通道中没有」；`asset` 为 `null` →「本机不可用」（附 `arch`）；
    `installed` 为 `null` →「未安装」；`newer` 为真 →「有更新」；否则「最新」（按这个顺序判断，第一个成立的生效）。
  - 操作：「安装」（`installed` 为 `null` 且 `asset` 不为空）或「更新」（`installed` 不为空且 `newer` 为真）→ `ap.run_job('update_package', [<包>])`；
    「回滚到 <previous>」（`previous` 不为空且 `installed` 不为空且 `installed` 不等于 `previous`）→ 确认后 `ap.run_job('update_package', [<包>, '--previous'])`，按钮用 `cbi-button-remove`。
    确认框写明「将安装 <previous>，替换当前的 <installed>」；`aether-proxy` 与两个 luci 包另加一句「服务会重启」。
  - 更新 `aether-proxy` 或 luci 包成功后提示「页面文件可能已变化，请刷新浏览器」（luci 包换了视图与翻译，旧页面继续用缓存的脚本）。
  - 表下一行：上次检查时间（相对时间）与清单地址（`url`）；`updates_available` 为 `null` 时显示「尚未检查」。
- **运行中的组件**：`status.components` 中 `xray`、`chinadns-ng` 的版本（`null` 显示「未知」）与路径。chinadns-ng 另注「不进发布通道，请在软件包页面从软件源安装或更新」，附 `arch`（没有 `updates_available` 时不显示 arch）。
  **2026-10-21 改（T10.15，跨页面问题 X6 与 r8 窗口前端第 6 条）**：chinadns-ng 的说明改为「不经发布通道自动更新：请在软件包页面从软件源安装或更新，或从发布页下载 `chinadns-ng` 包（本机架构 <arch>）手工安装。」，
  架构放进句子里对应的位置，不再接在句末；没有 `updates_available` 时省略「（本机架构 …）」。概览页的组件缺失提示中，chinadns-ng 缺失时同样补上「或从发布页下载 `chinadns-ng` 包手工安装」（xray 的提示不变）。
- **「检查更新」按钮** → `ap.run_job('update_check', [])`，结束后重新取 `status`。
- **作业期间**所有安装、更新、回滚、检查按钮都不可用（共用一把更新锁，[08](08-updates.md)「调度」）。
- **作业结果的文字**（模型计算）：
  - 检查：成功 →「检查完成」，附有更新的包数；失败按 `code`：`UPDATE_FETCH_FAILED` 连不上发布通道、`MANIFEST_BAD_SIGNATURE` 签名校验失败、`CONFIG_INVALID` 没有可用的通道地址；`BUSY` 另一个更新作业正在运行；`JOB_LOST` 作业进程意外退出；其他码原样显示并附 `detail`。
  - 安装/回滚（`update package` 的结果 `{ ok, package, from, to, rolled_back, code, detail }`）：`ok` 为真 →「<包> 已从 <from> 更新到 <to>」（`from` 为 `null` 时「已安装 <to>」）；
    `rolled_back` 为真 →「安装后检查失败，已回滚到 <from>」；`ok` 为假且未回滚 → 按 `code` 显示（`UPDATE_VERIFY_FAILED` 校验失败——有 `detail` 时附上、`NO_SPACE` 空间不足、`ARCH_UNSUPPORTED` 本机不可用，以及上面检查用的几个码），其他码原样显示。
- **更新策略**（`update` 段）：`xray_auto`（`off` 不提示、`notify` 只提示、`auto` 自动安装，各附一句说明；`auto` 的说明写明「只在运行正常时安装，同一版本只尝试一次，检查失败自动回滚」）、
  `data_auto`、`data_hour`（0–23）、`data_minute`（0–59，空表示 30，占位文字写「30」）、`channel_urls`（`DynamicList`）。
  `channel_urls` 每项用模型做与命令行**相同规则**的校验（`lib/config.uc` 的 `url`：`http://` 或 `https://` 开头、主机部分非空、不含空白），作为 `validate`。列表删空时 LuCI 会删除该选项，命令行回到默认通道（05「`config update`」），所以不阻止保存，只在说明中写「留空则使用默认的发布通道」。
  保存走 `form.Map` 的标准流程。

### 日志页（2026-10-16 定，T8.10）

只用已有的 `events`、`log` 方法，不改命令行与 rpcd。页面分两个标签：「事件」（默认）与「原始日志」（`ui.Tabs` 或两个按钮切换均可）。模型 `model/logs.js`。

**事件**：
- 取数：`ap.call('events', {})` 取全部（`events.jsonl` 最多 500 行，只含 notice 及以上），由模型在前端过滤，不按等级重复请求。
  勾选「自动刷新」（默认勾选）时经 `ap.poll` 每 5 秒重取一次；切到「原始日志」标签时停止轮询，切回再开始。
- 显示：**新的在上**。每行：时间（本地 `YYYY-MM-DD HH:MM:SS`）、等级（`error` 错误、`warn` 警告、`notice` 通知，三种颜色用 LuCI 现有的 `label` 样式区分）、事件码、中文说明。
  原始 `args` 不直接显示，放在该行的 `title`（悬停可见），便于排查。
- 过滤：等级（全部 / 错误 / 警告及以上 / 通知及以上，语义与命令行 `--level` 相同：该等级及以上）；事件码（下拉，选项为当前数据中出现过的事件码，按字母排序，外加「全部」）。两个过滤同时生效。
- `skipped` 大于 0 时在列表上方提示「有 <n> 行记录损坏，已跳过」。返回 `ok: false` 时显示 `code` 与 `detail`，列表保持上一次的内容。
- **中文说明**：每个事件码一个模板，`{参数名}` 换成 `args` 中的值。模板覆盖 [09](09-logging.md)「事件码目录」中等级为 notice、warn、error 的**全部**事件码（`CHILD_STARTED`、`CMD_RUN` 只在 syslog 出现，不需要）。
  参数值的显示：缺失 → `?`；数组 → 用「、」连接；对象 → `键 值` 用「、」连接（例如 `skipped` 的按原因计数、`steps`）；其他 → 原样。
  模板只用参数，不另外翻译参数的值（例如 `reason`、`mode` 原样显示）。未知事件码 → 「<事件码> <args 的 JSON>」。
  `SERVICE_STARTED` 只显示耗时，不展开 `steps`（`steps` 仍在悬停的 `args` 里）。

**原始日志**：
- 来源下拉（全部 / aether-proxy / Xray / DNS，对应 `source` 的 `all`、`aether-proxy`、`xray`、`dns`）、行数下拉（100、200、500、1000、2000，默认 200）、「刷新」按钮。
  打开标签与点「刷新」时 `ap.call('log', { source, lines })`；不自动刷新（日志多时一次可能有几百 KB）。
- 内容用 `<pre>` 按原样显示 `text`，不做着色；失败显示 `code` 与 `detail`。
- UCI `main.log_level` 为 `debug` 时，在标签顶部显示 [09](09-logging.md)「logd 容量」的提示。

### 高级页（2026-10-16 定，T8.11b）

`form.Map('aetherproxy')`，模型 `model/advanced.js`。字段以 [05](05-config.md) 为准，校验规则以 `lib/schema.uc` 与 `lib/config.uc` 为准（页面做与命令行**相同规则**的预检，理由同访问控制页；
测试逐个与 `check --no-precheck` 交叉核对）。不改命令行与 rpcd。分四个标签（`s.tab`）：

- **拦截**（`main` 段）：`lan_ifaces`（LuCI `tools.widgets` 的 `DeviceSelect`，`multiple`，至少一个；说明「拦截哪些入接口，通常是 br-lan」）、
  `quic_block`、`dns_hijack`、`ipv6_filter`、`filter_https_rr`、`fail_open`、`sniffing`（`Flag`，默认值按 05）。每个开关一句说明，取自 05 的「说明」列；另外：
  - `fail_open`：「关闭后，Xray 不可用时被代理的流量会中断，而不是改为直连」；
  - `dns_hijack`：「关闭后，自己指定了 DNS 的设备会绕过分流」；
  - `ipv6_filter`：「所有 AAAA 查询返回空结果，让设备只用 IPv4 访问；LAN 侧的 IPv6 地址分配不受影响」（03「IPv6」）。
- **日志**：`log_level`（`error` 错误、`warn` 警告、`notice` 通知（默认）、`info` 信息、`debug` 调试；选 `debug` 时说明中带上 09「logd 容量」的提示）、`xray_log_level`（`error`、`warning`（默认）、`info`、`debug`）。
- **开机与检测**：`boot_wait_timeout`（0–600 秒，0 = 不等待）、`boot_check_targets`（`DynamicList`，`IPv4:端口`）；`probe` 段的 `url`（与更新页 `channel_urls` 相同的 URL 规则）、
  `expect_code`（100–599）、`timeout`、`fail_threshold`、`recover_threshold`、`node_timeout`、`node_concurrency`（都是不小于 1 的整数，与命令行一致，不另加上限）。
- **组件与 DNS 实例**：`xray_bin`、`chinadns_bin`（绝对路径、不含空白，留空 = 按 01「组件二进制的查找顺序」自动查找）、`dns` 段的 `dnsmasq_instance`（非空字符串，留空 = 自动）。

数值与列表项的校验由模型给出（作为各选项的 `validate`）：整数按命令行的规则（`lib/config.uc`：`^-?[0-9]{1,9}$`，前导零允许，空白与小数不允许）与上下限；`hostport`、`url`、`path`、非空字符串同命令行。
留空的可选字段（删掉选项 = 用默认值）不报错。

### Dashboard：概览页升级（2026-10-17 定，T8.12）

需求见 [backlog](backlog.md) B2。仓库所有者确认（2026-10-17）：**在现有概览页上升级**（菜单不变）；自动刷新间隔存在**浏览器 localStorage**（各浏览器各自记，不进 UCI）；**不做历史曲线**（留在 B2）。
原则不变：数据由命令行按需读取（不在后台采样），速率由前端用相邻两次读数相减得到。

**1. 流量计数（T8.12a）**：nft 表增加两个具名计数器与两条只计数的链（`render/nft.uc`）：

```
counter proxy_tx {}
counter proxy_rx {}
chain traffic_out { type filter hook output priority filter; policy accept; ip daddr @node_ip4 counter name proxy_tx }
chain traffic_in { type filter hook input priority filter - 2; policy accept; ip saddr @node_ip4 counter name proxy_rx }
```

路由器发往节点、节点发回路由器的全部流量（Xray 与节点之间的连接，含 UDP）分别计入。整表替换（启动、节点 IP 变化的 reload）会把计数清零，前端按「计数变小」处理。

**`aether-proxy stats`**（只读、不记事件；接受 `--run-dir`、`--sys-root`、`--bin-dir`）：

```json
{ "ok": true, "at_ms": 123456789,
  "proxy": { "tx_bytes": 0, "rx_bytes": 0 },
  "wan": { "dev": "eth1", "tx_bytes": 0, "rx_bytes": 0 },
  "connections": { "proxy": 0, "total": 0 } }
```

- `at_ms`：单调时钟毫秒（ucode `clock(true)`），只用于前端求差，不是时间戳。
- `proxy`：`nft -j list counters table inet aetherproxy`（`sys.run`，5 秒，`quiet`）中 `proxy_tx`/`proxy_rx` 的 `bytes`；表不存在、命令失败或缺计数器 → `null`。
- `wan`：`/proc/net/route` 中目的为 `00000000`、`Metric` 最小的那一行的接口（IPv4 默认路由），在 `/proc/net/dev` 中取它的接收字节（第 1 个数）与发送字节（第 9 个数）；没有默认路由或读不到 → `null`。
- `connections.proxy`：`state.json` 的 `node_ip` 不为空时，统计 `/proc/net/tcp` 中远端地址等于它、状态为 `01`（ESTABLISHED）的行，加上 `/proc/net/tcp6` 中远端为对应 `::ffff:` 映射地址的行；`node_ip` 为空或文件读不到 → `null`。
  （文件中的 IPv4 是小端序十六进制，如 `1.2.3.4` 写作 `04030201`。）
- `connections.total`：`/proc/sys/net/netfilter/nf_conntrack_count`；读不到 → `null`。
- 某一项读不到只让该项为 `null`，整个调用仍 `ok: true`；`--sys-root` 下的 `/proc/...` 路径按 sys-root 拼接（测试用）。
- rpcd 方法 `stats`（无参数，read，10 秒）。

**2. 立即检测与换节点后自动检测（T8.12b）**：
- **`aether-proxy probe now`**：读 `state.json`，`state` 不是 `starting`、`running`、`degraded`、`failsafe` → `{ "ok": false, "code": "NOT_RUNNING", "detail": "…" }`，退出码 1，不记事件；
  否则经 procd 向 daemon 发 SIGUSR1（`ubus call service signal '{"name":"aether-proxy","signal":10}'`，与 08 的 SIGUSR2 写法相同），失败 → `CMD_FAILED`（记事件），退出码 1；
  成功 → `{ "ok": true, "requested_at": <秒> }`。monitor 立即跑一轮代理健康检测，`last_probe.at` 随后更新。rpcd 方法 `probe_now`（无参数，write，10 秒）。
- **daemon**：reload 成功、且当前节点（`main.node`）或节点 IP 变了 → reload 结束后立即跑一轮 monitor（等同收到 SIGUSR1），切换节点后几秒内就有新节点的健康检测结果。

**3. 页面（T8.12c，在概览页上加，原有内容与规则不变）**：
- **刷新间隔**：下拉「2 秒、5 秒（默认）、10 秒、30 秒、关闭」，存 `localStorage` 的 `aether-proxy.refresh`（读写都包在 try/catch 中，读不到就用默认值）。改了立即按新间隔重建 `ap.poll`；「关闭」时停止轮询，另有「刷新」按钮手动刷新一次。
  每次刷新**依次**调用 `status`、`stats`（同一时刻最多一个刷新在途，`ap.poll` 已保证）。
- **流量**：代理 ↑/↓、直连 ↑/↓、合计 ↑/↓ 的速率（↑ = 发送，`tx`）。速率 = 两次读数的字节差 ÷ `at_ms` 差；直连 = WAN − 代理（小于 0 按 0）。
  第一次读数、某项为 `null`、字节差为负（计数被清零或接口重置）、`wan.dev` 变了、`at_ms` 差不大于 0 → 该项显示「–」。单位按 1024 进位：`B/s`、`KB/s`、`MB/s`（保留一位小数）。
- **连接数**：代理连接、总连接（conntrack），`null` 显示「–」。
- **切换节点**：节点下拉（显示 `label`，当前节点预选）加「切换」按钮 → `uci.set('aetherproxy', 'main', 'node', <段名>)`、`uci.save()`、`ui.changes.apply(true)`（与节点页「设为当前」相同）。之后的健康检测由 daemon 自动完成。
- **测当前节点延迟**：`ap.call('probe_now')` → 成功后每秒取一次 `status`，直到 `last_probe.at` 不早于 `requested_at`（最多 15 秒），显示「正常，<latency_ms> ms」或「失败」；超时显示「检测未在 15 秒内完成」。
  进行中按钮不可用；`NOT_RUNNING` 显示「服务未运行」；其他失败显示 `code` 与 `detail`。
- ~~**更新订阅**~~（2026-10-20 起不在概览页，见下方「概览页重排」）：`ap.run_job('sub_update', [])`，结束后显示「订阅更新完成：成功 <n> 个，失败 <m> 个」（按结果 `subs` 中各项的 `ok` 计数），失败的列出订阅名与事件码；作业期间按钮不可用。
- 「停用/启用」即已有的「启用」开关（持久），「重启」即已有按钮；不新增。
- 模型 `model/overview.js` 增加：速率计算与格式化、连接数文字、刷新间隔的选项与解析、检测结果文字、订阅更新结果汇总。

### 概览页重排（2026-10-20 定，T10.3）

仓库所有者看过 0.2.0-r6 的概览页后的意见：状态文字偏小；「DNS 级别 T2」、节点名后的 IP 等含义不清；控件挤在一行，整页没有主次。
按 2026-10-20 确认的示意图重排。**本节与上面「概览页」「启用开关」「Dashboard」冲突的地方以本节为准**；没提到的规则（按钮可用性、停止确认、启用开关的保存流程、
刷新间隔与 localStorage、速率算法、测延迟的完成判断、切换节点的保存流程）全部不变。

**从上到下的分块**（视图中按此顺序排列，每块一个 `cbi-section`；第 0 块不是 section）：

0. **标题行**：左边页面标题（显示名，T10.2）；右边「自动刷新」下拉（选项与原来相同）和「刷新」按钮。删除标题下的说明「服务状态、待处理提示与启停控制。」。
1. **待处理提示**：读取状态失败的错误（`alert-message error`）、「服务未启用」提示、`notices` 各条（`alert-message warning`，一条一个列表项）都放在这里，没有就不显示这一块。
2. **状态**：
   - 第一行左边是**状态词**，字号 1.6 倍（`font-size: 1.6em`）、加粗，按状态着色（见下方「着色」）；后面跟持续时间「已持续 <时长>」（`since` 到现在，时长写成「x 秒」「x 分钟」「x 小时」「x 天」，进位同原来的相对时间）；`dns_failsafe` 为真时同一行再显示「DNS 已回退到原配置」（警告色）。
     右边是「启用」开关，开关的说明文字（原来的 `enabled_note`）放在开关下方，用小字。开关与说明是一个**靠右对齐**的紧凑组（不用 `cbi-value` 表单行：它的标题列让开关和说明与页面其他靠右的控件对不齐，2026-10-20 真机预览后改）。
   - `last_error` 不为空时，第一行下方显示「原因：<文字>」（失败色）。上面「概览页」本来就要求显示它，T8.4 漏了（2026-10-20 复查发现），这次补上。
     文字：`NODE_RESOLVE_FAILED` 节点地址解析失败；`CONFIG_INVALID` 配置无效，详见日志页；`START_FAILED` 启动失败，详见日志页；其他值原样显示（这三个是 daemon 目前会写入的全部取值）。
   - 第二行「境外域名解析」：服务处于 `starting`、`running`、`degraded`、`failsafe` 且 `dns_tier` 不为空时才显示，文字按级别（[03](03-dns.md)「DNS 级别」）：
     `T1` 经节点解析（正常）；`T2` 直连境外 DNS（启动中，或代理不健康）；`T3` 仅用国内 DNS（境外 DNS 都不通，结果可能被污染）；其他值原样显示。T1/T2/T3 这几个代号不出现在页面上。
   - 第三行：启动、重启、停止三个按钮（可用性与停止确认不变）。
3. **当前节点**：
   - 节点名（UCI `label`，找不到用段名；没有当前节点显示「未选择节点」），字号 1.2 倍；后面用小字显示 `node_ip`，悬停提示「节点地址」。
   - 同一行右边：最近一次健康检测的结果（「正常，<n> ms」成功色、「检测失败」失败色、「尚未检测」默认色）、相对时间、「测延迟」按钮；测延迟的结果文字显示在按钮旁边（原来的规则不变）。
   - 第二行：节点下拉（当前节点的选项后加「（当前）」）+「使用此节点」按钮；下拉选中的就是当前节点时按钮不可用（避免一次没有变化的保存并应用）。
4. **流量与连接**：表格三列「（空）| 上传 | 下载」，三行「代理」「直连」「合计」，取代原来「代理 ↑ / ↓」的写法（速率算法与「–」的规则不变）。表下一行「代理连接 <n>」「总连接 <n>」，
   「总连接」悬停提示「系统连接跟踪表（conntrack）中的连接总数」；页面上不再出现「conntrack」字样。
5. **组件版本**：小字（`font-size: 0.9em`）表格「组件 | 版本 | 路径」。第一行是本程序自身：名称 `aether-proxy`（指向具体程序，按 [README](README.md)「命名」不写显示名）、版本取 `version` 方法、路径「–」，
   取不到版本显示「–」；之后是 `components` 各项（原样）。原来状态表里单独的「aether-proxy 版本」一行删除。

**删除**：「更新订阅」按钮及其结果显示（仓库所有者定：订阅本来会定时更新，手动更新留在节点页与订阅页）。

**着色**（各主题通用的写法，见下方「UI 规则」中的「样式」）：模型给出等级 `ok`、`warn`、`error`、`neutral`，视图按等级取颜色：
`ok` → `var(--success-color-high, #2f855a)`；`warn` → `var(--warning-color, #b7791f)`；`error` → `var(--error-color-high, #c53030)`；`neutral` → 不设颜色。
状态词：`running` 为 `ok`；`degraded`、`failsafe` 为 `warn`；`error` 为 `error`；`stopped`、`starting`（含等待网络）及未知状态为 `neutral`。健康检测结果：成功 `ok`、失败 `error`、尚未检测 `neutral`。

**模型 `model/overview.js` 的变化**：`build()` 增加 `state_level`、`state_duration_text`（替代 `state_since_text`）、`dns_text`（不该显示时为 `null`，替代 `dns_tier_text`）、`probe_level`、
`error_text`（`last_error` 的文字，没有为 `null`）、`node_text` 没有当前节点时为「未选择节点」、`components` 的第一项为本程序自身；增加 `node_options(labels, current)` → `[{ value, text }]`（按 `labels` 的键排序，当前节点带「（当前）」）
与 `can_switch(selected, current)`；删除 `subscription_result`、`own_version` 不再单独渲染。所有文字、等级、显示与否都由模型决定，视图只把等级映射成颜色。

### 概览页真机修正（2026-10-20 定，T10.4）

T10.2、T10.3 在 H28K（主题 `proton2025`，服务未启用）上预览时仓库所有者发现的问题。**与「概览页重排」冲突处以本节为准。**

1. **标题行**：「刷新」按钮被拉伸成与「自动刷新」整块（标签在上、下拉在下）一样高；标题行与下方第一块贴在一起。
   → 标题行与其中的控件容器加 `align-items: center`；「自动刷新」的标签文字与下拉放在同一行（`label` 内 `display:flex; align-items:center; gap:0.5em`）；标题行下方留 `margin-bottom: 1em`。
2. **当前节点块**：「尚未检测。」与「测延迟」按钮上下错位。→ 该块所有 flex 行加 `align-items: center`。
   检测结果是短语，不是句子，去掉句号：「正常，<n> ms」「检测失败」「尚未检测」（测延迟后的结果文字同样）；「检测未在 15 秒内完成」之类的整句不变。
3. **服务未运行时的当前节点**：页面显示「未选择节点」，而下拉里写着「xxx（当前）」，互相矛盾。原因是 `status.node_id` 只在服务运行时才有。
   → 节点名：`status.node_id` 不为空时用它；为空时用页面加载时读到的 UCI `main.node`（取 `label`，找不到用段名）；两者都为空才显示「未选择节点」；读取状态失败仍显示「–」。
   节点地址（`node_ip`）只来自 `status`，服务未运行时不显示。健康检测结果照旧来自 `last_probe`。
4. **「服务未启用」提示**：原文是「打开上方的『启用』」，重排后开关不在提示上方了。→ 改为「服务未启用：打开『启用』开关后会自动启动」。
5. **组件版本只有 aether-proxy 一行**：`status.components` 由 daemon 在启动时写入 `state.json`，服务没运行就没有。概览页要的是「装了什么」，与服务是否运行无关，所以改为现场查找：
   - **命令行 `aether-proxy components --json`**（只读、不记事件；接受 `--confdir`、`--bin-dir` 测试选项）：
     `{ "ok": true, "components": { "xray": { "found": true, "path": "/usr/bin/xray", "version": "26.9.30" }, "chinadns-ng": { "found": false, "path": null, "version": null } } }`。
     查找用 `cmd/check.uc` 的 `find_component`（与 `check`、`status` 的 `notices` 相同；配置中的 `xray_bin`、`chinadns_bin` 作为 `configured`，读不到配置时按未配置处理）；
     版本按 daemon 已有的读法（`xray version`、`chinadns-ng -V`，取第一行第二个字段，`component_version.parse_version`），每个组件超时 3 秒、`quiet`，失败或超时版本为 `null`。
     把 daemon 中的 `read_component_version` 挪到可共用的位置，不要复制一份。
   - **rpcd 方法 `components`**（无参数，read，超时 15 秒；`ap` 的硬超时 20 秒），ACL 的 read 增加它。
   - **页面**：`load()` 中调用一次（与其他请求一样经 `ap.call`），不随刷新重复调用。组件表三行：`aether-proxy`（版本取 `version`，路径「–」）、`xray`、`chinadns-ng`
     （`found` 为真 → 版本，取不到为「–」，以及路径；`found` 为假 → 版本「–」、路径列写「未找到」；整个调用失败 → 这两行版本与路径都为「–」）。概览页不再使用 `status.components`。
   - 更新页「运行中的组件」**不改**：它要的就是正在运行的版本。
6. **节点下拉为空**（T10.3 的 `TODO(design)`）：没有节点、或下拉没有选中项时，「使用此节点」不可用。定为设计，删掉该 `TODO`。
7. **样式规则补一条**（10「UI 规则」的「样式」）：flex 容器一律写 `align-items`（一般为 `center`），不要依赖默认的 `stretch`——按钮会被拉高。

### 概览页第二轮修正（2026-10-20 定，T10.5）

T10.4 在 H28K 上预览后仓库所有者的意见，以及复核时的实测。**与前几节冲突处以本节为准。**

1. **「自动刷新」被折成两行**（flex 收缩了标签文字）。→ 标签文字放在自己的 `span` 里，`white-space: nowrap`；下拉与「刷新」按钮照旧。
2. **当前节点块里节点名重复显示**（上面一行大字节点名，下面下拉里又是「xxx（当前）」）。仓库所有者提议只保留下拉。采纳，块内改为两行：
   - 第一行：节点下拉 +「使用此节点」。下拉的预选项与「（当前）」后缀都按**生效中的当前节点**：服务运行时取 `status.node_id`，否则取 UCI `main.node`（与 T10.4 第 3 条节点名的取法相同）；
     「使用此节点」在选中项等于它时不可用。没有任何节点时不显示下拉和按钮，显示「还没有节点，请到节点页添加或导入」。读取状态失败时按 UCI `main.node` 预选。
   - 第二行：「节点地址 <node_ip>」（只在服务运行、有 `node_ip` 时显示）、健康检测结果（颜色同前）与相对时间、「测延迟」按钮及其结果文字。
   - 删除原来的大字节点名一行（`node_text` 只用于上面「没有节点」的情形，或改名，由模型决定字段名）。节点地址的悬停提示随之删除：文字里已经写了「节点地址」。
3. **组件版本拖慢首屏**：2026-10-20 在 H28K 上实测 `ubus call aetherproxy components` 约 1.6 秒（主要是 `xray version` 的启动开销），`status` 约 0.3 秒。
   它放在 `load()` 里，整页要等它才出来。→ `components` 不再放进 `load()`：页面渲染后再调用一次，回来后只更新组件表；回来之前 xray、chinadns-ng 两行的版本与路径显示「读取中…」，
   调用失败按 T10.4 的规则显示「–」。这只是概览页的局部改动，不是跨页面的「先出骨架」（X4）。

### 概览页第三轮修正（2026-10-20 定，T10.6）

T10.5 在 H28K 上预览后仓库所有者的意见（服务未启用）。**与前几节冲突处以本节为准。**

1. **流量表的口径**：「合计」有值而「代理」「直连」都是「–」，看起来像故障。三行来源不同：合计是 WAN 口（默认路由接口）在 `/proc/net/dev` 的计数，系统一直在统计，
   包含路由器自身以及其他代理应用（例如正在运行的 ssr-plus）转发的流量；代理是本服务 nft 表里的计数器，服务没运行时表不存在；直连 = 合计 − 代理，没有代理就算不出来。
   - 「合计」一行的名称改为「合计（WAN 口）」，悬停提示「WAN 接口 <接口名> 的全部流量，含路由器自身」（接口名取 `stats.wan.dev`，没有时提示里省略接口名：「WAN 接口的全部流量，含路由器自身」）。
   - 服务不在 `starting`、`running`、`degraded`、`failsafe` 时，在「合计（WAN 口）」那一格里、名称下方换行加小字「服务未运行，无法区分代理与直连」（2026-10-20 仓库所有者看过预览后改：原先放在表下）；代理、直连两行仍为「–」。
     **不要**在这时把合计当成直连：流量可能正由别的代理应用转发。
   - 文字与是否显示由模型给出（`build()` 已有状态；`traffic()` 的结果或 `build()` 的结果中加字段均可，测试要能单独断言）。
2. **当前节点块的排版**：第二轮修正后，检测结果与「测延迟」排在下拉框正下方、与上一行没有间距，位置显得不对。→ 合并成**一行**：
   左边一组是节点下拉与「使用此节点」，右边一组是「节点地址 <node_ip>」（规则不变：只在服务运行且有地址时）、检测结果（颜色不变）与相对时间、「测延迟」按钮及其结果文字；
   外层 `display:flex; align-items:center; justify-content:space-between; flex-wrap:wrap; gap:0.5em 1em`（`gap` 的第一个值是换行后的行距），窄屏放不下时右边一组整体换到下一行。
   没有节点时左边一组换成「还没有节点……」的提示文字，右边一组照常。

### 概览页第四轮修正（2026-10-20 定，T10.9）

T10.6 及其后的小修在 H28K 上预览后，仓库所有者提议并确认（2026-10-20）。**与前几节冲突处以本节为准。**

1. **「启用」移到标题旁**：它是整个应用的持久设置（开机是否启动），不属于某一块状态。标题行左边是页面标题与「启用」开关（标签与开关在同一行，`align-items: center`），右边照旧是「自动刷新」与「刷新」。
   - 原来开关下方的说明（`enabled_note`）不再显示在页面上，改为开关的悬停提示（`title`）。
   - **关闭时先确认**：说明不在页面上了，关闭又有立即生效的后果，所以从开到关时先弹出确认「关闭后服务立即停止，所有流量直连，开机也不再自动启动。确定关闭吗？」（文字由模型给出）；
     取消 → 开关恢复为开、不改 UCI；确定 → 照旧 `uci.set` → `uci.save()` → `ui.changes.apply(true)`。从关到开不确认。
2. **待处理提示不成块**：不再用 `cbi-section` 与「待处理提示」标题，提示横幅（`alert-message`，种类与顺序不变）直接放在标题行与下面的块之间；没有提示时什么都不显示。
3. **「状态」与「当前节点」合并为一块「运行状态」**（两块回答的是同一件事：在不在运行、走哪个节点）：
   - 第一行：左边状态词（字号与着色不变）、持续时间、DNS 已回退；右边启动、重启、停止按钮（可用性与停止确认不变）。这样按钮与第三行的「测延迟」在同一条右边线上。
   - 第二行（有内容才显示）：原因、境外域名解析（规则不变）。
   - 第三行：原「当前节点」块那一行（T10.6 的结构与规则不变）。
   - 原「状态」「当前节点」两块及其标题删除。

### 切换节点未生效时提示（2026-10-20 定，T10.11）

M10 回归窗口（backlog B13 第 1 条）：仓库所有者切换节点后页面仍显示原节点，没有任何提示，重复几次才切过去。后端原因（新节点域名解析只试一次、LKG 只存一个节点）由 T9.5 修；
但 reload 失败总是可能的（配置无效、组件缺失、解析失败），页面必须让用户知道。reload 失败时 daemon 不改 `state.json`（`node_id` 仍是原节点、`last_error` 不变），只记一条 error 事件。
所以前端用「配置的节点 ≠ 正在用的节点」来发现，不改后端：

- **判断**（模型）：服务处于 `starting`、`running`、`degraded`、`failsafe`，且页面加载时读到的 UCI `main.node` 不为空、`status.node_id` 不为空、两者不同 → 「切换未完成」。服务不在这几个状态时不判断（下次启动自然用配置的节点）。
- **原因**：处于「切换未完成」时，每次刷新额外调用 `ap.call('events', { since: <现在 − 600>, level: 'error' })`，取其中**最新**一条属于下列事件码的：
  `NODE_RESOLVE_FAILED`、`CONFIG_INVALID`、`PRECHECK_FAILED`、`RENDER_INVALID`、`START_FAILED`（只算 `args.step` 以 `reload:` 开头的）。
  中文说明复用日志页模型（`model/logs.js`）的事件模板，不另写一套。不处于「切换未完成」时不调用 `events`（不给每次刷新加请求）。
- **显示**：在提示横幅区（与其他提示同一处，种类 `alert-message warning`）：
  - 找到原因：「切换到「<配置的节点名>」未生效，服务仍在使用「<正在用的节点名>」。原因：<事件说明>（<相对时间>）。可以点「重启」用配置的节点重新启动（会短暂中断代理），或到日志页查看详情。」
  - 没找到原因（重载可能还在进行，例如正在解析域名）：「正在切换到「<配置的节点名>」…」。
  节点名用 UCI `label`，找不到用段名。
- 节点下拉的预选与「（当前）」仍按 T10.5（生效中的节点，即 `status.node_id`），失败后下拉显示的是原节点。**不能**靠再选一次配置的节点来重试：UCI 里已经是这个值，LuCI 没有改动可应用，不会触发重载；所以提示里给的重试办法是「重启」。
- 不改后端：T9.5 会让解析失败少很多，但本节的提示与它无关、任何 reload 失败都适用。

### 概览页第五轮修正（2026-10-20 定，T10.13）

r8 窗口（`h28k-test` 中的 r8 结论，前端第 1、2 条）。**与前几节冲突处以本节为准。**

1. **「测延迟」的结果只显示一处**：原来按钮旁的文字（「正常，208 ms」）与左边健康检测那一项（「正常，208 ms 0 秒前」）重复。
   - 等待期间按钮不可用，按钮旁显示「检测中…」。
   - 检测完成（`last_probe.at` 不早于 `requested_at`，不论成功或「检测失败」）→ 按钮旁的文字清空，并立即刷新一次状态，结果只在健康检测那一项显示（颜色规则不变）。
   - 只有没拿到结果时才在按钮旁显示文字：「检测未在 15 秒内完成」、「服务未运行」、其他错误码与说明（原有文字不变）。
2. **组件版本读取失败要看得出来，并可重试**：原来 `components` 调用失败时 xray、chinadns-ng 两行只显示「–」，与「找到了但读不到版本」分不清。
   - 调用失败（`ap.call` 返回 `ok: false`，含超时、rpc 失败）→ 两行的版本列显示「读取失败」，路径列显示错误码与说明（`<code>: <detail>`，没有 detail 只显示 code）。
   - 失败时组件表下方显示「重试」按钮（`cbi-button-action`）：点击后两行回到「读取中…」并重新调用一次 `components`；成功后按钮消失。成功时不显示该按钮。
   - 找到组件但版本命令失败（`found: true`、`version: null`）仍显示「–」，与调用失败区分。
   - 浏览器用着旧脚本时（X9）调用会以 `RPC_FAILED` 失败；此时页面顶部还会有「页面脚本已过期」横幅（T10.12，从带有它的版本起）。

### 其余页面先出页面（2026-10-21 定，T10.16、T10.17；X4 推广）

仓库所有者要求所有页面的载入速度统一按规则与 DNS 页的做法提高（2026-10-20）。按「页面卡的写法」中的「先出页面，后填数据」逐页套用；各页 `load()` 之后只剩 UCI（和本节另说的例外）：

| 页面 | 从 `load()` 移出、改为渲染后再取 | 回来之前的显示 | 回来之前不可用的控件 |
|---|---|---|---|
| 节点（T10.16） | `probe_results` | 检测列每格「读取中…」 | 无（检测按钮不依赖已有结果） |
| 订阅（T10.16） | `sub_status` | 「最近一次结果」列每格「读取中…」 | 无 |
| 更新（T10.16） | `status` | 软件包表与「运行中的组件」处显示「读取中…」 | 「检查更新」与各行安装/更新/回滚（它们依赖表格内容）；失败 → 显示原有错误文字，「检查更新」变为可用（检查本身不依赖读取结果） |
| 日志（T10.16） | `events` | 事件列表处「读取中…」 | 过滤下拉在第一次回复前不可用 |
| 概览（T10.17） | `status`→`stats`、`version`、切换未生效时的 `events` | 状态词处「读取中…」，境外域名解析、原因等行不显示，流量表各格「–」，组件表第一行版本「读取中…」 | 启动、重启、停止（依赖状态）、「测延迟」；节点下拉在状态回来前按 UCI `main.node` 预选 |
| 访问控制 | 不改 | — | `network.getHostHints()` 是 luci-rpc 的调用，H28K 实测约 10 毫秒，且 MAC 输入框的候选要在建表单时给出，留在 `load()` |

- 高级页本来不调 rpc，不改；规则与 DNS 页已完成（T10.10）。
- 概览页：第一次 `status` 回来后照常开始自动刷新（`ap.poll`），定时器不在 `load()` 期间启动；「启用」开关只依赖 UCI，一开始就可用；组件表已经是渲染后取（T10.5），不变。
- 每页回复失败时显示原有的错误文字，不出现永久的「读取中…」。
- 节点页第一次读取检测结果失败（原来没有对应文字，T10.16 的 `TODO(design)`，2026-10-21 定）：检测列每格显示「读取失败」，原因只在进度行显示一次「读取检测结果失败：<code>: <detail>」；之后的读取失败照旧保留已显示的结果。

UI 规则：

- 破坏性按钮（删除节点、删除订阅、回滚组件）使用 `cbi-button-remove`，并要求确认；不要使用 `cbi-button-reset`（那是中性的「撤销表单修改」）。
- **长作业的进度与失败恢复**（2026-10-21 定，T10.15；跨页面问题 X11）：r8 窗口中规则与 DNS 页「立即更新」跑了 52 秒，页面没有任何变化，仓库所有者以为没反应就离开了；更新页「检查更新」出过一直置灰的情况。规则：
  1. `common.js` 提供 `ap.job_progress(target, text)` → `{ stop() }`：立即在 `target` 显示「<text>（已用 N 秒）」，每秒更新 N（从调用时算起）；`stop()` 停止计时并清空 `target`。
  2. 每个发起作业的按钮（规则与 DNS 页「立即更新」；更新页「检查更新」「安装」「立即更新」「回滚」；订阅页「立即更新」「全部更新」）：点下后按原规则禁用相关按钮，在按钮旁的提示区开始 `ap.job_progress`，
     文字分别是「正在更新规则数据…」「正在检查更新…」「正在安装 <包>…」「正在回滚 <包>…」「正在更新订阅…」。作业结束 → `stop()`，显示原有的结果文字，按原规则刷新数据。
  3. **失败一定恢复**：作业链上任何一步抛出异常（不只是作业返回失败）→ 显示「操作失败：<异常说明>」，并且**按钮、`busy` 等状态一律在 `finally` 里复原**，页面不会停在置灰状态。节点页的检测作业已有自己的进度（「检测中 n/m」），只按这一条补上 `finally` 复原。
  4. 不做「重新打开页面后接着显示正在跑的作业」：需要后端先提供列出正在运行的作业的接口，留待以后。
- **确认框用 `ui.showModal`，不用 `window.confirm`**（2026-10-20 定，T10.14；跨页面问题 X10）：浏览器原生的确认框样式跟浏览器、不跟主题（r8 窗口在 proton2025 下截图）。
  统一经 `common.js` 的 `ap.confirm({ title, text, ok, destructive })` → `Promise<boolean>`：用 `ui.showModal(title, [ E('p', text), 按钮行 ])` 显示，按钮行按 LuCI 自己的写法放在 `E('div', { class: 'right' })` 里，
  依次是「取消」（`cbi-button`）与确认按钮（文字为 `ok`；`destructive` 为真时 `cbi-button-remove`，否则 `cbi-button-action`）；点任一按钮先 `ui.hideModal()` 再 resolve（取消为 `false`、确认为 `true`）。
  页面中不得再出现 `confirm(`（静态检查）。各处的标题与按钮：
  | 位置 | 标题 | 确认按钮 | 正文 |
  |---|---|---|---|
  | 概览页关闭「启用」 | 关闭「启用」 | 关闭（destructive） | 原 `disable_confirmation` |
  | 概览页「停止」 | 停止服务 | 停止（destructive） | 原 `stop_confirmation` |
  | 节点页删除 | 删除节点 | 删除（destructive） | 原「确定删除这个节点？」 |
  | 订阅页删除 | 删除订阅 | 删除（destructive） | 原删除计划的确认文字 |
  | 更新页回滚 | 回滚 <包名> | 回滚（destructive） | 原 `row.confirmation` |
  确认框是异步的：调用处等 `ap.confirm` 的结果再继续；取消时的行为与原来相同（概览页关闭「启用」时取消 → 开关恢复为开、不改 UCI）。
- 前端同时发出的请求不超过 2 个（为 uhttpd 的 `max_requests 3` 留出余量）。
- **样式**（2026-10-20 定，T10.3 起；跨页面问题 X7）：页面要在用户的任意主题下可用（H28K 用第三方主题 `proton2025`，另装 bootstrap、argon-plus），所以：
  布局与组件只用 LuCI 标准类名（`cbi-section`、`cbi-value`、`cbi-button-*`、`alert-message <等级>`、`table`）；内联样式只用于排版（`display:flex`、`gap`、`flex-wrap`、`justify-content`、`margin`）
  和**相对**字号（`em`），不写 `px` 字号；颜色只用主题的 CSS 变量，并带上回退值：`var(--success-color-high, #2f855a)`、`var(--warning-color, #b7791f)`、`var(--error-color-high, #c53030)`
  （bootstrap 与 proton2025 都定义了前两个 success/error 变量，warning 只有 proton2025 有，2026-10-20 核对）。**不要用 `label success` 之类的修饰类着色**：proton2025 只有 `.label`，没有这些修饰类。
  控件多的行用 `flex-wrap: wrap`，窄屏时自动换行。flex 容器一律写 `align-items`（一般为 `center`）：默认的 `stretch` 会把按钮拉高（2026-10-20 真机发现，T10.4）。
  放在 flex 行里的 `select` 写 `width:auto`：主题会把它设成 `width: 100%`（proton2025），在 flex 行里会占满整行、把同一行的按钮挤到下一行（2026-10-20 真机发现，T10.6 之后补）。
- 翻译包 `luci-i18n-aether-proxy-zh-cn` 与功能包分开生成。修改 po 后两个包要一起安装。
- **翻译一律带上下文 `aether-proxy`**（2026-10-20 定，T10.1）：界面文字写成 `_('Refresh', 'aether-proxy')`，po 中对应条目带 `msgctxt "aether-proxy"`。
  原因：LuCI 把设备上**所有**已安装应用的翻译目录（`/usr/lib/lua/luci/i18n/*.zh-cn.lmo`）并成一张表，按「上下文 + 原文」的哈希查找，
  同一原文在多个目录里都有时，用哪一份取决于 `readdir` 的顺序（`lmo.c` 的 `lmo_load_catalog`），不可预测。
  2026-10-20 在 H28K 上逐条核对（用 `cbi.js` 的 `sfh` 算我们每条原文的键，到其他 16 个 lmo 的索引里查）：18 条原文与别的目录撞车且译文不同，
  页面上实际显示的是别人的译文，例如概览页的「Switch」显示成「交换机」（luci-base）、「Refresh」显示成「更新」（ssr-plus），访问控制页的「Follow」显示成「跟随活动接口」。
  只改撞车的原文治标不治本：用户装别的应用（尤其是同类代理应用）随时会带来新的撞车。带上下文后键里含 `aether-proxy`，不会与任何其他应用相同；
  设备上的 `cbi.js`（`_(s, c)`）与 `po2lmo`（`msgctxt`）都支持，已核对 24.10 与 25.12 的源码和 H28K 上的 `cbi.js`。
  - **例外：菜单标题**（`menu.d` 的 `title`）由主题用 `_(child.title)` 翻译，传不了上下文，po 中这几条**不带** `msgctxt`。
    菜单标题仍可能与别的应用撞车（2026-10-20 在 H28K 上核对：目前没有），选词时避开过于通用的词，无法根除。
  - 翻译闸门（`tests/luci/i18n.test.js`）检查：每个 `_()` 都带字面量上下文 `'aether-proxy'`；po 按「上下文 + 原文」查找；
    不带上下文的条目只能是菜单标题；没有被引用的条目算失败。
