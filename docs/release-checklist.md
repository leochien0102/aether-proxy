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
- [ ] 发布说明 `docs/releases/<ver>-rN.md`（**文件名必须含 `-rN`**，`release-assets` 按 tag 推导），按下节核对用户摘要与最终代码；首份新格式为 [1.3.0-r1 未发布草稿](releases/1.3.0-r1.md)。
- [ ] 发版准备时再把草稿的「未发布」改为实际发布日期；草稿存在不表示已升包版本、扩展兼容窗口或正式发布。
      提交遵循 [12-ucode.md「协作流程」](12-ucode.md#协作流程)，正式版本提交仍用 `🔖 release: <ver>-rN`。
- [ ] 跑一遍：`bash tests/compat/run.sh && bash tests/luci/run.sh && tests/host/ucode tests/run.uc && bash tests/cli/run.sh && bash tests/update/run.sh`。

### 用户版发布说明（从 1.3.0-r1 起）

- 每个版本只维护 `docs/releases/<ver>-rN.md` 一份说明。草稿在标题下明确写「状态：未发布」，不填发布日期；
  实际发布时才填写日期，不回改旧版本说明或历史提交来套新格式。
- 固定二级标题 `## 主要变化`；有升级影响时增加 `## 升级须知`，没有则省略后者。
  两节各用单层 `- ` 纯文本列表，一条占一行；不用嵌套列表、加粗、链接、表格、代码块或行内代码。
  每条直接说明用户效果；升级须知写适用对象、升级前动作与限制，不用笼统的「优化体验」。
- 这两节是正式 Release 与 LuCI 共用的唯一摘要来源，不另维护一份界面文案。
  其他二级标题后的内容仅供维护者阅读，不混入用户摘要。
- LuCI 构建期由 `luci-app-aether-proxy/tools/build-changelog.py` 提取最多 8 个近期正式版本，按数值版本及 rN 倒序。
  文件名须为 `<ver>-rN.md`，标题下须有 `发布日期：YYYY-MM-DD`，且没有「未发布」标记；无日期或草稿不随包分发。
  旧格式只带版本与精确 Release 链接，不推测正文范围。构建必须保留包目录旁的 `docs/releases`，缺目录直接失败。
  更新页末尾折叠展示，摘要离线可读，Release 链接须联网；应用安装版本取既有更新状态，无记录时明确显示未知，
  缺少对应摘要不以最新版代替。正式态验收使用 `tests/luci/fixtures/changelog`，不修改真实草稿状态。
- 以「上一正式 tag..本次目标提交」的最终净变化为依据，按用户效果归并；同一修复只写一次，
  不把修复、补测、返工各列一条，不逐条翻译 git log。任务号、提交 SHA、测试数量和技术细节放在后面的维护者章节或任务报告。
- 逐条核对摘要对应的最终代码与任务卡，报告保留对应关系；特别核对包源版本/哈希是否已集成，
  独立 DNS 仓的已合并改动不等于应用包已交付。测试、CI 加固、临时方案和未完成的界面不得包装成用户功能。
- `1.3.0-r1` 首稿基线为 `v1.2.2-r10..HEAD`，不是重写 r10。后续合入或正式发版前重新核对目标提交，
  不因草稿已写就假定未来版本内容或升级路径已确定。此约定不新增 CI。

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

此入口只发布本仓 Makefile 生成的 **OpenWrt 包**，不发布上游裸二进制，不走应用正式版的 18 件组装链。
现有组件/tag 映射保持不变：`aether-xray` → `xray-v<版本>`、`aether-dns` → `dns-v<版本>`、
`chinadns-ng` → `chinadns-ng-v<版本>`（版本均含 `-rN`）。

- **xray 核心**：`aether-xray/Makefile` 从上游源码构建；只受上游版本驱动，不升应用版本。
- **DNS 引擎**：上游 DNS 仓库发布裸二进制（也有供人工下载的包）；本仓 `aether-dns/Makefile`
  下载哈希钉定的裸二进制并生成本仓 OpenWrt 包。`dns-v…` 仅表示这些包，不新增 DNS 上游发布入口。
- **ChinaDNS-NG**：`chinadns-ng/Makefile` 将上游哈希钉定的静态二进制打包；现有组件入口可发布这些包，
  不改变设备端手动安装/更新的策略。

发布核对：

- [ ] 按组件更新本仓 Makefile 的版本与来源哈希（xray 必要时同步 Go 工具链），不要升应用版本。
- [ ] 使用代码仓库 `release-component.yml`，输入单个组件及 Makefile 对应的 `<ver>-rN`。
      它调用现有 `build.yml` 的组件构建；组件-only 构建不保证运行应用 smoke，不宣称 dataplane 验证。
- [ ] 下载必须保留 `packages-<SDK>-<package_arch>` 目录；`24.10.8/IPK`、`25.12.5/APK`
      各有 `x86_64`、`aarch64_generic`，四槽每槽恰一件包。生产入口
      `tools/release/collect_component.py` 读取包内名称、版本、架构并核对槽位与格式，拒绝缺件、重复及输出名碰撞。
- [ ] 最终 IPK 为 `<组件>_<版本>_<架构>.ipk`，APK 为 `<组件>-<版本>_<架构>.apk`；
      架构只出现一次。四件全部通过后原子生成 `assets/`，内含四包及逐件验算的 `SHA256SUMS`。
      不覆盖已有输出目录，也不覆盖已有同 tag Release。
- [ ] 通道只拉取此正式组件 Release 已发布字节并验哈希，用 `--keep-missing` 保留其它条目；
      不为组件通道更新重编包，不把通道 ref 当成组件字节来源。
- [ ] 核对版本/哈希、`previous` 和设备更新策略，**应用版本不变**。

离线收集回归：`python3 tests/ci/test_component_assets.py`（不下载 SDK、不创建 Release）。
