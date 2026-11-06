# 13 分流

> 状态：**暂停**（2026-11-02 所有者决定：远端分流不是当前迫切需求，B20 调研搁置；当前优先做长期可维护的
> ChinaDNS-NG 替代实现，见 [backlog](backlog.md) B18 与 aether-dns 项目）。本文件保留为设计记录，
> 恢复时先复核「形态 B」与 aether-dns 的接口边界；不要在恢复前派任务卡。
> 背景与调研来源见 [backlog](backlog.md) 的 B1、B18、B20。

## 目标

1. **按服务/域名指定出口**：Netflix、OpenAI 之类走固定节点，其余走当前节点。
2. **按设备指定出口**：客厅盒子走 A 节点、手机走 B 节点，其余跟随默认。
3. **保住现有底线**：国内流量继续在 nft 层直连、不经 Xray，`fail_open` 仍成立。
4. **默认模式语义不变**：`gfw`、`bypass_cn`、`global` 三者的含义与页面文案不改。

## 非目标（本期不做）

- 自动测速/最少延迟选出口（Xray `balancer`），见 [backlog](backlog.md) B15 第 1 条，另立设计。
- 自动学习「gfwlist 漏网」的域名（B20 候选思路 1、2），本期只保留用户手动补漏。
- IPv6、按进程/端口段分流、按域名给设备分组之外的维度。
- 引入设备上的 `geosite.dat` / `geoip.dat`（体积与内存不可接受，见「数据」）。

## 判定总原则

1. **能用 IP 在 nft 判完的，仍在 nft 判**，不走 Xray（省 CPU，这是 `fail_open` 的基础）。
2. **需要域名信息、或需要换出口的，进 Xray 由 `routing` 判**。Xray 的在途开销与「Xray 挂了」的影响面都随进入 Xray 的流量增长，
   所以第 1 条不能放弃。
3. 没有配置任何分流时，数据面必须与现状**逐字节相同**（golden 样本不变）。

## 数据面形态

分流启用与否，是两种形态。渲染器按「是否存在启用的 route 段，或是否存在绑定了出口的 host」选择：

### 形态 A：未启用分流（现状，不变）

按 [02](02-dataplane.md)「判定顺序（规范）」1–10 判定，`by_mode` / `mode_<p>` 链与现在完全一致。

### 形态 B：启用分流

nft 只做「直连 / 进 Xray」的二分，**模式与规则的判定全部交给 Xray**：

| # | 条件 | 动作 |
|---|---|---|
| 0–5 | 同现状：接口/IPv4/TCP-UDP 守卫、已有透明 socket、本机、53 端口、保留地址、节点地址 | 同现状 |
| 6 | 目的地址命中用户直连 `direct_ip4` / `udirect4` | 直连 |
| 7 | 目的地址命中用户代理 `proxy_ip4` / `uproxy4` | 进 Xray |
| 8 | 源主机策略 = `direct` | 直连 |
| 9 | 源主机策略 = `proxy`（全局） | 进 Xray |
| 10 | 目的地址命中 `chnroute4` | 直连 |
| 11 | 其余 | 进 Xray |

所以形态 B 下 `by_mode`、`mode_<p>`、`gfw4`、`gfw_static4` 这些链与集合**不再参与拦截**（集合仍保留定义，`chinadns-ng` 仍往里写，见「兼容」）。

> 这意味着：启用分流后，`gfw` 模式下「境外但不在 gfwlist」的流量**也会进 Xray** 再由 Xray 判为 `direct`。
> 这是本方案的中心代价，写在「已知代价」里，不是实现缺陷。

### Xray `routing.rules`（按序，先命中先用）

