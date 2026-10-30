# 04 生命周期

## 状态

`/var/run/aether-proxy/state.json` 记录当前状态，LuCI 和 `aether-proxy status` 都从这里读取。

| 状态 | 含义 | 拦截规则 | DNS 接管 |
|---|---|---|---|
| `stopped` | 未运行 | 无 | 无 |
| `starting` | 启动流程进行中 | 无 → 末段加载 | 末段接管 |
| `stopping` | 停止流程进行中（收到 SIGTERM 起，2026-10-23 r14 加：页面据此显示「正在停止」） | 摘除中 | 撤回中 |
| `running` | Xray 存活且代理健康 | 有 | T1 |
| `degraded` | Xray 存活但代理不健康，或节点解析失败 | 有（`fail_open=1` 且节点解析失败时除外） | T2/T3 |
| `failsafe` | Xray 进程不可用 | **已摘除**（故障放行） | T2/T3 |
| `dns_failsafe` | chinadns-ng 不可用（可与以上状态叠加，作为标志位） | 不变 | **已撤回**，dnsmasq 回到原配置 |
| `error` | 启动失败，已回滚 | 无 | 无 |

`state.json` 字段：`state`、`dns_tier`、`dns_failsafe`、`node_id`、`mode`（当前生效的默认模式：启动或重载**成功应用**后写入，失败的重载不改；与 `node_id` 同理，2026-10-22 加，供概览页判断只换模式的切换何时完成，10「概览页：默认模式下拉」）、`node_ip`、`degraded_mode`、`degraded_since`（分流降级，02「节点不健康时的分流降级」，2026-10-27）、`since`（进入当前状态的时间戳）、
`last_probe`（`ok`、`latency_ms`、`at`）、`last_error`（事件码）、`components`（各组件的版本与路径）、`render_hash`（各产物的哈希）、
`wan_dns`（本次成功应用的渲染所用的运营商下发 IPv4 DNS，按接口名排序、保持接口内顺序并去重；`china_dns` 含 `wan` 但取不到时为 `[]`，此时渲染用 `223.5.5.5`；不含 `wan` 时为 `null`。启动和重载成功应用后更新，产物没变也更新；失败的重载不覆盖原值。2026-10-22 T9.23）。

`components` 的版本（2026-10-16 定，T8.9a）：`{ "xray": { "path", "version" }, "chinadns-ng": { "path", "version" } }`。daemon 在启动流程的前置检查找到组件后，
分别执行 `<xray> version` 与 `<chinadns-ng> -V`（各 5 秒超时），取输出**第一行的第二个字段**作为版本（实测 `Xray 26.9.30 (Xray, Penetrates Everything.) …`、
`ChinaDNS-NG 2025.06.20 be347b5 | …`，[08](08-updates.md)「S7 探针结论」）。取不到（命令失败、超时、输出不符合格式）→ `version` 为 `null`，**不影响启动**，也不记事件。
收到 SIGUSR2 重启 Xray 时（`xray-core` 软件包更新后，二进制可能换了）重新取一次 Xray 的版本并写回 `state.json`。版本解析是纯函数。
**重载也要保留版本**（2026-10-20，backlog B13）：重载写回 `state.json` 时，组件路径没变就沿用原来的 `version`；路径变了（例如改了 `xray_bin`）就按上面的方法重新取。原来重载只写 `path`，第一次重载后版本就没了。

## 启动（`aether-proxy daemon [--boot]` 的前半段）

**每一步失败都按相反顺序回滚已完成的步骤**，最终状态为 `error`，事件里带上失败的步骤名。

**启动失败后 daemon 不退出**（2026-10-15 真机验收后定）：停在 `error` 状态，按 30 s → 60 s → 5 min（封顶）的间隔重新执行第 2–11 步；
收到 SIGHUP 立即重试一次并把间隔归零，SIGTERM 照常停止。第 2 步（配置无效）失败不重试，只等 SIGHUP。
理由：退出会让 procd 立即拉起，而每轮都超过 procd 的 5 秒崩溃判定，于是无限快速循环，每轮还要重启两次 dnsmasq；在 daemon 内退避既省资源，状态也对 LuCI 可见。

| # | 步骤 | 失败处理 |
|---|---|---|
| 1 | 取锁 `/var/lock/aether-proxy.lock`（非阻塞） | 退出码 3，`BUSY` |
| 2 | 读取配置并校验（含主机冲突、节点存在等） | 退出码 2，**系统状态不做任何改动** |
| 3 | 前置检查：模块、命令、接口、组件二进制（[02](02-dataplane.md)、[01](01-architecture.md)） | `PRECHECK_FAILED` |
| 4 | 仅 `--boot`：等待网络（见下文） | 超时记 WARN 后**继续** |
| 5 | 渲染全部产物到 `/var/run/aether-proxy/staging/`，并校验：`xray run -test -c`、`nft -c -f`、chinadns 配置（见 [03](03-dns.md) 的核实项） | `RENDER_INVALID`，系统不改动 |
| 6 | staging 提交为当前（`mv`），记录 `render_hash` | — |
| 7 | 启动 chinadns-ng（DNS 级别 T2） | 回滚 |
| 8 | 写入 dnsmasq 片段并重启 dnsmasq | 回滚 |
| 9 | 引导解析节点 IP（[03](03-dns.md)），用结果补全 Xray 配置并再次 `-test` | 解析失败 → 继续，状态记为 `degraded`，不启动 Xray。`fail_open=1`（默认）：跳过第 10、11 步，流量全部直连；`fail_open=0`：跳过第 10 步，**仍执行第 11 步**（加载 nft 与 ip rule），代理目标的流量失败而不是改走直连（2026-10-15 复审后补） |
| 10 | 启动 Xray，在 5 秒内等待 `TPROXY_PORT` 进入监听（读取 `/proc/net/tcp`） | 回滚 |
| 11 | 加载 nft 表（含恢复动态集合）、添加 ip rule / route | 回滚 |
| 12 | 进入 monitor 循环，由它判定为 `running` / `degraded` | — |

