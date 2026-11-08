# WSL UDP/53 双端取证、mirrored 对照与回退（2026-11-08）

## 最终状态

**已按用户决定恢复原NAT。** `.wslconfig`原始字节SHA256恢复为`a9757a396b5a75464461d8c400e11ba71b77e7398fd36631e31924c5a7c0a560`，wslinfo报告nat，路由恢复经172.27.224.1/eth0、源172.27.228.101。pi-web与pi-web-ui均active。

H28K未重启，aether-proxy仍`0.6.3-r6.t157`、running/T1/bypass_cn；DNS/Xray PID14819/14707、配置哈希与设备boot ID均保持。本轮未改两个项目的生产代码、引擎、DNS策略或游戏模式。

**底层缺包没有根治。** mirrored下本次同负载未复现，但Docker Desktop/Traefik网络影响没有验证，不能据Ubuntu单项通过建议整体部署长期迁移。调查/变更窗口至此收口，不自动继续压力测试或修改NAT。

## 1. 固定范围和原基线

前置证据见[UDP/53范围及早期追查](t15.6-followup-20261108.md)。本事项仅指WSL向192.168.5.254 UDP/53发送DNS测试请求，不是游戏UDP代理转发或泛UDP吞吐问题。

- 当前未启游戏模式，UDP代理选择集为空。
- T1正式DNS上游是本机TCP31082/31083；客户端用UDP提交DNS，与代理是否转发普通UDP是不同配置面。
- 原接收侧抓包中多次超时请求未出现在H28K入口。本轮补齐发送侧，避免只凭接收侧缺包归责WSL或路由器。
- 测试仅使用带唯一标签的google.com随机子域名，NXDOMAIN为正常负回答，不以其判断直连。每轮普通用户新建UDP socket、约5qps、600请求、单请求最多等8秒；没有以重试掩盖首发缺包。

## 2. NAT模式双端结果

用户开启WSL工具管理员模式后，发送侧用Python AF_PACKET在实际路由接口eth0只记录本轮标签包，客户端仍为uid1000。H28K使用临时/tmp tcpdump，只捕获同标签UDP53/31053；没有安装包、加规则或启混杂模式。

| 指标 | 结果 |
|---|---:|
| 客户端请求 | 600 |
| 正常NXDOMAIN | 595 |
| 8秒超时 | 5 |
| 发送侧标签帧 | 1195（600请求＋595应答） |
| 两端抓包内核drop | 均0 |
| 5个失败请求的路径 | 全部只有sender_out；无H28K LAN/31053记录 |

595个成功请求均能对应发送、LAN请求、31053往返、LAN应答及客户端接收。5个失败请求在WSL eth0发送观察点可见，但H28K抓包入口不可见。

这将复现边界缩到WSL发送观察点之后、H28K入口观察点之前；不能再解释为Python没调用发送，或aether-dns/dnsmasq收到请求后处理超时。它仍不能单独区分Windows转发/NAT、vSwitch、主机过滤、物理链路或NIC在接收抓包点之前的丢弃。

首次抓包启动曾因MAC字节串写JSON失败，ready未生成、客户端未发查询；只修元信息序列化后开展上述正式一轮，初始化失败记录另外保存，没有计为网络丢包。

## 3. Windows原生对照

当前工具权限拒绝Windows原生执行，未通过WSL interop绕过；由用户在Windows PowerShell手动运行只发DNS请求、写结果的脚本，完整JSON已读取：

| 客户端 | 请求 | NXDOMAIN | 超时/异常 | 中位ms | p95 ms | 最大ms |
|---|---:|---:|---:|---:|---:|---:|
| WSL NAT | 600 | 595 | 5 | 150.88 | 167.17 | 8008.20 |
| 同主机Windows原生 | 600 | 600 | 0 | 152.59 | 167.00 | 379.13 |

WSL内部源地址为172.27.228.101；Windows原生源地址为192.168.5.10。NAT下H28K看到的成功WSL请求也来自192.168.5.10，但其UDP源端口被重写。相同主机LAN线路的原生对照通过，支持继续聚焦WSL专属主机转发路径；未精确定位到某个Windows内核模块，不宣称已证明WinNAT源码缺陷。

## 4. 经用户许可的mirrored试验

用户确认交叉审查结束、pi-web/pi-web-ui可停止、无运行任务，批准一次WSL重启窗口。操作在Windows侧手动完成：