| # | 条件 | 出口 | 说明 |
|---|---|---|---|
| 1 | `inboundTag: [dns-in-0, dns-in-1, http-in]` | `proxy` | 与现状相同：DNS 隧道与 HTTP 入站经当前节点 |
| 2 | 用户 route 规则（按 UCI 段顺序逐条） | 规则指定 | `domain` / `ip` / `port` / `network` / `sourceIP`（设备） |
| 3 | 设备出口绑定：`sourceIP ∈ host.node 组` | 该设备的 `node` | 只对绑定了出口的设备生成 |
| 4 | 设备模式覆盖：`sourceIP ∈ host policy=gfw` | `gfw` 兜底（见下） | 只对这类设备生成 |
| 5 | 设备模式覆盖：`sourceIP ∈ host policy=bypass_cn` | `bypass_cn` 兜底 | 同上 |
| 6 | `domain: [gfw 域名列表], ip: [gfw_static4]`（仅 `main.mode=gfw`） | `proxy` | gfw 模式兜底 |
| 7 | 最终 | 按 `main.mode`：`bypass_cn`/`global` → `proxy`；`gfw` → `direct` | 末条规则总是存在 |

- 表中的「兜底」每一项展开为 1–2 条规则：`bypass_cn` / `global` 只有 1 条（→ `proxy`）；`gfw` 为 2 条（命中列表 → `proxy`，末条 → `direct`）。
- **`gfw` 兜底**：`domain: <gfw 域名列表>` + `ip: <gfw_static4>` → `proxy`，末条 `direct`。
  域名列表来自现有的 `gfwlist.txt`（每行一个域名，见 [08](08-updates.md)「数据格式与来源」），渲染成 `domain:` 后缀匹配项。
- **`bypass_cn` 兜底**：末条 `proxy`（国内已在 nft 直连，进 Xray 的就是境外）。
- 设备策略与规则冲突：**规则优先**（更具体），设备绑定是「该设备的默认出口」，与 [02](02-dataplane.md) 中
  「目的地例外优先于主机策略」同一取向。
- `policy=direct` 与 `policy=proxy` 的设备不进 Xray 的判定链（在 nft 就分流了），所以不生成 `sourceIP` 规则。

### 出口（outbounds）

| tag | 内容 |
|---|---|
| `proxy` | 当前节点（`main.node`），与现状相同 |
| `direct` | `freedom`，与现状相同（现在只是没被规则引用） |
| `node:<节点段名>` | 每个被 route 规则或 host.node 引用的节点，各一个 |

- 只渲染**被引用**的节点。订阅里几百个节点全渲染会让 `xray.json` 膨胀、启动变慢，也让「引用保护」失去意义。
- 规则里的 `outbound=main` 直接指向 `proxy`，不复制一份。
- 节点被父订阅删除时，它的 route 引用也要算「被引用」（见「引用与 stale」）。

### 域名与直连出站的解析

- 入站嗅探保持 `sniffing: {enabled, destOverride: [http, tls, quic], routeOnly: false}`（[05](05-config.md)）。
  `routeOnly=false` 表示嗅探到域名后**用域名连接**，直连流量因此能命中 CDN 与 SNI 一致性，不是从 IP 反查。
- Xray 不需要自己的 `dns` 配置段：`freedom` 出站解析域名时走系统解析器（`/etc/resolv.conf` → dnsmasq → chinadns-ng），
  DNS 级别与污染判定仍由现有三级别机制负责。**真机需验证**（见「测试」）。
- `dns-in-*` 入站的定位不变：给 chinadns-ng 的 T1 提供「经节点查 53 端口」的通道。

### UDP

- 形态 B 下 UDP 也进 Xray（否则无法按域名/出口分流 UDP）：`proxy` 链对 UDP 做 TPROXY，但**顺序**是
  「游戏模式主机 → TPROXY；`quic_block=1` 且目的端口 443 → 打标记到 `quic_reject`；其余 UDP → TPROXY」。
- `quic_block=1` 仍按现状对非游戏模式主机的 UDP/443 拒绝。形态 B 下这会让**所有境外站点的 QUIC 被拒**、
  回落到 TCP——功能不受影响，代价是多一次回落。首版接受，写进「已知代价」；后续可改为「交给 Xray 判出口」。
- 游戏模式（`host_udp4` / `host_udp_mac`）语义不变：命中的主机全部 UDP 走 TPROXY，不看 `quic_block`。

## 配置模型

