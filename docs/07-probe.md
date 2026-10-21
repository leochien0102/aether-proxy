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

实现细节（2026-10-16 定，T8.5）：
- 开始时读取现有 `probe.json`（不存在或损坏 → 空），保留其中**仍在配置里**的节点结果，先写一次：`at` 为开始时间、`done: 0`、`total: <本次检测数>`、`finished: false`、
  `pending: [<本次要检测、尚未完成的段名>]`（新增字段，「检测中」由它判断）。
- 每个节点完成（3 次连接都结束，或解析失败）就把它的结果放进 `nodes`、`done` 加 1、从 `pending` 移除，并写一次文件；全部完成后最后一次写入 `finished: true`、`at` 更新为完成时间。
  `lib/probe.uc` 的 `probe_nodes` 增加一个回调参数，在每个节点完成时调用，写文件由 `cmd/probe.uc` 负责。
- 只检测部分节点时，其他节点的旧结果原样保留（之前的实现会整体覆盖，属于缺陷）。
- `probe nodes --json` 的输出为最后一次写入的完整内容。
- **`probe results`**：只读，输出 `probe.json` 的内容并加上 `"ok": true`（两种情况返回形状一致）；文件不存在或损坏 → `{ "ok": true, "at": null, "nodes": {}, "done": 0, "total": 0, "finished": true, "pending": [] }`，不记事件（前端会频繁轮询）。

实现：ucode `socket` 模块，非阻塞 connect 加 poll，用单调时钟计时。不准用 `curl telnet://` 之类的替代品，它们的计时含义不准确。

## 代理健康检测（daemon 内部）

- 请求：`curl --silent --output /dev/null --write-out '%{http_code} %{time_total}' --max-time <timeout> -x http://127.0.0.1:31081 <url>`
- 成功条件：HTTP 状态码等于 `expect_code`。
- 连续失败 `fail_threshold` 次 → 判为不健康；连续成功 `recover_threshold` 次 → 判为健康（滞回，避免状态抖动）。
- 结果写入 `state.json` 的 `last_probe`。每次判定**发生变化**时记事件（`PROXY_UNHEALTHY` / `PROXY_HEALTHY`），
  每一轮的结果只在 `debug` 等级记录。
- 请求经 Xray 发出，域名由节点在远端解析，不依赖本地 DNS 级别。所以无论当前处于 T1、T2 还是 T3，
  这个检测都能独立判断节点是否可用。

## 真实延迟（`aether-proxy probe url <站点>`，2026-10-21 定，r9 窗口）

概览页「检测真实延迟」用：经当前节点请求一个**预设站点**一次，只报告耗时。与上一节的健康检测**互不影响**——不改 `last_probe`、不计入滞回计数、不记事件、不影响 DNS 级别与服务状态。

- 预设站点（写在 `const.uc`，只能从中选，不接受任意地址）：

  | 名称 | 显示名 | 地址 |
  |---|---|---|
  | `google` | Google | `https://www.gstatic.com/generate_204` |
  | `cloudflare` | Cloudflare | `https://cp.cloudflare.com/generate_204` |
  | `apple` | Apple | `https://captive.apple.com/hotspot-detect.html` |
  | `youtube` | YouTube | `https://www.youtube.com/generate_204` |
  | `github` | GitHub | `https://github.com/robots.txt` |

  `probe sites` 输出 `{ "ok": true, "sites": [ { "name", "label", "url" }, … ] }`（按上表顺序，第一项为默认）。
- 请求与健康检测相同（`curl … -x http://127.0.0.1:31081`，超时 `probe.timeout`），但取 `%{http_code} %{time_starttransfer}`：耗时按**收到响应头**计，不同站点的响应体大小不影响结果。
- 成功：HTTP 状态码 200–399 → `{ "ok": true, "site", "url", "code", "latency_ms" }`（毫秒取整）。
  失败：超时 → `{ "ok": false, "code": "PROBE_TIMEOUT", "site" }`；连接失败或状态码不在范围内 → `{ "ok": false, "code": "PROBE_FAILED", "site", "http_code", "detail" }`；退出码 1，都不记事件（`PROBE_TIMEOUT`、`PROBE_FAILED` 是结果码，同 `JOB_NOT_FOUND`，不进 09 的事件码目录）。
  站点名不在表中 → `USAGE`（退出码 2）。服务不在 `running`/`degraded` → `NOT_RUNNING`（退出码 1；`failsafe` 时代理不可用，同样 `NOT_RUNNING`）。
- 一次只请求一次，不重试：它测的是用户点下去那一刻的延迟。
- 只读 `state.json` 判断服务状态，不写；配置无效（读 `probe.timeout` 时）→ `CONFIG_INVALID`，退出码 2，不发请求、不记事件（2026-10-21 T9.10 复核定）。

## 首版明确不做

- 多节点自动切换（检测结果只展示）。
- 对非当前节点做端到端检测。将来的做法：临时生成一份只含该节点的 Xray 配置，由另一个 Xray 进程监听随机本地端口执行，
  `probe.json` 的结构已经为这一点留好了扩展字段（新增 `e2e_ms` 字段即可，不改动现有字段）。
