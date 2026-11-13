# 发版清单（1.1.x 起的常规流程）

面向仓库所有者与代理执行者。目标是**每个 commit 只构建一次**，发布的字节与被 smoke 验证的字节一致。
流程依据：M4-15（复用门禁产物）、M4-17（未变版包复用已发布字节）。

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

## 3. RC（不重建）

- [ ] 在**同一个 commit** 打 RC tag：`v<ver>-r1-rc1`，push。
- [ ] `release-candidate` 成功，且该运行里**没有** packages 编译 job。
- [ ] 逐字节对比门禁产物与 RC 资产（应 20/20 一致）：

```bash
g=$(mktemp -d); r=$(mktemp -d)
gh run download <build_run_id> -R leochien0102/aether-proxy -D "$g"
gh release download v<ver>-r1-rc1 -R leochien0102/aether-proxy -D "$r"
python3 - "$g" "$r" <<'PY'
import hashlib, re, sys
from pathlib import Path
g, r = Path(sys.argv[1]), Path(sys.argv[2])
bad = n = 0
for f in g.rglob('*'):
    if f.suffix not in ('.ipk', '.apk'): continue
    arch = [p.name for p in f.parents if p.name.startswith('packages-')][0]
    arch = re.sub(r'^packages-[^-]+-', '', arch)
    cand = r / (arch + '--' + re.sub(r'[^A-Za-z0-9._-]', '.', f.name))
    if not cand.exists(): print('MISSING', f.name); bad += 1; continue
    n += 1
    if hashlib.sha256(f.read_bytes()).hexdigest() != hashlib.sha256(cand.read_bytes()).hexdigest():
        print('DIFF', cand.name); bad += 1
print(f'{n} compared, {bad} mismatches')
PY
```

## 4. Promote（通道）

- [ ] 触发（通道仓库，main）：

```bash
gh workflow run promote.yml -R leochien0102/aether-proxy-channel --ref main -f rc_tag=v<ver>-r1-rc1
```

- [ ] `promote` 成功；通道 `channel-stable` 清单里 `aether-proxy` / `luci-app-aether-proxy` 的 `current`
      为 `<ver>-r1`、`previous` 为上一版；未变版包的 `sha256` 与上一版**相同**。
- [ ] 确认通道**没有**触发新的 `packages` 构建。

## 5. 正式发布

- [ ] 在**同一个 commit** 打正式 tag：`v<ver>-r1`，push。
- [ ] `release-assets` 成功；Release 为 **18 个资产**、非 draft、Latest；说明来自 `docs/releases/<ver>-r1.md`。
- [ ] 抽查一个未变版包（如 `aether-xray`）与上一版 Release 的哈希相同。

## 6. 设备与记录

- [ ] H28K 页面更新；核对版本、`UPDATE_STARTED/INSTALLED` 事件、无 `PREREQ_*`、配置哈希、`boot_id`。
- [ ] 写 `docs/validation/<ver>-release-<date>.md`，更新 `docs/tasks/README.md`。
- [ ] 发布后另出**兼容快照**卡（B17：冻结新发布的版本，换 `tests/compat/fixtures/`）。

## 失败处理

| 现象 | 处理 |
|---|---|
| RC 失败「No successful build.yml run」/ 产物过期 | 先让门禁在该 SHA 成功；确认 `build.yml` 产物保留期（90 天） |
| RC 失败「Missing/duplicate SDK artifact matrix」 | 门禁运行不完整，重跑门禁，不要绕过 |
| promote 失败「Same version has different assets」 | M4-17 应已阻止；检查 RC 是否用了已发布字节；不得手工改清单 |
| promote 失败「RC tag/commit binding mismatch」 | RC 与正式 tag 必须在同一 commit |
| release-assets 失败（版本不一致/资产缺失） | 核对通道清单 `current` 与 tag 推导的版本是否一致 |

**回退**：只允许显式决定——更新通道 `AETHER_PROXY_REF` 走直发 `packages`（会再构建一次），并在
`docs/validation/` 里写明原因；不要静默回退。
