# 06 节点、订阅与 Xray 配置

## 订阅获取

- 下载工具：`curl --fail --silent --show-error --max-time 30 --max-filesize 5242880 -A <UA>`，写入 `/tmp/aether-proxy-dl/sub-<段名>`。
- `user_agent`、`fetch_via`、`interval_hours` 一律用**生效值**（单独设置 → `config sub` 通用设置 → 默认值，[05](05-config.md)「`config sub 'sub'`」，2026-10-22）。
- `fetch_via`：
  - `direct`：直接下载
  - `proxy`：**经当前节点**——追加 `-x http://127.0.0.1:31081`（本机 Xray 的 HTTP 入站），仅当 Xray 正在运行时可用，否则失败（`SUB_PROXY_UNAVAILABLE`）。不提供另填独立代理（2026-10-22 仓库所有者同意：订阅被墙时能用的代理就是自己的节点）
  - `auto`：先直连，失败后如果 Xray 在运行就经代理重试一次
- 以下情况都算**下载失败**，保留旧节点不动：HTTP 非 2xx、超时、内容为空、内容超过 5MB。

## 订阅解析

1. 去掉首尾空白。第一个非空行包含 `://` → 当作明文；否则做 Base64 解码（兼容标准与 URL-safe 两种字母表，填充可有可无）。
   解码失败 → **整体解析失败**（`SUB_DECODE_FAILED`）。
2. 内容以 `proxies:` 开头或含有 `\nproxies:` → `SUB_FORMAT_UNSUPPORTED`（Clash YAML，首版不支持）。
3. 按 `\r?\n` 切行，逐行解析 URI。每一行只会得到一个结果：一个节点，或一条跳过原因。
4. 解析结果中有效节点数为 0 → **整体失败**（`SUB_NO_VALID_NODES`），保留旧节点。≥ 1 → 继续，跳过的行按原因计数，写进事件 `SUB_UPDATED`。
5. 新的节点数少于旧节点数的 50%（且旧节点数 ≥ 4）→ 照常应用，同时记 WARN `SUB_SHRANK`。

跳过原因（固定枚举，LuCI 中翻译）：`unsupported_scheme`、`unsupported_transport`、`unsupported_security`、
`ss_plugin`、`vmess_alterid`、`ipv6_address`、`malformed`、`missing_field`、`duplicate`（同一次订阅内 strong 键重复，保留第一条）、
`insecure_transport`、`invalid_value`（节点取值违反 [05](05-config.md) 校验规则 7，即 Xray 会拒绝启动的节点）。

### URI 格式

所有查询参数值和 `#` 后的名称都要做 URL 解码。主机为 `[...]`（IPv6 字面量）→ `ipv6_address`。

**vless** `vless://<uuid>@<host>:<port>?<query>#<name>`

| 参数 | 节点字段 | 说明 |
|---|---|---|
| `type` | `transport` | `tcp`→`raw`；`ws`、`grpc`、`httpupgrade`、`xhttp`；`splithttp`→`xhttp`；其他（kcp、quic、h2）→ `unsupported_transport` |
| `security` | `security` | `none`／`tls`／`reality`，缺省为 `none`；其他 → `unsupported_security` |
| `encryption` | `encryption` | 缺省 `none` |
| `flow` | `flow` | |
| `sni`、`alpn`（逗号分隔）、`fp` | `sni`、`alpn`、`fingerprint` | |
| `pbk`、`sid`、`spx` | `reality_*` | |
| `host`、`path`、`serviceName`、`mode`、`headerType` | 对应字段 | |
| `pcs` | `pinned_cert_sha256` | |
| `vcn` | `verify_name` | |
| `allowInsecure` 或 `insecure` = `1`/`true` | — | 不支持（Xray 已移除）。照常导入，记 WARN `NODE_INSECURE_IGNORED`；证书不合法的节点会在健康检测中失败 |

**vmess** `vmess://<base64(JSON)>`（v2rayN 格式）

