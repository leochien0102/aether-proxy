# 09 日志

## 原则

- **不自造日志文件**。人读的日志写 logd（`logread` 可见）；机器读的结构化事件写 tmpfs 环形文件。都不落 flash。
- syslog 行使用**英文**（沿用 helloworld 的分层约定：syslog 英文，界面本地化），中文只出现在 LuCI 中，
  由事件码翻译得到。
- 事件码是**机器协议**：一旦发布就不改名、不改含义，只能新增。

## 来源与标签

| 来源 | 写入方式 | syslog 标签 |
|---|---|---|
| aether-proxy / daemon | `logger -t aether-proxy -p daemon.<level>` 或等价调用 | `aether-proxy` |
| Xray | daemon 读取子进程的 stdout/stderr，逐行转发（实现方式见下方「子进程日志」） | `aether-proxy-xray` |
| chinadns-ng | 同上 | `aether-proxy-dns` |

Xray 的 access 日志固定关闭（隐私和 CPU 开销），error 日志等级由 `xray_log_level` 决定。chinadns-ng 不开 `-v`。

## 子进程日志（S1 已定，2026-10-15）

宿主机实验结论：
- `fs.popen` 加 `uloop.handle` **不可行**：`fs` 句柄带 stdio 缓冲，一次读入多行后事件循环不再触发，尾部行与 EOF 会卡在缓冲区里；
  ucode 2025.07.18 没有把描述符设为非阻塞的手段。
- `uloop.process` 可靠：退出回调能拿到退出码，按 pid 结束进程后回调及时触发，子进程的 stdout/stderr 原样继承父进程。

**决定**：Xray 与 chinadns-ng 由 daemon 用 `uloop.process` 拉起，**直接继承 daemon 的 stdout/stderr**；init 脚本对 daemon 实例设置
`procd_set_param stdout 1` 与 `procd_set_param stderr 1`，由 procd 统一写入 logd。代价是三者共用 procd 给该实例的标签，
不再有 `aether-proxy-xray` / `aether-proxy-dns` 两个独立标签——两者的输出格式本身可以区分（Xray 为 `[Info]`/`[Warning]` 前缀，chinadns-ng 为 `[main.zig:…]` 之类的源码位置），
LuCI 原始日志页按内容过滤即可。上方「来源与标签」表中这两行以本节为准。

**限流**（2026-10-21 定，backlog B14 第 2 条）：r8 窗口中 Xray 重启的那一秒，chinadns-ng 连不上 Xray 的 DNS 入站，同一秒写了 1336 行警告，logd 缓冲区里之前的记录全被挤掉。
chinadns-ng 没有降低日志量的选项（只有 `-v` 加详细日志），daemon 又读不到子进程的输出（见上），所以在子进程与 procd 之间加一个过滤进程：

- daemon 为每个子进程建一个 FIFO（`/var/run/aether-proxy/<名称>.log.fifo`，启动前先删掉旧的再建），用 `uloop.process` 启动 `/bin/sh -c`：先在后台启动过滤进程（从 FIFO 读、写到继承来的 stdout），
  再 `exec` 子进程并把 stdout/stderr 重定向到 FIFO。**`exec` 保持 pid 不变**，监管、停止、退出码判断都照旧针对这个 pid。子进程退出后 FIFO 的写端关闭，过滤进程读到 EOF，输出汇总行后退出。
