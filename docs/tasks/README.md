# 任务卡

派给实现 agent 的任务卡。每张卡对应一个分支，由执行者在本地完成，设计负责人复审后合并（流程见下方「执行约定」）。

| 文件 | 里程碑 | 状态 |
|---|---|---|
| [m0.md](m0.md) | M0 骨架、打包、测试环境、探针 | T0.1–T0.6、S5 已完成；S1–S4、S6 由设计负责人在测试路由器上执行 |
| [m1.md](m1.md) | M1 配置读取、校验、渲染器 | T1.1–T1.13 已完成 |
| [m2.md](m2.md) | M2 启停、数据面上真机 | T2.0–T2.9 已完成（真机验收 2026-10-15 通过） |
| [m5.md](m5.md) | M5 订阅与节点身份 | T5.1–T5.3 已完成 |
| [m6.md](m6.md) | M6 节点检测与作业 | T6.1–T6.3 已完成 |
| [m7.md](m7.md) | M7 更新通道 | S7、T7.1–T7.5 已完成（T7.2：channel-stable 首发 2026-10-16，xray-core 26.9.30-r1、aether-proxy 0.1.0-r2）；T7.6 已完成；**T7.7 真机验收待安排** |

M2 及以后的任务卡在前一个里程碑完成、探针结论写回设计之后再拆。原因是这些任务依赖真机行为，提前拆卡容易写错。

已知要放进 M2 的事项：

- **`check --json` 的人读提示**：已拆为 [m1.md](m1.md) 的 T1.10。
- **初始数据基线**：已拆为 [m2.md](m2.md) 的 T2.0。

## 执行约定

任务卡由外部 agent 工具（目前是 WSL 中的 OpenCode）执行，设计负责人只做复审。**执行者只能依靠仓库里的内容开工**，所以下面的约定、[README](../README.md)「给实现者的规则」与 [12-ucode.md](../12-ucode.md) 共同构成完整的上下文。

### 1. 开工

worktree 由脚本创建，执行者在开工提示里第一步就运行它（在 WSL 中，任何目录下都可以）：

```bash
bash /workspace/openwrt/aether-proxy/tests/start-task.sh <卡号>
```

脚本会：从任务卡的「**分支**」一行读出分支名（任务卡没写时作为第二个参数传入）；基于本地 `main` 在
`/workspace/openwrt/aether-proxy-wt/<卡号>` 建 worktree（已存在就复用）；编译宿主机 ucode；跑一次基线检查（此时缺少报告的 FAIL 是正常的）；
最后打印工作目录。主检出有未提交的改动时拒绝创建。

### 2. 交给 agent 的开工提示

OpenCode 的工作空间是 `/workspace/openwrt`（其中还有 helloworld、luci-extras 等别的仓库）。把下面这段原样交给 agent，替换 `<卡号>`：

```
任务：完成 aether-proxy 仓库的任务卡 <卡号>（OpenWrt 透明代理应用，后端 ucode）。

第一步：运行 bash /workspace/openwrt/aether-proxy/tests/start-task.sh <卡号>
它会建好专用的 git worktree 并打印工作目录。之后所有读写、命令都只在那个目录里进行；
不要修改 /workspace/openwrt/aether-proxy（主检出）以及 /workspace/openwrt 下的任何其他仓库。

开工前在该目录中完整阅读：
1. docs/tasks/README.md 的「执行约定」——包括禁止事项、完成标准、报告格式
2. docs/README.md「给实现者的规则」
3. docs/12-ucode.md 全文（硬性规范，尤其「ucode 2025.07.18 的语法限制」）
4. 任务卡本身（docs/tasks/ 下）及其「必读」列出的章节

只做任务卡范围内的事。设计文档没覆盖的情况不要自行决定：按最保守的方式实现，在代码中标注 TODO(design)，并写进报告。
完成后在工作目录中运行 CI_TOOLS_DIR=/workspace/openwrt/ci-spike/tools bash tests/review.sh，FAIL 必须为 0；
然后按约定写 reports/<卡号>.md 并提交到本卡分支。不要 git push，提交信息不要带任何 AI 署名尾注。
```

