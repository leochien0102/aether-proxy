# r6→T15.7 交叉审查回执（2026-11-08）

> 审查对象：[r6 到 T15.7 交叉审查底稿](r6-to-t15.7-cross-review-20261108.md)（提交`48f9251`，源码截止`356e6f2`）。
> 审查方式：只读Git/源码/任务卡/已有证据；本地重跑部分套件；H28K只读核对。**未重启设备、未断网、未改配置、未安装/回退、未重启服务、未派实现子智能体。**
> 本文是复审回执，不是新任务卡，也不改变底稿的授权边界。

## 0. 结论

**底稿可以作为 r6→T15.7 的交叉审查依据接受：未发现事实性错误、数字夸大或把未完成项写成已完成。** 我独立复算的diff规模、提交范围、设备包/文件/内核状态全部与底稿一致；重点套件（unit 1257、passive 101、B3入口）重跑无失败；旧schedule入口的35/5也原样复现，失败原因与L1描述一致。

需要作者补的是**边界表述**，不是结论：

1. §8.2 的“不受保护窗口”清单漏了 **daemon 崩溃后 procd respawn** 这一条（与 opkg stop→start 同性质，代码路径可证，未做设备实验）。
2. §4/§9 对 stop/restart 失败传播的描述略强于实际（rc.common 的 procd `stop()` 不采用 `stop_service` 返回值）。
3. TPROXY 就绪门按卡片只覆盖 TCP；live 产物声明 `tcp,udp` 且确有 UDP 31080 监听，建议在文字上避免被读成“TPROXY 全部协议已证明”。

其余为文字/说明级建议，见§3。

## 1. 我独立复核了什么

### 1.1 Git 与规模（全部一致）

```text
v0.6.3-r6^{commit} = 435540b535197e79a330ff038fa716d7f3d0e40f   （轻量/注解标签均指向该提交）
356e6f2 = 2026-11-08 18:00:28 +0800  docs(t15.6): narrow UDP finding...
48f9251 = 2026-11-08 18:12:10 +0800  docs(review): inventory...（仅新增底稿，406行）
git diff --stat 435540b 356e6f2 = 143 files, 18391 insertions(+), 118 deletions(-)
生产 aether-proxy/ = 13 files, 1834/62；docs 10/1200/16；spikes 41/4374/0；tests 79/10983/40
```

- 7 个合并提交（T15.1/S15.2/S15.3/T15.4/T15.5/T15.6/T15.7）与 §0.2、§2 完全对应；§10 列出的补修提交（`7cfb361`…`f086adc`）全部存在且主题相符。
- `git diff 435540b 356e6f2 -- Makefile files/aether-proxy.config src/lib/config.uc luci-app-aether-proxy tests/fixtures` **为空**；`tests/schedule` 只有底稿自述的那 1 行 ELF fixture 准备。
- `git diff --quiet 5aafe95 356e6f2 -- aether-proxy` 为空（截止点相对 T15.7 合并无生产改动）。
- §1.2 的跨仓库纠正成立：`cb28b84` 只存在于 aether-dns（`docs(m4): freeze M4-01 cache refresh card`），`8264c51`/`b4909f0` 不是 aether-dns main 祖先、在 aether-proxy 对象库不存在。
- `reports/T15.*.md` 确认不在 main（`git show 356e6f2:reports/T15.7.md` 失败），与 §6.4 一致；main 仍保留到 `T14.3` 的旧报告。

### 1.2 本地重跑（未改工作树）

| 入口 | 我的结果 | 底稿/报告声称 |
|---|---|---|
| `tests/host/ucode tests/run.uc` | **1257 passed, 0 failed, 0 skipped** | 1257/0 |
| `bash tests/xray-ready/passive.sh` | **101 passed, 0 failed** | passive 101/0 |
| `bash tests/bootstrap-startup/run.sh` | **退出0**，末行 `xray-ready minimal modules and ELF: 52 passed, 0 failed` | B3 92/0、最小模块52/0 |
| `bash tests/schedule/run.sh` | **35 passed, 5 failed**，失败名与L1完全相同 | 35/5 |

关于 L1：失败stderr直接显示旧stub把 `-C` 的**配置文件路径**当成目录写 `calls.log`/`chinadns.pid`（`.../bootstrap/<id>/bootstrap.conf/calls.log: Directory nonexistent`）。这印证底稿“旧夹具目录定位失败、不是生产scheduler坏了”的判断；修复方向应是夹具识别新 `-C <file>` 形态，业务oracle不动。

B3我只确认了“全入口退出0、最小模块52/0”，没有重新数核心的92条（输出被尾部截断），不影响“0失败”结论。

