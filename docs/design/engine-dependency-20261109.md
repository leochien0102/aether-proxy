# DNS 引擎依赖与在线升级事务（设计草案，2026-11-09）

> 状态：**方向已定、未落地**。虚拟依赖（`dns-engine`）+ `DEFAULT_VARIANT` + 在线升级事务化三条已由所有者确认。
> 2026-11-09 经 DNS 侧评审：三处文档对齐已采纳；**升级事务补入四条阻断项的解法**（§4），仍需冻结后才能出实现卡。
> aether-dns 的包构建与分发归属仍待定（§8）。
> 本文是设计输入，不是实现授权：不构成构建、发版、安装或设备操作许可。
> 版本下限规则见 [M4-03 卡](../tasks/m4.md) 与 DNS 侧[版本契约草案](../../../aether-dns/docs/design/semver-contract-20261109.md)。

## 1. 目标与非目标

**目标**

- `aether-proxy` 对 DNS 引擎的依赖表达为"**必选其一、可共存**"：装任一引擎即可满足，两个都装也允许。
- 在线升级把"引擎前置 + 代理组"做成**可回滚的事务**，且**升级到 1.0.0 的路径本身不依赖尚未安装的新 updater**。

**非目标**

- 不改运行时引擎选择：存在性优先 `aether-dns` → `chinadns-ng`，**没有失败回退**（与 xray 同构）。
- 不提供 proxy 回退入口（`--previous` 仍只对 `aether-xray`）。
- 不改版本下限与事件形状（属 M4-03）。
- 不解决"手工降级"：`opkg install` 旧 ipk 永远能做，只靠发布说明约束。

## 2. 依赖模型：虚拟包

```make
# chinadns-ng/Makefile 与 aether-dns 的包定义
PROVIDES:=dns-engine
# 只放在 aether-dns 上：它是对外默认引擎
DEFAULT_VARIANT:=1

# aether-proxy/Makefile（1.0.0 起）
DEPENDS:= ... +dns-engine      # 1.0.0 之前是 +chinadns-ng
```

构建系统的转换规则（`scripts/package-metadata.pl:180-198`，已核对源码）：

```kconfig
select PACKAGE_aether-dns if PACKAGE_chinadns-ng<PACKAGE_aether-proxy
```

即"默认带出 aether-dns；**用户显式把 chinadns-ng 选成 y 时不再强制 aether-dns**"。`DEFAULT_VARIANT` 通过
（`metadata.pm:277` → `package-dumpinfo.mk:29`）决定哪个 provider 被排到首位。

**配方归属（DNS 侧 2026-11-09 评审意见）**：包配方必须纳入交付，但**不由 DNS 实现卡直接改其他仓库**；
`PKG_VERSION`/`PKG_RELEASE`、`PROVIDES`、`DEFAULT_VARIANT`、源码 pin 与 hash 归包维护方（当前为 openwrt-actions）。

### opkg 行为实测（2026-11-09，SDK host opkg + 离线 root + 自制 ipk）

| 场景 | 结果 |
|---|---|
| 无 provider 已装，安装依赖 `dns-engine` 的包 | opkg **自动装了一个 provider**（本次落在 chinadns-ng；顺序属实现细节，**不可依赖**） |
| 先装任一 provider | 满足，不再拉另一个 |
| 两个 provider 共存 | 允许，无冲突 |
| 卸载唯一 provider | 拒绝（`No packages removed`），需 `--force-depends` |
| 两个 provider 都在，卸其中一个 | **同样被拒**（opkg 不评估"还有别的 provider"），需 `--force-depends` |
| 断开 feed、只靠已装元数据装 proxy ipk | **成功**（依赖由已装包的 `Provides` 满足） |

### 两件不同的事，不能混

1. **包依赖满足**：opkg 层面 `dns-engine` 有任一 provider 即可——决定安装能否进行。
2. **运行时下限满足**：daemon 按**实际会被选中的那个引擎**比版本——决定服务能否启动。