新增一等段落 `config route`，可多个，**UCI 段顺序即优先级**（与 `host` 段的处理一致）。

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `enabled` | bool | `1` | |
| `name` | 字符串 | — | 仅用于显示 |
| `domain` | list | 空 | 匹配项，见下方语法 |
| `ip` | list IPv4/CIDR | 空 | 按目的地址匹配（在 Xray 里做，因此只对进了 Xray 的流量有效） |
| `port` | list 整数/范围 | 空 | 目的端口 |
| `network` | enum(`tcp`\|`udp`\|`tcp,udp`) | `tcp,udp` | |
| `host` | list host 段名 | 空 | 只对这些设备生效；空 = 所有设备 |
| `outbound` | enum(`main`\|`direct`\|`<节点段名>`) | `main` | 出口 |

`domain` 列表项的语法：

| 写法 | 匹配 | 例 |
|---|---|---|
| 以 `svc:` 开头 | 引用服务分类数据（见「数据」），渲染时展开 | `svc:netflix` |
| `domain:<域名>` | 该域名及其子域（Xray 后缀匹配） | `domain:openai.com` |
| `full:<域名>` | 精确匹配 | `full:api.openai.com` |
| `keyword:<字符串>` | 包含子串 | `keyword:netflix` |
| 裸域名 | 同 `domain:` | `netflix.com` |

- `svc:` 分类名必须是常量表中的已知分类，否则校验失败（`invalid_value`，不在启动时静默忽略）。
- `svc:` 展开后的域名数与规则数上限要有约束：单条规则展开后超过 N 个域名时拒绝并提示用户拆规则（N 待定，见「开放问题」）。

`config host` 新增：

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `node` | 节点段名 | 空 | 该设备的默认出口；空 = 跟随 `main.node` |

- 与 `policy` 的关系：`policy=direct` 时不渲染 `node`（配置错误？见开放问题 Q4）；`policy=proxy` 时 `node` 有意义（全局设备走指定节点）。
- 校验：`node` 必须指向存在的节点；与 `route.outbound` 相同，被引用的 stale 节点允许使用并产生 `NODE_STALE_IN_USE` 警告。

### 校验规则（补充到 [05](05-config.md)「校验规则」）

8. `route.host` 必须指向存在的 `host` 段；`route.outbound` 必须是 `main`、`direct` 或存在的节点段名。
9. `route.domain` 的 `svc:` 分类必须在常量表内；其余项按 [05](05-config.md) 规则 4 的域名语法校验。
10. 同一 `(domain, host, outbound)` 完全相同的两条规则允许（后者不会命中），但要在 LuCI 提示「被前面的规则完全覆盖」。

## 渲染

### `xray.json`

- `outbounds`：`proxy`（主节点）、`direct`、每个被引用节点一个 `node:<id>`；顺序固定（主、direct、其余按段名排序），保证 golden 稳定。
- `routing.rules`：按上文表格顺序生成，最后一条必须是「最终兜底」，避免出现无规则可走。
- 形态 A 与现状逐字节相同（`routing.rules` 只有一条 `inboundTag → proxy`）。

### `aether-proxy.nft`

- 形态 B 下 `by_mode` / `mode_<p>` 链删除，`chnroute4` 判定留在 `prerouting` 或一个 `direct_cn` 链里。
- `gfw4`、`gfw_static4`、`uproxy4`、`udirect4` 集合**仍保留定义**（`chinadns-ng` 会往 `gfw4`/`uproxy4`/`udirect4` 写，缺集合会让它报错）；
  只是不再被拦截链引用。
- `direct_ip4` / `udirect4` / `proxy_ip4` / `uproxy4` 的现有语义不变。
- `input_guard`、`dns_hijack`、`quic_reject`、计数链不变。

## 数据

### 服务分类（新数据项）

设备上**不安装** `geosite.dat` / `geoip.dat`：本机现成的 `geoip.dat` 是 19.9 MB，`geosite.dat` 同量级，
对 16–128 MB 的 NAND 与 RAM 都不合适，而且每次数据更新都要重启 Xray 才能生效。