`ps`→label、`add`→address、`port`（字符串或数字）→port、`id`→uuid、`scy`→method（缺省 `auto`）、
`net`→transport（映射规则同 vless）、`type`→header_type、`host`、`path`、`tls`（`tls` 或空）→security、
`sni`、`alpn`、`fp`。`aid` 存在且不为 0 → `vmess_alterid`（Xray 已不支持旧版 alterId）。

**trojan** `trojan://<password>@<host>:<port>?<query>#<name>`

参数同 vless。`security` 缺省为 `tls`。

**shadowsocks**

- SIP002：`ss://<userinfo>@<host>:<port>[/][?plugin=…]#<name>`。`userinfo` 是 `base64url(method:password)`，
  或者是 URL 编码的 `method:password`（2022 系列加密常见）。
- 旧格式：`ss://<base64(method:password@host:port)>#<name>`。
- 有 `plugin` 参数 → `ss_plugin`（Xray 不支持 SIP003 插件）。
- `method` 不在 Xray 支持列表内 → `unsupported_security`。支持列表以目标 Xray 版本的文档为准，写成常量。

其他 scheme（`hysteria2`、`hy2`、`tuic`、`ssr`、`socks` 等）→ `unsupported_scheme`。

## 节点身份

节点 ID = UCI 段名 `n_<32位十六进制>`，首次落地时生成，之后不变。LuCI、日志、引用一律使用节点 ID，不用名称或序号。

匹配键（存在 `match_strong` / `match_weak` 字段中，**直接存下列拼接字符串本身，不做哈希**——凭据本来就在同一个配置文件里，哈希不带来保密性，还会引入 `ucode-mod-digest` 依赖；2026-10-15 决定）：

```
tdisc  = path + "|" + host + "|" + service_name
strong = protocol|lower(address)|port|transport|tdisc|security|sni|(uuid 或 password)
weak   = protocol|lower(address)|port|transport|tdisc
```

只用「地址＋端口」作为键是不够的：机场常有大量节点共用同一 `IP:443`，靠 path、SNI、UUID 区分。

**匹配算法**（只在**同一个订阅**的旧节点范围内匹配，手动节点不参与）：

1. strong 键相同且旧节点尚未被匹配 → 沿用旧 ID。
2. 剩余新节点：weak 键与**恰好一个**未匹配的旧节点相同，且该 weak 键在旧节点中唯一 → 沿用旧 ID（覆盖凭据轮换的情况）。
3. 剩余新节点：`protocol` 相同、`label` 完全相同、且只有一个未匹配的旧节点满足 → 沿用旧 ID（覆盖换 IP 的情况）。
4. 仍未匹配 → 生成新 ID。
5. 未被匹配的旧节点：被引用（首版只有 `main.node`）→ 保留并设 `stale=1`，记 WARN `NODE_STALE`；没有被引用 → 删除。
6. 原本 stale 的节点重新被匹配上 → 清除 `stale`。

沿用旧 ID 时，用新解析出的值**覆盖**节点的所有协议字段。

## 原子应用

一次 `sub update` 依次处理每个启用的订阅（指定段名时只处理那一个）；订阅之间互不影响，一个失败不阻止其他订阅。禁用的订阅不处理，也不出现在结果里；指定段名而该订阅被禁用时，结果为 `{ "ok": true, "disabled": true }`，不下载。唯一的例外：某个订阅成功替换配置后，重新读取配置失败（文件读不了或已不合法）——此时没有可靠的基线，**停止处理其余订阅**并报 `FS_FAILED`，留待下次。对每个订阅：

1. 下载（「订阅获取」）、解析（「订阅解析」）。同一次订阅内 strong 键重复的节点按跳过原因 `duplicate` 计数，保留第一条。
2. 用「节点身份」的算法与该订阅的旧节点（`source` 等于该订阅段名）匹配，在内存中算出完整变更：新增、修改、标记 stale、恢复（清除 stale）、删除。
   - 新节点 ID：`n_` 加 32 位小写十六进制，取自 `/dev/urandom` 的 16 字节，按 UUID v4 设置版本位与变体位（第 7 字节高 4 位为 `4`，第 9 字节高 2 位为 `10`），与现有段名重复时重新生成。
   - 沿用旧 ID 时，新节点有的协议字段覆盖写入，**新节点没有的协议字段从旧段中删除**（例如旧节点有 `flow`、新节点没有）。
     `label`、`source`、`match_strong`、`match_weak` 随之更新；`stale` 按匹配结果设置或删除。
   - 「被引用」的判断：首版只有 `main.node`。