### 1.3 H28K 只读核对（18:27–18:38，未重启、未断网）

- 包：`aether-proxy 0.6.3-r6.t157`、`aether-dns 2026.11.04-1`、`aether-xray 26.10.31-1`；`state.json` = running/T1/bypass_cn；无 `restart-intent`；`host_udp4`、`host_udp_mac` 为空；两个 host 段均无 `udp=1`（游戏模式未启用）。
- boot ID `97edbacd-fd63-4a21-beb7-0cc59ac22b93`，uptime 2天8小时（与“各验收前后未重启”一致）。
- 文件核对：清单10个文件（init + 9个模块）中9个与仓库 **逐字节相同**；仅 `const.uc` 差 `RAW_VERSION` 占位符 → `0.6.3-r6.t157`，与“10文件核对、仅版本占位符替换”一致。
- 运行态：Xray PID 14707；`/proc/net/tcp6` 有本 inode `1762890` 的 `::`:**7968(31080)** LISTEN；`127.0.0.1:31082/31083` TCP LISTEN（inode 1762892/1762884），`127.0.0.1:31053` UDP state 07；`/proc/14707/fd` 确含这些inode。
- 日志：`loopback connection detected` 共 **4 条**，最后一条为 11:38（早于17:45升级），与“历史4条、升级及50次检查无新增”一致；`START_FAILED/CHILD_CRASHED` 仅 1 条 11-06 10:14 的历史记录。
- 包哈希：构建树 `aether-proxy_0.6.3-r6.t157_all.ipk` = `893c2650…d5522`，回退包 `rollback-r6.t156.ipk` = `dac244e9…71f7`，均与 §6.3 一致；`build-manifest.json` 的 source 为 `5aafe95`、10文件哈希与设备一致。
- **T15.7核心机制的独立确认**：用 `ucode -` 从stdin执行只读脚本（不落盘、不连接），对 inode 1762890 调用已安装 `socket_diag.query`，得到 `{ok:true, fallback:false, dual_stack:true}`；执行后 loopback 仍为4条、服务仍 running/T1。即“被动证据可用、未走兼容握手”在当前设备上成立。
- 事件时间线（`events.jsonl`）：17:45:38 `SERVICE_STOPPED` → 17:45:49 `SERVICE_STARTED`（本次opkg升级，间隔11秒）；10:42:32→10:42:43（B3受控restart，同样11秒，但有intent保护）。

### 1.4 我没有复核的

T15.1/T15.5/T15.6 的历史真机窗口、B2十二项变异、passive 10对预算控制、daemon/reload/monitor/procd 套件、`tests/review.sh` 本体、T15.1的11.9秒intent清除样本，以及 §6.1 的“宿主ucode源码固定到3f64c808”。这些只按报告/记录引用，未重跑。

## 2. 底稿中已被独立证实的点