代理是否真正可用由 monitor 异步判定，LuCI 能看到状态变化。

**组件最低版本闸门（2026-10-30，T9.44）**：第 3 步发现组件后、第 4 步等待网络之前，若版本可识别且低于 `XRAY_MIN_VERSION` / `CHINADNS_MIN_VERSION`，记 error `COMPONENT_TOO_OLD {component, version, min}`，`failed_step=component_version`，不执行后续步骤；版本取不到（null、坏 banner、命令失败）按上文允许启动、不记事件。`check` 用同一比较器只给 `COMPONENT_TOO_OLD` warning，不失败。

**与其他代理插件的冲突**（第 3 步的一部分；2026-10-24 定，r15 窗口：ssr-plus 被 `reload_config` 重新拉起，aether-proxy 每次启动都 `PRECHECK_FAILED conflict:ss_spec`，页面只写「启动失败，详见日志页」）。
这些插件都接管 dnsmasq 与透明代理规则，同一时间只能有一个在运行。下表的名字已按各插件源码核实（2026-10-24：fw876/helloworld、Openwrt-Passwall/openwrt-passwall 与 openwrt-passwall2、immortalwrt/homeproxy、vernesong/OpenClash、nikkinikki-org/OpenWrt-nikki 的 master/main 分支）：

| 插件（冲突名） | init 脚本 | 在运行的迹象（任一） | 配置里启用 |
|---|---|---|---|
| `ssr-plus` | `shadowsocksr`（传统 rc，**不经 procd**，`ubus call service list` 看不到） | nft 表 `inet ss_spec` 或 `ip ss_spec_mangle` | `shadowsocksr.@global[0].global_server` 存在且不是 `nil` |
| `passwall` | `passwall`（传统 rc） | nft 表 `inet passwall` | `passwall.@global[0].enabled=1` |
| `passwall2` | `passwall2`（传统 rc） | nft 表 `inet passwall2` | `passwall2.@global[0].enabled=1` |
| `homeproxy` | `homeproxy`（procd） | `inet fw4` 里有 `homeproxy_` 开头的链（它不建自己的表） | `homeproxy.config.main_node` 存在且不是 `nil`，或 `homeproxy.server.enabled=1` |
| `openclash` | `openclash`（procd） | `inet fw4` 里有 `openclash` 开头的链；或进程 `clash` | `openclash.config.enable=1` |
| `nikki` | `nikki`（procd） | nft 表 `inet nikki`；或进程 `mihomo` | `nikki.config.enabled=1` |
| `clash`、`mihomo` | — | 进程名（不属于上面插件的独立运行，原有检测保留） | — |

- **正在运行**（任一迹象）→ 第 3 步失败：`PRECHECK_FAILED`，`missing` 里写 `conflict:<冲突名>`（原来写 nft 表名 `conflict:ss_spec`，改为插件名，页面据此写出插件的名字）。照旧按退避重试，对方停掉后下一次重试自动恢复。
  检测用一次 `nft list tables` 与一次 `nft list chains inet fw4`（fw4 不在时不算错）加原有的进程检查；检查本身失败照旧记 `conflict-check:<原因>`。
- **停着但配置里仍启用**（init 脚本存在，且「配置里启用」成立）：不拦启动，但 `status` 的 `notices` 给出 `CONFLICT_ENABLED`（[10](10-cli-luci.md)「概览页」）。
  **只看「配置里启用」，不看开机自启**（2026-10-24 改，r16 窗口，仓库所有者定）：这几个插件配置里没启用时，被开机调起也什么都不做（ssr-plus `global_server=nil` 不装规则；passwall/passwall2 `enabled=0`；homeproxy 无节点且服务端关时退出；openclash `enable=0`、nikki `enabled=0` 不启动），开机自启本身不构成冲突。
  r16 里 ssr-plus 主服务器已停用、只剩 `/etc/rc.d/S95shadowsocksr`，横幅却一直在；而 LuCI「系统 → 启动项」没列出 shadowsocksr（链接实际存在），提示里「去启动项关掉开机自启」用户照做也找不到。args 里的 `boot` 保留，仅供参考。
  理由：「停止」不等于「停用」——这次 ssr-plus 已被 `/etc/init.d/shadowsocksr stop` 停掉，但配置里仍选着主服务器，它自己运行时改写过 `/etc/config/shadowsocksr`，`reload_config` 发现变化就通知 procd，对停着的服务 reload 等于启动。