3. **生成新配置文件**：把 `/etc/config/aetherproxy` 原样复制为 `/var/run/aether-proxy/sub-work/aetherproxy_sub`（**换一个包名**），
   用 ucode `uci.cursor('/var/run/aether-proxy/sub-work', '/var/run/aether-proxy/sub-work/.delta')` 对包 `aetherproxy_sub` 执行第 2 步的全部 add/set/delete 后 `commit`。
   任意一步失败 → 整体放弃（`SUB_APPLY_INVALID`）。不用 `uci` 命令行的 `batch`：值里可能有任意字符，经 shell 转义容易出错。
   **为什么换包名**：libuci 在创建上下文时就把默认的 `/tmp/.uci` 加进 delta 路径，设置 savedir 只是追加一个路径；`commit` 时会把**所有** delta 路径里同名包的未提交修改
   一起写进文件（libuci `delta.c` 的 `uci_load_delta`，`uci -t` 命令行同样如此）。所以「独立 savedir」挡不住 LuCI 里尚未保存的修改；换包名后 `/tmp/.uci` 中不会有它的 delta。
4. 当前节点（`main.node`）受影响时（字段变化；被标记 stale 不算变化），把生成的文件以包名 `aetherproxy` 放进另一个临时 confdir，用它走完整渲染加 `xray run -test`。
   失败 → 整体放弃该订阅，保留旧节点（`SUB_APPLY_INVALID`）。
5. **替换**：重新读取 `/etc/config/aetherproxy`，与第 3 步复制时的内容比较。不同（期间有人提交了配置）→ 放弃本次（`SUB_APPLY_INVALID`，`detail` 写明是并发修改），
   等下次更新；相同 → 用 `sys.write_atomic` 写入。用户在 LuCI 中未提交的修改仍留在 `/tmp/.uci`，之后照常叠加在新文件之上。
6. 替换成功后，当前节点的字段发生了变化且服务在运行（`state.json` 的 `state` 为 `starting`/`running`/`degraded`）→ 执行 `/etc/init.d/aether-proxy reload`。
   执行前先释放订阅锁（见下），避免与 reload 中的 `check` 相互等待。
7. 订阅状态写入 `/etc/aether-proxy/state/sub.json`（值变化时才写）。它只是状态记录：内容损坏时记 `FS_FAILED` 并当作空记录重新开始，不阻止更新；
   读不了（I/O 错误）时记 `FS_FAILED`，本次不做任何更新；配置已替换后写状态失败，记 `FS_FAILED`、退出码 1，配置保留。
   第 6 步的 reload 失败不回滚配置（新文件已通过 `xray run -test`），结果里报告失败，daemon 继续运行旧的渲染结果直到下一次 reload。格式：`{ "<段名>": { "last_attempt": <时间>, "last_ok": <时间>|null, "nodes": <数量>, "skipped": { <原因>: <数量> }, "error": <事件码>|null } }`。

**互斥**：`sub update` 使用独立的锁 `/var/lock/aether-proxy-sub.lock`（非阻塞，拿不到 → 退出码 3，`BUSY`），不使用 daemon 的全局锁——
它只改 UCI，不直接改系统状态；系统状态的变化统一经 reload 交给 daemon。

**命令**：`aether-proxy sub update [<段名>] [--json]`，同步执行；支持 10「仅供测试的选项」中的 `--confdir`、`--run-dir`、`--sys-root`、`--bin-dir`。
退出码：全部订阅成功 0；任一订阅失败 1；段名不存在或不是 `subscription` 段 2；拿不到锁 3。
`--json` 输出 `{ "ok": <bool>, "subs": { "<段名>": { "ok": <bool>, "code": <事件码>|null, "added": n, "updated": n, "stale": n, "revived": n, "removed": n, "skipped": {…} } } }`。