- 过滤进程是 busybox `awk`（`systime()`、`fflush()`；H28K 上实测可用），脚本随包安装。每行读入后立即 `fflush`，不缓冲正常日志。
- **合并重复消息**（2026-10-23 定，r13 窗口：启动后约 6 秒里 chinadns-ng 交替写 `recv(tcp://8.8.8.8) failed` 与 `recv(tcp://1.1.1.1) failed`，每秒约 10 行，没超过限流却刷了一屏）：
  每行先去掉行首的时间戳（chinadns-ng 的 `YYYY-MM-DD HH:MM:SS` 连同前面的颜色控制码、Xray 的 `YYYY/MM/DD HH:MM:SS.ffffff`）得到「消息」；10 秒窗口内同一条消息第一次照常输出，之后的只计数不输出；
  窗口结束时（窗口满 10 秒后的第一行到来时，以及 EOF 时）对每条被压下的消息输出一行 `aether-proxy: <名称> repeated N more times: <消息，截断到 160 字符>`。每个窗口最多跟踪 32 条不同的消息，超出的照常输出（仍受下面的限流）。
  合并先于限流：被合并掉的行不计入限流的配额。系统时间往回跳时与限流一样清空重来。
  **跟踪位满时让位**（2026-10-23 定，r14 窗口：chinadns-ng 启动先打印约 40 行各不相同的配置信息，占满 32 个跟踪位，紧接着每秒上千行的 `connect(...) failed` 没被跟踪，只被限流压住）：
  32 条都在跟踪时来了新消息，就把**最早开始跟踪、且至今没有重复过**（计数为 0）的那一条换掉；32 条都有重复时新消息照旧不跟踪。被换掉的那条没有被压下的行，不需要汇总。
- **转发时去掉颜色码与子进程自带的时间戳**（2026-10-23 定，r14 窗口，仓库所有者同意）：chinadns-ng 的行带 ANSI 颜色控制码，LuCI 原始日志与 `logread` 原样显示成 `[33;1m … [0m`；
  它自带的时间是 UTC，与 syslog 的本地时间并列，一行两个时间容易看错。过滤器转发的是**去掉颜色码（行内所有 `ESC[…m`）、再去掉行首时间戳（同上两种格式）与随后空白之后的消息**，即合并用的同一个键；
  认不出时间戳的行只去颜色码。syslog 自己会加时间。chinadns-ng 时间戳后的级别字母（`W`/`I`/`E`）保留在行首，能看出是警告还是信息（T9.31 复核定）。（取代原先「首次放行的原始行保持不变」，T9.30 定的是原样转发。）
  细节（2026-10-23 T9.30 定）：第一次出现的行即使随后被限流丢掉也照样跟踪，后面的重复只计数——重试不再占配额，窗口结束的汇总行带着消息原文，丢掉的那一行算在限流汇总里；
  窗口是固定的 10 秒（从窗口内第一行起算，重复不延长）；时间回跳时未结束窗口的重复计数直接丢弃，不输出汇总；汇总行与限流汇总一样不占配额。
- 规则：每个子进程**每秒最多 20 行、每分钟最多 120 行**，超出的丢弃并计数；之后第一次又有行可输出时（以及 EOF 时）先输出一行
  `aether-proxy: <名称> output rate limited, dropped N lines between HH:MM:SS and HH:MM:SS`（与子进程的输出同样进 syslog，不记事件：过滤进程不连事件日志）。
  数字的依据：logd 默认缓冲区约 64 KB，按每行 150 字节约 400 行；每分钟 120 行时，即使持续刷屏，最早的记录也能保留约 3 分钟以上，日常的启动、切换日志远低于这个量。
- FIFO 建不了（例如没有 `mkfifo`）→ 退回原来的直接继承，记一次 `FS_FAILED`（`op: mkfifo`），不影响启动。
  过滤脚本读不到（打包缺失）同样退回直接继承，记 `FS_FAILED`（`op: read`）：否则 awk 立刻退出，子进程写第一行就因 SIGPIPE 死掉、反复崩溃重启（2026-10-21 T9.7 复核补）。
- 细节（2026-10-21 T9.7 定）：「每分钟」是**滚动的 60 秒**（自然分钟的边界两侧可以各放 120 行）；汇总行**不占**配额（满额时也要能说明丢了多少）；
  系统时间**往回跳**（NTP 校正、手动改时间）时清空计数重新开始——只是多放行一份配额，而钳在上次的时间上会让子进程在回跳的整段时间里每秒只剩 20 行可用。

注意：被信号结束的子进程在 `uloop.process` 回调里报告的退出码也是 0，与正常退出无法区分。daemon 必须自己记录「这次是主动停止」，
凡不是主动停止的退出一律视为崩溃并按退避重启。

## 等级

