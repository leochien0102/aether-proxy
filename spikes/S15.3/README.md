# S15.3 真实 bootstrap 引擎契约

入口（在本卡 worktree 内）：

```sh
bash spikes/S15.3/run.sh
```

只执行本地探针，不运行生产服务。依赖 Linux `/proc`、Python 3、openssl、离线 Cargo 缓存与
`tests/host/ucode`（start-task 已构建）。默认读取两个既有来源：

- `/workspace/openwrt/aether-dns`：只读 `git archive a3d42a2…`，在 `.build/source/` 内
  `cargo build --release --locked --offline`；校验 M4-01 的 `325b614` 是祖先。
- `/workspace/openwrt/ci-spike/tools/chinadns-ng-2025.08.09/chinadns-ng`：校验本仓库包定义的 SHA256。

缺失依赖会输出双引擎 E1–E10 BLOCKED 并退出 2，不下载、不安装、不写来源仓库。
第三方源码快照及构建产物留在忽略的 `.build/`，不进入提交。

## 文件与证据

- `probe.py`：仅 A/IN 的受控终端 authority（UDP/TCP/TLS），显式 loopback 查询器，
  真实引擎 child、PID/socket inode 归属验证与清理。Python **不是被测 DNS 转发器**。
- `suite.py`：正常运行 → 两种变异各按两个引擎执行 → 恢复运行。
- `evidence/provenance.txt`：来源、版本、架构、SHA256、大小。
- `evidence/{normal,restored}.jsonl`：每次各 268 条断言；E1–E10 矩阵、配置、PID、
  child 完整日志、报文来源和单调时间（`t`，秒）。
- `evidence/{closed-formal,impostor}-<engine>.jsonl`：变异及清理；对应 `.exit` 是实际退出码，
  `.stderr` 是预期 AssertionError 的 traceback；正常 `.stderr` 为空。
- `evidence/entry.log`：统一入口的 44 条分类输出（20 正常 + 4 反向验证 + 20 恢复）。
- `evidence/build.log`：离线构建结果。

原始证据覆盖每次运行，复跑会更新动态 PID、端点、时间；不可并行运行统一入口（共享证据和 runtime fixture）。
两 child 并存由 E8/E9 在一次运行内验证。不要在证据目录放置凭据。

## 隔离与边界

所有监听均 literal `127.0.0.1`，动态端口排除 53/31053/31082/31083。端口先选后 bind 有竞争，
以真实 child 失败、PID 所属 socket 和明确应答判断，不能把占位者当成就绪。
Python audit hook 禁止调用系统 getaddrinfo、禁止访问非私有端点、限制外部命令为引擎、renderer 和 openssl。
这不是对子进程进行 syscall 沙箱或抓全量网络包；通过明确的 literal 上游配置与实际 authority 收包证明路径。
没有运行 nft、ip、dnsmasq、init、ubus 等命令，不操作宿主系统配置。

E4 对无 scheme 的 `127.0.0.1#动态端口` 做真实查询；对无 `#port` 的 `127.0.0.1` 只测启动接受，
不向宿主 53 发包。默认 53 的网络可达性未测试，不将其等同于默认端口查询通过。
chinadns-ng 的非 TLS host@IP 是实际拒绝（子项 UNSUPPORTED），E4 PASS 表示接受/拒绝契约均符合实测，
不表示所有语法都能解析。aether-dns 的 E6 为 UNSUPPORTED，不降级协议。
回退引擎 TLS 使用临时自签证书，默认不校验证书；测试握手、SNI 和查询，不证明 PKI 验证能力。

只有调用方发送的节点域名进入 bootstrap；不发布到 handoff **不是域名 ACL**。
没有实现 TC/CNAME/坏报文的完整 resolver，没有验证生产启动编排或设备。

详见 `docs/validation/s15.3-real-bootstrap-contract.md` 和 `reports/S15.3.md`。