- 只认上表这些插件；dae/daed、v2rayA 等未核实，以后需要时按同样方法核实后补进表里。
- 细节（T9.34 复核定）：进程 `clash`/`mihomo` 在装着 openclash/nikki 的 init 脚本（或已有它们的 nft 迹象）时算作该插件，否则保留独立的进程名；`status` 里运行检测本身失败时不给 `CONFLICT_ENABLED`（不能把可能在运行的插件说成停着），启动检查照旧报 `conflict-check:`。
  H28K 实测一次扫描约 90 ms（`status` 每 5 秒一次，可接受）。

第 1 步的锁：daemon 在启动流程（第 2–11 步）期间持锁，进入 monitor 循环后释放，之后每次动作临时取锁。

**配置备份与恢复（T10.70）**：应用层的四条写配置路径（10「原子语义」）在替换前把当前已校验配置原子备份到 `/etc/aether-proxy/config.backup`（0600，不是 UCI 包），备份失败则不替换；成功逐字节回读后再更新备份。原子替换保持真实配置的权限/属主。第 2 步先按全局 → config 顺序取得非阻塞配置锁，清理本包的 `aetherproxy.tmp.*`、`config.backup.tmp.*` 与 sub-work 下残留 `*.tmp.*`（不清理其他 UCI 包）。读取/解析/归一化校验失败时，只有备份也通过完整校验才用同目录临时文件原子恢复、逐字节回读，并记一次 WARN `CONFIG_RECOVERED {path}`，随后继续启动。无有效备份时保留原配置和原错误；恢复 I/O 失败明确报 `FS_FAILED`，不谎报恢复成功。配置有效时启动刷新备份（覆盖 LuCI 外部提交的有效配置）；轮询/status 不执行恢复，不重复事件。断电/fsync 不在本卡保证范围。

## 停止（daemon 收到 SIGTERM；`cleanup` 是同样的步骤，只是不依赖 daemon 存活）

顺序与启动相反，**每一步都要执行，前一步失败也不能跳过后续步骤**（失败记 ERR）：

0. 先把 `state.json` 的 `state` 写为 `stopping`、`since` 为此刻，其余字段保留（2026-10-23 r14：原来停止期间一直显示旧的 `running`，页面点「重启」后会读到旧进程的「运行中」）。写失败只记 `FS_FAILED`，不影响后续步骤
   - 2026-10-30（T9.46）：停止意图在 SIGTERM 回调里**立即**发布，不等 `monitor.busy` 或正在执行的异步动作；置位后 monitor tick、订阅调度、重载不再启动新动作，正在执行的动作完成后不得把 `stopping` 写回 `running`（进程内 state 写屏障），最终写 `stopped`。同步探测无法抢占，返回后的第一个可派发点发布 `stopping`。
1. 退出 monitor 循环
2. 导出动态集合（`gfw4`、`udirect4`、`uproxy4`）到 `/var/run/aether-proxy/sets.save`
3. `nft delete table inet aetherproxy`；删除 ip rule / route。重复的 ip rule（异常退出后再次启动可能留下）逐条删除，**最多 16 次**：正常只有 0～1 条；上限只是防止 `ip rule del` 报成功而规则仍在时陷入死循环，超过仍有残留就报失败（2026-10-17 补理由，backlog B9）。
4. 删除 dnsmasq 片段并重启 dnsmasq
5. 停止 chinadns-ng、Xray
6. 状态写为 `stopped`（只写停止相关的字段：`state`、`since` 等；组件版本、节点、模式、哈希不保留——概览页的组件表走独立的 `components` 接口；2026-10-27 定，复核 Q2）

### 进程模型（已定）

启动顺序有硬依赖：chinadns-ng → dnsmasq → 解析节点 → Xray 监听 → 加载 nft。procd 的多个实例是在
`start_service` 返回后才统一拉起的，表达不了这种顺序。所以：

- procd **只托管一个实例**：`aether-proxy daemon`（respawn `3600 5 5`，`term_timeout 30`：SIGTERM 要等当前一轮检测的同步部分，再导出集合、删表、重启 dnsmasq；procd 默认等 5 秒就 SIGKILL，远远不够）。
- `aether-proxy daemon` 是监督进程：执行上面的启动步骤，以**子进程**方式拉起并重启 Xray、chinadns-ng
  （退避 5s → 10s → 30s → 60s 封顶），然后进入 monitor 循环。
  子进程用 `uloop.process` 拉起，继承 daemon 的 stdout/stderr（日志由 procd 收集，见 [09](09-logging.md)「子进程日志」）；退出由回调通知，不轮询。daemon 记录每个子进程是否处于「主动停止」中，不是主动停止的退出一律视为崩溃。连续稳定运行 5 分钟后退避计数归零。
