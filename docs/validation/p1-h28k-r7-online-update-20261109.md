# P1：H28K 在线升级到 0.6.3-r7 验收（2026-11-09）

## 结论

用户于 2026-11-09 12:43 在 H28K 用更新页**在线更新**，把 `aether-proxy` 与 `luci-app-aether-proxy` 从本地包 `0.6.3-r6.t1510`/`0.6.3-r6` 升到 **0.6.3-r7**，中文翻译包同时升到 `26.313.11636~0690c59`。

两条结论分别成立：

- **A：设备确实在跑 r7 且运行正常。** running/T1/bypass_cn，无新增启动失败、崩溃或解析失败，设备未重启。
- **B：装的就是 Release 页的字节。** 通道签名清单里三个包的 `sha256` 与 GitHub Release 资产逐个相同，且生成机制是"从清单复制并校验、不重编"。

本次采集方式为**只读**：WSL 既有密钥 SSH 执行查询命令、下载通道清单做离线验签；未安装/卸载包、未重启服务或设备、未改配置、未动 WAN/防火墙。

## 1. 设备与采集环境

| 项 | 值 |
|---|---|
| 设备 | H28K，`root@192.168.5.254` |
| 固件 | OpenWrt 24.10.5，`rockchip/armv8`，`aarch64_generic`（包管理为 opkg，非 apk） |
| 采集时间 | 2026-11-09 13:36（UTC+08:00） |
| 采集命令 | `cat /etc/openwrt_release`、`cat /proc/sys/kernel/random/boot_id`、`uptime`、`opkg list-installed`、`aether-proxy status --json`、`logread`（grep 事件）、`ls -l /tmp/dnsmasq.d/` |
| 通道侧 | 只读下载 `channel-stable` 的 `manifest.json`/`.sig`，用 `aether-proxy-channel/keys/` 公钥离线验签 |

## 2. A：版本、运行状态与升级时间线

### 2.1 已安装版本

```text
aether-proxy - 0.6.3-r7
luci-app-aether-proxy - 0.6.3-r7
luci-i18n-aether-proxy-zh-cn - 26.313.11636~0690c59
aether-xray - 26.10.31-1
chinadns-ng - 2025.08.09-1
aether-dns - 2026.11.04-1
```

`/usr/lib/opkg/info/aether-proxy.control` 同样是 `Version: 0.6.3-r7`，依赖仍为 `aether-xray`、`chinadns-ng`。

### 2.2 运行状态（`aether-proxy status --json` 摘要）

```text
state=running  dns_tier=T1  dns_failsafe=false  mode=bypass_cn
node_ip=20.243.137.248  since=1794199396（2026-11-09 12:43:16 HKT）
last_probe: ok=true latency_ms=195
monitor: running/T1, xray_down_count=0, chinadns_down_count=0,
         dns_fail_count=0, proxy_ok_count=2, ever_healthy=true, table_missing_count=0
components: xray /usr/bin/aether-xray 26.10.31；chinadns-ng /usr/bin/aether-dns 2026.11.04
```

### 2.3 升级时间线（syslog 原文摘录）

```text
Mon Nov  9 12:31:27 UPDATE_AVAILABLE [package=aether-proxy current=0.6.3-r6.t1510 latest=0.6.3-r7]
Mon Nov  9 12:31:27 UPDATE_AVAILABLE [package=luci-app-aether-proxy current=0.6.3-r6 latest=0.6.3-r7]
Mon Nov  9 12:31:27 UPDATE_AVAILABLE [package=luci-i18n-aether-proxy-zh-cn current=26.309.19503~4e51528 latest=26.313.11636~0690c59]
Mon Nov  9 12:43:03 SERVICE_STOPPED [mode=bypass_cn node=n_a2df65324fcb4d3a98b5f344b7d7db16]
Mon Nov  9 12:43:15 SERVICE_STARTED [... elapsed_ms=9215 steps={..., "dnsmasq_install": 2699, ...}]
Mon Nov  9 12:43:16 UPDATE_INSTALLED [package=aether-proxy version=0.6.3-r7]
Mon Nov  9 12:43:17 UPDATE_INSTALLED [package=luci-app-aether-proxy version=0.6.3-r7]
Mon Nov  9 12:43:19 UPDATE_INSTALLED [package=luci-i18n-aether-proxy-zh-cn version=26.313.11636~0690c59]
```

只有**一对** STOPPED/STARTED，中间 12.2 秒；`elapsed_ms=9215` 是启动步骤耗时，不是命令耗时，也不是中断窗口长度。

### 2.4 设备未重启、无失败事件

- `boot_id` 仍为 `97edbacd-fd63-4a21-beb7-0cc59ac22b93`，与 T15.10 记录相同；`uptime` 3 天 3:31，说明升级没有走重启。
- 升级时刻之后 `START_FAILED` / `CHILD_CRASHED` / `NODE_RESOLVE_FAILED` 计数为 **0**；日志中唯一 `CHILD_CRASHED` 是 11-06 10:14（早于升级，且为历史事件）。
- dnsmasq 片段 `/tmp/dnsmasq.d/aether-proxy.conf`（33 字节，0600）mtime 为 12:43，即由本次启动安装。

