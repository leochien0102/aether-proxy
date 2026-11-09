# aether-proxy：r6 基线至 T15.7 的任务、交付与遗留交叉审查

> 编制日期：2026-11-08；所有时间按 UTC+08:00。本文是交叉审查底稿，不是新的实现卡或再次测试授权。
> **源码统计截止快照：`356e6f274b1ae23569e3baea3335ed1c7907e934`。** 不包含本文自己的新提交。
> 原底稿编制时只读取本地Git、源码、任务卡及已有记录；未重新操作H28K、未改生产代码、未追加测试。后续状态按各独立任务的记录更新，不计入下列固定源码统计。
> 后续审查收口：原底稿为`48f9251`；[独立回执](r6-to-t15.7-cross-review-verdict-20261108.md)已按所有者许可原样入库。本版补齐F1–F6的保证边界及后续状态，不改上面的源码统计截止点，也不把历史未复核项改写为已重新测试。

## 0. 审查摘要与阅读次序

1. 正式r6基线是标签 **`v0.6.3-r6` → `435540b535197e79a330ff038fa716d7f3d0e40f`**，提交时间2026-11-06 20:00:33。不要混用其他仓库的临时基线。
2. 此后aether-proxy主线接受 **7个任务**：T15.1、S15.2、S15.3、T15.4、T15.5、T15.6、T15.7。两个S卡仅提供探针证据；B1/B2/B3是T15.4/5/6的设计阶段名，不是另外三张任务。
3. 已交付：restart handoff连续性、隔离节点bootstrap、显式IPv4查询器、引用驱动的owned readiness、成功启动重排、被动双栈验证及兼容回退。
4. 最近实际设备验收：2026-11-08 17:53，H28K运行本地包 **`0.6.3-r6.t157`**、running/T1/bypass_cn；17:59只读确认游戏模式未启用、UDP代理选择集为空。不是本报告生成时又进行了一轮设备测试。
5. 后续状态（2026-11-09）：schedule旧夹具已由T15.8合并收口，原入口恢复47/0。当前仅冻结T15.9处理B3 Authority测试端口竞争，init低优先级候选后排；命名/独立semver/正式发布/中断体验优化分别决策。UDP按所有者决定归档，仅其他独立环境复现相同问题再评估，不扩查。
6. **保证范围**：T15.1保护由init `restart`预先建立的intent触发，并延续到其失败重试。普通opkg `stop → start`升级、首次接管、没有既存intent的daemon崩溃respawn不主动建立同等保护；人工stop/禁用则有意释放handoff。不能把标记UDP计数推广为所有协议不泄漏，也不能把就绪当作上游健康。

建议先读§1–3和§7–9，再按§4生产文件表下钻；提交与证据定位见§10–11。

---

## 1. 基线、范围与版本身份

### 1.1 权威基线

| 对象 | 明确身份 | 含义 |
|---|---|---|
| 正式r6标签 | `v0.6.3-r6` | 注解标签，指向下列提交 |
| r6提交 | `435540b535197e79a330ff038fa716d7f3d0e40f` | `release: 0.6.3-r6 toolbar hint alignment` |
| 本报告源码截止点 | `356e6f274b1ae23569e3baea3335ed1c7907e934` | 2026-11-08 18:00:28，UDP/53范围更正记录 |
| 最后生产代码合并 | `5aafe95` | T15.7合并；之后至截止点为文档/状态记录 |
| 当前本地验收包 | `0.6.3-r6.t157` | SDK隔离配方覆盖版本；不是新正式release/tag |

r6已经包含早先的T14.x成果（包括raw-log collector、uci.load retry、toolbar hint alignment）；它们不重复算作r6之后新增任务。