改为：**CI 时从 geosite 数据里抽取出需要的分类，生成我们自己的小文件**，随现有数据通道（[08](08-updates.md)）发布。

- 文件名 `services.txt`，格式每行 `分类<TAB>域名`，`#` 开头为注释，UTF-8、行尾 `\n`。
- 分类常量表（首批，待定稿确认）：`netflix`、`disney`、`primevideo`、`hbo`、`youtube`、`openai`、`anthropic`、`google`、`telegram`、`spotify`、`github`、`apple`。
- 抽取工具放 `tools/data/`（与现有 `build.py` 并列），构建时校验：每个分类行数 ≥ 1、总行数上限、域名语法、无重复。
- 更新策略：与 `gfwlist.txt` 等一起每天生成；设备端按现有 `update data` 流程安装到 `/etc/aether-proxy/data/services.txt`。
- 数据缺失或分类为空时：`svc:` 规则在校验阶段失败（`CONFIG_INVALID`），不静默降级为空规则——
  否则用户以为在分流、实际全走默认出口。这一点与「规则数据文件缺失即报错」的现有做法一致。

> 上游与许可证需在实现前确认：候选是 `v2fly/domain-list-community`（MIT）与 `Loyalsoldier/v2ray-rules-dat`（GPL-3.0，与本项目一致）。
> 无论选哪个，`SOURCES.md` 必须写明来源、抓取时间与许可证，与现有五个数据文件同一格式。

## 引用与 stale

- 订阅更新时「被引用的节点保留为 stale」的判定，从 `main.node` 扩展为：
  `main.node ∪ {host.node} ∪ {route.outbound（非 main/direct）}`。
- 只有被引用的节点才会被渲染成 outbound，所以「不引用就不渲染」和「不引用就删除」是同一套逻辑，不会出现引用已删节点。

## 事件与状态

- 分流本身不新增事件码（页面通过 UCI 与 `status` 读）。渲染失败沿用现有 `RENDER_FAILED` / `CHECK_FAILED`。
- `status` 增加 `routes`：`{enabled: <启用的 route 段数>, render_mode: "A"|"B"}`，供概览页显示「分流已启用」。
- 事件里引用节点时用节点 ID，与现有做法一致（[09](09-logging.md)）。

## 兼容与迁移

- 没有 `route` 段、也没有 `host.node` 的配置：渲染与现在**逐字节相同**，不需要迁移。
- `chinadns-ng` 的组配置（`boot`、`udirect`、`uproxy`）保持不变；`gfw4` 等集合仍定义、仍写入，只是形态 B 下不参与拦截。
  DNS 引擎的替换见 [03](03-dns.md)「替换 ChinaDNS-NG」：`dns.engine=dnsmasq` 时 gfw 域名由 dnsmasq 的 `server=` 行送进
  Xray 的 DNS 出站，chinadns-ng 只在 `engine=chinadns-ng` 的过渡配置里使用。
- 用户自定义域名列表（`proxy_domain.txt` / `direct_domain.txt`）继续走 `chinadns-ng` 组，不迁到 Xray——**除非**用户希望「不经过路由器 DNS 的设备也能生效」，
  那是 B20 的补漏课题，见开放问题 Q1。

## 故障与降级

| 情形 | 现在 | 形态 B |
|---|---|---|
| Xray 不可用，`fail_open=1` | 摘除拦截规则，全部直连 | 同左。差别是境外直连流量本来也走 Xray，摘除后仍直连，结果一致 |
| Xray 不可用，`fail_open=0` | 境外全断 | 同左，但断的范围更大（境外直连也断） |
| 节点不健康（`degrade_gfw`） | nft 按 `gfw` 重渲染 | 改渲染 Xray 兜底规则：`bypass_cn` 设备的末条改成 `gfw` 兜底 |
| 切换节点 / 改模式 / 数据更新 | 重启 Xray，断掉代理连接 | 重启 Xray，**断掉所有境外连接**（已知代价） |

- `degrade_gfw` 在形态 B 下仍然「只降绕过大陆」，实现位置从 nft 移到 Xray 兜底规则；`state.json` 的 `degraded_mode` 语义不变。

