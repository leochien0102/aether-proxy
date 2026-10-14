# ADR-0005 procd 只托管一个监督进程

- 状态：**已定**（2026-10-14）
- 背景：启动有严格顺序（chinadns-ng → dnsmasq → 解析节点 → Xray 监听 → nft）。procd 的多个实例在 `start_service` 返回后才统一启动，
  无法表达这种顺序。
- 决定：procd 只托管 `aether-proxy daemon`。由它按顺序启动、以子进程方式监督 Xray 和 chinadns-ng，并运行 monitor 循环。
  init 脚本的 `service_stopped` 执行幂等的 `aether-proxy cleanup` 兜底；daemon 每次启动时也先执行 cleanup。
- 后果：子进程的重启策略由 daemon 实现（退避），不使用 procd 的 respawn。daemon 自身的崩溃由 procd 重启，重启时 cleanup 会清掉残留状态。
