# 06 节点、订阅与 Xray 配置

## 订阅获取

- 下载工具：`curl --fail --silent --show-error --max-time 30 --max-filesize 5242880 -A <UA>`，写入 `/tmp/aether-proxy-dl/sub-<段名>`。
- `fetch_via`：
  - `direct`：直接下载
  - `proxy`：追加 `-x http://127.0.0.1:31081`，仅当 Xray 正在运行时可用，否则失败（`SUB_PROXY_UNAVAILABLE`）
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

1. 在内存中算出完整的变更（新增、修改、标记 stale、删除）。
2. 对新的当前节点（如果有变化）做一次 Xray 渲染加 `xray run -test`，失败 → 整体放弃，保留旧节点（`SUB_APPLY_INVALID`）。
3. 用**独立的 savedir** 写 UCI：`uci -t /var/run/aether-proxy/uci-save batch` + `uci -t … commit aetherproxy`。
   不能用默认 savedir，否则会把用户在 LuCI 里尚未保存的修改一起提交。
   batch 中任意一条失败 → `uci -t … revert aetherproxy`，整体放弃。
4. 提交成功后，如果当前节点的字段发生了变化 → `/etc/init.d/aether-proxy reload`。
5. 订阅状态（最后成功时间、节点数、跳过计数）写入 `/etc/aether-proxy/state/sub.json`（值变化时才写）。

## 调度

订阅不使用 cron。daemon 内部计时：每个订阅按 `interval_hours` 加 0–10% 的随机抖动执行；手动更新通过
`aether-proxy sub update [<段名>]` 触发。执行时以子进程方式运行，不阻塞 monitor 循环（[10](10-cli-luci.md) 作业机制）。
aether-proxy 未运行时不做自动更新。

## Xray 配置渲染

渲染产物 `/var/run/aether-proxy/xray.json`。字段名以**设备上实际运行的 Xray 版本**为准，下面按新版文档（`tunnel` 协议，
旧称 `dokodemo-door`）书写。aether-proxy 管理的 Xray 有最低版本要求（写成常量，首版定为实现时 helloworld 中的版本 26.9.30），
低于最低版本时 start 失败（`COMPONENT_TOO_OLD`）。

```json
{
  "log": { "loglevel": "{{xray_log_level}}", "access": "none" },
  "inbounds": [
    {
      "tag": "tproxy-in", "listen": "0.0.0.0", "port": 31080, "protocol": "tunnel",
      "settings": { "allowedNetwork": "tcp,udp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy" } },
      "sniffing": { "enabled": {{sniffing}}, "destOverride": ["http", "tls", "quic"], "routeOnly": false }
    },
    {
      "tag": "dns-in-0", "listen": "127.0.0.1", "port": 31082, "protocol": "tunnel",
      "settings": { "rewriteAddress": "{{trust_dns[0]}}", "rewritePort": 53, "allowedNetwork": "tcp" }
    },
    {
      "tag": "dns-in-1", "listen": "127.0.0.1", "port": 31083, "protocol": "tunnel",
      "settings": { "rewriteAddress": "{{trust_dns[1] 或 trust_dns[0]}}", "rewritePort": 53, "allowedNetwork": "tcp" }
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
| transport | `streamSettings.method` |
| ws | `wsSettings = {path, host}` |
| httpupgrade | `httpupgradeSettings = {path, host}` |
| xhttp | `xhttpSettings = {path, host, mode}` |
| grpc | `grpcSettings = {serviceName}` |
| raw + header_type=http | `rawSettings.header = {type: "http"}` |
| security=tls | `tlsSettings = {serverName: sni 或原始域名, alpn, fingerprint, pinnedPeerCertSha256, verifyPeerCertByName}`（后两个为空时不输出） |
| security=reality | `realitySettings = {serverName: sni, fingerprint（缺省 chrome）, publicKey: reality_pbk, shortId: reality_sid, spiderX: reality_spx}` |

- 已在 Xray v26.9.30 源码核实（2026-10-14）：`tunnel` 协议及 `rewriteAddress` / `rewritePort` / `allowedNetwork` / `followRedirect` 字段存在，旧名 `dokodemo-door` 和旧字段 `address` / `port` / `network` 仍被接受；`raw` 与 `tcp` 等价；`rawSettings`、`xhttpSettings` 存在；四种出站（VLESS、VMess、Trojan、Shadowsocks）都接受扁平写法（`address`/`port`/`id` 或 `password` 直接写在 `settings` 中）；`streamSettings` 中 `method` 与 `network` 等价（源码中 `method` 覆盖 `network`），ssr-plus 自 Xray 26.7.11 起改用 `method`。
- **一律使用新版命名**（2026-10-15 决定）：入站用 `tunnel` 及 `rewrite*` 字段，出站用扁平写法，`streamSettings` 用 `method`，传输用 `raw`。最低版本 26.9.30 已全部支持，不为旧版本保留旧字段名。旧写法 `vnext`/`servers`/`network`/`dokodemo-door` 只在解析导入的配置时识别，渲染时不输出。
- Xray 升级可能再次移除字段。渲染器只输出本文档列出的字段；CI 的 golden 测试用清单中的**当前** Xray 版本执行 `run -test`，升级 Xray 前必须先让这一步通过。
- 渲染器的正确性以 golden 测试为准（[11](11-plan.md)）：每种协议 × 传输 × 安全层的组合至少一个夹具，
  并且在 CI 中用真实的 Xray 二进制执行 `xray run -test` 验证。
