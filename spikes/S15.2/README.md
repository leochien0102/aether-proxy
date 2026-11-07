# S15.2 本地启动 DNS 探针

依据 `docs/tasks/m15.md`（633d74b）。仅设计实验，不是生产实现、真机验收或 DNS 库。

## 复现

在本卡 worktree 根目录：

```sh
bash spikes/S15.2/run.sh
```

依赖已初始化的 `tests/host/ucode`、Bash、Python 3.11+ 标准库。无需 root、网络下载、真实上游或系统配置。
入口运行正常 A/B 对照、三个应失败的变异、恢复后正常复跑；任一正常断言失败或变异未被指定断言杀死，入口非零。
`evidence/` 每次覆盖，是可提交的原始记录；端口、PID、绝对单调时间随运行变化，判定不比较这些不稳定值。

- `probe.py`：自写 DNS A 报文、真实 loopback TCP/UDP 假上游及中继；不复制生产模块。
- `evidence/{normal,restored}.log`：逐项断言。
- `evidence/*.jsonl`：`case` 关联 P 编号，`time_ns` 为本机 monotonic ns；`send/receive` 含 qname、协议、真实目标。
  `listen` 将动态端口映射到角色，`gate_open` 标记实际门禁开放；`production_render` 留存真实纯渲染器输出。
- `evidence/{tproxy-only,closed-handoff,client-leak}.log`：预期 AssertionError，不能仅凭非零退出算反向验证成功。

## 隔离和取证

全部绑定 127.0.0.1 的内核分配端口。角色 `formal/old-31053`、`tproxy-31080`、`*-31082/31083`
是生产常量的映射，不占生产端口。关闭的旧 handoff 端点实际执行查询并验证无响应，不凭文件内容推定网络失败。
来源 IP 分别为 china `192.0.2.11`、direct `192.0.2.22`、tunnel `192.0.2.82`，不是实际外网 DNS。
P4 调用真实 `render/chinadns.uc`，给 `wan_dns` 注入本地上游，验证 WAN 展开和开关选择；没有运行 ubus。
P5 读取真实渲染结果验证一项/两项 trust 引用，再用映射的 socket 验证等待顺序。
P6 启动本脚本独立 worker，真正发送 SIGTERM、wait 回收，验证 socket 可重新 bind、临时文件消失、handoff 字节不变。
临时目录仅位于本目录，正常和异常路径均由 finally / TemporaryDirectory 收口。

A：直接向选择的假上游查询节点；B：增加独立 loopback bootstrap 中继，仅显式节点查询使用它，普通客户端从不切过去。
普通客户端正式链路为假 formal DNS → 假 Xray DNS tunnel；启动未就绪时旧链路超时是允许结果。

## 证据边界

- 真实的是本机 socket bind、DNS 报文、TCP framing、UDP 收发、到达时序和进程信号。
- 上游仅 UDP/TCP IPv4 A 的受控应答；不是通用解析器：未实现 CNAME、TLS、恶意报文全校验、多上游并发等。
  不能把本脚本的末四字节解析用于生产。完整接口要求见设计文档。
- B 的中继模拟隔离拓扑，不代表真实 chinadns-ng 接受了 bootstrap 配置；未运行真实 Xray、chinadns、dnsmasq、nft、procd。
- 门禁在实验里使用 DNS 往返，强于只看 socket；生产建议检查引用端口的 TCP/UDP socket，不能把外网回答成功当成启动必需条件。
- P3 的 fail_open 和 P7 的 handoff/intent 是显式文件/策略模型；生产语义依据现有源码/测试，而非本模型自行证明。
- 无系统 resolver 调用；来源断言通过“bootstrap 收到的真实 qname 不含普通客户端名”判泄漏，不能由 NOERROR/NXDOMAIN 判来源。
- 首次 start 没有旧 handoff 的窗口没有隐私连续性保证；显式 stop 后也恢复系统语义。未承诺所有窗口零超时。
