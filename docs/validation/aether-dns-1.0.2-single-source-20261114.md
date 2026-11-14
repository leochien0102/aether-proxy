# aether-dns 1.0.2 单一来源切换（2026-11-14）

**结论**：aether-dns 的包定义已移到 proxy 仓库，固件与通道都用同一份 `aether-dns/Makefile`；
DNS 仓库只发布裸二进制与 ipk/apk 供人工下载，通道不再 staging。

## 链路

| 环节 | 结果 |
|---|---|
| DNS 1.0.2 | tag `v1.0.2`，Release 7 个资产（4 包 + 2 裸二进制 + SHA256SUMS）；`-V` = 1.0.2 |
| proxy M4-20 | `aether-dns/Makefile` 下载裸二进制、按架构哈希、静态无 libc 依赖；CI 四组打包 + 六组 smoke 绿 |
| 通道 C1 | 从 proxy feed 构建 aether-dns，删除 staging 与两个 pin；构建后校验产物版本 == Makefile 版本 |
| 通道清单 | `aether-dns current=1.0.2-r1 previous=1.0.1-r1`；`aether-proxy`/`luci` 仍 `1.1.2-r1` |
| 固件 feed | `openwrt-actions` 只剩 `aetherproxy` 一个 feed（钉 `6b52be8`），不再有 `aetherdns` |

## 产物差异说明

通道现在发布的 aether-dns ipk/apk 由通道从裸二进制打包（哈希 `e32f0456…`/`ce590583…` 等），
与 DNS 仓库自己发布的 ipk（`1dbc307c…`）不同；设备只安装通道清单里的那一份，DNS Release 的包
供人工下载。两者包含同一个 1.0.2 二进制。

## 设备（H28K，2026-11-14 16:59）

- 安装通道里的 `aether-dns 1.0.2-r1`（sha256 `e32f0456…` 与清单一致），`/etc/init.d/aether-proxy restart`；
- **版本口径已一致**：opkg `1.0.2-r1`，`aether-dns -V` = 1.0.2，`components` 的 `dns.version` = `1.0.2`；
- 服务 `running` / `T1`，`latency_ms=199`、`xray_down_count=0`、`dns_fail_count=0`；DNS 端到端正常；
- 日志级别仍是 `daemon.info`（1.0.1 起生效）；
- 由此，组件页与包管理器不再有 aether-dns 的版本不一致。