- 收到 SIGTERM：按「停止」的顺序清理，然后退出。
- `/etc/init.d/aether-proxy`：
  - `start_service`：直接注册 `aether-proxy daemon` 实例（开机时 `boot()` 带 `--boot`），**不再先同步执行 `aether-proxy check`**。
    （2026-10-23 改，r13 窗口：H28K 上这次 check 约 5–10 秒（新进程没有缓存，读配置与数据、渲染、`nft -c`、`xray run -test`），期间 `state.json` 仍是 `stopped`，
    页面点了「启用」「启动」看不到任何变化，重复点只会再排一次 check；daemon 随后又把同样的事做一遍。重载已在 2026-10-21 因同样理由去掉了这次 check。）
    **daemon 启动后第一件事**是写 `state.json`：`state: starting`、`since`、`node_id` 与 `mode` 取 UCI 原值（此时尚未校验），然后才读配置。
    同时写 `dns_tier`：UCI 原值 `dns.direct_dns_enabled` 为 `1` 时 `T2`，否则 `T1`（与随后的初始级别一致；2026-10-23 r14：原来这份早期状态没有 `dns_tier`，启动的十几秒里状态页的 DNS 级别是空的）。
    配置无效等失败照「启动」各步记事件（`CONFIG_INVALID` 等）、进入 `error` 并按退避重试——页面经 T10.11 的失败原因能看到为什么。
  - `service_stopped`：执行 `aether-proxy cleanup --wait 35`。这是**幂等**的清理（删表、删 rule/route、删 dnsmasq 片段、
    杀掉残留子进程），兜底 daemon 被 SIGKILL 时来不及清理的情况。
    procd 的停止是异步的：`service_stopped` 运行时 daemon 往往还在自己的有序退出中（最多 `term_timeout` 30 秒）并持有锁。`--wait <秒>` 让 cleanup 在锁被占用时每秒重试、最多等这么久，拿到锁再清理；等满仍拿不到才按原来的 `BUSY` 处理。
    （2026-10-22 定，r12 窗口：运行中用 opkg 重装时 cleanup 撞上 daemon 的锁，记了一条 `BUSY {holder: daemon}` warn，backlog B15 第 2 条。）
    拿锁失败不区分「被占用」与锁文件 I/O 错误，两者都按上面重试、等满记 `BUSY`（T9.25 复核定：`sys.lock` 只返回句柄或 null，没有更细的原因）。
    **还要等 daemon 进程退出**（2026-10-23 改，r13 窗口：daemon 在 monitor 阶段不持锁，`service_stopped` 的 cleanup 立刻拿到锁、先删了表，daemon 的有序退出再导出动态集合时表已不在，
    每次重启都记 `CMD_FAILED` 与 `START_FAILED {step: sets_export}`，动态集合也没能保留）：daemon 启动时写 `/var/run/aether-proxy/daemon.pid`；`--wait` 期间同时等「锁可拿到」与
    「该 pid 已不存在，或 `/proc/<pid>/cmdline` 不再是 `aether-proxy daemon`」，两者都满足才清理；等满仍不满足照原来的 `BUSY` 处理。daemon 正常退出时删除自己的 pid 文件；启动失败进入 `error` 退避重试时保留（进程还在）。pid 文件或 cmdline 读不了、内容损坏时一律当作 daemon 还在（宁可等满报 `BUSY`，也不在活着的 daemon 底下删表）；daemon 写不了 pid 文件就不启动（记 `FS_FAILED` 并退出，否则 cleanup 看不见它）。停止时 nft 的输出解析不了，只返回失败、不另记事件（执行失败已有 `CMD_FAILED`）。（T9.27 复核定）
- **配置变化的触发器在停止后也要保留**（2026-10-23 定，r14 窗口：「启用」关掉再打开并应用，服务没有启动）。procd 的 `stop` 会删除整个服务连同 `procd_add_reload_trigger` 登记的触发器，
  之后改配置不再触发 `reload_service`。开机时即使 `enabled=0` 也会登记一个不带实例的服务和触发器，所以只有「停过一次之后」才出问题。
  做法：停止完成后（`service_stopped` 的清理之后）重新向 procd 登记不带实例的服务与 `service_triggers`，与 `enabled=0` 开机时相同。
- **手动停止标记**（同日定，仓库所有者：手动点了「停止」，之后改配置不应把服务拉起来）：`/var/run/aether-proxy/stopped-by-user`（重启路由器自然清掉）。
  - init 的 `stop`（页面「停止」、命令行 `/etc/init.d/aether-proxy stop`）写这个标记；`start`、`restart` 清掉它（`restart` 是先 stop 后 start，结果是清掉）。
  - `reload_service`：`enabled=0` → 停止（若在运行）并**清掉标记**；`enabled=1` 且没在运行 → 有标记就什么都不做，没有才 `start`；在运行 → 照旧发 HUP。
  - 结果：开关关着时改配置不启动；开关开着但手动停止后改配置不启动；开关从关到开（中间经过 `enabled=0` 分支清标记）会启动。
  - 实现（T9.32 复核定）：标记写在 `stop_service` 钩子里（rc.common 的 procd 模式按 `stop_service` → 删除服务 → `service_stopped` 的顺序调用），不覆盖 `stop`；`enabled=0` 分支在自己的 stop 之后再清掉它。
    重新登记只需 `procd_open_service` + `procd_close_service`：后者自己会加 `service_triggers`，在两者之间再调一次会把触发器塞进 `instances` 对象（复核时修正，H28K 实测停止后触发器仍在、连续两次配置变化后仍在）。
  - `aether-proxy cleanup` 命令本身不写 `stopping`（它不依赖 daemon 存活，直接清理并写 `stopped`）。