## 已知代价（要写进用户文档）

1. 启用分流后，境外直连流量也经过 Xray：CPU 上升，Xray 重启（换节点、更新数据）会断开正在进行的境外连接。
2. `gfw` 模式下「不在 gfwlist」的境外站点也要进 Xray 才能判为直连，比现在的纯 nft 路径多一跳。
3. `quic_block=1` 时启用分流会让所有境外 QUIC 被拒、回落 TCP。
4. 分流依据的域名来自嗅探（TLS SNI / HTTP Host / QUIC SNI）。**ECH、加密 SNI、纯 IP 连接嗅探不到域名**，
   这类流量只能落到兜底规则，`svc:` 分类对它们无效。
5. 服务分类数据每天更新，更新后需要重启 Xray 才生效。

## 测试

- **golden（宿主机）**：形态 A 与现有一致（字节比较）；形态 B 覆盖：单条 `svc:` 规则、多规则顺序、设备绑定、`gfw` 兜底、
  `bypass_cn` 兜底、引用的节点被标记 stale。
- **`xray run -test`**：每个形态 B 夹具都用真实 Xray 跑；含 `domain:` 与 `ip:` 规则、`sourceIP` 规则、`node:*` 出口。
- **数据**：`services.txt` 生成器的合理性检查（分类非空、语法、去重、行数上限）；CI 中数据缺失时校验必须失败。
- **真机（H28K）**：
  1. Netflix 走指定节点、其余走当前节点；
  2. ChatGPT 走另一个节点；
  3. 一台设备绑定出口，另一台不绑定，互不影响；
  4. `gfw` 模式兜底正确（不在 gfwlist 的境外站点直连）；
  5. 直连流量的出口 IP 与直连语义一致（验证 freedom 出站与系统解析器）；
  6. 节点不健康时 `degrade_gfw` 生效；
  7. 停掉 Xray（`fail_open=1`）时国内、境外都直连；
  8. 切换节点后连接中断的体感，与现状对比记录。

## 任务拆分（M13，定稿后出卡）

| 卡 | 内容 | 依赖 |
|---|---|---|
| R1 | `schema.uc` / `config.uc` 读取与校验：`route` 段、`host.node`、`svc:` 分类常量 | — |
| R2 | `render/xray.uc`：多出口、`routing.rules` 全部规则、稳定排序 | R1 |
| R3 | `render/nft.uc`：形态 B 的二分链路，形态 A 不变 | R1 |
| R4 | `tools/data`：从 geosite 抽取 `services.txt`，清单、签名、`SOURCES.md` | — |
| R5 | 引用与 stale 扩展、`status.routes`、`degrade_gfw` 在 Xray 侧的实现 | R1、R2 |
| R6 | LuCI 分流页（规则列表、`svc:` 分类下拉、设备与出口选择） | R1 |
| R7 | 节点页与订阅页：被引用节点的删除保护与提示 | R5、R6 |
| R8 | golden 与真机验收、用户文档、已知代价 | 全部 |

R4 可与 R1–R3 并行。

## 开放问题（定稿前必须逐条定）

- **Q1** 用户自定义域名列表（`uproxy` / `udirect`）是否迁到 Xray 规则？
  在 Xray 里更准（不依赖 DNS 经过路由器，DoH 设备也生效），但直连域名会因此进入 Xray。倾向：**另立一条独立的 route 段**（用户可选），不自动迁移。
- **Q2** `services.txt` 上游与许可证（见「数据」）。
- **Q3** `svc:` 单条规则展开后的域名数上限 N、总规则数上限。
- **Q4** `policy=direct` 的设备同时填了 `host.node`：报配置错误，还是忽略 `node` 并给警告？
- **Q5** 形态 B 下 QUIC 是否仍按 nft reject（首版建议是），还是交给 Xray 按出口处理。
- **Q6** `gfw` 模式在形态 B 下确认接受「境外流量整体进 Xray」——这会改变 `gfw` 模式「省流量」的卖点，需要在页面上说明。