- §0/§1/§2 的版本、提交、7任务、diff规模、数字口径：**全部一致**；`0.6.3-r6.t157` 不是新release，Makefile 仍 `PKG_VERSION=0.6.3 / PKG_RELEASE=6`。
- §3.2 启动顺序与 `daemon.uc#L473` 起的代码逐段对应：解析→停child→Xray `-test`/启动→B2门→nft/route→正式DNS门→dnsmasq_install→清intent→状态。
- §3.3 的“仅startup切B1”：`bootstrap.resolve` 只在 `daemon.uc:693` 调用；reload/monitor 仍走 `apply.resolve_node`。
- §3.4 的6条资源契约与 `bootstrap.uc` 实现一致：无respawn、5秒停止判定、未确认即保留并阻断、历史PID零信号、fork→PID发布窗口只保留记录。
- §4 的13个生产文件与“顺带修复”`retire_interval` 存在且语义相符；`socket_diag` 225行、`xray_ready` 329行新增数与统计一致。
- §5 的补修提交与内容相符（`b1ae912` 禁用残留分支、`c556599` ELF字节序、`f031104` connected UDP、`e7eb0a0` interval保活、`5e6b5b5` ENOENT限定、`f086adc` 测试确定性）。
- §6.2 三组设备数字与各自验收文档一致（11.9秒intent、650样本/92.93秒/8.09秒、392 NXDOMAIN/52 timeout/6 errno111、50/50与FD14→14）。
- §6.3 的构建隔离、包哈希、备份目录、postinst/postrm 的 `fw4 reload`（[Makefile#L73-L85](../../aether-proxy/Makefile#L73-L85)）均属实；底稿没有把“没碰防火墙”写成事实。
- §7 的 L1/L2/L3 定位准确：L2 的 Authority 确实是 UDP `bind(0)` 后 TCP 绑同号端口（[run.py#L46-L51](../../tests/bootstrap-startup/run.py#L46-L51)）；L3 的 270/270/270、1700/1691/9 与追查文档一致。
- §11 的 aether-dns 依赖提交 `b2acecf`(M4-07)、`325b614`(M4-01) 存在；本地忽略区证据目录确实存在。

## 3. 发现的问题与建议

### F1（中）§8.2 的窗口清单少了 procd respawn

底稿把“不受T15.1保护”的路径列为 opkg stop→start、首次start、人工stop。还有一条同性质的路径：**daemon 因崩溃/异常退出后由 procd respawn 直接重启命令**（`procd_set_param respawn 3600 5 5`），不会调用 init 的 `restart()`，因此没有 intent。新进程启动时 `start_sequence → apply_cleanup → dnsmasq_remove`（[daemon.uc#L650-L655](../../aether-proxy/src/lib/daemon.uc#L650-L655)、[#L961](../../aether-proxy/src/lib/daemon.uc#L961)）会在无intent时**移除handoff并重启dnsmasq**，直到启动末段 `dnsmasq_install` 才重新装上。按本机实测的启动耗时（config约3.4秒、dnsmasq_install约3.2秒、总计约9.3秒）估算，这段是**数秒级直连DNS窗口**，与升级窗口同性质。

- 未做设备实验（需要杀daemon，违反本次约束），是代码路径结论；r6起就存在，不是T15.7回归。
- 建议：§8.2 增加第三条窗口，并明确“init restart 是当前唯一受保护路径”；是否扩展保护另立卡（见§5）。

### F2（低）`stop_service` 的返回值在 procd 下不生效

设备 `/etc/rc.common` 的 procd `stop()` 是：

```sh
stop() { procd_lock; stop_service "$@"; procd_kill ...; if type service_stopped; then service_stopped; fi }
```

函数返回的是 `service_stopped` 的状态，**`stop_service` 的 `return 1` 不会阻止 kill，也不会进入 `restart()` 的 `stop_rc`**（`stop_rc` 实际只反映 `cleanup` 的rc）。因此 [init#L119-L127](../../aether-proxy/files/aether-proxy.init#L119-L127) 的“返回失败”只在日志上可见：

- intent 删除失败仍会继续 stop；因为删除发生在 `procd_kill` 之前，方向仍是 fail-closed（handoff保留、查询失败而不泄漏），不会误放行。
- 真正有后果的是 **stop-mark 写失败**：手动 stop 后没有 `stopped-by-user`，后续 UCI 变更的 `reload_service` 可能把服务重新拉起。概率极低（/var/run 不可写时其他步骤也会失败），但底稿§4“普通stop不能误保留”的表述应改为“靠顺序保证，不靠返回值”。

### F3（低）自定义 `restart()` 少了 `trap '' TERM`

rc.common 原 `restart()` 在 `stop` 前后有 `trap '' TERM`，自定义版本（[init#L45-L76](../../aether-proxy/files/aether-proxy.init#L45-L76)）没有。正常 procd 路径下不会向init脚本自身发TERM，风险低；但它确实偏离了原语义，建议在注释里说明“故意省略/已知差异”，或补回。

### F4（说明）TPROXY 门只覆盖 TCP，别被读成“TPROXY 全协议”

T15.5 卡片明确写“始终保留现有**TPROXY TCP**就绪要求”，实现也如此（[xray_ready.uc#L38-L41](../../aether-proxy/src/lib/xray_ready.uc#L38-L41)）。但 live 产物 `tproxy-in` 的 `network` 是 `"tcp,udp"`，设备上也确有 `::`:**31080** 的 UDP state 07 监听。也就是说：UDP TPROXY 监听失败不会被就绪门发现。这是卡片范围内的设计，不算缺陷，但§4/§9的“只等待真实配置引用的端口/协议”容易被读成已覆盖 TPROXY UDP，建议加一句限定。

顺带：`monitor.wait_xray_port` 在 reload 改接后被保留但已无调用者（卡片允许保留），底稿未提；如果保留是给兼容测试，建议在§4注明，避免后人误以为生产仍在用。

### F5（说明）diag 回退分类依赖 `strerror()` 文本

`socket_diag.compatible()` / `dump_handler_missing()` 用 `socket.strerror(errno)` 与英文串比较（[socket_diag.uc#L28-L43](../../aether-proxy/src/lib/socket_diag.uc#L28-L43)）。在 musl/英文环境可靠；换 libc 或加 locale 时分类可能变成“netlink error/ack”而**不走回退**（fail-closed，但要人工排查）。建议在§6.1/§8.1把“错误分类依赖C locale英文errno串”列为已接受前提。

### F6（文字）

- §0.6 的“受保护的init `restart`不等于任意opkg `stop → start`升级、首次start或人工stop均受同一隐私保证”一句语法易误读（“不等于……均受……”）。建议拆成两句：“只有init restart受保护；opkg升级、首次start、人工stop都不受同一保证。”
- §1.2 说“`8264c51`、`b4909f0`属于aether-dns早期撤回实现”，句首已给出仓库，但建议每个提交号都带仓库前缀，与§1.2自己的要求一致。
- §7 L1 的“旧stub目录定位失败”可以写得更可修：stub把 `-C` 的文件路径当目录用。

## 4. §9 清单逐项回答

| 清单项 | 结论 |
|---|---|
| r6基线/源码/本地包/发布状态区分 | 是。tag=435540b；截止356e6f2；设备t157；Makefile仍r6、未发版 |
| 7任务对应合并/报告/现存代码 | 是。7个合并、7份分支报告可读、代码位置可查 |
| T15.1 只对有intent的restart保留handoff；手动stop/禁用释放 | 是（代码顺序保证；返回值不生效见F2）。手动stop/禁用先删intent再kill |
| 是否接受§8.2边界 | 建议接受当前边界，但补上 respawn 窗口（F1）；扩展保护另立卡（§5） |
| B1 DNS优先/有界TC-CNAME/LKG保存失败/取消，仅startup | 是。`resolve_node_explicit` 先DNS后LKG；写LKG失败不冒充成功；cancelled直接返回；仅daemon启动调用 |
| B2 只等真实引用端口/协议，不能靠无关PID/connected UDP | 是（UDP要求校验 state07+远端全零；TPROXY按卡片只TCP，见F4） |
| B3 先确认child停止、失败不删证据/不继续fork、无LKG不永等Xray | 是。`resolve()` 失败即返回；`stop` 未确认即 `cleanup_failed` 阻断；degraded分支不启动Xray |
| collector延后、timer保活、rollback错误传播已审 | 是。`start_collector` 在cleanup/publish之间；`retired_intervals` 至uloop.done；rollback错误拼接返回 |
| T15.7 归属/字节序/取消/总预算；ENOENT仅在合法无证据DUMP回退 | 是。设备实测 `fallback=false`；ENOENT要求 `!seen` 且关联完整 |
| 探针/fixture/真实内核/真实引擎/H28K边界分开 | 是。§6.1分级清楚，未见外推 |
| 原失败/重跑/变异存活可追溯 | 是。schedule 5失败、B3 EADDRINUSE、passive变异均保留记录；我复现了35/5 |
| L1/L2归测试，L3未误归aether-dns/泛UDP | 是。L3限定“WSL→H28K IPv4 UDP/53 DNS测试请求” |
| 无新增依赖/未改UCI-LuCI-golden/未重启设备 | 是。diff为空；DEPENDS未变；boot ID/uptime连续 |

## 5. 对 §8.2 的决定建议

**建议：接受“只有 init restart 受保护”这一边界，本轮不扩卡。** 理由与代价：

1. 扩展保护的机制不便宜。opkg 的 prerm 走的是**普通 `stop`**，要区分“升级”与“人工卸载/停用”需要包脚本上下文（卸载时保留handoff是错的）；不同opkg/固件版本的钩子行为也要另行验证，不能靠猜环境变量。
2. 保留handoff的收益是隐私，代价是**升级窗口内DNS直接失败**（handoff指向已停止的31053）。如果升级失败需要回退，DNS会一直失败到人工处理；这比“短暂回落到WAN DNS”对家庭网络的可用性影响更大。
3. 实测窗口是**11秒/次**（17:45:38→17:45:49），升级频率以月/年计；风险量级与“首次start”“崩溃respawn”同类。

如果一定要做，建议单独立卡，最小目标写成：“在**受控升级**上下文中发布与init restart同语义的intent，并证明卸载/回退不会保留handoff”，验收必须包含：升级窗口的标记DNS计数、升级失败后的收口、以及卸载路径不残留。**不要**把普通stop改成永久保留。

## 6. 不可外推

- 我确认的是“本设备、本包、本窗口”的被动证据与运行态；不外推为所有内核/所有平台都无握手副作用（兼容回退仍在）。
- 就绪只证明owned socket/地址族，不证明上游健康或端到端代理可用；本回执不改变这一点。
- UDP/53 前置缺包（L3）仍未定位，本次没有新增证据，也不归责任何组件。
- F1 是代码路径分析，没有在H28K上制造daemon崩溃（会中断服务），不能当作“已实测窗口”。