"日期版本 `2026.11.04` 能通过 `1.0.0` 下限"与"它是否满足虚拟包依赖"是两个独立判断：
旧日期版的已装元数据**没有 `Provides`**，所以它能过版本闸门，却**不能**满足 1.0.0 proxy 的包依赖。

### 迁移前提

现网已装的 `chinadns-ng 2025.08.09-1` 与 `aether-dns 2026.11.04-1` 都是用**没有 `Provides` 的旧 Makefile** 构建的。
因此 1.0.0 proxy 的 `Depends: dns-engine` 必须由本次事务装的 `aether-dns 1.0.0`（带 `Provides`）满足。

### 日期版本 → 1.0.0 的安装命令（2026-11-09 已用 host opkg 验证）

| 命令 | 结果 |
|---|---|
| `opkg install aether-dns_1.0.0-1_*.ipk`（日期版已装） | **静默不装**：`Not downgrading package aether-dns on root from 2026.11.04-1 to 1.0.0-1.`，退出码 0，版本不变 |
| `opkg install --force-downgrade …` | 成功 |
| `opkg remove aether-dns` 后安装 | 成功（但会先失去引擎） |

结论：**不能默认普通覆盖安装成功**；一次性人工迁移必须显式 `--force-downgrade`，并先备份。
上述只在 host opkg 上验证，设备上仍需复验（§6 D34）。

## 3. 四场景矩阵

| 场景 | 顺序 | 依赖满足方式 | 运行时引擎 | 失败后果 |
|---|---|---|---|---|
| 手动装包（不刷机） | aether-dns → aether-xray → aether-proxy → luci-app → i18n | 已装 aether-dns 提供 `dns-engine` | 存在性优先 aether-dns，缺失回落 chinadns-ng | 无任何引擎时 opkg 报缺 `dns-engine`；只有 chinadns-ng 时可装可用 |
| 在线更新 **0.x → 0.7.0** | 单包组（仍依赖 `chinadns-ng`） | 不变 | chinadns-ng（若已装 aether-dns 则切过去） | 与今天相同，无引擎依赖变化 |
| 在线更新 **0.7.0 → 1.0.0** | 事务：引擎前置 → proxy 组 | 事务先装 aether-dns 1.0.0 | aether-dns | 任一步失败 → 回到"能启动的 0.7.0 组合" |
| 在线更新 **0.x → 1.0.0 一步到位** | —— | —— | —— | **不支持**：旧 updater 没有事务能力（§4.1） |
| 刷机 | 镜像一次装全 | 构建期解析 | aether-dns（两者都在时仍优先它） | 不适用 |
| 固件构建 | `+dns-engine` + `PROVIDES` + `DEFAULT_VARIANT` | 构建期 | 同上 | 构建期暴露 |

**0.7.0 是桥接版本**：它带按引擎下限、存在性选择、reload 一致性与事务逻辑，但**仍依赖 `chinadns-ng`**，
所以从任何 0.x 升上来都不涉及引擎变化。

## 4. 升级事务

### 4.1 为什么需要桥接（阻断项 1、4 的解法）

旧 proxy（≤0.6.3-r7）的闸门是"按名取 2025.08.09"，`1.0.0 < 2025.08.09` → **DNS 1.0.0 会让它拒启**。
所以"先装引擎"并不天然安全，而是制造了一个"旧 proxy + 新 DNS"的不可启动组合。

解法：**拆成两跳**。

- 第一跳 0.x → 0.7.0：旧 updater 只装 proxy 组，依赖仍是 `chinadns-ng`，**不碰引擎**。这一跳由旧 updater 自己完成，不需要新能力。
- 第二跳 0.7.0 → 1.0.0：由 **0.7.0 的 updater** 执行事务（它已经有引擎前置、回滚与一致性逻辑）。
  0.7.0 的闸门接受 DNS 1.0.0，所以即使第二跳中途失败，设备仍处于"能启动"的状态。

这样"谁执行首轮事务"有了明确答案：**桥接版本**。0.x → 1.0.0 一步到位被明确列为不支持。

