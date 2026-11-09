# DNS 引擎依赖与在线升级事务（设计草案，2026-11-09）

> 状态：**方向已定、未落地**。虚拟依赖（`dns-engine`）+ `DEFAULT_VARIANT` + 在线升级事务化三条已由所有者确认；
> aether-dns 的**包构建与分发归属尚未定**（§8），它决定通道侧能否发布 aether-dns。
> 本文是设计输入，不是实现授权：不构成构建、发版、安装或设备操作许可。
> 版本下限规则本身见 [M4-03 卡](../tasks/m4.md) 与 DNS 侧[版本契约草案](../../../aether-dns/docs/design/semver-contract-20261109.md)。

## 1. 目标与非目标

**目标**

- `aether-proxy` 对 DNS 引擎的依赖表达为"**必选其一、可共存**"：装任一引擎即可满足，两个都装也允许。
- 在线升级把"引擎前置 + 代理组"变成**一次可回滚的事务**：先满足依赖，再换代理；任一步失败都回到升级前能启动的组合。

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

# aether-proxy/Makefile
DEPENDS:= ... +dns-engine      # 原来是 +chinadns-ng
```

构建系统的转换规则（`scripts/package-metadata.pl:180-198`，已核对源码）：

```kconfig
select PACKAGE_aether-dns if PACKAGE_chinadns-ng<PACKAGE_aether-proxy
```

即"默认带出 aether-dns；**用户显式把 chinadns-ng 选成 y 时不再强制 aether-dns**"。`DEFAULT_VARIANT` 通过
（`metadata.pm:277` → `package-dumpinfo.mk:29`）决定哪个 provider 被排到首位。

### opkg 行为实测（2026-11-09，SDK host opkg + 离线 root + 自制 ipk）

| 场景 | 结果 |
|---|---|
| 无 provider 已装，安装依赖 `dns-engine` 的包 | opkg **自动装了一个 provider**（本次落在 chinadns-ng；顺序属实现细节，**不可依赖**） |
| 先装任一 provider | 满足，不再拉另一个 |
| 两个 provider 共存 | 允许，无冲突 |
| 卸载唯一 provider | 拒绝（`No packages removed`），需 `--force-depends` |
| 两个 provider 都在，卸其中一个 | **同样被拒**（opkg 不评估"还有别的 provider"），需 `--force-depends` |
| 断开 feed、只靠已装元数据装 proxy ipk | **成功**（依赖由已装包的 `Provides` 满足） |

最后一行是设备上的真实形态：更新流程装的是单个 ipk，通道并不是 opkg feed。

### 迁移前提

现网已装的 `chinadns-ng 2025.08.09-1` 与 `aether-dns 2026.11.04-1` 都是用**没有 `Provides` 的旧 Makefile** 构建的，
已装元数据里没有这个虚拟名。所以：

- 新 proxy 的 `Depends: dns-engine` **只能由本次事务先装的 `aether-dns 1.0.0` 满足**；
- 反过来说，"先装 aether-dns、再装 proxy"不是可选的优化，而是升级路径的必要条件。

## 3. 四场景矩阵

| 场景 | 顺序 | 依赖满足方式 | 运行时引擎 | 失败后果 |
|---|---|---|---|---|
| 手动装包（不刷机） | aether-dns → aether-xray → aether-proxy → luci-app → i18n | 已装 aether-dns 提供 `dns-engine` | 存在性优先 aether-dns，缺失回落 chinadns-ng | 无任何引擎时 opkg 报缺 `dns-engine`；只有 chinadns-ng 时可装可用 |
| 在线更新 0.x → 1.0.0 | 事务内：引擎 → proxy 组 | 同上 | aether-dns | 任一步失败 → 回滚到"能启动的旧组合" |
| 刷机 | 镜像一次装全 | 构建期解析 | aether-dns（两者都在时仍优先它） | 不适用 |
| 固件构建 | `+dns-engine` + `PROVIDES` + `DEFAULT_VARIANT` | 构建期 | 同上 | 构建期暴露 |

## 4. 事务语义

事务是**顺序化计划**，不是"每个组件都装一遍"。每步三态：

| 步骤 | 执行条件 | 跳过条件 | 跳过的结果 |
|---|---|---|---|
| 引擎前置 | 无已装 provider，或已装引擎低于下限 | 有 provider 且版本 ≥ 1.0.0 | `skipped`，不下载不安装 |
| proxy 组（proxy/luci/i18n） | 目标版本 ≠ 已装版本或未安装 | 版本相同 | `skipped`，不重装 |
| 重启服务 | 本次至少真的装了一个包 | 全部跳过 | 不重启、不改状态 |

固定规则：

1. **"需要"看下限，不看最新**：引擎前置只保证 ≥ 1.0.0，不会顺手升级到更新版本；引擎自己的更新由它自己那一行决定。
2. **跳过不是失败**：只有"本应执行的那一步"出错（下载、签名/sha256、安装、启动）才算失败。
3. **幂等**：全部跳过 → 作业成功、返回"已是最新"、不重启、不写 `UPDATE_INSTALLED`；失败后重试只补缺的步骤。
4. **只回滚执行过的步骤**：
   - 引擎跳过 + proxy 失败 → 只回滚 proxy；
   - 引擎执行 + proxy 失败 → 回滚 proxy，并**仅当回滚目标 proxy < 1.0.0**（即不依赖 `dns-engine`）时卸载本次装的 aether-dns；
   - 引擎执行失败 → 事务停在第一步，proxy 完全不动，服务保持原样。
5. **结果可见**：作业结果新增 `prerequisite: { package, version, action: installed|skipped|rolled_back }`；
   aether-dns 的实际安装仍走既有 `UPDATE_INSTALLED` 事件，不新增事件码。

## 5. 各仓库改动清单

| 仓库 | 改动 |
|---|---|
| **aether-proxy** | `Makefile` 的 `DEPENDS` 改 `+dns-engine`；`UPDATE_PACKAGES` 增加 `aether-dns`；`update.uc` 两阶段事务与结果字段；LuCI 更新页新增引擎行与前置结果文案；`docs/01/04/05/08/09/10`；测试见 §6 |
| **aether-proxy-channel** | 构建与发布清单加入 `aether-dns`；资产名/版本校验/`AETHER_PROXY_REF` 相关检查（取决于 §8 的归属决定） |
| **openwrt-actions** | 固件 config 增加 aether-dns；`aether-dns-local/Makefile`：`PKG_VERSION:=1.0.0`、`PKG_RELEASE:=1`、`PROVIDES:=dns-engine`、`DEFAULT_VARIANT:=1`、源码 pin 与 hash |
| **aether-dns** | banner 取 `env!("CARGO_PKG_VERSION")`；`Cargo.toml`/`Cargo.lock` 1.0.0；`-V` 断言；发布说明写清反向组合不支持 |

## 6. 测试用例

分三层：**proxy 仓库能跑的**、**只有 SDK/通道 CI 能跑的**、**必须设备的**。报告不得把第三层写成已通过。

### A. 包元数据与依赖（SDK/通道 CI 或 openwrt-actions；proxy 仓库只做静态断言）

| 编号 | 前置 | 动作 | 期望 | 承载 |
|---|---|---|---|---|
| D1 | 改完两个 Makefile | 生成 control 文件 | `Provides: dns-engine` 两边都在；aether-proxy 的 `Depends` 含 `dns-engine`、不再含 `chinadns-ng` | proxy 仓库 `tests/release/` 静态断言 |
| D2 | 离线 root，无 provider | 装 aether-proxy | 成功，且自动装上一个 provider | SDK/通道 CI（脚本化 §2 的实验） |
| D3 | 离线 root，先装 chinadns-ng | 装 aether-proxy | 成功，不拉 aether-dns | 同上 |
| D4 | 离线 root，两个 provider | 装 aether-proxy | 成功；随后 `remove` 任一 provider 被拒 | 同上 |

### B. 升级事务（proxy 仓库，`tests/update/` + 现有 stub opkg/apk）

| 编号 | 前置 | 动作 | 期望 |
|---|---|---|---|
| D5 | 引擎已满足（1.0.0 已装） | 更新 proxy | 引擎步骤 `skipped`，只装 proxy 组 |
| D6 | 引擎缺失 | 更新 proxy | 先装 aether-dns，再装 proxy，服务回到 running |
| D7 | 引擎下载/校验失败 | 更新 proxy | 作业失败，proxy **完全没动**，服务保持原状 |
| D8 | 引擎装好、proxy 安装失败 | 更新 proxy | proxy 回滚到 prior；本次装的 aether-dns 被卸载；旧 proxy 能启动 |
| D9 | 回滚目标 proxy 已依赖 `dns-engine` | 同上 | **不卸载** aether-dns（否则依赖断裂） |
| D10 | 引擎满足且 proxy 已是最新 | 触发更新 | 全跳过；返回"已是最新"；不重启；无 `UPDATE_INSTALLED` |
| D11 | D8 之后重试 | 再次更新 | 只补未完成的步骤（幂等） |
| D12 | 成功/失败/跳过三种结果 | 读作业结果 | `prerequisite.action` 分别为 installed/skipped/rolled_back，字段形状固定 |

### C. 运行时引擎选择与下限（proxy 仓库，unit + daemon）

| 编号 | 场景 | 期望 |
|---|---|---|
| D13 | 两个二进制都在 | 选中 aether-dns（存在性优先），`engine='aether-dns'` |
| D14 | 只有 chinadns-ng | 选中它，`engine='chinadns-ng'` |
| D15 | 显式 `chinadns_bin` 指向别的路径 | 用覆盖值，`engine=null`，不设下限、信息性放行 |
| D16 | aether-dns 0.9.9 | 启动拒绝，`COMPONENT_TOO_OLD.min='1.0.0'` |
| D17 | chinadns-ng 2025.08.08 | 启动拒绝，`min='2025.08.09'`（下限不随引擎漂移） |

### D. reload 一致性（proxy 仓库，`tests/reload/`）

| 编号 | 场景 | 期望 |
|---|---|---|
| D18 | 改 `chinadns_bin` 后 reload | 子进程 argv 与 `state.components` 一致（当前**不**一致，本设计要求修） |
| D19 | 装上新引擎后 reload（无 UCI 变更） | 同上：要么真的切过去，要么元数据不变，不允许"说切了没切" |

### E. 页面（proxy 仓库，`tests/luci/`）

| 编号 | 场景 | 期望 |
|---|---|---|
| D20 | 更新页有 aether-dns 更新 | 出现独立行，安装/更新按钮语义与其它包一致 |
| D21 | 作业结果带 `prerequisite` | 显示"已先安装 DNS 引擎 aether-dns <版本>"；跳过时不显示 |

### F. 固件构建（SDK，人工或构建 CI）

| 编号 | 场景 | 期望 |
|---|---|---|
| D22 | 只选 aether-proxy | 自动带出 aether-dns |
| D23 | 先选 chinadns-ng 再选 aether-proxy | **不**强制 aether-dns |
| D24 | 两者都选 | 都进镜像，无冲突 |

### G. 设备（需单独授权）

| 编号 | 场景 | 期望 |
|---|---|---|
| D25 | H28K 0.x → 1.0.0 在线更新 | 引擎先装、proxy 后装、服务回 running/T1、`components` 显示 `engine=aether-dns`、`dns` 键存在 |
| D26 | 失败注入（可选） | 按 D8 语义恢复；服务不停留不可启动状态 |

## 7. 兼容与回退

- 手动降级不受支持：`opkg install` 旧 ipk 仍可执行，但"旧 proxy + DNS 1.0.0"会拒启；救急办法是把 `chinadns_bin` 指回
  `/usr/bin/chinadns-ng` 并 **restart**（reload 不够，见 D18）。
- JSON 别名 `components.chinadns-ng` 的删除要等含 M4-02 全部阶段的正式版发布后**再过一版**。

## 8. 未决

1. **aether-dns 的构建与分发归属**（阻塞通道侧）：
   - A：DNS 仓库 CI 出 ipk → channel 只做搬运、签名、进清单；
   - B：包定义搬进 aether-proxy 仓库，channel 直接构建（需引入 Rust 构建链）；
   - C：proxy 更新流程直连 DNS release（第二套验签，不建议）。
2. **apk（25.x）未验证**：本设计的依赖实测只在 opkg 上做过；apk 的 `provides` 语义相近，但必须在新固件上复测一次。
3. **aether-dns 是否进更新页主列表**：D20 依赖此决定；若只作为前置静默安装，则不需要独立行。
