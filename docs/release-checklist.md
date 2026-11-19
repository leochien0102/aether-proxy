# 发版清单（1.1.x 起的常规流程）

面向仓库所有者与代理执行者。目标是**每个 commit 只构建一次**，发布的字节与被 smoke 验证的字节一致。
流程依据：M4-15（复用门禁产物）、T16.30（三个入口及同版本资产不可覆盖）。

## 0. 前提

- [ ] 这次发版由**真实改动**驱动（产品/页面/契约），不是只改文档或 CI。
- [ ] main 上的 CI 全绿：`test` + `build`（4 组打包 + 6 组 smoke）。
- [ ] 没有未合并的卡；`git status` 干净。

## 1. 版本与契约

- [ ] `aether-proxy/Makefile`、`luci-app-aether-proxy/Makefile`：`PKG_VERSION:=<ver>`、`PKG_RELEASE:=1`。
- [ ] `tests/compat/update-contract.json`：
  - [ ] `support_window` → `["<ver>", "<prev>"]`（当前 + 上一个正式版）；
  - [ ] 新增 `clients["<ver>"]`，与上一版同形（四个 `UPDATE_PACKAGES` + `aether-dns`、`route: direct`）；
  - [ ] 滑出窗口的版本改 `manual-only`；更老版本保持 `manual-only`。
- [ ] `docs/08-updates.md`：窗口句、迁移表加新行、滑出版本改 `manual-only`。
- [ ] 发布说明 `docs/releases/<ver>-r1.md`（**文件名必须含 `-rN`**，`release-assets` 按 tag 推导）。
- [ ] 跑一遍：`bash tests/compat/run.sh && bash tests/luci/run.sh && tests/host/ucode tests/run.uc && bash tests/cli/run.sh && bash tests/update/run.sh`。

## 2. 一次推送（门禁）

- [ ] 把上面所有改动合成**一次推送**到 main。CI 的 `build` 就是这次发布唯一的构建。
- [ ] 等 `test` 与 `build` 都成功，记下 `build` 的 run id 与 SHA。

## 3. 发 RC（预发布 + 持久的 RC 通道）

```bash
tools/release/rc.sh 1.2.1 --dry-run
tools/release/rc.sh 1.2.1
```