## 3. B：通道字节与 Release 资产逐字节相同

### 3.1 哈希对照

| 包 | 通道签名清单 sha256 / size | GitHub Release 资产 sha256 / size |
|---|---|---|
| `aether-proxy_0.6.3-r7_all.ipk` | `f8f90a8488ebc40ee1552fdb3edf90b3884d93cb4339c75b5ec542ec1486c597` / 687047 | 同 |
| `aether-proxy-0.6.3-r7.apk` | `6cc7ea1f7545edcd8ceb027a9dfac22852044080e039af651ca6e28374a5583a` / 687399 | 同 |
| `luci-app-aether-proxy_0.6.3-r7_all.ipk` | `fd60924b7ed65389c5fcde4684461b028599e9fe21fa45e14d53add9cf0d539f` / 61766 | 同 |
| `luci-app-aether-proxy-0.6.3-r7.apk` | `435103a968bf323adbf3a435514a4f15ba3f3d848389c489c80b4b68e95dc5f2` / 62520 | 同 |
| `luci-i18n-aether-proxy-zh-cn_26.313.11636.0690c59_all.ipk` | `6cf60789e6111d49fe3d833c5c9f99750725b1e47ed450a26cc28fb780c7ffe1` / 16211 | 同 |
| `luci-i18n-aether-proxy-zh-cn-26.313.11636.0690c59.apk` | `a32bf9716af5b756463ff6184bd06ec2ac9d37ae3e46efdbcaf082b5d464879f` / 16160 | 同 |

### 3.2 为什么是同一份字节（机制，而不是巧合）

1. **生成端**：`aether-proxy/.github/workflows/release-assets.yml` 等待与版本匹配的 `channel-stable` 清单，按清单的 `url` 下载包、逐个 `sha256sum` 比对后上传，注释写明 "no rebuild"；清单/签名文件留在 channel。即 Release 资产是通道资产的**副本**。
2. **清单可信**：本次用通道公钥 `keys/daa36ac969b8b881` 对 `manifest.json` 做 Ed25519 验签**通过**（消息为 9534 字节原文；公钥块 42 字节 = 10 字节前缀 + 32 字节密钥，签名块 74 字节 = 10 字节前缀 + 64 字节签名）。本机未装 usign，改用 Python `cryptography` 独立验证，不是复用发布时的验签脚本。
3. **设备端**：`update.uc` 下载后按清单 `size` 与 `sha256` 校验通过才改名安装（`L442–472`），失败即 `UPDATE_VERIFY_FAILED`；所以设备装上的必然是清单所列字节。

结论：`0.6.3-r7` 的通道包与 Release 资产是同一份文件，"验证的不是发布的"在本次版本上不成立。

## 4. 与既有边界的衔接（并更正一条口头说法）

- 更新流程对 `aether-proxy` 调用的激活命令是 `init restart`（`update.uc` 的 `restart_service()`，`L816–826`），不是包管理器裸 stop/start。因此**本次升级走的是 restart 路径，享有 T15.1 的 restart-intent handoff 保护**。此前"在线更新等于 opkg 独立 stop/start、无同等保护"的说法对本路径不成立，以此处为准；`04-lifecycle.md` 里"普通 opkg 独立 stop/start 不建同等保护"仍指用户手工 opkg 操作。
- 命令返回仍是异步语义：`SERVICE_STARTED` 与 `since` 才是服务恢复证据。
- 不声称零中断：本次没有在升级窗口内做客户端查询采样，也没有出口泄漏计数。

## 5. 顺带发现：引擎逻辑名与物理路径（M4-02 的现场证据）

设备上同时装有 `chinadns-ng 2025.08.09-1` 与 `aether-dns 2026.11.04-1`；`status` 的 `components` **逻辑名仍是 `chinadns-ng`**，实际 `path=/usr/bin/aether-dns`、`version=2026.11.04`。即当前真实运行的是 aether-dns 二进制，逻辑键与物理路径已经分离但命名未迁移。这是 M4-02（组件逻辑名/JSON 兼容迁移）的真实输入，本次不改。

## 6. 未覆盖

- LAN 客户端端到端浏览与 DNS 取样；只用了设备自身 `status`/monitor 指标与日志。
- B3（`fail_open=0` 且 Xray 缺位）与 B13.3（stop 撞 monitor）的注入观察。
- 出口泄漏计数、逐客户端协议覆盖。
- 只核到**包级** sha256；未解包比对包内文件与 Release 资产内部文件的逐文件哈希（包级已相同，内部必然相同）。
- 单台 aarch64、OpenWrt 24.10.5；不外推到其他架构或固件版本。

## 7. 回退可用性

- 设备持久备份 `/root/aether-proxy-before-t1510-20261109/` 仍在（旧 r6.t157 包/配置/文件）。
- 通道清单 `aether-proxy.previous` 为 `0.6.3-r6`（ipk `f48d27bb7a2189b4c47a2433da2960648afd2d104128f2190bc248d0098a4375`），`update package --previous` 路径可用；本次未执行回退。