| aether-proxy 等级 | syslog 优先级 | 用于 |
|---|---|---|
| `error` | `err` | 功能受损：启动失败、故障放行、回滚 |
| `warn` | `warning` | 有降级但仍可用：DNS 降级、使用 LKG、订阅缩水 |
| `notice` | `notice` | 状态变化与用户操作：启停、切换节点、更新完成（**默认等级**） |
| `info` | `info` | 每个流程步骤 |
| `debug` | `debug` | 每轮检测结果、执行的外部命令及其退出码 |

## syslog 行格式

```
<EVENT_CODE> <英文描述> [k=v k=v ...]
```

示例：
```
aether-proxy: XRAY_DOWN_FAILOPEN xray not listening for 2 rounds, interception removed [port=31080]
aether-proxy: DNS_TIER_CHANGED trust upstream switched [from=T1 to=T2 reason=proxy_unhealthy]
aether-proxy: CMD_FAILED external command failed [cmd="nft -f /var/run/aether-proxy/aether-proxy.nft" rc=1 stderr="Error: ..."]
```

外部命令失败一律使用 `CMD_FAILED`，带上命令、退出码和 stderr 的第一行（截断到 200 字符）。

## 结构化事件

`notice` 及以上等级的事件同时追加到 `/var/run/aether-proxy/events.jsonl`，每行一个 JSON：

```json
{"ts":1760400000,"level":"warn","code":"DNS_TIER_CHANGED","args":{"from":"T1","to":"T2","reason":"proxy_unhealthy"}}
```

保留最近 500 行（超过时截掉前面的一半）。裁剪是「读全文件 → 写临时文件 → 改名」，不加锁：daemon 与作业进程恰好同时追加时，裁剪窗口内另一进程追加的那一行可能丢失。这是接受的代价（每约 250 条事件才裁剪一次，窗口很短；每个事件同时写了 syslog，`events.jsonl` 只是 LuCI 的视图），2026-10-17 定（backlog B9）。读取时跳过无法解析的行（断电可能留下半行）并计数，不能因个别坏行导致整个读取失败。LuCI 的「事件」视图读取这个文件，按 `code` 套用中文模板显示，
例如 `DNS_TIER_CHANGED` → 「DNS 已从 {from} 切换到 {to}（原因：{reason}）」。

## 事件码目录（首版）