**删除订阅**（2026-10-16 定）：同时删除该订阅的节点，被 `main.node` 引用的节点保留并改为 `source manual`（不然它会指向一个不存在的订阅）。由 LuCI 订阅页执行（[10](10-cli-luci.md)「订阅页」）。

## 调度

订阅不使用 cron。daemon 内部计时：每个订阅按 `interval_hours` 加 0–10% 的随机抖动执行；手动更新通过
`aether-proxy sub update [<段名>]` 触发。执行时以子进程方式运行，不阻塞 monitor 循环（[10](10-cli-luci.md) 作业机制）。
aether-proxy 未运行时不做自动更新。

细节（2026-10-15 定，T6.3）：

- daemon 进入 monitor 阶段后另起一个 60 秒的 uloop 定时器检查是否到期，不放进 monitor 的一轮里。
- 每个启用且 `interval_hours > 0` 的订阅：到期时间 = `sub.json` 中该订阅的 `last_attempt`（没有就视为 daemon 启动时刻）+ `interval_hours × 3600 × (1 + 抖动)`，
  抖动在 daemon 启动时为每个订阅取一次 `[0, 0.1)` 的随机数（`/dev/urandom`），之后不变。
- 到期 → 执行 `aether-proxy job start sub update <段名>`（经 `sys.run`，立即返回）；退出码 3（已有订阅作业在跑）→ 本轮跳过，下一分钟再看。
  同一分钟内只发起一个订阅的作业，按段名排序取第一个到期的。
- 以 `last_attempt` 而不是 `last_ok` 计时：下载失败也要等满一个周期再试，避免对机场频繁重试。
- daemon 不在 `running`/`degraded`（例如 `failsafe`、`error`）时不发起。
- `sub.json` 损坏，或某个订阅的记录、`last_attempt` 格式不对：按「没有记录」处理（以 daemon 启动时刻计时），与 `sub update` 的处理一致；损坏只记一次 `FS_FAILED`，不每分钟重复。
  读 `/dev/urandom` 失败时抖动取 0，照常调度。

## Xray 配置渲染

渲染产物 `/var/run/aether-proxy/xray.json`。字段名以**设备上实际运行的 Xray 版本**为准，下面按新版文档（`tunnel` 协议，
旧称 `dokodemo-door`）书写。aether-proxy 管理的 Xray 有最低版本要求（写成常量 `XRAY_MIN_VERSION`），
低于最低版本时 start 失败（`COMPONENT_TOO_OLD`）。**最低版本取 Xray 的最新正式版**（GitHub 未标 prerelease 的最新 release，2026-10-15 为 26.3.27），
渲染只用该版本认识的写法：绝大多数服务端跑的是正式版或更旧的版本，新的 prerelease 会在一段时间内兼容旧写法（2026-10-15 决定，取代此前的「一律新版命名」）。

```json
{
  "log": { "loglevel": "{{xray_log_level}}", "access": "none" },
  "inbounds": [
    {
      "tag": "tproxy-in", "listen": "0.0.0.0", "port": 31080, "protocol": "tunnel",
      "settings": { "network": "tcp,udp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy" } },
      "sniffing": { "enabled": {{sniffing}}, "destOverride": ["http", "tls", "quic"], "routeOnly": false }
    },
    {
      "tag": "dns-in-0", "listen": "127.0.0.1", "port": 31082, "protocol": "tunnel",
      "settings": { "address": "{{trust_dns[0]}}", "port": 53, "network": "tcp" }
    },
    {
      "tag": "dns-in-1", "listen": "127.0.0.1", "port": 31083, "protocol": "tunnel",
      "settings": { "address": "{{trust_dns[1] 或 trust_dns[0]}}", "port": 53, "network": "tcp" }
    },
    { "tag": "http-in", "listen": "127.0.0.1", "port": 31081, "protocol": "http", "settings": {} }
  ],
  "outbounds": [
    {{proxy_outbound}},
    { "tag": "direct", "protocol": "freedom" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "inboundTag": ["tproxy-in", "dns-in-0", "dns-in-1", "http-in"], "outboundTag": "proxy" }
    ]
  }
}
```