在干净工作树上运行。脚本核对 HEAD 的版本、迁移契约、发布说明和同 SHA 的成功门禁，推送下一个
`v<ver>-r<n>-rc<N>`（从 `rc1` 起，绝不覆盖），等待 `release-candidate`，打印预发布 URL 和 26/27 件资产。
确认预发布来自同一 commit 的门禁后，派发 `promote.yml`（`release_tag=RC tag`, `publish_target=rc`）。
签名清单会持久写到 [`channel-rc`](https://github.com/leochien0102/aether-proxy-channel/releases/tag/channel-rc)，
供开启 RC 检查的设备读取。清单整体 `prerelease: true`，24 个架构/格式格子的哈希与 RC 一致；`previous`
取 stable 当前同包条目。下一次发 RC 会替换旧条目，成功发布 stable 后清空。
RC 包沿用最终包版本（如 `1.2.1-r1`）；这一步**不写 stable、不打正式 tag、不建正式 Release**。
未通过试用就停在这里。三条入口的 `--dry-run` 只打印计划，允许查询 GitHub 元数据；不会推 tag 或派发工作流。
`rc.sh 0.0.0-dryrun --dry-run` 是合成示例，只借一个已发布版本的真实门禁来展示计划。

## 4. RC Promote（Release → RC 字节对照 → stable）

```bash
tools/release/promote-rc.sh v1.2.1-r1-rc1 --dry-run
tools/release/promote-rc.sh v1.2.1-r1-rc1
```

仅用于已通过试用的 RC。核对 prerelease、候选工作流和 manifest 与 RC tag 指向同一门禁 commit 后，先推同一
commit 的正式 tag。此时 stable 没有该版本，`release-assets` 走 direct，从同 commit 门禁产物组 18 件并发布。
再确认正式 Release 不是 draft/prerelease、正式 tag 与 RC 同 commit，并逐件比较 18 个正式包与对应 RC 包的
SHA-256（noarch 选择 ARM64 构建副本）。**任一项不一致就停止，不写通道**。只有比对通过才用**正式 tag**
派发 `promote.yml`（`publish_target=stable`）；stable 成功后清空持久的 `channel-rc`。

- **正式 tag 已推、Release 失败**：不要重打 tag；核对 tag commit 后手动重跑 app `release-assets.yml`
  （`tag=正式 tag`, `dry_run=false`）。正式 Release 成功后再做下述比对。
- **Release 已发、通道未推进**：先重新验证，再以正式 tag 派发 stable（示例）：

  ```bash
  python3 tools/release/verify.py compare leochien0102/aether-proxy v1.2.1-r1 v1.2.1-r1-rc1 &&
    gh workflow run promote.yml -R leochien0102/aether-proxy-channel --ref main -f release_tag=v1.2.1-r1 -f publish_target=stable
  ```

  若比对失败，保留 `channel-rc`，查明原因；不挪动 tag、不覆盖已发资产、不绕过比对。

## 5. 发 Release（不经过 RC，Release 先于通道）

```bash
tools/release/release.sh 1.2.1 --dry-run
tools/release/release.sh 1.2.1
```

前置检查与发 RC 相同。先推正式 tag；如果 stable 还没有该版本，`release-assets` 为 tag commit 选门禁、
下载产物并组装 18 件正式包，验证 `SHA256SUMS` 后创建 Release。再派发 `promote.yml`（正式 tag、`publish_target=stable`）
推进 stable，并在成功后清理残留的 `channel-rc`。入口打印 Release URL、`current/previous` 及 24 个架构/格式格子的
SHA-256（noarch 每格式实际一件）。

- **Release 已发、通道未推进**：重跑通道仓 `promote.yml`，`release_tag=正式 tag`, `dry_run=false`；不重发 Release。
- **直接发版组包失败**：修复门禁产物/权限后在 app 仓重跑 `release-assets.yml`，不重新推同一个 tag。
  如同版本同名包与 stable 的字节不同，停止发布，检查可复现性或提升该组件的包修订号，再以新 commit 走门禁。
  新发版不从旧 Release 替换门禁包；历史上做过此类替换的 RC 只可用于 `--dry-run`，不能再推进。

已部署新工作流后，可单独手动派发远端只读验收：

```bash
gh workflow run release-assets.yml -R leochien0102/aether-proxy --ref main -f tag=v1.2.1-r1 -f dry_run=true
gh workflow run promote.yml -R leochien0102/aether-proxy-channel --ref main -f release_tag=v1.2.1-r1 -f publish_target=stable -f dry_run=true
gh workflow run promote.yml -R leochien0102/aether-proxy-channel --ref main -f release_tag=v1.2.1-r1-rc1 -f publish_target=rc -f dry_run=true
```

前者强制走直发组包，即使 stable 已有此版本；后者读取已发布的 18 件套，打印将保留/写入的清单版本和哈希。
第三条校验 RC 并预演持久 RC 清单。以上远端 dry-run 都不修改 Release 或通道；本地入口的 dry-run 不执行这些命令。

## 6. 固件 feed 钉版（**每次发版必做**，2026-11-17 起固化）

固件构建从 `openwrt-actions` 的 `configs/feeds.conf` 取 `aetherproxy` 提交，**与通道无关**；
不同步就会出现"在线更新已是新版、刷固件还是旧版"。

- [ ] 把 `openwrt-actions/configs/feeds.conf` 里 `src-git aetherproxy ...^<提交号>` 改成
      本次正式 tag 的**完整提交号**（`git -C <aether-proxy> rev-parse v<ver>-r<n>^{commit}`），
      并把上一行的「当前 v<版本>」注释同步。
- [ ] 提交并推送 `openwrt-actions` main（`📌 feeds: pin aether-proxy <版本>`）。
- [ ] 固件构建只跑每周日定时 + 手动 dispatch，推送本身不触发；需要立即验证时手动 dispatch。

## 7. 设备与记录

- [ ] H28K 页面更新；核对版本、`UPDATE_STARTED/INSTALLED` 事件、无 `PREREQ_*`、配置哈希、`boot_id`。
- [ ] 写 `docs/validation/<ver>-release-<date>.md`，更新 `docs/tasks/README.md`。
- [ ] 发布后另出**兼容快照**卡（B17：冻结新发布的版本，换 `tests/compat/fixtures/`）。

## 失败处理

| 现象 | 处理 |
|---|---|
| RC 失败「No successful build.yml run」/ 产物过期 | 先让门禁在该 SHA 成功；确认 `build.yml` 产物保留期（90 天） |
| RC 失败「Missing/duplicate SDK artifact matrix」 | 门禁运行不完整，重跑门禁，不要绕过 |
| promote 失败「Same version has different assets」 | 仅使用同 commit 门禁字节；不得覆盖同版本资产或手工改清单，按第 5 节处理 |
| promote 失败「RC tag/commit binding mismatch」 | RC 与正式 tag 必须在同一 commit |
| release-assets 失败（版本不一致/资产缺失） | 按第 4–5 节区分匹配清单路径与直发路径后重跑 |

**回退**：只允许显式决定——更新通道 `AETHER_PROXY_REF` 走直发 `packages`（会再构建一次），并在
`docs/validation/` 里写明原因；不要静默回退。

## 组件发布（与应用解耦）

**xray 核心**（`aether-xray`）只受上游版本驱动，不升应用版本：

- [ ] 只改 `aether-xray/Makefile` 的 `PKG_VERSION` 与源码 `PKG_HASH`（必要时 `GO_TOOLCHAIN_VERSION`）；
- [ ] 推送后等门禁 `build` 成功（含 smoke 的 `xray run -test`）；
- [ ] 更新通道 `AETHER_PROXY_REF` 到该提交，并 `workflow_dispatch` `packages`、`components` 填 `aether-xray`
      （只构建该组件，其余条目由 `--keep-missing` 保留）；
- [ ] 核对清单：`aether-xray` 版本/哈希已更新、`previous` 正确，**应用版本不变**；
- [ ] 设备在更新页只会看到 `aether-xray` 有更新。

**DNS 引擎**（`aether-dns`）：由 DNS 仓库发布；proxy 的 `aether-dns/Makefile` 按架构下载裸二进制，
通道 `packages` 重新构建后清单更新，同样不升应用版本。
