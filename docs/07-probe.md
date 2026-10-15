# 07 检测

两类检测，**用途不同，不要混用**：

| | 节点可达性检测 | 代理健康检测 |
|---|---|---|
| 对象 | 任意节点（含非当前节点） | 只测当前节点，端到端 |
| 方法 | TCP 连接节点 `IP:port` | 经 Xray 的 HTTP 入站请求 `probe.url` |
| 能发现 | 端口不通、IP 失效、延迟 | 鉴权失败、握手被干扰、节点出口不通 |
| 发现不了 | 握手被干扰、鉴权、CDN 节点（端口永远通） | — |
| 触发 | 手动（LuCI 按钮）、订阅更新后 | daemon 的 monitor 循环 |
| 结果用途 | 仅展示 | 驱动状态切换与 DNS 级别 |

LuCI 中节点检测的列名叫「**TCP 可达**／延迟」，不要写成「可用」。某些网络下会出现「端口能连上、TLS 握手却间歇失败」
的问题，节点检测会显示正常，只有代理健康检测能发现。

## 节点可达性检测（`aether-proxy probe nodes [<节点ID>...]`）

1. 解析地址：域名经系统解析器（会落到 chinadns-ng 的 `boot` 组）；aether-proxy 未运行时由 `resolveip` 走用户原有的 DNS。
   解析失败 → 结果 `resolve_failed`。
2. 对每个节点建立 3 次 TCP 连接，每次超时 `node_timeout` 秒，记录每次的连接耗时（从 connect 发起到建立完成）。
   连接建立后立即关闭，**不发送任何数据**。
3. 并发上限 `node_concurrency`（默认 8）。
4. 结果写入 `/var/run/aether-proxy/probe.json`：

```json
{
  "at": 1760400000,
  "nodes": {
    "n_xxx": { "ip": "203.0.113.10", "ok": 3, "fail": 0, "min_ms": 41, "median_ms": 44, "error": null }
  }
}
```

`error` 枚举：`resolve_failed`、`timeout`、`refused`、`unreachable`、`other`。

**逐个出结果**（2026-10-15 定，M8 节点页面需要；以后单独拆卡，不在 T6.1/T6.2 范围内）：检测仍然并发进行，但**每完成一个节点就写一次** `probe.json`（经 `sys.write_atomic`），
顶层增加 `"done": <已完成数>, "total": <总数>, "finished": false|true`，最后一次写入时 `finished: true`。前端经作业轮询（1–2 秒一次）读取，结果陆续填进列表并显示进度。
理由：从前端逐个或分批发请求，要么慢（串行累加），要么观感是一批一批跳出来；后端并发加增量写入，速度和观感兼得。未完成的节点保持上一次的结果，标记为检测中。

实现：ucode `socket` 模块，非阻塞 connect 加 poll，用单调时钟计时。不准用 `curl telnet://` 之类的替代品，它们的计时含义不准确。

## 代理健康检测（daemon 内部）

- 请求：`curl --silent --output /dev/null --write-out '%{http_code} %{time_total}' --max-time <timeout> -x http://127.0.0.1:31081 <url>`
- 成功条件：HTTP 状态码等于 `expect_code`。
- 连续失败 `fail_threshold` 次 → 判为不健康；连续成功 `recover_threshold` 次 → 判为健康（滞回，避免状态抖动）。
- 结果写入 `state.json` 的 `last_probe`。每次判定**发生变化**时记事件（`PROXY_UNHEALTHY` / `PROXY_HEALTHY`），
  每一轮的结果只在 `debug` 等级记录。
- 请求经 Xray 发出，域名由节点在远端解析，不依赖本地 DNS 级别。所以无论当前处于 T1、T2 还是 T3，
  这个检测都能独立判断节点是否可用。

## 首版明确不做

- 多节点自动切换（检测结果只展示）。
- 对非当前节点做端到端检测。将来的做法：临时生成一份只含该节点的 Xray 配置，由另一个 Xray 进程监听随机本地端口执行，
  `probe.json` 的结构已经为这一点留好了扩展字段（新增 `e2e_ms` 字段即可，不改动现有字段）。