主线[包定义](../../aether-proxy/Makefile#L3-L5)仍为PKG_VERSION=0.6.3、PKG_RELEASE=6；相对r6无diff。没有在主线正式升版，也未发布/push新release。**正式发版前必须选新发布版本并验证更新通道，不能把新代码无说明地覆盖到原r6。**

### 1.2 跨仓库提交混淆的纠正

实际对象核对表明：

- `aether-dns@cb28b84b20175e8b139428343f3a71b5fe320df2`是M4-01缓存刷新卡的冻结提交；不是aether-proxy r6基线。
- 会话中曾出现的`aether-dns@8264c51`、`aether-dns@b4909f0`是该仓库早期撤回实现/合并对象；均不是aether-dns当前main祖先，也不在aether-proxy对象库中。
- 本文不把这些撤回对象算入已交付，不从它们补回代码。所有提交号必须连同仓库识别。

### 1.3 r6至截止点的实际diff规模

| 类别 | 文件数 | 新增行 | 删除行 | 审查解释 |
|---|---:|---:|---:|---|
| aether-proxy生产目录 | 13 | 1834 | 62 | §4列出全部文件 |
| docs | 10 | 1200 | 16 | 含任务、设计与设备摘要 |
| spikes | 41 | 4374 | 0 | 两个探针及其证据，不是运行时模块 |
| tests | 79 | 10983 | 40 | 含夹具、控制实验与大量证据记录 |
| **合计** | **143** | **18391** | **118** | 不含本文；不能将全部新增行当生产逻辑 |

已核对相对r6不变：LuCI目录、包Makefile/依赖表、默认UCI配置、config解析、probe节点解析、dns_test诊断实现、Xray renderer、正式tests/fixtures/golden。**并非所有测试文件不变**：例如schedule入口已增加一行ELF fixture准备，但其后续B3兼容缺陷仍存在。

---

## 2. 七个任务总账

任务范围与原验收标准以[M15任务卡](../tasks/m15.md)为入口。下表“完成”不包含未承诺的功能与未做的设备矩阵。

| 任务 | 目标与实际交付 | 最终交回 | 接受合并 | 状态/证据 |
|---|---|---|---|---|
| **T15.1** | 区分restart与stop；tmpfs intent跨stop/cleanup/start保留handoff，安装成功后清intent；显式stop/禁用恢复系统DNS | `c5d66c9` | `0e0aac4`，11-07 13:56 | 本地+H28K受控restart/stop验收；[记录](t15.1-h28k-20261107.md) |
| **S15.2** | 用真实本地socket/假角色端点比较A显式直查与B隔离bootstrap；选择B，否决只后移DNS/只等TPROXY/临时直连 | `18b98ef` | `38ef822`，11-07 14:57 | 设计探针；正常/恢复各54断言、3类变异；[设计证据](s15.2-startup-dns-design.md) |
| **S15.3 / B0** | 用两个真实DNS引擎确认私有最小配置、协议/语法、端口归属、并发及清理契约 | `1b8063e` | `d6281b5`，11-07 15:29 | 正常/恢复各268断言，19 PASS/1 UNSUPPORTED；[真实契约](s15.3-real-bootstrap-contract.md) |
| **T15.4 / B1** | 新增面向私有loopback端点的A/IN取IPv4查询器和显式apply入口，抽取共享boot上游选择 | `c3b926d` | `a417edf`，11-07 16:26 | 首次实现时未接入启动；Q1–Q11、73 PASS、4类变异，单元1248/0 |
| **T15.5 / B2** | 从正式DNS/Xray产物导出所需socket，按本child归属/地址/协议等待，覆盖启动、reload/rollback、节点IP刷新与SIGUSR2 | `8320eb7` | `e80b2e2`，11-07 20:37 | 经struct和connected UDP补修后139 PASS/12项变异；合并后单元1252/0 |
| **T15.6 / B3** | 接入短命bootstrap start/stop，完成节点解析→退出确认→Xray→正式DNS→handoff顺序，保守处理异常残留 | `eeec7f1` | `07b6d0b`，11-08 10:29 | B3 92/0、最小模块52/0及规定变异/回归；[部署样本](t15.6-h28k-20261108.md) |
| **T15.7** | 支持内核优先只读INET_DIAG双栈证据，避免TPROXY普通握手触发loopback；保留限定兼容回退 | `28a151d` | `5aafe95`，11-08 17:43 | passive101/0、单元1257/0、10对预算控制及原门禁；H28K50/50、FD稳定、无新增日志；[定向验收](t15.7-h28k-20261108.md) |

**数字口径**：suite核心汇总、wrapper的PASS行数、不同卡断言有重叠，不相加当作独立覆盖率。例如B3核心92/0和最小模块52/0之外还有harness打印行；不能把整段输出的161条PASS理解成161个不同生产场景。

---

## 3. 行为从r6到当前的变化

### 3.1 r6成功启动的依赖环

```text
正式DNS先启动 → dnsmasq handoff先安装
                ↓
系统resolveip解析节点 → dnsmasq → 正式DNS的boot路径
                ↓
得到节点IPv4后才启动Xray，旧gate只看TPROXY 31080
```

这带来两个独立问题：restart时删除handoff可使DNS回落系统直连；保留handoff后，若只把正式DNS后移，节点解析又会依赖尚未存在的正式DNS。T1正式DNS先接客而Xray DNS入口尚未可用，还会产生refused/SERVFAIL。

### 3.2 当前正常成功路径

```text
前置配置/组件校验、冻结同一快照、按原边界清理/发布
  → IPv4字面量直接使用；域名则启动私有bootstrap
  → B1显式查询私有端点：DNS优先，失败才按地址LKG
  → stop私有child并确认退出，清本代文件
  → 补全并-test Xray，启动Xray
  → B2等待owned TPROXY TCP及正式DNS实际引用的socket/协议
  → 应有的nft/route
  → 正式DNS启动并验证owned UDP/TCP
  → dnsmasq_install成功
  → 清restart intent
  → 最终状态/既有健康检测
```

源码主线见[start_sequence](../../aether-proxy/src/lib/daemon.uc#L473)、[解析至正式DNS门](../../aether-proxy/src/lib/daemon.uc#L690-L814)。T15.7只替换适用的双栈证明方式，不再重排B3。

### 3.3 必须保留的分支与边界

- **节点引导不是普通客户端流量**：私有配置上游取同一冻结快照的boot选择；direct_dns_enabled=0使用展开china_dns，=1使用direct_dns。节点bootstrap按设计可走其直连上游，不属于标记普通gfw查询的泄漏统计。
- **B1不是通用递归resolver**：仅A/IN、有限CNAME与显式TC→同端点TCP，随机事务ID、来源/问题关联和长度检查；每轮3秒、最多3轮，解析/回退共享本轮deadline。
- **DNS优先/LKG不抢先**：已存在LKG仍先查询；写LKG失败不是解析成功。取消不重试、不fallback、不写缓存。
- **无LKG解析失败**：保持既有degraded/fail_open/初始tier分支，不启动或永远等待不存在的Xray，不偷偷临时开启T2/T3。
- **readiness≠健康**：owned监听与地址族能力不是上游能否回答或代理端到端连通；后者仍由monitor负责。协议范围是TPROXY TCP、DNS实际引用协议及正式DNS的UDP/TCP，不包括TPROXY UDP31080；产物声明tcp,udp或设备当时确有UDP监听，不等于该UDP已纳入门禁。
- **仅startup切B1**：reload、monitor、probe的运行期节点解析没有顺带改为私有bootstrap；它们的计划Xray重启门则按B2改进。
- **首次start及普通stop不同于restart**：首次接管前没有旧handoff；手动stop/禁用明确释放handoff。这些不是T15.1的restart连续性保证。

### 3.4 资源契约的最终收敛

最初曾要求过强的“任何父SIGKILL窗口都安全自动回收”，并讨论gate授权及pidfd。最终采用用户批准的`8e4d6a2`修订，**未实现这些候选**：

1. 私有child无自动respawn，资源在run_dir独占代目录，正常使用内部start/stop。
2. stop在最多5秒内给出判定；真实直属退出回调确认后才删除本代文件。
3. 未确认退出：保留handle/身份/代记录、报告失败，不开下一阶段/下一代，不用LKG掩盖清理失败。
4. 历史PID/孤儿只核对；旧生命周期消失可清owned记录，仍执行或无法确认则失败阻断，**不自动向历史数字PID发TERM/KILL**。
5. fork至PID身份发布之间的未知窗口不再要求自动恢复；缺失PID不是“无人执行”的证明。可能需要管理员处理，这是已接受的可用性取舍。
6. 有界的是判定与返回，不保证D-state/SIGSTOP/无调度进程按墙钟必然消失；不把发KILL成功当退出。

具体实现：[bootstrap.stop/recover](../../aether-proxy/src/lib/bootstrap.uc#L155)、[shutdown失败传播](../../aether-proxy/src/lib/daemon.uc#L931-L990)。不靠设备重启作为正常收口步骤。

这套“不向历史PID自动发信号”的收敛专指新增私有bootstrap。正式Xray/DNS原有[supervise.kill_stale](../../aether-proxy/src/lib/supervise.uc#L228)仍保留原信号清理；正常直属stop也复用既有监督者机制。本轮没有把整个应用改成pidfd式原子目标绑定，不能把私有残留策略扩写为全应用已消除数字PID竞态。

---

## 4. 全部13个生产文件的审查地图

链接行号对应截止源码；建议用§10命令查看固定提交，避免以后main移动造成误读。

| 文件 | r6后实际变化 | 交叉审查重点 |
|---|---|---|
| [init](../../aether-proxy/files/aether-proxy.init) | restart intent、stop/disable边界与兜底 | 正常文件操作下先清intent/写stop-mark再kill；rc.common不采用stop_service返回值，异常日志与最终rc边界见§8.2a |
| [apply](../../aether-proxy/src/lib/apply.uc) | intent/handoff保留、B1显式入口及共享失败/LKG收口 | 安装成功才清intent；保存失败/取消语义；原resolve_node运行期行为未改 |
| [bootstrap](../../aether-proxy/src/lib/bootstrap.uc) | 新增443行生命周期/私有配置/所有权记录 | start/stop注册时机、预算、known与unknown残留、只删本代、历史PID零信号 |
| [bootstrap_dns](../../aether-proxy/src/lib/bootstrap_dns.uc) | 新增363行显式节点查询器 | TC/CNAME/压缩/关联A、坏报文、socket来源、总deadline及取消 |
| [const](../../aether-proxy/src/lib/const.uc) | tmpfs路径、预算、协议常量等 | 不新增用户选项或包依赖；版本仅占位符由包构建替换 |
| [daemon](../../aether-proxy/src/lib/daemon.uc) | 启动顺序、失败/停止收口、collector时机与timer对象保活 | 不能只审“后移DNS”；需审冻结快照、残留优先级、错误传播及既有可观测性 |
| [monitor](../../aether-proxy/src/lib/monitor.uc) | 节点IP刷新后的planned restart门改为published readiness | busy/锁/停止优先、NODE_IP_CHANGED不能先于就绪；周期health不改成阻塞门；旧wait_xray_port仍定义/导出但已无生产调用者，保留兼容测试接口不在本轮清理 |
| [net](../../aether-proxy/src/lib/net.uc) | 纯地址与proc socket表解析 | native-endian 32位字、IPv4/6、远端UDP tuple；纯函数不读文件/不导入struct |
| [reload](../../aether-proxy/src/lib/reload.uc) | 正向和rollback新child门、rollback错误传播 | 读取当时current产物、不跨代缓存requirements；回滚失败不能吞 |
| [chinadns renderer](../../aether-proxy/src/lib/render/chinadns.uc) | 抽取共享boot_upstreams | 正式产物字节与golden不变；不静默改上游语法/顺序 |
| [socket_diag](../../aether-proxy/src/lib/socket_diag.uc) | 新增225行最小TCPv6 INET_DIAG | tuple/inode/state/序号/长度与终止、ENOENT上下文、无隐含新模块依赖 |
| [supervise](../../aether-proxy/src/lib/supervise.uc) | 短命child可选不respawn及退出/错误观察 | 默认正式child监督行为不变；不将PID文件缺失等同于已退出 |
| [xray_ready](../../aether-proxy/src/lib/xray_ready.uc) | 新增引用导出、owned gate、ELF字节序、T15.7被动优先 | TPROXY仅TCP，DNS按引用TCP/UDP；v6only、FD归属、兼容分类、所有需求共享预算与取消优先 |

**顺带但重要的生产修复**：[retire_interval](../../aether-proxy/src/lib/daemon.uc#L914-L929)保留已cancel的uloop interval对象至uloop.done，避免最低版本libubox的queued fd回调指向已释放对象。它不保留活动timer FD，不是关闭scheduler；这是B3本地停止回归暴露后做的兼容修复，不能在“只改启动顺序”概述中漏掉。共享host/libubox源码没有被修改或替换。

---

## 5. 复审中发现、补修或排除的事项

| 阶段 | 曾出现的问题 | 最终处理 | 性质/当前状态 |
|---|---|---|---|
| T15.1 | enabled=0且无procd实例但有intent时漏清理 | `b1ae912`补残留禁用分支 | 生产修复，已验证 |
| T15.1 | 原SIGKILL用例不是真正SIGKILL | `9a38989`补实际kill/wait与重复cleanup | 验收证据补正，非伪造成功 |
| T15.5 | net静态import struct，而包未声明 | `c556599`改fs读16字节ELF、显式字节序 | 生产加载风险已消除，未增依赖 |
| T15.5 | owned connected UDP被误当DNS入站 | `f031104`要求state07且远端全零/port0 | 生产误判已修，IPv4/6真实负例 |
| T15.6 | PID发布失败＋监督者SIGKILL的资源窗口 | 先`bc2f078`停点、`7b16f8b`设计；随后按`8e4d6a2`缩为有界stop判定/不确定保留 | 原过强保证撤回，不是声称原子回收已实现 |
| T15.6 | 最低libubox timer取消/对象释放导致原生停止崩溃 | `e7eb0a0`仅在daemon保留cancel对象至loop teardown | 生产兼容修复，停止/定时器回归覆盖 |
| T15.6 | waiting predicate已见stopping，第二次读取却见stopped | `383b066`保留实际匹配快照、TERM入口状态与完整写入轨迹，保留字段/原时间界限及3项控制 | 测试双读竞态；受控实际daemon反例，不冒称捕获了历史所有自然路径 |
| T15.6真机 | loopback Error | 实际readiness、普通31080握手各触发一条；非探测阶段计数稳定 | 进入T15.7解决，不靠删日志 |
| T15.7 | 漏识别handler不可用的ENOENT错误通道 | `5e6b5b5`只在关联完整且尚无证据的TCPv6 DUMP中处理ERROR/DONE的-ENOENT | 兼容缺口已修；create/send ENOENT、空正常dump等仍失败 |
| T15.7 | probe-after-budget变异偶发存活 | `f086adc`确定晚到合法结果并直接计connect，10对删除/恢复控制 | 测试可靠性补修；生产守卫未为配合测试改变 |
| 最后B3复跑 | Authority UDP取端口后同号TCP bind冲突 | 原失败保留，原入口只重跑一次后通过 | 旧夹具问题未修，列§7，不扩大T15.7 |

原始分支报告保留历史停点与修复过程；不要只读最早的未完成段落，也不要只看最终摘要忽略中途发现。报告提取方法见§10。

---

## 6. 验证、部署与证据等级

### 6.1 本地证据分类

| 等级 | 例子 | 可以证明 | 不可以外推 |
|---|---|---|---|
| 真实内核/真实进程/真实引擎 | socket归属、v6only=0/1、真实TERM/SIGKILL、两个DNS引擎、真实Xray | 实际资源/协议/进程机制及受控因果 | 不等同全配置生产实机、所有内核或设备长期稳定 |
| 实际daemon＋合成sys-root/proc | B3顺序、故障、快照、rollback、停止状态 | 当前生产ucode流程对明确输入的行为 | fixture不是固件内核实际端口 |
| 纯报文/错误边界 | LE/BE netlink、坏DNS、错误返回、关闭失败 | parser及失败分类、预算/FD逻辑 | 不是内核真的发过每一种坏消息；BE不是大端设备验证 |
| 设计角色模型 | S15.2及部分handoff/策略模型 | 拓扑候选和反例 | 不是运行真实DNS/procd/nft的验收 |
| H28K授权样本 | T15.1、B3与T15.7记录 | 本设备、本配置、本窗口的真实结果 | 不是全流量/全协议/零中断或永不复发保证 |

最低宿主ucode源码固定到`3f64c808`。BusyBox awk/其他真实架构并非每次宿主都执行；已有日志明确保留这一限制。

### 6.2 关键设备结果

**T15.1（11-07）**：[原始摘要](t15.1-h28k-20261107.md)

- restart时handoff全程存在且内容不变；intent约11.9秒后清除。
- 标记UDP/53直连计数0；主动stop阳性对照31包，之后start恢复running/T1。
- 只证明所标记普通gfw请求的UDP/53路径；NXDOMAIN本身不是直连证据。

**B3（11-08）**：[原始摘要](t15.6-h28k-20261108.md)

- 650样本跨92.93秒，平均约143ms，不冒报严格100ms。
- 观察到bootstrap退出后新Xray出现；新正式DNS出现约在restart后8.09秒，所有其可见样本已有Xray owned 31082/31083 TCP LISTEN，违例0。
- handoff无缺失，标记计数阳性对照1→restart结束仍1；额外直连0。
- 450请求392 NXDOMAIN、52 timeout、6 errno111、0 SERVFAIL；恢复后325中仍3次2秒timeout，所以当时没有报“全无异常”。

**T15.7（11-08）**：[原始摘要](t15.7-h28k-20261108.md)

- 实际内核证据：本Xray owned inode、dual_stack=true、fallback=false。
- 连续50次readiness成功，FD14→14，升级启动和50次检查没有新增loopback；历史4条不清除，其中2条来自此前有意因果控制。
- 两次必要本机TCP DNS冒烟NOERROR；不是再次UDP丢包诊断。

### 6.3 三次本地包部署

| 包 | 源码依据 | SHA256 | 设备备份 |
|---|---|---|---|
| `0.6.3-r6.t151` | 审查实现`c5d66c9`，随后合并`0e0aac4` | `89bdd30418bf2f833549b77f8fcf060eeb15d51b283dc3f59d3f572021a0189e` | `/root/aether-proxy-before-t151-20261107/` |
| `0.6.3-r6.t156` | 合并`07b6d0b` | `dac244e904f4a8a99b06bc56b2191bc8cf716f272db07dda359431499fb371f7` | `/root/aether-proxy-before-t156-20261108/` |
| `0.6.3-r6.t157` | 合并`5aafe95` | `893c265083930b38fb303b7af644bb55f57dcce9aa30b6534277b6d5e56d5522` | `/root/aether-proxy-before-t157-20261108/` |

均在Rockchip构建树隔离包配方构建、只读导出审查源码，不改共享feed或正式发布版本。T15.7包内与安装后10文件逐字节/哈希核对，版本占位符替换有记录。

- 活动UCI配置保留；包管理器生成的aetherproxy-opkg提示不是活动配置被覆盖。
- 包原有postrm/postinst执行fw4 reload，实际日志可见；不能写成“完全没碰防火墙规则”。未重启防火墙/网络服务、未改WAN/接口、未重启/刷H28K。
- 设备boot ID在各验收前后均为`97edbacd-fd63-4a21-beb7-0cc59ac22b93`。这是历史连续性证据，不要求未来永远不变。
- r6.t156构建曾清除输出目录旧ipk；在安装前找回设备留存并校验哈希后补齐备份。r6.t157提前复制旧包，避免再发生。
- 原始包/日志在本地忽略目录与设备备份，不因构建树滚动删除而假定永远可从bin/packages找到旧包。

### 6.4 不把这些误写成“全绿”

- main按约定移除了分支实现报告，分支专用review在main可能因报告不存在失败；不得伪造报告或把它冒报为完整review通过。main基线采用相应unit/CLI/目标入口核对。
- 正式review的docs WARN由卡片授权解释；个别早期提交scope格式WARN也保留。WARN≠所有额外套件已通过。
- 初始start-task多次在调用端120秒预算中断，只确认已打印的单元基线，不当作完整基线review成功。
- schedule原入口5失败是实际存在的记录；47/0是保持oracle的兼容补测，不是原命令通过。
- 一次夹具绑定EADDRINUSE、一次预算变异存活等失败记录没有被后续成功覆盖；结论标明定位和处理方式。

---

## 7. 当前遗留账：按项目与性质拆开

| ID | 归属/类型 | 已有事实 | 后续动作与边界 | 是否阻塞已关闭T15.7 |
|---|---|---|---|---|
| **L1** | aether-proxy／测试夹具，已收口 | 原35/5的两处输入边界已由T15.8适配，保留全部业务oracle；最终f804c07，合并a369fba，独立正向/恢复47/0及两项反向通过，合并main再跑47/0 | 原始失败记录保留；compat已转为原入口的exec薄包装，不是生产调度修复，不再重复开卡 | 否，已完成；未构建/部署设备包 |
| **L2** | aether-proxy／测试资源竞争 | B3 Authority先UDP bind0，再TCP绑定同号端口，曾EADDRINUSE | 独立修双协议端口选择/有界重试；不改生产bootstrap，不加sleep或放宽断言 | 否，已定位且原入口一次重跑通过 |
| **L3** | 历史观察／后续已归档 | 截止快照时9失败请求未见H28K入口；后续Windows原生、mirrored、Debian桥接各600/600通过 | 按“WSL＋NAT环境相关、具体归因未定”保留记录，不作常规组件验收基线；仅其他独立环境复现相同问题再评估。见[最终归档](udp53-wsl-mirrored-trial-20261108.md) | 否，不列为当前组件已知故障，不继续扩查 |
| **L4** | aether-proxy／产品一致性backlog | 逻辑组件/日志/状态键仍有chinadns-ng与xray旧称 | M4-02：先决定逻辑名与物理回退路径分离、JSON兼容迁移，再独立实现；不是全局字符串替换 | 否 |
| **L5** | aether-dns＋aether-proxy兼容／版本backlog | aether-dns仍为日期版本；代理现有检查需按具体引擎拆分 | M4-03：独立semver，不与proxy同号；先定起始号、最低兼容范围、opkg日期→semver排序/迁移路径 | 否；正式发版前需明确策略 |
| **L6** | aether-proxy／可选可用性优化 | restart仍有旧DNS停止、新服务构建及一次dnsmasq安装restart窗口；T15.1已去掉删除handoff引起的另一次restart | M4-06必须重估，不按历史“两次重启/零超时”直接实现；先定可接受中断和成本，不假定HUP可重读全部配置 | 否，是已接受fail-closed下的体验议题 |
| **L7** | 发布流程／未正式发布 | 当前仅r6.t157本地验收包，main包版本仍r6，未push/发release | 独立确定正式release号、更新清单/包排序、发布与回退验证，不静默覆盖原r6 | 不影响本地验收；阻止将其冒称正式版 |

L1五个原失败名为：`auto degraded scheduler setup`、`notify degraded scheduler setup`、`reload-jitter test daemon enters degraded`、`unresolved current node enters degraded for failsafe test`、`stop-timer test daemon enters degraded`。参考[旧schedule入口](../../tests/schedule/run.sh)与[B3 Authority](../../tests/bootstrap-startup/run.py#L40-L51)。

### L3的精确范围（避免误修）

17:59只读确认UDP代理选择集host_udp4/host_udp_mac为空，游戏模式未启用；正式trust-dns是TCP31082/31083。本次UDP是客户端提交DNS的传输，不是游戏UDP透明代理：

```text
WSL -- UDP/53 --> H28K dnsmasq --> 本地31053 --> T1 TCP DNS tunnel/Xray
       失败样本未出现在H28K抓包入口
```

三路对照：LAN UDP270中2次8秒超时；LAN TCP270/270、直接TCP31053经SSH270/270成功。窄抓包1700次中1691完整四阶段往返、9失败无入口包，内核抓包drop0。

原部署的3个2秒timeout未抓包，不能逐包追溯为同一原因。接收侧没有包也不能排除NIC/驱动在抓包点前丢弃；不能仅此定案为某Windows模块。NAT外部端口分配段切换是线索，不是已修复的根因。新socket/复用socket500次均成功，也不支持“复用就已经解决”。详情见[追查与范围更正](t15.6-followup-20261108.md)。

---

## 8. 已接受限制与仍需你判断的范围

### 8.1 不是当前待修bug的已接受限制

- 不确定的历史私有残留会保留记录并阻止继续启动，可能需人工处理；不保证异常孤儿自动回收，不猜PID强杀。
- 有界stop不保证D-state等进程按时消失；发送信号不等于完成回收。
- 不支持只读属性的内核可走原有界主动验证，仍可能有旧握手副作用；H28K已实测被动路径，不宣称所有平台都完全被动。
- 兼容分类依赖已列举的英文socket.strerror文本（含常见glibc/musl差异）；不保证任意libc/locale。无法识别时保守失败，不把当前H28K被动路径成功当成所有错误文字环境已覆盖。
- readiness只证明所需owned socket/地址族，不证明DNS/代理上游健康；无LKG时按原degraded/fail_open处理，不伪造可用。
- 当前设备验证集中于T1、bypass_cn、现有节点及两项TCP trust；其他协议/失败/取消矩阵主要来自本地真实进程与fixture，不冒称全在生产设备注入。

### 8.2 已接受的保护范围：intent、升级与daemon respawn

所有者同意本轮按现有范围收口，**不启动受控升级或respawn扩保实现**；以下包含代码路径分析，不是新增设备故障注入或测得的泄漏时长。

- [init.restart](../../aether-proxy/files/aether-proxy.init#L45-L76)预先创建intent，保护由这个标记触发。安装前失败/退避后的重试或respawn若仍继承该intent，也继续保留handoff；不能把respawn一概写成没有保护。
- 正常文件操作下，[普通stop_service](../../aether-proxy/files/aether-proxy.init#L113-L128)先清intent并写stop-mark，随后沿手动stop/禁用语义释放handoff。异常返回传播不是这个顺序的保证，见下一节。
- 标准包管理器独立stop/start不等于调用init.restart；[包脚本](../../aether-proxy/Makefile#L73-L85)还有fw4 reload。未给所有opkg升级窗口作同等标记出口抓包背书。
- **正常运行后daemon崩溃，由procd直接respawn命令且没有既存intent时**，不会自动创建intent；若新启动正常推进至[apply_cleanup](../../aether-proxy/src/lib/daemon.uc#L650-L655)，[dnsmasq_remove](../../aether-proxy/src/lib/apply.uc#L489-L529)可能摘掉旧handoff并重启dnsmasq，直到末段install重新接管。此间有回落系统resolver的潜在窗口；未在H28K制造daemon崩溃测量。私有残留导致提前阻断等分支也不能一概写成必然回落。
- 首次接管前没有旧handoff，人工stop/禁用则有意恢复系统DNS；不把这些路径等同于受保护restart。

回执中的11秒是SERVICE_STOPPED→SERVICE_STARTED事件间隔，不是已测得的11秒泄漏长度。已有设备restart标记计数结论不外推到全部opkg/首次接管/普通无intent respawn路径。是否将来扩保需另立最小目标，不能把普通stop改成永久保留。

### 8.2a stop返回值与TERM兼容差异（尚未修代码）

当前固件rc.common的procd stop依次调用stop_service、procd_kill、service_stopped，不采用stop_service的返回值。本init的service_stopped最终返回cleanup结果，所以restart里的stop_rc并不保证收到了前置标记操作错误。

- intent删除失败可使旧handoff保留，方向为fail-closed；不能把这报告为普通stop已成功释放。
- stop-mark写失败时，后续UCI reload可能再次启动服务。现有日志可见，但CLI最终rc未必反映前置失败；这是真实异常路径边界，不因文字澄清就标为已修。
- 自定义restart还缺rc.common在stop阶段的TERM屏蔽与start前恢复。若后续立init小修卡，应完整恢复对应语义（含提前返回），不能只忽略TERM而不恢复。

当前仅明确记录；低优先级init契约候选另排，不重写procd、不承诺在不可写文件系统下仍能持久保存manual-stop，也不扩生命周期自动恢复。

### 8.3 其他未冻结候选，不塞入当前任务

DoT/证书策略、负缓存、TCP连接数上限、更多IPv6/nft能力、引擎切换UI等仍为[aether-dns M4候选](../../../aether-dns/docs/tasks/m4.md)。

S15.3明确：aether-dns当前不支持TLS；回退chinadns-ng只验证了默认不校验证书模式的TLS传输与SNI，未证明完整PKI策略。两引擎非TLS host@IP语义也不同。不能把probe的可支持场景PASS写成两引擎全配置等价，或把这些候选当本轮已承诺却漏交付。

---

## 9. 建议你逐项打勾的交叉审查清单

- [ ] r6基线、当前源码、设备本地包、正式发布状态是否区分准确？
- [ ] 7个任务的目标是否都能对应到接受合并、历史报告与现存代码？
- [ ] 是否区分有intent的restart/失败重试与普通无intent respawn，且只在文件操作正常时宣称手动stop/禁用释放？
- [ ] 是否明确接受§8.2的升级/首次接管/普通respawn边界，并保留§8.2a异常返回与TERM差异未修的事实？
- [ ] B1是否保持DNS优先/有界TC-CNAME/LKG保存失败与取消语义，且只接startup？
- [ ] B2是否明确TPROXY只检查TCP、DNS按实际引用协议检查，不能靠无关PID或connected UDP过关，而非宣称已覆盖TPROXY UDP？
- [ ] B3是否先确认私有child停止，失败不删证据、不继续fork，且无LKG分支不永远等Xray？
- [ ] daemon collector延后、timer对象保活、rollback错误传播等附带生产改动是否已审，而非只看DNS顺序？
- [ ] T15.7是否保留归属/字节序/取消/总预算，ENOENT仅在合法无证据DUMP上下文回退？
- [ ] 是否将探针、fixture、真实内核、真实引擎、H28K样本的证明边界分开？
- [ ] 原失败/重跑/变异存活记录是否可追溯，而非单看最终PASS？
- [ ] L1/L2明确归aether-proxy测试；L3未误归aether-dns或泛UDP代理？
- [ ] 当前无新增依赖、未改UCI/LuCI/golden、未重启设备等结论是否与diff/部署记录相符？

所有者确认的有序安排：文档边界及T15.8已收口；当前只冻结T15.9处理L2，随后才单列有限init契约候选，不并行扩卡。L3已归档，除其他独立环境复现相同问题外不重开。L4/L5/L6与正式发布分别决策，不绑入当前测试修复。T15.8合并后仅复跑原schedule入口47/0，其他已验收且未变证据复用；没有追加设备矩阵或升级包。

---

## 10. 可重复的Git审查命令

以下是建议命令，不要求为了读文档再跑全部耗时测试。固定HEAD是为了不把本文或后续任务混入统计。

```sh
cd /workspace/openwrt/aether-proxy
BASE=435540b535197e79a330ff038fa716d7f3d0e40f
REVIEW_HEAD=356e6f274b1ae23569e3baea3335ed1c7907e934

git rev-parse 'v0.6.3-r6^{commit}'
git log --first-parent --oneline "$BASE..$REVIEW_HEAD"
git diff --stat "$BASE" "$REVIEW_HEAD"
git diff "$BASE" "$REVIEW_HEAD" -- aether-proxy
# 理应为空：包依赖/正式版本、默认配置、LuCI与正式golden

git diff "$BASE" "$REVIEW_HEAD" -- \
  aether-proxy/Makefile aether-proxy/files/aether-proxy.config \
  aether-proxy/src/lib/config.uc luci-app-aether-proxy tests/fixtures
```

分支报告按仓库约定在merge main时删除，但已确认全部可从接受的第二父提交读取：

```sh
git show c5d66c9:reports/T15.1.md
git show 18b98ef:reports/S15.2.md
git show 1b8063e:reports/S15.3.md
git show c3b926d:reports/T15.4.md
git show 8320eb7:reports/T15.5.md
git show eeec7f1:reports/T15.6.md
git show 28a151d:reports/T15.7.md

# 查看某卡所有实现/报告补修，不只看最终提交
MERGE=5aafe95
git log --reverse --oneline "$MERGE^1..$MERGE^2"
git diff "$MERGE^1" "$MERGE" -- aether-proxy
```

主要补修提交导航：

```text
T15.1  7cfb361 → b1ae912 → 9a38989 → c5d66c9
S15.2  2067f1a → 18b98ef
S15.3  9559f28 → 1fef399 → 1b8063e
T15.4  21bb449 → c3b926d
T15.5  3e3daee → c556599 → f031104 → 8320eb7
T15.6  bc2f078(停点) → 7b16f8b(候选设计，未实施)
        → 40f5868 → c93463d → e7eb0a0 → 87c4249 → 2c44e00
        → 830cc8e → 383b066 → eeec7f1
T15.7  e318d24 → 5e6b5b5 → f086adc → 28a151d
```

以上导航省略部分纯报告提交；完整历史由前述范围命令给出，不把导航误读为所有Git提交的逐条清单。

## 11. 相关aether-dns工作与证据索引

### 11.1 不算作aether-proxy新增任务的相关依赖工作

| 项目任务 | 接受合并 | 作用/边界 |
|---|---|---|
| aether-dns M4-07 | `b2acecf` | 修其自身Rust集成测试端口交接竞争；已完成。不是L2的aether-proxy Python Authority问题 |
| aether-dns M4-01 | `325b614` | 有界异步缓存刷新；H28K依赖包2026.11.04-1，运行banner仍2026.11.04，不是与proxy同号发布 |

[缓存验收](../../../aether-dns/M4-VALIDATION-2026-11-07.md)：61次低频查询TTL0为1.64%；1800/1800持续命中NOERROR、TTL0=0；上游尝试计数120/360秒是含背景/多上游/重传的保守上界，不是精确刷新次数。T15.6/T15.7没有再修改该引擎二进制。

### 11.2 随仓库保存的审查入口

- [M15原任务与批准修订](../tasks/m15.md)
- [当前DNS说明](../03-dns.md)、[当前生命周期说明](../04-lifecycle.md)
- [T15.1 H28K验收](t15.1-h28k-20261107.md)
- [S15.2拓扑证据](s15.2-startup-dns-design.md)、[S15.3真实引擎契约](s15.3-real-bootstrap-contract.md)
- [B3构建/安装/真实窗口](t15.6-h28k-20261108.md)
- [loopback与窄UDP/53追查](t15.6-followup-20261108.md)
- [T15.7最终定向收口](t15.7-h28k-20261108.md)
- [跨项目M4待办与历史材料](../../../aether-dns/docs/tasks/m4.md)：其中有历史目标/待决策段落，不应跳过开头最新状态，把它们当仍未实现的B1/B2/B3要求。

### 11.3 本地原始证据的可获得性

以下目录在相邻aether-dns仓库的忽略区，**存在于本机，但不是克隆aether-proxy就自动得到的版本化交付**；不要把缺失的本地原始文件与版本化摘要混为一谈。需要异机交叉审查时应另行安全打包，避免将活动配置/敏感原始日志提交公开仓库。

```text
/workspace/openwrt/aether-dns/dist/logs/t15.1-install/
/workspace/openwrt/aether-dns/dist/logs/t156-h28k-20261108/
/workspace/openwrt/aether-dns/dist/logs/t156-h28k-20261108/analysis/
/workspace/openwrt/aether-dns/dist/logs/t157-h28k-20261108/
```

其中T15.7目录保存实现最终报告副本、独立review原失败与一次重跑、main目标基线、source commit/build manifest/包配方、旧包、安装/状态/50次验证/源码哈希。S15.2/S15.3版本化探针证据位于各自spike目录；纯编译产物和第三方二进制不提交。

**本文只提供审查事实、边界和决策入口。没有替你批准新范围，也没有把未知现象强行归类为某组件缺陷。**
