# aether-proxy 独立会话交接（2026-11-09）

> 本文件用于从混合会话切换到**仅负责aether-proxy**的新对话。
> **2026-11-10 更新**：0.7.0-r1 已发布（tag `v0.7.0-r1`，Release 14 资产、Latest；通道 `AETHER_PROXY_REF` 固定为该 tag 提交）。本文件其余内容是 11-09 的快照，其中"正式版本 0.6.3-r7"应理解为发布时的状态；新的发布记录见 [0.7.0 说明](../releases/0.7.0.md) 与任务卡 M4-03d。
旧会话的设备交付、r7发行目标均已完成；没有默认待执行实现卡。先核对状态，再等用户选择下一目标，不恢复旧目标或重复部署。

## 1. 权威状态

| 对象 | 已核实状态 |
|---|---|
| 项目目录 | `/workspace/openwrt/aether-proxy`（WSL Ubuntu-26.04） |
| 源码远端 | `git@github.com:leochien0102/aether-proxy.git` |
| 交接文档创建前main | `9a2932ece238597f4f18611fb1787807ecf6f594`，当时工作树干净、与origin/main同步 |
| 正式版本 | **0.6.3-r7，Latest、非draft、非prerelease**；发布验收时确认 |
| 正式tag/产品源码 | `v0.6.3-r7` → `cd7812c6e6c0f2f68171214a28f6d5477b299a61` |
| 发版后测试维护 | `ea8625f`，最新正式版兼容快照已换为r7，维护CI通过 |
| 后续纯文档收口 | `9a2932e`，仅docs，使用[skip ci]；不是跳过产品门禁 |
| 通道仓库 | `/workspace/openwrt/aether-proxy-channel`；main `8ae93f7250242d71ac1612e116ba9c6db00e54e4` |
| 通道源码固定值 | AETHER_PROXY_REF与正式tag均为上述cd7812c完整SHA |