### 4.2 窗口与包脚本事实

- 当前 `aether-dns` 配方只有安装段，**没有 postinst、没有 init 脚本**，所以安装/替换它**不会启停 aether-proxy**。
- aether-proxy 的更新流程只对 `aether-proxy` 做 restart；`aether-dns` 安装不触发服务重启。
- 因此引擎替换期间，运行中的旧引擎进程继续用已打开的 inode 服务；只有它**下次被重启**（崩溃重生、DNS 级别切换、用户重启、设备重启）才会用到新二进制。
- 有桥接后，这个窗口里跑的 proxy 是 0.7.0，它接受新旧两种引擎，窗口不再是"不可启动"风险。

### 4.3 前置判定（阻断项 3 的解法）

**不能**用"某个已装包提供了 `dns-engine`"当满足条件——那会让未选中的合格 chinadns-ng 掩盖被优先选中的过旧 aether-dns。
必须按 daemon 的同一套解析结果判定：

```text
resolve = 显式 main.chinadns_bin（可执行时）→ /usr/bin/aether-dns → PATH 中的 chinadns-ng
engine  = basename(resolve)
min     = { aether-dns: 1.0.0, chinadns-ng: 2025.08.09 }[engine]（未知引擎无下限）
满足    = resolve 存在 且 (min 不存在 或 version(resolve) >= min)
```

要点：

- 判定必须**复用 `component_id.engine()` 与同一解析顺序**，不得在 update 流程里另写一份；
- 若 `aether-dns` 尚未安装但即将安装，则按"安装后会被选中"的情形判断（`1.0.0 >= 1.0.0`）；
- engine 未知（自定义路径）→ 视为满足、无下限；
- 判定输入取当前实际解析结果，而不是 UCI 里写了什么。

### 4.4 引擎步骤的三种情形（阻断项 2 的解法）

回滚**不能只卸载**：H28K 原本装有日期版，且 `chinadns_bin` 显式指向它；卸载后旧 proxy 会因为"显式路径不可执行"而 fail-closed，仍然起不来。

| 情形 | 判定 | 动作 | 失败回滚 |
|---|---|---|---|
| **首次新增**（未装 aether-dns） | 引擎不满足且 aether-dns 不存在 | 装 aether-dns | 卸载本次装的包（旧 proxy 不依赖它，安全） |
| **替换**（已装，且清单有 previous 资产） | 引擎不满足，清单有可回退版本 | 记下当前版本 → 装新包 | 从未被覆盖前重装 previous（`opkg install --force-downgrade`），**不卸载** |
| **替换但无回退资产**（如日期版） | 已装版本不在清单里 | **拒绝事务**，输出人工迁移指引（备份 + `--force-downgrade`）；不改任何包 | 不适用（什么都没做） |

第三种情形是本轮真正的迁移入口：日期版从未公开发布，清单里没有它可回退，所以**只能人工迁移**，
且必须先做备份（二进制 + 已装状态），并验证恢复路径。

### 4.5 步骤三态与幂等

| 步骤 | 执行条件 | 跳过条件 | 跳过的结果 |
|---|---|---|---|
| 引擎前置 | §4.3 判定为不满足，且属于 §4.4 的可自动情形 | 判定满足 | `skipped`，不下载不安装 |
| proxy 组 | 目标版本 ≠ 已装版本或未安装 | 版本相同 | `skipped`，不重装 |
| 重启服务 | 本次至少真的装了一个包 | 全部跳过 | 不重启、不改状态 |

- "需要"看**下限**，不看最新：引擎不因出了 1.0.1 就被顺带升级，它的更新由自己那一行决定。
- 跳过不是失败；只有"本应执行的那一步"出错（下载、签名/sha256、安装、启动）才算失败。
- 全跳过 → 作业成功、"已是最新"、不重启、不写 `UPDATE_INSTALLED`。
- 只回滚**执行过**的步骤；失败后重试只补缺的步骤（幂等）。

### 4.6 结果可见

