# aether-dns 1.0.1 发布与下游同步（2026-11-13）

**结论**：aether-dns 1.0.1 已发布并进入通道；固件 feed 已钉到含 1.0.1 哈希的提交。
发布过程中发现并修掉了发布流水线里写死的 `1.0.0-r1` 资产名。

## DNS 仓库

- 版本：`PKG_VERSION:=1.0.1`、`PKG_RELEASE:=1`（`428b560`）；
- tag `v1.0.1` 最终指向 `6a4edfa`（含 CI 修复）；Release 5 个资产：两个架构的 ipk/apk + `SHA256SUMS`。
- 内容：M4-11（生命周期日志改 stdout，含 `upstream failed`）+ M4-12（剩余测试的端口预留竞态）。
- **CI 修复**（`6a4edfa`）：`release.yml` 的资产名、上传列表、二进制版本检查，以及
  `tests/ci/verify-assets.sh` 原先都写死 `1.0.0-r1`，导致包内 `Version: 1.0.1-r1` 与文件名不一致而失败。
  现改为从 `openwrt/Makefile` 与 `Cargo.toml` 推导；`verify-assets.sh` 用真实 1.0.0 资产做过正/负向验证。
- 哈希已写回 `openwrt/Makefile` 的下载分支（`efd77dc`），外部构建可直接从 1.0.1 的 ipk 取二进制。

## 通道

- `AETHER_DNS_RELEASE` → `TAG=v1.0.1`、`VERSION=1.0.1-r1`；
- `AETHER_DNS_SHA256SUMS` → 四条 1.0.1 哈希；
- **触发缺口修复**：`packages.yml` 的 `paths` 原先只有 `AETHER_PROXY_REF`，改 DNS 钉版不会重建；
  已加入 `AETHER_DNS_RELEASE`、`AETHER_DNS_SHA256SUMS`（`8fcc402`）。
- 重建后清单：`aether-dns current=1.0.1-r1 previous=1.0.0-r1`，四个资产哈希与 DNS Release 一致；
  `aether-proxy`/`luci` 仍为 `1.1.2-r1`（未变版沿用旧条目）。

## 固件

- `openwrt-actions/configs/feeds.conf` 的 `aetherdns` → `efd77dc`（`82d7168`）；
- 固件构建时会下载 1.0.1 的 ipk 并按新哈希校验；重建后固件内的 `aether-dns` 为 1.0.1。

## 设备（H28K，2026-11-14 05:41）

- 已手动安装 `aether-dns 1.0.1-r1`（来自通道资产，sha256 校验一致），`/etc/init.d/aether-proxy restart` 后生效；
- **日志级别修复已验证**：重启后 `listening TCP/UDP` 记为 `daemon.info`，不再出现在 `err` 里；
- 服务 `running` / `T1`，`latency_ms=218`、`xray_down_count=0`、`dns_fail_count=0`；DNS 端到端正常；
- 引擎进程只有一条（新二进制），临时安装包已删除。
- **版本口径**：包为 `1.0.1-r1`，但二进制 `-V` 仍是 `1.0.0`（Cargo 版本未随包装版本升），
  所以 `components --json` 的 `dns.version` 显示 `1.0.0`。代理的兼容闸门按二进制版本判断，不受影响；
  需要 UI/诊断显示 1.0.1 时，应在 DNS 仓库升 Cargo 版本并另发一版。
- 1.0.1 是诊断修复，**不会**被更新页的引擎前置事务自动安装（已装版本已满足条件），本次为手动安装。
