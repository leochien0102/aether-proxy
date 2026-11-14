# 组件版本口径统一（2026-11-14）

**目标**：任何界面、日志、清单都显示**同一个**版本字符串；"是否已更新完成"可以直接用
"界面版本 == 清单版本"判断，不需要读者知道哪个字段来自哪里。

## 1. 现状审计（H28K，2026-11-14 09:46）

| 组件 | opkg 包版本 | 二进制自报 | 组件页 |
|---|---|---|---|
| aether-proxy | `1.1.2-r1` | `aether-proxy 1.1.2-r1` | —（页面单列） |
| aether-xray | `26.10.31-1` | `Xray 26.10.31` | `26.10.31` |
| chinadns-ng | `2025.08.09-1` | `ChinaDNS-NG 2025.08.09` | —（备用引擎） |
| aether-dns | `1.0.1-r1` | `aether-dns 1.0.0` | `1.0.0` |
| luci-app | `1.1.2-r1` | — | — |
| i18n | `26.316.50246~0695113` | — | — |

问题：

1. **aether-dns 二进制版本与包版本脱节**：1.0.1 只升了包，`Cargo.toml` 仍是 1.0.0；
2. **修订号两种写法**：固件（LEDE）构建出 `-1`，通道（SDK）构建出 `-r1`，同一个包两种字符串；
3. **组件页只看二进制横幅**，不知道 opkg 实际装的版本，两者不一致时无法发现；
4. 三种自报格式并存：proxy 带 `-rN`，xray/chinadns-ng 只有核心，aether-dns 只有核心且过期。

## 2. 规则

**R1 单一来源**：每个组件的版本由它的包 Makefile 决定：`PKG_VERSION`（核心）+ `PKG_RELEASE`（修订）。
规范字符串为 **`<核心>-r<修订>`**（如 `1.0.2-r1`）。

**R2 二进制必须自报核心**：`-V`/`version` 输出的版本核心必须等于该包构建时的 `PKG_VERSION`。
第一方组件（proxy、aether-dns）应输出完整规范串；第三方二进制（xray、chinadns-ng）只要求核心一致。

**R3 展示以"已安装包"为准**：组件页/更新页显示**包管理器里的版本**（规范化成 `-rN`），
二进制横幅作为"一致性校验"：核心不一致时标记为**不一致**，而不是静默显示其中一个。

**R4 修订号写法归一**：`-<n>`（LEDE）与 `-r<n>`（SDK）是同一修订；所有展示与比较统一成 `-r<n>`。

**R5 更新完成的判据**：更新成功后，组件页显示的版本必须等于清单里的 `current` 版本；
不等就是"未完成"（页面显式提示），不允许只凭"作业成功"就说完成。

**R6 清单/说明/日志同串**：通道清单、Release 说明、`UPDATE_STARTED/INSTALLED` 事件里的版本，
都用规范串，不再出现 `-1` 与 `-r1` 混用。

## 3. 执行点

| 位置 | 改动 |
|---|---|
| `aether-proxy` 的 `components` | 读 opkg/apk 的已装版本；规范化 `-1`→`-r1`；与二进制核心比对，不一致时输出 `mismatch: true` 与两个值；页面显示规范串 + 警告 |
| 代理更新页 | 更新完成后用 `components` 的值与清单 `current` 比对，显示"已更新到 X"或"版本不一致" |
| 通道 `packages`/`promote` | 对每个构建产物执行 `-V`，核心与 `PKG_VERSION` 比对，不一致失败；清单统一写 `-rN` |
| DNS 仓库 | `Cargo.toml` 版本 == `PKG_VERSION`；`-V` 输出核心；CI 守卫；发 1.0.2 修正现状 |
| 固件 feed | 无需改构建；展示层做 `-1`→`-r1` 归一即可 |

## 4. 迁移顺序

1. DNS：升 `Cargo.toml` 与 `PKG_VERSION` 到 1.0.2，加 CI 守卫，发 1.0.2；
2. 代理：`components` 改为"已装包版本 + 一致性校验"，更新页用版本判完成；
3. 通道：构建后校验 `-V` 核心，清单统一 `-rN`；
4. 固件：重建，确认组件页显示 `1.0.2-r1` 且无 mismatch。

## 5. 不做

- 不改变版本比较的语义（`-rN` 仍不参与排序，只用于展示与相等判断）；
- 不为第三方二进制强求完整串（只校验核心）；
- 不引入新的版本字段或数据库，全部从包管理器现读。

## 6. 发布物分工（2026-11-14 明确，同日修订）

| 发布物 | 位置 | 用途 | 内容 |
|---|---|---|---|
| **通道 Release** | `aether-proxy-channel` 的 `channel-stable` | **页面在线更新**：清单 + 资产，设备按清单校验安装 | `manifest.json`（各组件 current/previous 与哈希）+ ipk/apk + 数据包 |
| **代码仓库 Release** | `aether-proxy`、`aether-dns` 各自的 tag | **人工按需下载** | ipk/apk；**不额外提供 tarball** |

规则：

- **T1 通道只服务在线更新**：通道清单的版本与哈希必须与代码仓库 Release 的资产一致；通道不产生新的二进制。
- **T2 feed 用 commit 钉版**：源码构建的组件（aether-proxy、aether-xray、chinadns-ng）由 feeds 直接按
  `src-git <repo>^<commit>` 取源码构建，不需要 tarball。
- **T3 预编译组件从发布资产取**：aether-dns 的二进制不在 git 里，feed 的 Makefile 从它的 Release 下载
  已发布的 ipk（按架构校验 sha256）后打包；同样不引入 tarball 资产。
- **T4 同一版本的三处字符串一致**：代码仓库 Release 资产名、feeds Makefile 里的版本、通道清单里的版本，
  都是 `<核心>-r<修订>`。

## 7. 发布单元（2026-11-14，解耦）

版本列车按**单元**划分，一个单元的变更只发布该单元，不拉着其它单元一起升版：

| 单元 | 组成 | 版本 | 发布方式 |
|---|---|---|---|
| **应用** | aether-proxy + luci-app-aether-proxy + luci-i18n-aether-proxy-zh-cn | `1.x.y-rN`（三者同步） | 一次推送 → 门禁 `build` → RC（复用产物）→ `promote` → 正式 tag → `release-assets` |
| **xray 核心** | aether-xray | 上游版本 `26.x.y-rN` | 只改 `aether-xray/Makefile` → 更新通道 `AETHER_PROXY_REF` → `packages` 用 `components=aether-xray` 只构建该组件（`--keep-missing` 保留其它条目）。**不升应用版本、不打应用 tag** |
| **DNS 引擎** | aether-dns | DNS 仓库版本 | DNS 仓库发布 → 通道构建（proxy 的 `aether-dns/Makefile`）→ 清单更新；固件 feed 同步 |

要点：

- **应用单元**的三件套必须同版本、同一次发布（页面与后端一起换）；
- **xray** 只受上游版本驱动；bump 提交不改应用版本，通道直发只更新清单里的 `aether-xray` 条目
  （其余包版本不变，`build.py` 沿用已发布字节）；
- **DNS** 本来就独立发布（DNS 仓库），proxy 只负责打包与清单；
- 清单是三个单元的**组合**，各自维护 `current`/`previous`；
- 已知限制：RC/promote 的 tag 绑定应用版本，因此**组件直发暂不走 RC**；若将来要让组件也走 promote，
  需要按单元设计 tag（如 `xray-v26.11.9-r1-rc1`），这是后续工作。