- daemon 每次启动时执行一次 `cleanup`，清掉上一轮崩溃留下的残留。时机在第 5 步渲染校验通过之后、第 6 步之前：
  第 2–5 步失败时承诺「系统不改动」，残留也原样保留，交给 `service_stopped` 的 `cleanup` 处理。
- 收到停止信号时**不等锁**：monitor 阶段可能有一次性命令（如 `probe`）正持锁，停止流程照样按顺序清理。
  理由是停止的优先级高于任何一次性动作；被打断的命令看到的是表或子进程消失，按失败处理即可。
- 子进程的 pid 写入 `/var/run/aether-proxy/<name>.pid`，`cleanup` 依据它杀进程，**只杀命令行确实匹配的进程**
  （读取 `/proc/<pid>/cmdline` 核对），避免误杀复用了该 pid 的其他进程。

所以「启动」表里第 7、10 步的「启动」都由 daemon 派生子进程完成。表中的「回滚」等于执行 `cleanup`，
之后 daemon **不退出**：状态写为 `error`，在 daemon 内按退避重试（见「启动」，2026-10-17 改正此处的旧说法）。

## 重载（`aether-proxy reload`，UCI 变更触发）

init 脚本中注册 `procd_add_reload_trigger "aetherproxy"`。`reload_service` 先看两种状态切换：`enabled` 变为 0 时执行 `stop`；
服务没在运行（刚启用，或之前启动失败）时执行 `start`。其余情况直接向 daemon 发 `SIGHUP`，由 daemon 执行下面的流程。
（2026-10-21 改，backlog B14 第 3 条：原来发信号前先同步跑一次 `aether-proxy check`，H28K 上约 10 秒，而 daemon 收到信号后把同样的读取、渲染、校验又做一遍；
check 失败时只写一行 syslog、不记事件，概览页的「切换未生效」提示（10，T10.11）反而找不到原因。现在只由 daemon 做，失败照样不做任何改动，并按下面各步记事件。）

1. 重新读取配置与规则数据并校验（**整个重载只读一次**），失败则不做任何改动。
2. 把全部产物渲染到 staging，逐个与当前产物比对哈希。校验（前置检查、`nft -c`）每次都做；**`xray run -test` 只在 `xray.json` 与 `current/` 中的不同时做**
   （H28K 上约 6 秒；只改模式、名单时 Xray 配置不变，不必重测）。
3. 节点或节点地址变了：先对新节点做一次引导解析（[03](03-dns.md)），失败则不做任何改动；**解析放在第 2 步的渲染之前**，渲染直接用新 IP，只渲染一次
   （`node_ip4` 随之变化，nft 也要替换）。运行中的 DNS 级别沿用 monitor 当前的值。
   （2026-10-21 改，r9 窗口：H28K 上读配置与数据加整套渲染一次约 3.5 秒，切换节点原来要做三次——解析前、解析后、导出集合后——共约 13 秒，占重载的三分之二。）
   nft 要替换时先导出动态集合、带着它们重新渲染 nft（下表第一行）：**只重新渲染 nft 一个产物**，复用第 1 步读到的配置与数据；**这一轮只重写了 nft，只做 `nft -c`**，不重做前置检查与 `xray run -test`
   （2026-10-21 改，B14 第 3 条：原来整套校验再做一遍，切换节点时 Xray 配置被测了两次）。
4. 先把 staging 提交为 current（旧的保留为 `previous/`），再执行动作。这样子进程的命令行始终指向固定的 `current/` 路径；
   任一动作失败时恢复 `previous/`，并逆序撤销已完成的动作。比对的基准是 `current/` 里实际的文件，不是启动时记下的哈希，
   因为 monitor 切换 DNS 级别、刷新节点 IP 时也会重写其中的文件。
5. 只处理变化的部分：

| 变化的产物 | 动作 |
|---|---|
| `aether-proxy.nft` | 导出动态集合 → 整表原子替换（无流量中断） |
| `xray.json` | 重启 Xray |
| `chinadns.conf` | 重启 chinadns-ng，然后 SIGHUP dnsmasq |
| dnsmasq 片段 | 重启 dnsmasq |
| 启用状态变为关闭 | 等同 `stop` |

**比对的是输出而不是输入**：生成器自身升级后输出变了，也会被检测到（避免 ssr-plus U8 那类问题）。

**已应用上下文与冻结名单（2026-10-30，T9.43）**：启动或重载完整成功时，把 chinadns-ng / dnsmasq 会按路径打开的六份名单（gfwlist、chnlist、apple、proxy_domain、direct_domain、boot）复制到 `run_dir/applied/<generation>/`（0700）；本次渲染与之后 monitor 的恢复/重建都只用这些副本，不再读原始路径。代标识是「来源路径 + 内容哈希」manifest 的 SHA-256，来源与内容都没变时复用。失败的重载/校验/动作回滚删除候选代、不动当前代；成功后切换并清理旧代。CLI `check`/`render` 仍用原始路径，不做冻结。