- 不打包、不加载 `geoip.dat` / `geosite.dat`：路由决策全部在 nft 中完成，Xray 只负责转发。
- `direct` 出站目前没有用到，保留给将来的分流功能。
- 节点不可用（解析失败）时不渲染 Xray 配置，也不启动 Xray（[04](04-lifecycle.md)）。

### 出站映射

`address` 填**引导解析得到的 IP**（[03](03-dns.md)）；没有解析结果时（例如 `check` 命令不做解析）填节点原始的 `address`。原始域名用于 `sni` 缺省值和 `host` 缺省值。

| 节点字段 | Xray 位置 |
|---|---|
| vless | `settings = {address, port, id: uuid, encryption, flow}` |
| vmess | `settings = {address, port, id: uuid, security: method}` |
| trojan | `settings = {address, port, password}` |
| shadowsocks | `settings = {address, port, method, password}` |
| transport | `streamSettings.network` |
| ws | `wsSettings = {path, host}` |
| httpupgrade | `httpupgradeSettings = {path, host}` |
| xhttp | `xhttpSettings = {path, host, mode}` |
| grpc | `grpcSettings = {serviceName}` |
| raw + header_type=http | `rawSettings.header = {type: "http"}` |
| security=tls | `tlsSettings = {serverName: sni 或原始域名, alpn, fingerprint, pinnedPeerCertSha256, verifyPeerCertByName}`（后两个为空时不输出） |
| security=reality | `realitySettings = {serverName: sni, fingerprint（缺省 chrome）, publicKey: reality_pbk, shortId: reality_sid, spiderX: reality_spx}` |

- 已在 Xray v26.9.30 源码核实（2026-10-14）：`tunnel` 协议及 `rewriteAddress` / `rewritePort` / `allowedNetwork` / `followRedirect` 字段存在，旧名 `dokodemo-door` 和旧字段 `address` / `port` / `network` 仍被接受；`raw` 与 `tcp` 等价；`rawSettings`、`xhttpSettings` 存在；四种出站（VLESS、VMess、Trojan、Shadowsocks）都接受扁平写法（`address`/`port`/`id` 或 `password` 直接写在 `settings` 中）；`streamSettings` 中 `method` 与 `network` 等价（源码中 `method` 覆盖 `network`），ssr-plus 自 Xray 26.7.11 起改用 `method`。
- ~~一律使用新版命名~~（2026-10-15 上午的决定，同日下午改为按最新正式版书写）。现行规则：入站协议名用 `tunnel`、字段用 **`address` / `port` / `network`**（26.3.27 没有 `rewrite*` / `allowedNetwork`）；
  出站用扁平写法；`streamSettings` 用 **`network`**（26.3.27 没有 `method`）；传输名用 `raw`。
- 已在源码核实（2026-10-15，S7）：26.3.27 认识 `tunnel` 协议名、扁平出站、`pinnedPeerCertSha256`、`verifyPeerCertByName`、`raw`、`serviceName`；
  26.9.30 与 26.10.10 仍接受 `address`/`port`/`network`（`dokodemo.go` 中原样映射到 `rewrite*` / `allowedNetwork`）和 `streamSettings.network`。
  **注意**：Xray 忽略不认识的字段，用旧版本跑 `run -test` 能通过并不说明字段被识别——26.3.27 遇到 `rewriteAddress` 会让 DNS 隧道没有上游，遇到 `method` 会让 ws/grpc/xhttp 节点退回 raw，`run -test` 都照样通过。
  因此 CI 对最低版本与最新版本各跑一遍 golden，且新增字段前要对照最低版本的源码。
- Xray 升级可能再次移除字段。渲染器只输出本文档列出的字段；CI 的 golden 测试用清单中的**当前** Xray 版本执行 `run -test`，升级 Xray 前必须先让这一步通过。
- 渲染器的正确性以 golden 测试为准（[11](11-plan.md)）：每种协议 × 传输 × 安全层的组合至少一个夹具，
  并且在 CI 中用真实的 Xray 二进制执行 `xray run -test` 验证。
