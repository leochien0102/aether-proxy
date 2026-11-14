# aether-xray 26.11.9 独立发布（2026-11-14）

**结论**：xray 作为独立发布单元完成"仓库构建 + 仓库 Release + 通道拉取发布"，**应用版本保持 1.1.3-r1**，
设备已升级到 `aether-xray 26.11.9-r1`。

## 发布单元

| 单元 | 版本 | 发布方式 |
|---|---|---|
| 应用（proxy+luci+i18n） | `1.1.3-r1` | 不变；RC→promote→tag |
| xray 核心 | `26.11.9-r1` | 组件 release：仓库构建 → 仓库 Release → 通道拉取 |
| DNS 引擎 | `1.0.2-r1` | 不变 |

## 链路

1. `aether-xray/Makefile`：`PKG_VERSION` 26.11.9，源码 tar 哈希
   `d5a47bed1b85e1cdfe3cb2f88a02e2db7144f0f8bee541d20b84bafa8fdf6c8d`（go 1.27，工具链 1.27.2 满足）；
2. 仓库 `release-component`（`component=aether-xray`、`version=26.11.9-r1`）：
   - `build.yml` 按 `components` 只构建 xray（4 组 SDK/架构，运行名与作业名都写明构建范围）；
   - 4 个作业全部成功（smoke 按设计跳过，因为没构建应用）；
   - Release `xray-v26.11.9-r1`（tag 在 `186d925`）：`aether-xray_26.11.9-r1_<arch>.ipk`、
     `aether-xray-26.11.9-r1_<arch>.apk`、`SHA256SUMS` —— **架构只出现一次**；
3. 通道 `publish-component`（`tag=xray-v26.11.9-r1`）：下载并校验 Release 资产 → `--keep-missing`
   合并 → 签名发布；清单 `aether-xray current=26.11.9-r1 previous=26.10.31-r1`，
   `aether-proxy`/`luci` 仍 `1.1.3-r1`。

## 设备（H28K，2026-11-14 22:35）

- 包：`aether-proxy 1.1.3-r1`、`luci-app 1.1.3-r1`、i18n `26.318.42926~c8844e5`、
  `aether-xray 26.11.9-r1`、`aether-dns 1.0.2-r1`；
- 组件页（M4-19）：`xray version=26.11.9-r1 installed=26.11.9-r1`、`DNS 1.0.2-r1`，`mismatch` 全为 false；
- `running` / `T1`，`latency_ms=216`，失败计数 0；DNS 正常。

## 构建解耦（本次落地）

- `build.yml` 新增 `detect`：按 push 改动路径映射到组件（`tools/ci/changed-components.sh`），
  也支持 `workflow_dispatch` 的 `components` 输入；运行名与作业名写明构建范围；
- 通道新增 `publish-component`：只拉取代码仓库 Release 的资产，不跑 SDK、不编译；
- `tools/channel/build.py` 的 `--keep-missing` 让组件发布保留其它已发布条目。