**完成后记 `RELOAD_APPLIED`**（notice，2026-10-21 加，B14 第 3 条）：有动作执行成功时记一条，`from_node`、`to_node`（节点 ID；没换节点时两者相同）、`actions`（执行了的动作）、
`elapsed_ms`（从收到 SIGHUP 起）、`steps`（步骤名 → 毫秒，形同 `SERVICE_STARTED`）。没有任何变化的重载不记（规则数据更新、保存未改动的页面都会触发重载）。
原来重载成功不记任何事件，日志里看不出切换发生过、用了多久。
`steps` 的步骤名（T9.8）：`config_render`（读一次配置与数据、渲染一次全部产物并写 staging；T9.9 起不再有解析后的重新渲染）、`resolve_node`、`validate`（两轮校验之和）、`sets_export_render`（导出集合并重新渲染 nft）、`actions`（发布与执行动作）。
**细分**（2026-10-21 加，r10 窗口：重载约 11 秒中 `config_render` 4.6 秒、`validate` 1.9 秒、`actions` 1.8 秒，要先知道各自花在哪才能决定是否继续提速）：原有五个键保持不变（旧的读取方照常工作），另加 `detail` 对象：
`read`（读配置与规则数据）、`render`（渲染全部产物）、`stage`（写 staging 与算哈希）、`precheck`、`nft_check`（两轮之和）、`xray_test`、`sets_export`（导出集合）、`nft_render`（带集合重新渲染 nft）、
以及 `actions` 中每个动作各一个键（`nft_replace`、`restart_xray`、`restart_chinadns`……，键名即动作名）。没有发生的步骤不出现。单位毫秒，同其他步骤。
`elapsed_ms` 还包括等待 monitor 本轮结束等开销，不等于各步之和。nft 要替换时（含只改模式）`nft -c` 做两次：第一轮与导出集合之后各一次。

**规则数据缓存**（2026-10-22 定，r11/r12 实测 `read` ≈ 2.7 s、`render` ≈ 1.8 s、`nft_render` ≈ 1.75 s，占切换节点约 11 s 的六成）：规则数据一天最多变一次，每次重载却都从头解析 `chnroute4`（约 8000 个网段）并在两次 nft 渲染中各排序一次。
- `data.load` 在**模块内**缓存每个文件的解析结果，键为路径，同时记下文件的 `size`、`mtime`、`inode`；下次读取时先 `stat`，三者都相同就直接复用，任一不同（或文件不见了）就重新读取解析。只有常驻的 daemon 进程会用到缓存，一次性的命令行进程照常每次读。
- nft 渲染里对同一份数据的排序结果同样缓存（键为数据数组本身；数组来自上面的缓存，未变时是同一个对象）。每个集合只保留最近一份，不累积历次更新（T9.24 复核定）。
- 输出与不缓存时**逐字节相同**；缓存只影响耗时。缓存不跨进程、不落盘。宿主机先测出热点：大头若不在这两处，先停下来改设计。

`chinadns.conf` 按路径引用域名名单（`gfwlist-file`、`chnlist-file`、`group-dnl`），名单内容变了配置文本却不变。所以它的哈希是「配置文件哈希 + 每个被引用文件的哈希」拼成的串；
比对时配置文件部分用 `current/` 中现在的文件（monitor 切 DNS 级别会重写它），名单部分用上次生效时（启动或上一次 reload）记在 `render_hash` 里的值——名单不在 `current/` 里，现读只会读到已经改过的内容。
（真机验收时发现：只改自定义名单，reload 判定无变化，chinadns-ng 没有重启。规则数据更新同样依赖这一点。）

## 等待网络（仅 `--boot`）

用于 PPPoE、静态地址场景下，WAN 还没真正可用、代理进程却已经先启动的问题。

- 判定「网络可用」：存在 IPv4 默认路由，**并且**对 `boot_check_targets`（默认 `223.5.5.5:53`、`114.114.114.114:53`）
  中任一目标的 TCP 连接在 3 秒内成功。不用 ICMP，有的网络会屏蔽 ICMP。
- 每 5 秒重试一次，总时长 `boot_wait_timeout`（默认 120 秒）。
- 超时：记 WARN `NET_WAIT_TIMEOUT`，**继续启动**。DNS 会停留在 T2，monitor 会持续重试。
- 手动 start/restart（LuCI、命令行）不等待，避免 LuCI 操作被阻塞。
- 等待期间 `state=starting`，`state.json` 中带 `waiting_network=true`，LuCI 状态页显示「等待网络」。

## 热插拔

`/etc/hotplug.d/iface/90-aether-proxy`：`ACTION=ifup` 且接口不在 `lan_ifaces` 中时，如果 aether-proxy 正在运行，向 daemon
发 `SIGUSR1`，触发**立即执行一轮检测**。**不重启任何东西。** PPPoE 重拨不影响 TPROXY，节点 IP 的变化由检测发现。

## 信号一览

| 信号 | 作用 |
|---|---|
| SIGTERM / SIGINT | 按「停止」清理后退出 |
| SIGHUP | 增量重载（「重载」）；启动失败的退避期间则立即重试 |
| SIGUSR1 | 立即执行一轮 monitor 检测，不重启任何东西（热插拔、首页「测延迟」用） |
| SIGUSR2 | **只重启 Xray 子进程**（停止 → 按当前 `xray.json` 再拉起，退避计数归零），随后立即执行一轮检测。`xray-core` 软件包更新后用（[08](08-updates.md)「软件包安装」）：换了二进制而配置没变，SIGHUP 不会重启它，完整重启服务又要重启 dnsmasq（2026-10-16 定） |

## monitor 循环

