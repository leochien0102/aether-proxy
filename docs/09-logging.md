# 09 日志

## 原则

- **不自造日志文件**。人读的日志写 logd（`logread` 可见）；机器读的结构化事件写 tmpfs 环形文件。都不落 flash。
- syslog 行使用**英文**（沿用 helloworld 的分层约定：syslog 英文，界面本地化），中文只出现在 LuCI 中，
  由事件码翻译得到。
- 事件码是**机器协议**：一旦发布就不改名、不改含义，只能新增。

## 来源与标签

| 来源 | 写入方式 | syslog 标签 |
|---|---|---|
| aether-proxy / daemon | `logger -t aether-proxy -p daemon.<level>` 或等价调用 | `aether-proxy` |
| Xray | daemon 读取子进程的 stdout/stderr，逐行转发（实现方式见下方「子进程日志」） | `aether-proxy-xray` |
| chinadns-ng | 同上 | `aether-proxy-dns` |

Xray 的 access 日志固定关闭（隐私和 CPU 开销），error 日志等级由 `xray_log_level` 决定。chinadns-ng 不开 `-v`。

## 子进程日志

ucode 的 `uloop.process` 不支持重定向子进程的 stdio（2026-10-14 核实 `lib/uloop.c`），所以「逐行转发并打上各自标签」需要别的办法。候选方案在 M0 的探针任务 S1 中实测后选定，结论写回本节：

1. `fs.popen("echo $$; exec <bin> <args> 2>&1")`：第一行读出 pid（`exec` 不改变 pid），之后用 `uloop.handle` 监听管道逐行读取；退出由 EOF 加 `close()` 的返回值判断。
2. 启动命令改为 `sh -c '<bin> <args> 2>&1 | logger -t <标签>'`：实现最简单，但 pid 指向 sh，停止时要杀整个进程组。
3. 子进程直接继承 daemon 的 stdout，由 procd（`procd_set_param stdout 1`）收集：最省事，但所有输出共用一个标签。

## 等级

| aether-proxy 等级 | syslog 优先级 | 用于 |
|---|---|---|
| `error` | `err` | 功能受损：启动失败、故障放行、回滚 |
| `warn` | `warning` | 有降级但仍可用：DNS 降级、使用 LKG、订阅缩水 |
| `notice` | `notice` | 状态变化与用户操作：启停、切换节点、更新完成（**默认等级**） |
| `info` | `info` | 每个流程步骤 |
| `debug` | `debug` | 每轮检测结果、执行的外部命令及其退出码 |

## syslog 行格式

```
<EVENT_CODE> <英文描述> [k=v k=v ...]
```

示例：
```
aether-proxy: XRAY_DOWN_FAILOPEN xray not listening for 2 rounds, interception removed [port=31080]
aether-proxy: DNS_TIER_CHANGED trust upstream switched [from=T1 to=T2 reason=proxy_unhealthy]
aether-proxy: CMD_FAILED external command failed [cmd="nft -f /var/run/aether-proxy/aether-proxy.nft" rc=1 stderr="Error: ..."]
```

外部命令失败一律使用 `CMD_FAILED`，带上命令、退出码和 stderr 的第一行（截断到 200 字符）。

## 结构化事件

`notice` 及以上等级的事件同时追加到 `/var/run/aether-proxy/events.jsonl`，每行一个 JSON：

```json
{"ts":1760400000,"level":"warn","code":"DNS_TIER_CHANGED","args":{"from":"T1","to":"T2","reason":"proxy_unhealthy"}}
```

保留最近 500 行（超过时截掉前面的一半）。LuCI 的「事件」视图读取这个文件，按 `code` 套用中文模板显示，
例如 `DNS_TIER_CHANGED` → 「DNS 已从 {from} 切换到 {to}（原因：{reason}）」。

## 事件码目录（首版）

| 代码 | 等级 | 参数 |
|---|---|---|
| `SERVICE_STARTED` / `SERVICE_STOPPED` | notice | `mode`、`node` |
| `BUSY` | warn | `holder` |
| `CONFIG_INVALID` | error | `field`、`reason` |
| `PRECHECK_FAILED` | error | `missing` |
| `RENDER_INVALID` | error | `artifact`、`detail` |
| `START_FAILED` | error | `step`、`detail` |
| `NET_WAIT_TIMEOUT` | warn | `waited` |
| `COMPONENT_MISSING` / `COMPONENT_TOO_OLD` | error | `component`、`version`、`min` |
| `NODE_RESOLVE_FALLBACK` / `NODE_RESOLVE_FAILED` | warn / error | `node`、`domain`、`lkg_ip` |
| `NODE_IP_CHANGED` | notice | `node`、`old`、`new` |
| `NODE_STALE` / `NODE_STALE_IN_USE` | warn | `node`、`label` |
| `NODE_INSECURE_IGNORED` | warn | `node`、`label` |
| `PROXY_HEALTHY` / `PROXY_UNHEALTHY` | notice / warn | `latency_ms`、`fails` |
| `DNS_TIER_CHANGED` | warn（降级）/ notice（恢复） | `from`、`to`、`reason` |
| `XRAY_DOWN_FAILOPEN` / `XRAY_DOWN` / `XRAY_RECOVERED` | error / error / notice | `port` |
| `DNS_DOWN_FAILSAFE` / `DNS_RECOVERED` | error / notice | — |
| `NFT_TABLE_RESTORED` | warn | — |
| `DNSMASQ_CONFDIR_NOT_FOUND` / `DNSMASQ_EXTRA_SERVERS` | error / warn | `servers` |
| `IPV6_PRESENT` | warn | `iface` |
| `SUB_UPDATED` | notice | `sub`、`added`、`updated`、`stale`、`removed`、`skipped`（按原因计数的对象） |
| `SUB_FETCH_FAILED` / `SUB_DECODE_FAILED` / `SUB_FORMAT_UNSUPPORTED` / `SUB_APPLY_INVALID` / `SUB_PROXY_UNAVAILABLE` | error | `sub`、`detail` |
| `SUB_SHRANK` | warn | `sub`、`old`、`new` |
| `UPDATE_AVAILABLE` | notice | `component`、`current`、`latest` |
| `UPDATE_INSTALLED` / `UPDATE_VERIFY_FAILED` / `UPDATE_ROLLED_BACK` | notice / error / error | `component`、`version` |
| `DATA_UPDATED` | notice | `items` |
| `MANIFEST_BAD_SIGNATURE` | error | `url` |
| `NO_SPACE` / `ARCH_UNSUPPORTED` | error | `need`、`free` / `arch` |
| `CMD_FAILED` | error | `cmd`、`rc`、`stderr` |

新增事件码时同步修改本表、LuCI 的翻译模板和 po 文件。

## logd 容量

OpenWrt 默认的 logd 缓冲区只有 64KB，在 `debug` 等级下很快就会被冲掉。LuCI 日志页在等级为 `debug` 时提示：
「建议在 系统 → 日志 中调大缓冲区，排查完成后调回 notice」。aether-proxy 不修改 `system.@system[0].log_size`。

## LuCI 展示

- 「事件」页：读取 `events.jsonl`，按等级着色，支持按等级、事件码过滤。默认打开这一页。
- 「原始日志」页：`logread -e '^aether-proxy'` 的输出（需在 rpcd 中实现，不能让前端执行任意命令），可按 `aether-proxy` / `aether-proxy-xray` / `aether-proxy-dns` 过滤。
