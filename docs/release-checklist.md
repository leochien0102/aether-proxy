# 发版清单（1.1.x 起的常规流程）

面向仓库所有者与代理执行者。目标是**每个 commit 只构建一次**，发布的字节与被 smoke 验证的字节一致。
流程依据：M4-15（复用门禁产物）、T16.35（只发布正式通道，不覆盖同版本资产）。

不提供候选通道；试用请手动下载并安装预发布 Release，预发布不会进入更新通道。

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

## 3. 发 Release

```bash
bash tools/release/release.sh 1.2.1 --dry-run
bash tools/release/release.sh 1.2.1
```

正式入口核对干净工作树、HEAD 版本、迁移契约、发布说明及同 SHA 的成功门禁，再推正式 tag。
stable 还没有该版本时，`release-assets` 按 tag commit 下载门禁产物，组装 18 件正式包并验证 `SHA256SUMS`，
再创建 Release（资产版本、SHA-256 与 commit 写入发布说明的 inventory 注释，不额外上传一件资产）。
stable 已有该版本时，工作流只核对已有正式 Release 与 stable 的实际包字节，不重建、不创建或覆盖 Release。

正式 tag 已推但 Release 失败时，核对 tag commit 后手动重跑 app 仓 `release-assets.yml`（`tag=正式 tag`，
`dry_run=false`），不要重推 tag。

**同版本包复用已发布字节（M4-17）**：不是每个组件都会随版本升号。门禁会重新构建全部组件，
构建产物未必逐字节可复现；因此 `stage.py` 在正式组装时先读 `channel-stable` 清单，对**版本号与
已发布版本相同**的包，直接取通道里的已发布字节（逐个校验 sha256/size），再写 `SHA256SUMS` 与
inventory。所以 Release 的字节来源是「升号包用门禁产物、未升号包用已发布字节」，二者都必须能在
stable 清单里对上。若复用之后仍有冲突，才说明版本号变了却没构建出预期内容，这时才停止发布。

## 4. 写正式通道

`release.sh` 在正式 Release 成功后自动派发 channel 仓的 `publish-channel.yml`。工作流只接受已发布的正式 tag，
下载已发布包并验 18 件包、版本和 inventory（旧 Release 若无注释，则从资产名及下载字节计算）；
随后预览并写入签名的 `channel-stable`，不重新构建包。入口最终核对正式 Release 与通道的实际下载字节，
打印 Release URL、`current/previous` 与 24 个架构/格式格子的 SHA-256（noarch 每格式实际一件）。

Release 已发但尚未写通道时，只需重跑通道仓 `publish-channel.yml`（`release_tag=正式 tag`、`dry_run=false`），
不用重发 Release。两边发布成功后可重跑只读对照：
`python3 tools/release/verify.py compare leochien0102/aether-proxy v1.2.1-r1`。

本地 `--dry-run` 只查询 GitHub 元数据并打印计划，不打 tag、不派发工作流。部署后可另行手动派发远端预演：

```bash
gh workflow run release-assets.yml -R leochien0102/aether-proxy --ref main -f tag=v1.2.1-r1 -f dry_run=true
gh workflow run publish-channel.yml -R leochien0102/aether-proxy-channel --ref main -f release_tag=v1.2.1-r1 -f dry_run=true
```

前者强制从门禁组装 18 件包；后者读取正式 Release，预览将保留或写入的清单及哈希。两者都不改远端 Release。

## 5. 固件 feed 钉版（**每次发版必做**，2026-11-17 起固化）

固件构建从 `openwrt-actions` 的 `configs/feeds.conf` 取 `aetherproxy` 提交，**与通道无关**；
不同步就会出现"在线更新已是新版、刷固件还是旧版"。

- [ ] 把 `openwrt-actions/configs/feeds.conf` 里 `src-git aetherproxy ...^<提交号>` 改成
      本次正式 tag 的**完整提交号**（`git -C <aether-proxy> rev-parse v<ver>-r<n>^{commit}`），
      并把上一行的「当前 v<版本>」注释同步。
- [ ] 提交并推送 `openwrt-actions` main（`📌 feeds: pin aether-proxy <版本>`）。
- [ ] 固件构建只跑每周日定时 + 手动 dispatch，推送本身不触发；需要立即验证时手动 dispatch。

## 6. 设备与记录

- [ ] H28K 页面更新；核对版本、`UPDATE_STARTED/INSTALLED` 事件、无 `PREREQ_*`、配置哈希、`boot_id`。
- [ ] 写 `docs/validation/<ver>-release-<date>.md`，更新 `docs/tasks/README.md`。
- [ ] 发布后另出**兼容快照**卡（B17：冻结新发布的版本，换 `tests/compat/fixtures/`）。

## 失败处理

| 现象 | 处理 |
|---|---|
| release-assets 失败「No successful build.yml run」/ 产物过期 | 先让门禁在该 SHA 成功；确认 `build.yml` 产物保留期（90 天） |
| release-assets 失败「Missing/duplicate SDK artifact matrix」 | 门禁运行不完整，重跑门禁，不要绕过 |
| 写通道失败「Same version has different assets」 | 仅使用同 commit 门禁字节；不得覆盖同版本资产或手工改清单，按第 3–4 节处理 |
| release-assets 失败（版本不一致/资产缺失） | 按第 3 节核对 tag 与门禁后重跑 |

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