在 daemon 内运行，正常每 30 秒一轮，非 `running` 状态下每 10 秒一轮；收到 SIGUSR1 立即执行一轮。
另有两处立即执行一轮（2026-10-19，[03](03-dns.md)「DNS 级别」）：启动流程完成后（不等第一个周期），以及任何原因切到 DNS T2 之后。
启动以来从未健康过时，一次代理健康检测通过即进入 `running` 与 T1。
每轮按顺序执行：

1. **规则表自检**：`inet aetherproxy` **连续 2 轮**不存在（被 `fw4 flush` 或第三方工具删除）且当前不是 `failsafe` → 重新加载，记 WARN `NFT_TABLE_RESTORED`。
   只看一轮不够：真机上 WAN 重拨触发的 `fw4 reload` 期间，`nft list` 会短暂报「No such file or directory」，而表其实还在；
   此时重建会用空集合替换一张仍有内容的表。重新加载时表已不存在，集合从 `sets.save` 恢复（没有就为空），不再要求导出成功。
2. **Xray 进程**：TPROXY 端口没有监听，持续 2 轮 →
   - `fail_open=1`（默认）：进入 `failsafe`。摘除拦截的方法是 `nft flush chain inet aetherproxy prerouting`
     （集合保留），然后切到 DNS T2。记 ERR `XRAY_DOWN_FAILOPEN`。
   - `fail_open=0`：保持规则（代理流量会失败），记 ERR `XRAY_DOWN`。
   - 端口恢复监听 → 重新加载整表，回到 `degraded`，等健康检测通过后升为 `running`。
3. **chinadns-ng 进程**：`CHINADNS_PORT` 没有监听，持续 2 轮 → 删除 dnsmasq 片段、重启 dnsmasq，
   置 `dns_failsafe=true`，记 ERR `DNS_DOWN_FAILSAFE`。端口恢复后重新写入片段，清除标志。
4. **代理健康检测**（[07](07-probe.md)）：根据连续成功/失败的次数在 `running` ↔ `degraded` 之间切换，并驱动 DNS 级别（[03](03-dns.md)）与分流降级（[02](02-dataplane.md)「节点不健康时的分流降级」：判为不健康且 `degrade_gfw=1` → 临时按仅被墙分流；恢复健康 → 还原）。
5. **DNS 级别探测**：仅在 T2/T3 下执行（[03](03-dns.md)）。
6. **节点 IP 刷新**：距上次超过 10 分钟就重新解析（[03](03-dns.md)）。

daemon 中的外部命令经 `sys.run` 阻塞执行，每次必须带不超过 10 秒的超时；一轮检测累计超过 30 秒时跳过下一轮。信号只在回到事件循环时处理，所以 SIGTERM 要等当前一轮检测的同步部分做完，最坏约 20 秒（curl 加两次 resolveip）；procd 的 `term_timeout` 因此设为 30 秒，仍超时则由 `cleanup` 兜底。

monitor 自己的动作（重启 chinadns-ng、重新加载 nft 表等）也要拿全局锁。拿不到锁就跳过本轮（说明用户正在操作），
不要阻塞等待。

## 动态集合的导出与恢复

- 导出：`nft -j list set inet aetherproxy <set>`，把元素写入 `/var/run/aether-proxy/sets.save`（tmpfs，整机重启会丢失）。
  文件格式：`{ "gfw4": ["1.2.3.4", …], "udirect4": […], "uproxy4": […] }`，元素为裸 IPv4 字符串（不带超时等属性），即渲染上下文 `ctx.runtime.restored` 的格式。
- `nft -j` 的元素格式：普通元素是裸值（`"1.2.3.4"`、`{"prefix":…}`、`{"range":[…]}`），只有带超时、计数器、注释的元素才包成 `{"elem":{"val":…}}`。两种都要解析（真机验收时发现只认包装格式导致导出全部失败）。
- 恢复：渲染 nft 文件时如果存在 `sets.save`，把元素作为集合初值写进去。**`nft -f` 加载成功之后才删除 `sets.save`**（2026-10-17 改，backlog B9）：之前解析成功即删除，加载失败后的退避重试只能用空集合重建，导出的动态集合全部丢失。启动与 monitor 的「表丢失后重建」两处都按此顺序。
  **`sets.save` 损坏或不认识**（不是 JSON、结构不对、元素不合法；2026-10-27 定，复核 Q1）：把它改名为 `sets.save.bad`（只留一份，覆盖旧的），记 WARN `SETS_RESTORE_FAILED {detail}`，用空集合继续启动——可用性优先，坏文件留作排查。文件不存在照旧按空集合，不记事件。
- 会导出的地方：stop、`cleanup`（表还在时，兜底 daemon 被 SIGKILL 的情况；导出失败只记日志，不阻断清理）、reload（整表替换）、failsafe 恢复。
  **停止时表已不存在**（被 cleanup、`fw4 flush` 或他人删掉）= 没有集合可导出：跳过导出，不记 `CMD_FAILED`。停止过程中的其他失败照记 `CMD_FAILED`，**不记 `START_FAILED`**（那是启动失败的事件码；2026-10-23，r13 窗口）。

## 故障语义汇总

