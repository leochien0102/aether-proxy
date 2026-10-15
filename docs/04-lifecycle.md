# 04 生命周期

## 状态

`/var/run/aether-proxy/state.json` 记录当前状态，LuCI 和 `aether-proxy status` 都从这里读取。

| 状态 | 含义 | 拦截规则 | DNS 接管 |
|---|---|---|---|
| `stopped` | 未运行 | 无 | 无 |
| `starting` | 启动流程进行中 | 无 → 末段加载 | 末段接管 |
| `running` | Xray 存活且代理健康 | 有 | T1 |
| `degraded` | Xray 存活但代理不健康，或节点解析失败 | 有（`fail_open=1` 且节点解析失败时除外） | T2/T3 |
| `failsafe` | Xray 进程不可用 | **已摘除**（故障放行） | T2/T3 |
| `dns_failsafe` | chinadns-ng 不可用（可与以上状态叠加，作为标志位） | 不变 | **已撤回**，dnsmasq 回到原配置 |
| `error` | 启动失败，已回滚 | 无 | 无 |

`state.json` 字段：`state`、`dns_tier`、`dns_failsafe`、`node_id`、`node_ip`、`since`（进入当前状态的时间戳）、
`last_probe`（`ok`、`latency_ms`、`at`）、`last_error`（事件码）、`components`（各组件的版本与路径）、`render_hash`（各产物的哈希）。

## 启动（`aether-proxy daemon [--boot]` 的前半段）

**每一步失败都按相反顺序回滚已完成的步骤**，最终状态为 `error`，事件里带上失败的步骤名。

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
| 9 | 引导解析节点 IP（[03](03-dns.md)），用结果补全 Xray 配置并再次 `-test` | 解析失败 → 继续，状态记为 `degraded`，不启动 Xray，跳到第 12 步 |
| 10 | 启动 Xray，在 5 秒内等待 `TPROXY_PORT` 进入监听（读取 `/proc/net/tcp`） | 回滚 |
| 11 | 加载 nft 表（含恢复动态集合）、添加 ip rule / route | 回滚 |
| 12 | 进入 monitor 循环，由它判定为 `running` / `degraded` | — |

代理是否真正可用由 monitor 异步判定，LuCI 能看到状态变化。

第 1 步的锁：daemon 在启动流程（第 2–11 步）期间持锁，进入 monitor 循环后释放，之后每次动作临时取锁。

## 停止（daemon 收到 SIGTERM；`cleanup` 是同样的步骤，只是不依赖 daemon 存活）

顺序与启动相反，**每一步都要执行，前一步失败也不能跳过后续步骤**（失败记 ERR）：

1. 退出 monitor 循环
2. 导出动态集合（`gfw4`、`udirect4`、`uproxy4`）到 `/var/run/aether-proxy/sets.save`
3. `nft delete table inet aetherproxy`；删除 ip rule / route
4. 删除 dnsmasq 片段并重启 dnsmasq
5. 停止 chinadns-ng、Xray
6. 状态写为 `stopped`

### 进程模型（已定）

启动顺序有硬依赖：chinadns-ng → dnsmasq → 解析节点 → Xray 监听 → 加载 nft。procd 的多个实例是在
`start_service` 返回后才统一拉起的，表达不了这种顺序。所以：

- procd **只托管一个实例**：`aether-proxy daemon`（respawn `3600 5 5`，`term_timeout 15`：有序停止要导出集合、删表、重启 dnsmasq，procd 默认等 5 秒就 SIGKILL，在慢的路由器上不够）。
- `aether-proxy daemon` 是监督进程：执行上面的启动步骤，以**子进程**方式拉起并重启 Xray、chinadns-ng
  （退避 5s → 10s → 30s → 60s 封顶），然后进入 monitor 循环。
  子进程用 `uloop.process` 拉起，继承 daemon 的 stdout/stderr（日志由 procd 收集，见 [09](09-logging.md)「子进程日志」）；退出由回调通知，不轮询。daemon 记录每个子进程是否处于「主动停止」中，不是主动停止的退出一律视为崩溃。连续稳定运行 5 分钟后退避计数归零。
- 收到 SIGTERM：按「停止」的顺序清理，然后退出。
- `/etc/init.d/aether-proxy`：
  - `start_service`：先同步执行 `aether-proxy check`（第 1–3 步加第 5 步，只校验不改动；失败就不注册实例，
    LuCI 能立即看到错误），然后注册 `aether-proxy daemon` 实例（开机时 `boot()` 带 `--boot`）。
  - `service_stopped`：执行 `aether-proxy cleanup`。这是**幂等**的清理（删表、删 rule/route、删 dnsmasq 片段、
    杀掉残留子进程），兜底 daemon 被 SIGKILL 时来不及清理的情况。
- daemon 每次启动时执行一次 `cleanup`，清掉上一轮崩溃留下的残留。时机在第 5 步渲染校验通过之后、第 6 步之前：
  第 2–5 步失败时承诺「系统不改动」，残留也原样保留，交给 `service_stopped` 的 `cleanup` 处理。
- 收到停止信号时**不等锁**：monitor 阶段可能有一次性命令（如 `probe`）正持锁，停止流程照样按顺序清理。
  理由是停止的优先级高于任何一次性动作；被打断的命令看到的是表或子进程消失，按失败处理即可。