- 原始配置仅有experimental/sparseVhd=false。
- 原文件校验后在Windows用户目录逐字节备份；只新增wsl2/networkingMode=mirrored，保留原字段。
- 用户执行wsl --shutdown并启动Ubuntu；这是所有WSL实例/进程的重启，不是H28K或Windows网络服务restart。
- wslinfo确认mirrored；路由变为eth1直达H28K、源192.168.5.10，两个原有systemd Web服务active。
- 完全相同的普通用户客户端代码再跑一轮；仅发送侧抓包接口按真实路由从eth0改为eth1，新nonce避免缓存。

| 指标 | mirrored结果 |
|---|---:|
| 请求/正常NXDOMAIN | 600/600 |
| 超时 | 0 |
| 发送侧标签帧 | 1200 |
| 两端抓包内核drop | 均0 |
| H28K所见源端口与WSL一致 | 600/600 |
| 中位/p95/最大 | 151.90/165.68/250.81ms |

所有600请求均可对应完整双端路径。相比NAT，源端口不再被重写，本轮前置缺包未复现。

这是一个可用的绕行候选证据，不是“永远零丢包”的保证。切换模式同时必然重启WSL，未通过多次NAT→mirrored→NAT负载回测剥离重启状态因素，也未修补或定位Windows内部源代码。为收敛和保护原环境，没有继续追加来回重启或更多端口测试。

## 5. 为什么不保留mirrored

用户补充：除Ubuntu外还有Docker Desktop的WSL实例，并部署Traefik做路由转发。

- `.wslconfig`不是Ubuntu单独的发行版配置，不能把它当成只影响这一份DNS测试。
- 当前只读列表中docker-desktop为Stopped，本轮没有验证Docker端口发布、Windows/LAN入口、Traefik后端地址/localhost假设等。
- Docker Desktop有独立网络实现，具体影响依版本与拓扑；不是断言一定不兼容，也不能据600/0承诺兼容。
- 因此此前“建议保留”被收回，用户选择恢复原NAT，避免把窄UDP诊断扩大成全局Docker/Traefik网络迁移。

参考：[微软WSL网络问题说明](https://learn.microsoft.com/en-us/windows/wsl/troubleshooting)、[Docker Engine 27版本修复记录](https://docs.docker.com/engine/release-notes/27/)。这些只说明存在需版本化评估的风险，不能代替本环境实际验收。

## 6. 回退核对

用户在Windows侧执行原始备份恢复脚本并再次重启WSL，随后仅做只读核对，无UDP负载：

- 原文件SHA256与切换前完全一致。
- nat模式、eth0/172.27.228.101、网关172.27.224.1恢复。
- pi-web、pi-web-ui均active；没有擅自启动Docker或测试Traefik。
- H28K boot ID始终`97edbacd-fd63-4a21-beb7-0cc59ac22b93`，PID、活动配置与运行版本未变。
- 临时抓包进程/路由器工具/目录已清理；未新增防火墙规则。
- 原备份和trial元数据保留在Windows用户目录；元数据的requested_mode描述历史试验，不是当前模式，当前以wslinfo和原哈希核对为准。
- 用户未跟踪的交叉审查结论文档未修改、未提交；两个项目生产源码没有改动。

## 7. 收口与后续边界

1. **已完成定位增强和可回退试验，不是完成底层UDP修复。** 当前仍保持NAT，不能宣布NAT缺包已消失；回退后没有重新发负载。
2. 不修改aether-proxy/aether-dns DNS策略来修主机路径问题，也不开游戏模式。
3. 日常组件验证可参考已通过的Windows原生/本机TCP路径，但仍保留首发UDP缺包记录，不把换测试入口当网络修复。
4. 若后续继续，需另定Windows出口/NAT取证或Docker/Traefik兼容迁移目标和窗口；不得由本轮自动扩展。
5. 既有r6→T15.7交叉审查底稿的固定源码范围不被本次环境实验改写。

## 原始证据（本机忽略目录）

```text
aether-dns/dist/logs/udp53-dual-20261108/
  before-mirrored.json / windows-native-queries.json / comparison-summary.json
  sender.pcap / router.pcap / sender-capture.json / queries.json
  packet-paths.json / summary.json / router-after.txt / cleanup.txt
  switch-wsl-mirrored.ps1 / restore-wsl-nat.ps1
  initialization-failure/
aether-dns/dist/logs/udp53-mirrored-20261108/
  environment-before.json / environment-after.json / rollback-state.json
  sender.pcap / router.pcap / queries.json / packet-paths.json / summary.json
  router-after.txt / cleanup.txt
```

原始pcap已核对两端文件哈希，正常对照与失败记录均保留；这些原始文件不会自动随aether-proxy克隆取得，也不提交设备配置或未脱敏日志到公开仓库。