| 代码 | 等级 | 参数 |
|---|---|---|
| `SERVICE_STARTED` / `SERVICE_STOPPED` | notice | `mode`、`node`；`SERVICE_STARTED` 另有 `elapsed_ms`、`steps`（步骤名 → 毫秒） |
| `RELOAD_APPLIED` | notice | `from_node`、`to_node`、`actions`、`elapsed_ms`、`steps`（[04](04-lifecycle.md)「重载」，有动作执行成功时才记；`steps.detail` 为更细的分段计时，T9.12） |
| `BUSY` | warn | `holder` |
| `CONFIG_INVALID` | error | `field`、`reason` |
| `PRECHECK_FAILED` | error | `missing` |
| `RENDER_INVALID` | error | `artifact`、`detail` |
| `START_FAILED` | error | `step`、`detail` |
| `JOB_LOST` | warn | `job`、`kind`（作业文件为 running 但工作进程已不存在，见 10「作业机制」） |
| `START_RETRY` | warn | `attempt`、`in_secs`（启动失败后 daemon 内的退避重试，见 04） |
| `NET_WAIT_TIMEOUT` | warn | `waited` |
| `COMPONENT_MISSING` / `COMPONENT_TOO_OLD` | error | `component`、`version`、`min` |
| `NODE_RESOLVE_FALLBACK` / `NODE_RESOLVE_FAILED` | warn / error | `node`、`domain`、`lkg_ip` |
| `NODE_IP_CHANGED` | notice | `node`、`old`、`new` |
| `NODE_STALE` / `NODE_STALE_IN_USE` | warn | `node`、`label` |
| `NODE_INSECURE_IGNORED` | warn | `node`、`label` |
| `PROXY_HEALTHY` / `PROXY_UNHEALTHY` | notice / warn | `latency_ms`、`fails` |
| `DNS_TIER_CHANGED` | warn（降级）/ notice（恢复） | `from`、`to`、`reason` |
| `XRAY_DOWN_FAILOPEN` / `XRAY_DOWN` / `XRAY_RECOVERED` | error / error / notice | `port` |
| `CHILD_STARTED` | info | `name`、`pid` |
| `CHILD_CRASHED` | warn | `name`、`pid`、`code`、`restart_in`（秒）。子进程不是因主动停止而退出时记录（[04](04-lifecycle.md)「进程模型」） |
| `DNS_DOWN_FAILSAFE` / `DNS_RECOVERED` | error / notice | — |
| `NFT_TABLE_RESTORED` | warn | — |
| `DNSMASQ_CONFDIR_NOT_FOUND` / `DNSMASQ_EXTRA_SERVERS` | error / warn | `servers` |
| `IPV6_PRESENT` | warn | `iface` |
| `SUB_UPDATED` | notice | `sub`、`added`、`updated`、`stale`、`removed`、`skipped`（按原因计数的对象） |
| `SUB_FETCH_FAILED` / `SUB_DECODE_FAILED` / `SUB_FORMAT_UNSUPPORTED` / `SUB_APPLY_INVALID` / `SUB_PROXY_UNAVAILABLE` | error | `sub`、`detail` |
| `SUB_SHRANK` | warn | `sub`、`old`、`new` |
| `SUB_NO_VALID_NODES` | error | `sub`、`skipped`（按原因计数）。解码成功但没有任何可导入的节点（与 `SUB_DECODE_FAILED` 区分） |
| `UPDATE_AVAILABLE` | notice | `package`、`current`、`latest` |
| `UPDATE_INSTALLED` / `UPDATE_VERIFY_FAILED` / `UPDATE_ROLLED_BACK` | notice / error / error | `package`、`version`（数据更新的 `UPDATE_VERIFY_FAILED` 用 `item`） |
| `DATA_UPDATED` | notice | `items` |
| `MANIFEST_BAD_SIGNATURE` | error | `url` |
| `UPDATE_FETCH_FAILED` | error | `urls`（所有发布通道地址都连不上；与验签失败区分，见 08「检查」） |
| `NO_SPACE` / `ARCH_UNSUPPORTED` | error | `need`、`free` / `arch` |
| `CMD_FAILED` | error | `cmd`、`rc`、`stderr`；作业工作进程记录时另有 `code`、`detail`（子命令 `--json` 输出中的错误码与原因，没有就不带；`code` 不是字符串时两项都不带，`detail` 不是字符串时只带 `code`；2026-10-22 加，r11 窗口：`sub update` 未知订阅时 `stderr` 为空，看不出原因） |
| `CMD_RUN` | debug | `cmd`、`rc`、`ms`（每次执行外部命令后记录，只在 debug 等级输出） |
| `FS_FAILED` | error | `op`（open/read/parse/write/rename/unlink/mkdir/stat/list，以及 `reload-config` 等说明具体步骤的值）、`path`、`detail`（调用方在 `sys.write_atomic` 等返回失败时记录） |

新增事件码时同步修改本表、LuCI 的翻译模板和 po 文件。

## logd 容量

OpenWrt 默认的 logd 缓冲区只有 64KB，在 `debug` 等级下很快就会被冲掉。LuCI 日志页在等级为 `debug` 时提示：
「建议在 系统 → 日志 中调大缓冲区，排查完成后调回 notice」。aether-proxy 不修改 `system.@system[0].log_size`。

## LuCI 展示

- 「事件」页：读取 `events.jsonl`，按等级着色，支持按等级、事件码过滤。默认打开这一页。
- 「原始日志」页：经 rpcd 的 `log` 方法（命令行 `log`，不能让前端执行任意命令），可按来源（aether-proxy / Xray / DNS）过滤。
- 页面细节见 [10](10-cli-luci.md)「日志页」与「`log`、`node import`、`custom`」（2026-10-16 改：原来写的 `logread -e` 与 `aether-proxy-xray` 等标签已被 T8.2 的实现取代，子进程共用 `aether-proxy` 标签）。