- 子进程的 pid 写入 `/var/run/aether-proxy/<name>.pid`，`cleanup` 依据它杀进程，**只杀命令行确实匹配的进程**
  （读取 `/proc/<pid>/cmdline` 核对），避免误杀复用了该 pid 的其他进程。

所以「启动」表里第 7、10 步的「启动」都由 daemon 派生子进程完成。表中的「回滚」等于执行 `cleanup`，
然后 daemon 以非零码退出，交给 procd 的 respawn 策略处理。

## 重载（`aether-proxy reload`，UCI 变更触发）

init 脚本中注册 `procd_add_reload_trigger "aetherproxy"`。`reload_service` 先看两种状态切换：`enabled` 变为 0 时执行 `stop`；
服务没在运行（刚启用，或之前启动失败）时执行 `start`。其余情况先执行 `aether-proxy check`，
失败就不做任何改动（错误留在事件里）；通过则向 daemon 发 `SIGHUP`，由 daemon 执行下面的流程：

1. 重新读取配置并校验，失败则不做任何改动。
2. 把全部产物渲染到 staging，逐个与当前产物比对哈希。
3. 节点或节点地址变了：先对新节点做一次引导解析（[03](03-dns.md)），失败则不做任何改动；成功后以新 IP 重新渲染
   （`node_ip4` 随之变化，nft 也要替换）。运行中的 DNS 级别沿用 monitor 当前的值。
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

## monitor 循环

在 daemon 内运行，正常每 30 秒一轮，非 `running` 状态下每 10 秒一轮；收到 SIGUSR1 立即执行一轮。
每轮按顺序执行：

1. **规则表自检**：`inet aetherproxy` 不存在（被 `fw4 flush` 或第三方工具删除）且当前不是 `failsafe` → 重新加载，记 WARN `NFT_TABLE_RESTORED`。
2. **Xray 进程**：TPROXY 端口没有监听，持续 2 轮 →
   - `fail_open=1`（默认）：进入 `failsafe`。摘除拦截的方法是 `nft flush chain inet aetherproxy prerouting`
     （集合保留），然后切到 DNS T2。记 ERR `XRAY_DOWN_FAILOPEN`。
   - `fail_open=0`：保持规则（代理流量会失败），记 ERR `XRAY_DOWN`。
   - 端口恢复监听 → 重新加载整表，回到 `degraded`，等健康检测通过后升为 `running`。
3. **chinadns-ng 进程**：`CHINADNS_PORT` 没有监听，持续 2 轮 → 删除 dnsmasq 片段、重启 dnsmasq，
   置 `dns_failsafe=true`，记 ERR `DNS_DOWN_FAILSAFE`。端口恢复后重新写入片段，清除标志。
4. **代理健康检测**（[07](07-probe.md)）：根据连续成功/失败的次数在 `running` ↔ `degraded` 之间切换，并驱动 DNS 级别（[03](03-dns.md)）。
5. **DNS 级别探测**：仅在 T2/T3 下执行（[03](03-dns.md)）。
6. **节点 IP 刷新**：距上次超过 10 分钟就重新解析（[03](03-dns.md)）。

daemon 中的外部命令经 `sys.run` 阻塞执行，每次必须带不超过 10 秒的超时；一轮检测累计超过 30 秒时跳过下一轮。因此 SIGTERM 最多延迟一个命令的超时时间。

monitor 自己的动作（重启 chinadns-ng、重新加载 nft 表等）也要拿全局锁。拿不到锁就跳过本轮（说明用户正在操作），
不要阻塞等待。

## 动态集合的导出与恢复

- 导出：`nft -j list set inet aetherproxy <set>`，把元素写入 `/var/run/aether-proxy/sets.save`（tmpfs，整机重启会丢失）。
  文件格式：`{ "gfw4": ["1.2.3.4", …], "udirect4": […], "uproxy4": […] }`，元素为裸 IPv4 字符串（不带超时等属性），即渲染上下文 `ctx.runtime.restored` 的格式。
- 恢复：渲染 nft 文件时如果存在 `sets.save`，把元素作为集合初值写进去；加载完成后删除该文件。
- 只有 stop、reload（整表替换）、failsafe 恢复这三处会导出。

## 故障语义汇总

| 故障 | 用户可见的结果 |
|---|---|
| 节点不通（Xray 存活） | 代理目标访问失败；国内站点正常；DNS 降到 T2/T3 |
| Xray 崩溃且 procd 无法拉起 | `fail_open=1`：全部直连（被墙站点打不开，其余正常）；`fail_open=0`：代理目标访问失败 |
| chinadns-ng 崩溃 | DNS 回到用户原配置（ISP DNS），分流精度下降，网络可用 |
| dnsmasq 被用户重启 | conf-dir 片段仍在，自动恢复对接 |
| 整机断电 | tmpfs 清空；aether-proxy 开机重新完整启动；未启用时不留任何痕迹 |
| `fw4 flush` | 下一轮 monitor 重建规则表（最长约 30 秒的直连窗口） |
| monitor 查询规则表本身出错（`nft list` 失败） | 本轮按「表存在」处理，不重建，记 ERR；下一轮再查。理由：查询失败多半是 nft 暂时不可用，此时重建同样会失败，还可能把集合导出成空的 |