| 故障 | 用户可见的结果 |
|---|---|
| 节点不通（Xray 存活） | 绕过大陆且 `degrade_gfw=1`（默认）：临时按仅被墙分流——被墙站点打不开，其余境外与国内正常；全局、仅被墙或 `degrade_gfw=0`：代理目标访问失败。DNS 降到 T2/T3 |
| Xray 崩溃且 procd 无法拉起 | `fail_open=1`：全部直连（被墙站点打不开，其余正常）；`fail_open=0`：代理目标访问失败 |
| chinadns-ng 崩溃 | DNS 回到用户原配置（ISP DNS），分流精度下降，网络可用 |
| dnsmasq 被用户重启 | conf-dir 片段仍在，自动恢复对接 |
| 整机断电 | tmpfs 清空；aether-proxy 开机重新完整启动；未启用时不留任何痕迹 |
| `fw4 flush` | 下一次至两次采样确认后重建；`running` 下通常约 30–60 秒（另加检测/动作耗时），非 `running` 按 10 秒周期通常约 10–20 秒；锁冲突或单轮过长会继续顺延，不设无条件硬上限 |
| monitor 查询规则表本身出错（`nft list` 失败） | 本轮按「表存在」处理，不重建，记 ERR；下一轮再查。理由：查询失败多半是 nft 暂时不可用，此时重建同样会失败，还可能把集合导出成空的 |

## 真机验证（M2 验收，2026-10-15）

在一台 lede 固件（fw4、busybox、aarch64）的测试路由器上，用 init 脚本走完整流程，以下各项通过：
启动到 `running`（约 65 秒，含 init 的 `check`）；QUIC 拒绝（YouTube 播放时计数器有命中）；`kill -9` Xray / chinadns-ng 后约 5–7 秒被拉起；
reload 改模式只替换 nft、Xray 不重启、动态集合保留；配置不变的 reload 不做任何动作；`ifup wan` 触发 USR1，2 秒内多出一轮检测，
且 `fw4 reload` 后表与 ip rule 仍在；阻断节点 90 秒降到 T2 / `degraded`，恢复后 34 秒回到 T1 / `running`；
stop 清理干净并保存集合，boot 后集合恢复；`kill -9` daemon 后 procd 拉起、孤儿子进程被清理；`kill -9` 后立即 stop 由 `cleanup` 兜底并保存集合。

补测（2026-10-15 晚，第二次窗口）也全部通过：三种主机策略与 `unlisted_policy=direct`、DNS 劫持（`direct` 主机不劫持）、自定义名单（只重启 chinadns-ng）、
`fw4 flush` 后第二轮重建、Xray 无法重启 → `failsafe`（摘除拦截后境外直连，恢复约 19 秒）、chinadns-ng 无法重启 → DNS 回落（仍可解析，恢复约 19 秒）、
daemon 启动失败 → 留在 `error` 并按 30 秒重试成功；真实订阅导入 7 个节点、第二次更新文件不变、`xray run -test` 通过。

测试方法上的教训（以后的验收照此做）：
- 改策略后要用**新连接**验证（`curl`），不要刷新浏览器页面：已被 TPROXY 接管的连接由 `socket transparent` 规则继续交给 Xray，开启流量卸载时已建立的转发连接绕过 prerouting，二者都沿用旧路径。这是预期行为——策略与模式变化只影响新连接。
- 改域名名单后先清客户端 DNS 缓存（Windows `ipconfig /flushdns`）：名单靠 DNS 应答填集合，客户端用缓存时查询到不了路由器。
- `fw4 flush` 之后 `fw4 reload` 会拒绝执行（fw4 表已不存在），要用 `/etc/init.d/firewall restart` 重建。

验收中发现、已修正的实现问题（宿主机测试都没能暴露，记在这里供以后参考）：

- Go（Xray）把 `0.0.0.0` 监听开成一个 IPv6 双栈 socket，只出现在 `/proc/net/tcp6`；端口检查必须同时读 `tcp` 和 `tcp6`。
- uloop 的 SIGCHLD 处理没有 `SA_RESTART`，子进程退出会打断 `popen()` 的读取（EINTR），命令结果丢失；`sys.run` 改为 `system()` 加结果文件。
- 持锁期间拉起的子进程会继承锁的 fd，daemon 被 SIGKILL 后孤儿一直占着锁；锁文件以 `O_CLOEXEC` 打开。
- dnsmasq init 被打断时会留下 `dnsmasq.conf.<section>.<pid>` 临时文件；conf-dir 发现要忽略它，并按目录而不是文件计数。
- busybox 可能没有 `od`；uci-defaults 改用 ucode 读 `/dev/urandom`。
- pid 文件指向的进程已不存在或被复用时，`cleanup` 只删 pid 文件，不算失败。
- `chinadns.conf` 按路径引用名单，只改名单时渲染文本不变，reload 判定无变化；哈希改为覆盖被引用的名单（见「重载」）。
- 路由表 233 已空或从未建立时，按表操作会失败：`ip route flush table 233` 报 ESRCH「No such process」或「Flush terminated」，Linux 6.18 + iproute2 6.18（H28K，2026-10-19）上连 `ip -4 route show table 233` 也报「Dump terminated」。所以**一律用 `ip -4 route show table all` 查 233 表的路由**（`apply.table_routes`）：没有路由就不 flush；flush 失败后再查一次，没有剩余就按成功处理。不匹配错误文字。