### 3. 禁止事项

- 不准 `git push`，不准切换到别的分支，不准修改主检出 `/workspace/openwrt/aether-proxy` 或其他 worktree、其他仓库。
- 不准使用 sudo，不准安装系统软件包，不准运行容器。
- 不准修改 `docs/`（探针卡除外，探针卡的产出就是文档）。
- 不准修改共享基础设施：`tests/run.uc`、`tests/host/`、`tests/review.sh`、`.github/`，除非任务卡明确要求。
- 不准修改别的卡的期望文件；确实需要改时，在报告中逐个说明原因。
- 不准复制其他项目的代码（README 规则 8）。
- 需要下载工具或二进制时，只能放在仓库之外，并在报告中写明下载了什么、放在哪、多大。
- 提交信息用 emoji 格式（`✨ feat(<范围>): …`、`🐞 fix(…)`、`🧪 test(…)`、`📝 docs(…)`、`👷 ci(…)`、`🔬 spike(…)`），**不准**带 `Co-authored-by` 或任何 AI 署名尾注。

### 4. 完成标准

1. `bash tests/review.sh` 的 FAIL 为 0。每一条 WARN 都要在报告中解释。
   本机有缓存的 Xray 时设置 `CI_TOOLS_DIR=/workspace/openwrt/ci-spike/tools`，脚本会额外用真实 Xray 校验所有 `expected/xray.json`。
2. 任务卡「验收」中能在本地验证的条目都已验证，命令和输出写进报告；不能在本地验证的（需要虚拟机、CI、root），写明原因。
3. 工作区干净，所有改动都已提交到本卡的分支上。

### 5. 报告

在分支中提交 `reports/<卡号>.md`（例如 `reports/T0.3.md`）。复审合并时会把它移出 `main`，所以不用担心它进入正式代码。格式：

```markdown
# <卡号> 完成报告

## 改动
- 新增/修改的文件，每个一句话说明

## 验收
- 任务卡的每条验收：怎么验证的（命令）、结果（关键输出）；未验证的写原因

## tests/review.sh 输出
（完整粘贴）

## 偏差与待定
- 与设计文档不一致的地方及理由
- 代码中的 TODO(design) 列表
- 发现的文档矛盾或歧义

## 下载与环境
- 下载了什么、放在哪、多大（没有就写「无」）
```

### 6. 复审（设计负责人）

执行者完成后，告诉设计负责人「卡号 + 分支名」即可。复审步骤：

1. 读 `reports/<卡号>.md`，再运行 `bash tests/review.sh`，核对两边一致。
2. 读关键的代码改动，处理报告中的偏差与待定（需要改设计的，先改 `docs/`）。
3. 在主检出上 `git merge --no-ff <分支>`，然后 `git rm reports/<卡号>.md` 并提交，再跑一次全量测试，删除 worktree 和分支。
4. 推送前询问仓库所有者。

## 卡片类型

- 每个任务卡文件（`m<N>.md`）开头必须有一段「项目与范围」说明：所属仓库、只在本卡 worktree 中工作、不准碰 `/workspace/openwrt` 下的其他仓库。新建任务卡文件时照抄 [m0.md](m0.md) 开头那一段。

- **实现卡（T）**：产出代码与测试，验收标准是命令及其预期输出。
- **探针卡（S）**：在真机或虚拟机上验证某个假设，产出是写回设计文档的结论（只改 `docs/`，附带实测记录）。
  探针不写正式代码，原型脚本放进 `spikes/<编号>/`，合并后保留作为证据。

## 测试机

探针 S1–S4、S6 需要 OpenWrt 虚拟机：官方 24.10.8 与 25.12.5 的 x86-64 镜像各一台，**不要用承担实际出口的设备**。
虚拟机需要能访问一个测试用的 Xray 节点（自建一个即可，不要用生产节点的凭据）。