[正式Release](https://github.com/leochien0102/aether-proxy/releases/tag/v0.6.3-r7)已含14个软件资产，清单usign验签、全部资产下载SHA-256均通过。普通客户端channel-stable URL也已确认是签名有效的r7。应用test、4组SDK构建/6组smoke、通道gate/build/publish、Release资产、tag测试和兼容快照维护CI均通过，详见[发行验收](../validation/0.6.3-r7-release-20261109.md)。

本文件及索引是本次新增的**本地文档提交，未推送、不触发CI**。因此新会话可能看到main仅有文档ahead；不要把它误判成r7产品未推送。以tag和通道REF认定发行源码，不要求维护后的main HEAD等于tag。不要为同步文档移动已发r7 tag、改channel REF重编同号包或覆盖已发资产；新产品修改应另按版本策略发布。

## 2. 已完成，不再重开

- T15.1：init restart预先创建intent，保留DNS handoff。
- S15.2/S15.3：设计及两种真实引擎契约探针，仅证据阶段，不是另一份生产实现。
- T15.4/B1：startup用私有端点的显式IPv4 A/IN查询，DNS优先、失败才LKG，有限CNAME、TC转TCP与共享预算。不是通用递归resolver，也没顺带改运行期解析。
- T15.5/B2：按发布产物引用检查owned PID/starttime、FD inode、地址族与协议，拒绝connected UDP伪就绪。
- T15.6/B3：私有bootstrap → 确认退出 → Xray就绪 → nft/route → 正式DNS owned UDP/TCP → handoff → 清intent。正常私有停止有界，不确定历史残留保留且不信号历史PID。
- T15.7：适用内核优先被动SOCK_DIAG证明双栈，保留限定兼容回退；不是所有平台都保证无握手。
- T15.8：schedule正式入口已从35/5修为47/0，原业务oracle保留；旧compat入口已成薄包装。
- T15.9：**proxy Python B3 Authority**动态双协议端口最多16次、失败显式关闭；固定端口不换号。不是DNS Rust harness的M4-07。
- T15.10：停止错误经真实rc.common顺序对调用者可见；cleanup原非0优先；restart只在stop阶段屏蔽TERM，随后恢复默认。
- T15.11：发行CI发现4个新阶段缺译，已补显示映射/PO，当前31项与历史chinadns_start明确分层；完整LuCI1043 pass/0 fail/3原有skip，未弱化覆盖。

本轮实现卡均合并收口并清理。可能仍有其他历史实验工作树（B25/T14等），不是本轮待办；不要自行清理、合并或推送它们。

## 3. 设备：最后已验记录，不是刚刚查询

H28K入口`root@192.168.5.254`，使用WSL既有SSH密钥；本次交接整理不访问设备。

- 最近实机安装/验收：2026-11-09 12:43，用户经**在线更新**把 H28K 从本地包`0.6.3-r6.t1510`升到 **CI 正式 r7**（`aether-proxy`/`luci-app-aether-proxy` 均`0.6.3-r7`），running/T1/bypass_cn、boot ID未变、无新增失败事件。通道签名清单的包哈希与 Release 资产逐字节相同，故"通道包不是验证过的包"在 r7 上不成立；证据、时间线与未覆盖项见[P1验收](../validation/p1-h28k-r7-online-update-20261109.md)。正式r7发行阶段本身仍未安装设备，那段历史结论原样保留在[发布验收](../validation/0.6.3-r7-release-20261109.md)。
- boot ID记录为`97edbacd-fd63-4a21-beb7-0cc59ac22b93`，设备未重启，活动配置未变。
- restart命令返回0约1.678秒，发起至running/T1约11.748秒；stop返回0约4.603秒；start请求约0.098秒、恢复T1约11.175秒。**异步命令耗时与服务恢复/事件间隔分开，均不是泄漏长度。**
- 119个restart样本handoff始终存在且字节不变；手动stop标记为空文件、片段移除、trigger保留，start后恢复。随后30秒采样正常，本机UDP53/TCP31053两次NOERROR，无新增启动失败/崩溃/loopback。
- 真实固件隔离ash11项通过，但procd/cleanup是模拟边界；没有对生产运行目录注入FS故障。不能冒称全部69项均在固件或所有真实失败路径跑过。
- 设备备份`/root/aether-proxy-before-t1510-20261109/`保留旧r6.t157包/配置/文件；本地回退与新包均留在证据目录。

细节/包SHA/辅助脚本诊断及安装警告如实保存在[实机验收](../validation/t15.10-h28k-20261109.md)，不为清日志再重复服务操作。

## 4. 必须保留的保证边界

1. 保护由**已有restart-intent**触发。失败restart遗留intent时，后续重试/respawn仍可继承；普通无intent respawn、opkg独立stop/start、首次接管不主动建同等保护。手动stop/禁用有意恢复系统resolver。更新流程对 aether-proxy 调用 `init restart`，属受保护路径，不计入“opkg独立stop/start”。
2. 不宣称零中断或所有协议/微秒均无泄漏。TPROXY readiness只查TCP；DNS按实际引用协议，正式DNS检查UDP/TCP。就绪不等于上游或端到端代理健康。
3. 非0不表示服务完全没停：固件仍继续kill/callback；不可写FS可能留intent/缺manual-stop标记，后续reload仍可能拉起。只是修错误可见性，不保证所有故障下持久停用。
4. 不向无法核实的历史私有PID自动发信号，不扩成pidfd/gate/全生命周期自动回收；私有停止的5秒判定也不是整个init stop的总时长。
5. **WSL＋NAT相关UDP观察已归档，具体归因未定；仅其他独立环境复现相同问题才再评估。** NAT600次中5超时、Windows原生/mirrored/Debian桥接各600/600成功。不能外推软件全无缺陷，也不再把NAT-only失败当常规组件验收阻断；TCP通过不能替代UDP功能测试。
6. WSL内部单元、loopback、受控集成仍有效。不擅自切mirrored、重启WSL、启动Docker/改Traefik或改全局网络。

## 5. 以后可以讨论，但没有冻结新卡

- ~~是否把H28K从本地验收包切到**CI正式r7**~~：**已完成**（2026-11-09 在线更新，证据见[P1验收](../validation/p1-h28k-r7-online-update-20261109.md)），不再是待办。
- M4-02组件逻辑命名/JSON兼容迁移，主要属于proxy：阶段1（`dns`权威键+`chinadns-ng`别名+`engine`）已合并`4fd78c5`，见[m4.md](../tasks/m4.md)；阶段2（LuCI展示、事件迁移）未出卡。不是全局字符串替换，且当前逻辑名仍可为chinadns-ng、实际运行路径可能是aether-dns，不代表引擎未生效。
- M4-03引擎独立semver：DNS制定自己的版本，proxy按具体引擎定义兼容最低值/范围；需先双项目约定，不能用chinadns日期最低值直接比较新semver。
- M4-06中断体验：旧“两次dnsmasq重启”已过时，现仅安装阶段一次；需先重估目标，不默认承诺零超时。
- 正式发版、本轮代码工作都已完成；以上backlog不自动阻挡收口，不借此再扩升级/respawn保护。

## 6. 资料与跨项目界面

初始化先读本文件与执行约定；其余资料按用户下一目标定位相关章节，不必一次加载全部历史卡、日志或重跑套件，动代码前仍须完成卡片必读。

优先读[执行约定](../tasks/README.md)、[ucode规范](../12-ucode.md)、[M15卡及状态](../tasks/m15.md)、[生命周期](../04-lifecycle.md)、[r6→T15.7固定审查底稿](../validation/r6-to-t15.7-cross-review-20261108.md)、[T15.10交接](../validation/t15.10-merged-cross-review-20261109.md)。历史分支报告已按规则从main移除，可`git show <tip>:reports/<card>.md`，不要因main无报告认定未验收。

DNS本体源码另由[DNS交接](../../../aether-dns/docs/handoffs/session-handoff-20261109.md)负责。**本轮r7不新增或发布aether-dns包，不需要重建它**；默认包依赖仍是aether-xray与chinadns-ng。

很多proxy原始证据因混合会话而放在**DNS仓库的忽略目录**，这只是存储位置，不代表DNS代码更新。不要迁移/删证据，也不要把跨仓库日志位置当作任意写另一仓库的许可：

```text
aether-dns/dist/logs/t1510-h28k-20261109/          # proxy构建/设备验收
aether-dns/dist/logs/release-0.6.3-r7-20261109/    # proxy发行、签名、14资产与CI记录
```

[首轮CI失败](../validation/0.6.3-r7-ci-preflight-20261109.md)已由T15.11解决；源码新旧两次结果不要混。实现者review与负责人独立review也是不同运行，WARN数按各自日志，不把源码脚本没有设置环境变量误解成外层调用不可能设置。

## 7. 测试资源（只有按需验证资格，不是自动任务）

VMware Debian 13：`leochien@192.168.139.130`，WSL既有密钥可SSH、sudo免密码；2CPU/约4GB、内核6.12.116、Python3.13、Bash/Dash/BusyBox ash。缺Git/gcc/make/Rust/tcpdump；本会话只读调查，未安装工具或跑功能测试。用户声明快照 **baseline-new-install-261109**，不等于已授权回滚/删除。NAT网关192.168.139.2，适合本地进程/信号/socket等特定验证，跨NAT UDP不单独判组件故障。安装依赖/持久配置/网络改动需另确认。

旧VirtualBox ag-t04-debian已被用户关闭、计划删除，**不再作为可用资源，不为核查持久化中断步骤而启动它**。桥接600/600只保留为历史对照。VMware不是该旧VM。

## 8. 新会话工作方式

- 只处理本项目。你负责有证据的设计、拆卡、复审、授权后的合并/交付；用户转发实现卡，不擅自派实现子智能体或代执行者写卡内生产代码。一次小卡收口后再下一项。
- 实现卡从本库`tests/start-task.sh`创建独立worktree；跨项目先给接口/影响清单并让用户明确分工，不默认改DNS或channel。不得清理用户未知文件或历史实验树，也不自动提交未知/用户未提交文件；遇到脏树先报告，不用ignore或clean绕过检查。长基线/CI使用足够预算或托管后台，120秒中断不算PASS，不重复启动仍在运行的同一任务。
- 没有新目标时先只读核对；不重复全套已验且未变测试，不盲目重跑碰绿、不放宽oracle。
- **不自行重启H28K/刷固件/动WAN接口；设备安装、服务窗口、回退均要新授权。** 当前会话归档不是永久设备操作许可。
- 原运行记录不等于新会话当前设备健康；需要现场结论时先获得对应授权再核对。

### 可粘贴入口

```text
本对话仅负责aether-proxy。
先读 @/workspace/openwrt/aether-proxy/docs/handoffs/session-handoff-20261109.md，再读本项目执行约定与ucode规范。
只读核对Git和发布身份，简要列当前状态与待决策项，然后等我指定下一目标。
不自动修改、测试、构建、推送或操作设备，不改aether-dns；沿用用户转发实现、你负责设计/复审的分工。
旧混合会话及其目标已结束，不恢复旧目标或重做r7发布。
```