作业结果新增 `prerequisite: { package, version, action: installed|skipped|rolled_back|manual_required }`；
aether-dns 的实际安装仍走既有 `UPDATE_INSTALLED` 事件，不新增事件码。

## 5. 各仓库改动清单

| 仓库 | 改动 |
|---|---|
| **aether-proxy** | 0.7.0：按引擎下限、存在性候选、reload 一致性、事务逻辑（仍 `Depends: chinadns-ng`）；1.0.0：`DEPENDS` 改 `+dns-engine`；`UPDATE_PACKAGES` 增加 `aether-dns`；LuCI 更新页与结果文案；`docs/01/04/05/08/09/10` |
| **aether-proxy-channel** | 0.7.0 与 1.0.0 的资产/清单；发布 aether-dns 资产（依 §8 归属）；`previous` 链要保证 1.0.0 的 previous 是 0.7.0 |
| **openwrt-actions** | 固件 config；`aether-dns-local/Makefile`：`PKG_VERSION:=1.0.0`、`PKG_RELEASE:=1`、`PROVIDES:=dns-engine`、`DEFAULT_VARIANT:=1`、源码 pin 与 hash；保留日期版包作为迁移测试样本 |
| **aether-dns** | banner 用 `env!("CARGO_PKG_VERSION")`；`Cargo.toml`/`Cargo.lock` 1.0.0；测试同时断言 banner 第二字段 == crate 版本 **且** 目标版本确为 1.0.0；发布说明写清反向组合与手工迁移 |

## 6. 测试用例

分三层：proxy 仓库能跑的、只有 SDK/通道 CI 能跑的、必须设备的。报告不得把第三层写成已通过。

### A. 包元数据与依赖（SDK/通道 CI；proxy 仓库只做静态断言）

| 编号 | 前置 | 动作 | 期望 |
|---|---|---|---|
| D1 | 改完两个 Makefile | 生成 control | `Provides: dns-engine` 两边都在；proxy 的 `Depends` 含 `dns-engine`、不含 `chinadns-ng` |
| D2 | 离线 root，无 provider | 装 proxy | 成功，自动装上一个 provider |
| D3 | 离线 root，先装 chinadns-ng | 装 proxy | 成功，不拉 aether-dns |
| D4 | 离线 root，两个 provider | 装 proxy | 成功；随后 `remove` 任一 provider 被拒 |

### B. 升级事务（proxy 仓库，`tests/update/` + 现有 stub opkg/apk）

| 编号 | 前置 | 动作 | 期望 |
|---|---|---|---|
| D5 | 引擎满足 | 更新 proxy | 引擎步骤 `skipped`，只装 proxy 组 |
| D6 | 引擎缺失 | 更新 proxy | 先装 aether-dns，再装 proxy，服务回 running |
| D7 | 引擎下载/校验失败 | 更新 proxy | 作业失败，proxy **完全没动**，服务保持原状 |
| D8 | 引擎首装成功、proxy 安装失败 | 更新 proxy | proxy 回滚；**卸载**本次装的 aether-dns；旧 proxy 能启动 |
| D9 | 引擎是"替换"且有 previous 资产，proxy 失败 | 更新 proxy | **恢复 previous，不卸载**；已装版本与元数据回到升级前 |
| D10 | 已装引擎版本不在清单（日期版） | 更新 proxy | **拒绝事务**，`manual_required`，不改任何包 |
| D11 | 引擎满足且 proxy 已最新 | 触发更新 | 全跳过；"已是最新"；不重启 |
| D12 | D8/D9 之后重试 | 再次更新 | 只补未完成步骤（幂等） |
| D13 | 成功/跳过/回滚/人工 | 读结果 | `prerequisite.action` 四值正确，字段形状固定 |

### C. 前置判定（proxy 仓库，unit）

| 编号 | 场景 | 期望 |
|---|---|---|
| D14 | 选中 aether-dns 0.9.9，chinadns-ng 2025.08.09 也在 | **判定不满足**（不被 chinadns-ng 掩盖） |
| D15 | 选中 aether-dns 2026.11.04 | 判定满足（> 1.0.0） |
| D16 | 选中 chinadns-ng 2025.08.09 | 判定满足 |
| D17 | engine 未知（自定义路径） | 判定满足、无下限 |
| D18 | 解析顺序与 daemon 一致 | 用同一函数，构造显式覆盖/存在性两种输入验证一致 |

### D. 运行时与 reload（proxy 仓库，unit + daemon + reload）

| 编号 | 场景 | 期望 |
|---|---|---|
| D19 | 两个二进制都在 | 选中 aether-dns，`engine='aether-dns'` |
| D20 | aether-dns 0.9.9 | 启动拒绝，`min='1.0.0'` |
| D21 | chinadns-ng 2025.08.08 | 启动拒绝，`min='2025.08.09'` |
| D22 | 改 `chinadns_bin` 后 reload | 子进程 argv 与 `state.components` 一致 |
| D23 | **同路径二进制升级**（版本变）后 reload | 子进程重启，`state` 版本与实际进程一致（不能只比路径） |
| D24 | 装上新引擎后 reload（无 UCI 变更） | 要么真切换，要么元数据不变 |

### E. 页面（proxy 仓库，`tests/luci/`）

| 编号 | 场景 | 期望 |
|---|---|---|
| D25 | 更新页有 aether-dns 更新 | 独立行，按钮语义与其它包一致 |
| D26 | 结果带 `prerequisite` | 显示"已先安装 DNS 引擎…"；跳过不显示；`manual_required` 显示迁移指引 |

### F. 固件构建（SDK，人工或构建 CI）

| 编号 | 场景 | 期望 |
|---|---|---|
| D27 | 只选 aether-proxy | 自动带出 aether-dns |
| D28 | 先选 chinadns-ng 再选 proxy | **不**强制 aether-dns |
| D29 | 两者都选 | 都进镜像，无冲突 |

### G. 设备（需单独授权）

| 编号 | 场景 | 期望 |
|---|---|---|
| D30 | 0.x → 0.7.0 在线更新 | 成功，依赖仍是 chinadns-ng，服务正常 |
| D31 | 0.7.0 + 装 DNS 1.0.0 | 0.7.0 接受 1.0.0，服务正常（验证桥接消除空窗） |
| D32 | 0.7.0 → 1.0.0 在线更新 | 引擎先装、proxy 后装、回 running/T1、`engine=aether-dns` |
| D33 | 事务失败注入（可选） | 按 D9 语义恢复；服务不停留在不可启动状态 |
| D34 | 日期版 → 1.0.0 的人工迁移命令 | 普通 install 被拒（`Not downgrading`）、`--force-downgrade` 成功、备份与恢复路径可用 |

## 7. 兼容与回退

- 手工降级不受支持：`opkg install` 旧 ipk 仍可执行，但"旧 proxy + DNS 1.0.0"会拒启；救急办法是把 `chinadns_bin`
  指回 `/usr/bin/chinadns-ng` 并 **restart**（reload 不够，见 D22）。
- `--force-depends remove` 只是**维护操作**：必须有替代引擎、已处理显式 `chinadns_bin`、并验证过恢复路径；
  不作为普通卸载建议。
- 别名 `components.chinadns-ng` 的删除要等含 M4-02 全部阶段的正式版发布后**再过一版**。

## 8. 未决

1. **aether-dns 的构建与分发归属**（DNS 侧建议 A）：A DNS CI 产包 → channel 校验后纳入既有签名清单；
   B 包定义搬进 proxy 仓库由 channel 构建；C proxy 直连 DNS release（不建议）。
   仍需约定支持架构、源码提交、工具链、包哈希与旧包留存。
2. **apk（25.x）未验证**：DNS 侧确认**目前没有可用的 25.x/apk 测试环境**，Debian VM 不能替代；
   本设计的依赖行为只在 opkg 上实测过，apk 需在拿到 25.x 环境后复测。
3. **aether-dns 是否进更新页主列表**：D25 依赖此决定。
