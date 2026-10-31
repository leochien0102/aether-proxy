# 08 更新

## 范围

### B24 包名迁移（2026-10-31）

- 本应用只管理 `aether-xray`，纯上游基版本当前为 **26.10.31**，不带补丁；安装到 `/usr/bin/aether-xray`。最低运行版本仍为 26.3.27。
- 已有的通道版或 feeds 版 `xray-core` **不自动卸载，也不再由本应用更新**，它可能属于 feeds 或 ssr-plus。
  运行时按显式 `main.xray_bin` → `/usr/bin/aether-xray` → `/usr/bin/xray` 选择，组件信息显示实际路径与版本。
- 新客户端忽略清单中的旧 `xray-core`，不查询它的安装版本、不下载安装或删除它；旧清单只有该条目时不提供 Xray 更新。
  通道可继续保留旧条目供旧客户端使用；新旧条目同时存在且版本不同时也只比较 `aether-xray` 的包管理器版本。
- `--previous` 只接受 `aether-xray`。停止服务时的安装验证只执行新包的二进制并对比上游基版本（去掉 `-rN` / `-N`），
  不能以 `/usr/bin/xray` 的补丁版或显式运行路径代替新包验证。运行时组件版本仍如实显示，不冒充新包版本。
- `tools/channel/build.py` 只收集新包；软件包发布时原样保留上一份清单的 `xray-core` 条目供旧客户端使用，
  仅发布数据时保留整个旧清单（含 `xray-core`），不做旧条目重命名或版本继承。
  本卡不发布通道、不更改 `AETHER_PROXY_REF`，合并须等待 T10.72。

| 对象 | 方式 | 默认策略 |
|---|---|---|
| `aether-xray` | **软件包**：发布仓库按 Makefile 从源码编译，**先过我们的测试再改 Makefile 的版本**，产物（ipk/apk）随签名清单发布；设备经包管理器安装 | `notify`：发现新版本只提示，用户点击后安装；可改为 `auto` |
| `aether-proxy`、`luci-app-aether-proxy` | **软件包**：同上，由仓库所有者决定何时把新版本放进通道 | `notify`（不提供自动安装） |
| `chinadns-ng` | **不进更新流程**：DNS 出问题影响全网解析，代价远大于 Xray（2026-10-15 定，与 helloworld 一致）。但发布仓库**为没有它的固件打包上游的静态二进制**（wolfssl 版，按 `PKG_HASH` 固定；aarch64 用 `wolfssl_noasm`，x86_64 用基线版），随 Release 发布、写进签名清单，供用户手工安装；设备端只处理 `UPDATE_PACKAGES` 中的四个包，清单里的 `chinadns-ng` 被忽略（2026-10-20 定） | 手工安装、手工升级 |
| 规则数据 | `gfwlist`、`chnlist`、`apple`、`chnroute4`、`gfw_static4`，经签名清单每天更新 | 每天自动 |

（2026-10-15 改为软件包方案，取代此前的「下载官方预编译二进制、自管版本目录」。参照 helloworld 的发布方式——用官方 SDK 编译软件包发到 GitHub Release、设备下载后用包管理器安装——并补上它缺少的两点：**签名与哈希校验**（它直接安装下载的包，apk 还加了 `--allow-untrusted`）和**安装后检查与回滚**。）

## 应用仓库内的核心包与本地构建（T11.5）

- 应用仓库现提供 `aether-xray/Makefile`：纯上游 Xray **26.10.31**，无补丁；源码归档由 `PKG_HASH` 固定，使用固定哈希的官方 Go **1.27.2** 工具链（linux-amd64 构建主机），交叉编译静态二进制。目前支持 `aarch64_generic` 与 `x86_64`。
- 新包使用独立的 `build_dir/.../aether-xray-<版本>/Xray-core-<版本>` 源码/产物目录，避免与 feeds 的同版本 patched `xray-core` 共用目录或构建标记。
- `aether-proxy` 的 runtime `DEPENDS` 包含 `+aether-xray`；全量固件选中应用时带入核心。核心仍为**独立 ipk**，唯一数据文件是 `/usr/bin/aether-xray`，不嵌入 `aether-proxy` ipk。helloworld 的 patched `xray-core` 继续安装 `/usr/bin/xray`，包名和路径均不冲突。
- 将本仓库的 `aether-proxy/`、`aether-xray/` 注册到构建树（例如分别链接为 `package/aether-proxy`、`package/aether-xray`），刷新包元数据并用 `make defconfig` 确认目标架构与包选择。不要同时注册 channel 的同名包。
- 本地 OpenWrt 24.10.8 x86_64 SDK 实测：注册两个包并选中为 `m` 后，`make package/aether-proxy/compile` **自动带出** `aether-xray`（生成的 `.packagedeps` 有相应 compile 依赖边，且实际生成两个独立 ipk）。这不是对未注册依赖包、未刷新元数据或其他构建树配置的承诺。单独构建行为及双架构验证见 [T11.5 报告](../reports/T11.5.md)。为明确要求两个独立产物，可使用：
  ```sh
  make package/aether-xray/compile package/aether-proxy/compile
  ```
  设备用包管理器安装应用时也必须有可解析的 `aether-xray` 软件源或先安装本地产出的核心 ipk；依赖元数据不会把核心二进制塞进应用包。
- **channel 暂不切换**：现有发布仓库仍使用自己的 Makefile 与 `AETHER_PROXY_REF`；上文 26.10.31 是应用仓库的包/测试基线，不表示已发布。T11.6 再做 channel 单源复制，本任务不改通道引用、release 或 tag。

## 发布通道（服务端）

**编译、测试、数据转换都在 CI 中完成**，设备只负责下载、验签、校验哈希、调用包管理器。

发布 CI 在**单独的发布仓库** `leochien0102/aether-proxy-channel`（见下方「发布仓库」）。生成发布目录与清单的代码在 aether-proxy 仓库的 `tools/channel/`，发布仓库的 workflow 负责编译、运行它、签名、发布：

1. **软件包**：用 OpenWrt 官方 SDK 编译，矩阵为「SDK 版本 × 目标」——24.10（ipk）与 25.12（apk）各编 `aarch64_generic`、`x86_64`（首版范围，以后按需增加）。
   编译的包：`aether-xray`（发布仓库自己维护的 Makefile，从上游源码包编译，`PKG_HASH` 校验源码包）、`chinadns-ng`（自己维护的 Makefile，打包上游发布的静态二进制，只供手工安装，见上方「范围」）、`aether-proxy`、`luci-app-aether-proxy`、`luci-i18n-aether-proxy-zh-cn`（取 aether-proxy 仓库的指定提交）。
2. **Xray 版本闸门**：定时任务发现上游有新版本（含 prerelease）时，在发布仓库开一个改 Makefile 版本与 `PKG_HASH` 的 PR；PR 的检查用新版本对 aether-proxy 仓库全部 golden 配置跑 `xray run -test`（用官方 linux-64 二进制或本次编译出的 x86_64 包中的二进制）。
   **检查通过、仓库所有者合并后**才进入发布。PR 上的检查拿不到签名私钥，也不发布。
3. **数据**：每天拉取上游 → 转换 → 合理性检查 → 与上一版比较，没有变化就不发布。
4. 生成 `manifest.json`，用 **usign** 私钥签名得到 `manifest.json.sig`，与所有资产一起发布到固定 tag `channel-stable` 的 GitHub Release。

### 数据格式与来源（初始选择，CI 中可替换）

| 文件 | 格式 | 上游 | 合理性检查 |
|---|---|---|---|
| `gfwlist.txt` | 每行一个域名 | gfwlist/gfwlist（Base64 解码后抽取域名规则） | ≥ 3000 行；必须包含 `google.com` |
| `chnlist.txt` | 每行一个域名 | felixonmars/dnsmasq-china-list `accelerated-domains.china.conf` | ≥ 50000 行；必须包含 `baidu.com` |
| `apple.txt` | 每行一个域名 | 同上 `apple.china.conf` | ≥ 50 行；至少包含一个以 `.apple.com` 结尾的域名。**不准补入 `apple.com` 根域名**：上游只列有国内 CDN 的子域名，chinadns-ng 按后缀匹配，补入根域名会让所有 `*.apple.com` 都改用国内 DNS |
| `chnroute4.txt` | 每行一个 CIDR | APNIC delegated（CN, ipv4），或 misakaio/chnroutes2 | ≥ 3000 行；必须覆盖 `223.5.5.5`、`114.114.114.114`，不得覆盖 `8.8.8.8`、`1.1.1.1` |
| `gfw_static4.txt` | 每行一个 CIDR | Telegram 官方网段（`core.telegram.org/resources/cidr.txt`）＋生成器内置的常见境外公共 DNS：`8.8.8.8` `8.8.4.4` `1.1.1.1` `1.0.0.1` `9.9.9.9` `149.112.112.112` `208.67.222.222` `208.67.220.220`（2026-10-22 加，02「各模式」gfw 一行） | Telegram 来源可以为空；内置的公共 DNS 必须全部在内 |

合理性检查不通过 → CI 失败，不发布。设备会继续使用上一版数据。

**生成器只做格式转换，不增删条目**（唯一例外：`gfw_static4` 中内置的公共 DNS 是有意加入的固定条目，2026-10-22）。合理性检查用来发现上游异常（例如下载到错误页、列表被清空），检查不通过时应当失败，而不是改数据去迎合检查。

**数据来源的再分发**（2026-10-14 确认）：gfwlist 为 LGPL-2.1、dnsmasq-china-list 为 WTFPL，按许可证在 `SOURCES.md` 中注明即可；
APNIC 的 delegated 统计文件是公开发布的注册数据，被大量 chnroute 项目再分发，转换后的 CIDR 列表可以随包分发；
Telegram 公布的网段是事实性的 IP 地址列表，同样可以随包分发。这些数据不受 README 规则 8（不准复制第三方代码）约束。

### `manifest.json`

```json
{
  "schema": 2,
  "generated": "2026-10-15T04:00:00Z",
  "packages": {
    "aether-xray": {
      "current": {
        "version": "26.10.31-r1",
        "assets": {
          "aarch64_generic": {
            "ipk": { "url": "aether-xray_26.10.31-r1_aarch64_generic.ipk", "sha256": "…", "size": 0 },
            "apk": { "url": "aether-xray-26.10.31-r1_aarch64_generic.apk", "sha256": "…", "size": 0 }
          }
        }
      },
      "previous": { "version": "26.7.28-r1", "assets": { } }
    },
    "aether-proxy": { "current": { "version": "0.2.0-r1", "assets": { "all": { "ipk": { }, "apk": { } } } }, "previous": null }
  },
  "data": {
    "chnroute4": { "version": "3f2a…", "url": "chnroute4-3f2a….txt.gz", "sha256": "<gz 文件>", "size": 0, "content_sha256": "<解压后内容>", "lines": 0 }
  }
}
```

- 数据项的 `size`、`sha256` 描述**下载的 .gz 文件**（与其他资产一样在下载时校验）；`content_sha256` 是解压后列表的哈希，用来和本机的数据比较是否变化。
- 软件包：`aether-xray`、`aether-proxy`、`luci-app-aether-proxy`、`luci-i18n-aether-proxy-zh-cn`。
- 资产文件名：ipk 原样（`<名>_<版本>_<架构>.ipk`）；25.12 SDK 输出的 apk 文件名**不带架构**（`<名>-<版本>.apk`），架构相关的 apk 发布时改名为 `<名>-<版本>_<架构>.apk`，否则各目标的同名文件在 Release 里互相覆盖。
  `tools/channel/build.py` 按 SDK 的输出布局 `<目标架构>/<feed>/<文件>` 取架构；架构无关的包每个 SDK 都会再编一份，只取第一份。
- `assets` 的键直接是 OpenWrt 的包架构（设备 `/etc/openwrt_release` 的 `DISTRIB_ARCH`，与 `opkg print-architecture` 一致），`all` 用于架构无关的包。不再需要额外的架构映射表。
- 每个包保留 `current` 与 `previous` 两个版本的资产：回滚时安装 `previous`（opkg/apk 本身不保留旧包）。
- `url` 是相对路径，相对于下载清单所用的那个 `channel_urls` 地址，镜像只需整体镜像目录。
- 设备的 `DISTRIB_ARCH` 不在某个包的 `assets` 中 → 该包对本机不可用（`ARCH_UNSUPPORTED`），提示用户自行从软件源安装。

### 签名

- 使用 OpenWrt 自带的 `usign`（Ed25519）。公钥随 `aether-proxy` 包安装在 `/etc/aether-proxy/keys/`，文件名为密钥指纹。
- 允许同时存在多个公钥（用于轮换），任一公钥验签通过即可。
- 私钥只由仓库所有者持有（D3，2026-10-15 定）：在所有者本机用 `usign -G` 生成；私钥放进发布仓库的 Actions Secret `USIGN_SECRET_KEY`，离线备份放在所有者的密码管理器中；
  **不进任何仓库，也不进笔记库**。公钥提交到 aether-proxy 仓库 `aether-proxy/files/keys/<指纹>`，随包安装。
- 轮换：先发布同时带新旧两个公钥的包，等用户升级后再改用新私钥签名。私钥丢失时同样走这条路（新公钥随包发出）；私钥泄露时还要尽快发布去掉旧公钥的包。
- **验签不通过的清单一律丢弃**，即使是从主地址下载的也一样。正因为有签名，镜像地址才可以不受信任。

### 发布仓库（D3）

发布 CI 与 Release 放在单独的仓库 `leochien0102/aether-proxy-channel`，不放在代码仓库里。理由：

- 设备写死的默认下载地址指向 Release 所在的仓库。代码仓库以后会新开、旧仓库改名归档（仓库规划），发布仓库独立，已装好的设备不受影响；
  Secrets 与 Release 也不必随代码仓库迁移。
- 发布仓库只有 CI 与产物，提交记录干净，Secret 的暴露面小（只有它的 workflow 能读）。

约定：

- 默认 `channel_urls` 为 `https://github.com/leochien0102/aether-proxy-channel/releases/download/channel-stable/`（[05](05-config.md)），镜像地址追加在其后。
- 数据生成器（`tools/data/`）与 `gfw_static4.txt` 仍在 aether-proxy 仓库：发布 CI 每次 checkout aether-proxy 的 `main` 来运行生成器，生成器改动不需要同步两个仓库。
- 发布仓库是公开仓库，只有仓库所有者可以写入。发布（读私钥、签名、上传）只在定时、手动触发与 `main` 上的推送运行；PR 上只跑编译与 golden 检查（拿不到 Secret，也不发布）。
- 发布仓库维护 `aether-xray` 的 Makefile（自己编写，不复制 helloworld 或 openwrt/packages 的文件，README 规则 8），以及要打包的 aether-proxy 提交（一个版本文件）。

### 发布仓库的实现（T7.2，2026-10-16）

- **`aether-xray` 不用 feeds 里的 golang**：OpenWrt 24.10 packages feed 的 Go 是 1.23，Xray 26.x 的 `go.mod` 要求 1.27。
  Makefile 像源码包一样固定一个官方 Go 工具链（`GO_TOOLCHAIN_VERSION` + sha256，linux-amd64），用它交叉编译静态二进制（`CGO_ENABLED=0`、`-trimpath -ldflags "-s -w -buildid="`），
  两个 SDK、所有目标用同一个工具链。目前只支持 `aarch64`、`x86_64`（ARCH→GOARCH 映射写在 Makefile，其他架构直接失败）。本地 24.10.8 SDK 实测：ipk 约 12.8MB，`xray version` 输出正确。
- 仓库内容：`aether-xray/Makefile`、`AETHER_PROXY_REF`（要打包的 aether-proxy 完整提交哈希）、`keys/<指纹>`（与 aether-proxy 中相同的公钥，发布前验签用）、
  `scripts/usign.sh`（从固定提交编译 usign）、`scripts/publish.sh`、三个 workflow：
  - `packages`：`gate`（Makefile 的 Go 版本 ≥ Xray `go.mod` 要求；用该 Xray 版本对 `AETHER_PROXY_REF` 的全部 golden 跑 `xray run -test`，即 `XRAY_CHECK_VERSIONS=<版本> tests/ci/xray.sh`）
    → `build`（`openwrt/gh-action-sdk` 固定提交，2 个 SDK × 2 个目标；检查 4 个包都产出；x86_64 的 xray 实际运行并核对版本）→ `publish`（只在 `main`）。
  - `data`：每天 04:00（北京时间）只发布数据，不编译包；`build.py` 不带 `--packages` 时沿用已发布清单的软件包条目。
  - `xray-bump`：每天检查上游最新版本（含 prerelease），有更新就改 `PKG_VERSION`/`PKG_HASH`（`go.mod` 要求更高时同时改 Go 工具链）并开 PR。
    用 `GITHUB_TOKEN` 开的 PR 不会触发 workflow，所以接着在该分支上 `workflow_dispatch` 一次 `packages`（非 `main` 分支不发布）。
- **`publish.sh` 的资产规则**：Release 中已有的文件**一律不覆盖**。版本不变时 `build.py` 沿用旧条目（旧的 sha256），而重新编译出的包字节不同，覆盖就会让所有设备校验失败。
  顺序：下载并验签已发布的清单 → 生成数据与清单（`unchanged` 则结束）→ 签名并用 `keys/` 验签 → 上传清单引用而 Release 缺少的文件 → 核对引用的文件都在（GitHub 会改名含特殊字符的文件）
  → 上传 `manifest.json.sig`、`manifest.json` → 删除不再被引用的旧资产。
- **资产文件名**只用 `[A-Za-z0-9._-]`，其他字符换成 `.`（`build.py`）：LuCI 翻译包的版本带 `~`（`26.287.20981~ba764d5`），上传后会被 GitHub 改名。包管理器读包内元数据，文件名不影响安装。设备端同样按此校验清单里的包资产 `url`：只能是单个文件名、只含这些字符、不是 `.`/`..`，否则拒绝（2026-10-27 交叉审查 security F2、复核 6.1）。
- **旧清单重放**（2026-10-27，复核 6.3）：签名清单没有防重放，镜像可以回放已签过的旧清单。接受这个风险：**主更新路径**按版本比较只安装比已装版本**新**的包，回放装不回旧版本；最多让规则数据退回较旧的一版。
  **版本保证的边界**（2026-10-30，D1 定）：分组事务中的其他包、独立组件更新与自动回退使用清单 `previous`，可能安装比更新前更旧的版本。文档不承诺“软件绝不回旧版”；需要更强保证时另立提案，给所有入口加版本门槛并提供可验证的恢复版本策略。单调发布序号记 backlog B22。
- 清单中资产按**包格式**取键（`ipk`/`apk`）。设备端按包管理器选格式：opkg → `ipk`，apk → `apk`。

### S7 探针结论（2026-10-15）

**usign**
- 源码只有 7 个 C 文件，不依赖任何库，`gcc` 一条命令即可编译（不定义 `USE_LIBUBOX` 时自带 base64）。宿主机测试与发布 CI 都从 `git.openwrt.org/project/usign.git` 的固定提交 `c4c72b1b` 编译，与测试路由器固件中的版本一致；
  OpenWrt 24.10 的 `f1f65026` 与它之间只差一个改 CMake 最低版本的提交，签名与验签代码完全相同。不用 signify。
- `usign -V -m <文件> -P <目录>`：从签名中读出签名密钥的指纹，只在目录中找名为 `<16 位小写十六进制指纹>` 的公钥文件（与 `/etc/opkg/keys/` 相同的约定）。
  实测：正确签名 rc=0；篡改内容 rc=1；签名用的公钥不在目录中 rc=1；目录中放多个公钥、换另一把私钥签名仍然通过（轮换可行）。`-q` 只用退出码。

**上游资产**
- Xray：`Xray-linux-<键>.zip` 与 `.zip.dgst`（含 `MD5=`、`SHA1=`、`SHA2-256=`、`SHA2-512=` 行）。arch 键示例：`arm64-v8a`、`64`、`32`、`arm32-v7a`、`arm32-v5/v6`、`mips32le`、`mips32`、`mips64le`、`riscv64`、`loong64`。
  **近期版本几乎都标为 prerelease**（2026-10 时 GitHub 的 latest 仍是 26.3.27），通道按「最新版本含 prerelease」跟踪，见上方「发布通道」。
- chinadns-ng：**未压缩的单个二进制**，命名 `chinadns-ng+wolfssl@<三元组>@<cpu>@fast+lto`（如 `aarch64-linux-musl@generic+v8a`、`x86_64-linux-musl@x86_64`、`mipsel-linux-musl@mips32+soft_float`），
  **没有摘要文件**。（chinadns-ng 后来决定不进通道，此条仅作记录。）

**测试路由器**（aarch64，自建 lede）
- `DISTRIB_ARCH='aarch64_generic'`（与官方 armsr/armv8 SDK 的包架构一致，helloworld 的发布也用它）。
- 有 `usign`、`gunzip`、`sha256sum`，**没有 `unzip`**（印证「CI 解压后改用 gzip」）。
- 空间：`/tmp` 约 1 GB，overlay 剩约 390 MB。
- 试运行输出：`Xray 26.9.30 (Xray, Penetrates Everything.) …`、`ChinaDNS-NG 2025.06.20 be347b5 | …`——版本号都是第二个字段。

## 设备端流程

### 下载（所有更新共用）

1. 依次尝试 `channel_urls`。每个地址：Xray 正在运行时先经代理（`-x http://127.0.0.1:31081`），失败再直连。
2. 下载 `manifest.json` 和 `.sig` 到 `/tmp/aether-proxy-dl/`，用 `usign -V -m manifest.json -P /etc/aether-proxy/keys` 验签。
3. 按需下载资产，校验 `size` 和 `sha256`，任一不符就删除并换下一个地址。
4. 空间预检：下载前 `/tmp` 可用空间 ≥ `size + 1MB`，不足 → `NO_SPACE`，不下载。软件包安装所需的 overlay 空间由包管理器自己检查，它报空间不足时同样记 `NO_SPACE`。
5. 清单 `schema` 不是 2，或 JSON 解析失败 → 视同验签失败，换下一个地址。

### 检查（`aether-proxy update check`，T7.3）

下载并验签清单后，对比本机状态，结果原子写入 `/var/run/aether-proxy/updates.json`，`status` 的 `updates_available` 直接取它（没有该文件时为 `null`）：

```json
{
  "checked": 1760400000,
  "url": "<实际取到清单的 channel_urls 地址>",
  "arch": "aarch64_generic", "pm": "opkg",
  "packages": {
    "aether-xray": { "installed": "26.9.30-r1", "available": "26.10.31-r1", "newer": true },
    "aether-proxy": { "installed": "0.1.0-r1", "available": "0.2.0-r1", "newer": true }
  },
  "data": { "chnroute4": { "changed": true, "sha256": "<清单的 content_sha256>" }, "gfwlist": { "changed": false, "sha256": "…" } }
}
```

- `data.<名称>.sha256`（2026-10-21 加，r9 窗口）：检查时清单中该项的 `content_sha256`。`data status` 用它**现场**判断是否有更新（见 10「`data status`」），
  不再只看检查时算好的 `changed`——那个值在 `update data` 写入新数据后不会变，r9 窗口中刚更新完的数据项仍显示「有更新」。`changed` 照旧保留，供旧版本读取。
- `packages.<包>.asset`：本机架构与包管理器对应的资产文件名，包对本机不可用时为 `null`。
- `packages.<包>.previous`：清单中 `previous` 对本机可用时为它的版本，否则为 `null`（2026-10-16 加，T8.9b；更新页据此显示回滚按钮）。
- `channel_urls` 为空 → `CONFIG_INVALID`（退出码 2）。至少一个地址返回了清单但都没通过验签 → `MANIFEST_BAD_SIGNATURE`（退出码 4）；所有地址都连不上 → `UPDATE_FETCH_FAILED`（退出码 1）。
  两种失败分开报，LuCI 才能分别提示「连不上发布通道」与「签名校验失败」。
- `pm`：有 `apk` 命令为 `apk`，否则有 `opkg` 为 `opkg`。「有命令」指在 `PATH` 的各目录中找到可执行文件（`PATH` 为空时用 `/usr/sbin:/usr/bin:/sbin:/bin`）；指定 `--bin-dir` 时只看该目录。OpenWrt 的 opkg 在 `/bin/opkg`（2026-10-19 真机发现：之前只检查了相对路径，检查更新完全不可用，backlog B10）。`installed` 取自包管理器（`opkg status <包>` 的 `Version:`、`apk list -I <包>`）；没装为 `null`。
- 版本比较：先按 `-r` 前的上游版本逐段比较数字，相同再比 `r` 后的数字（`26.10.10-r1` > `26.9.30-r5`）。release 后缀写成 `-rN` 或 `-N` 都认（不同固件与 SDK 两种都有：2026-10-19 H28K 上 ssr-plus 的 xray-core 为 `26.9.30-5`，之前被当成上游版本的一部分、release 记为 0，于是当时通道的 `26.9.30-r1` 被误判为更新，backlog B10）。
- 包对本机架构不可用 → `available` 照常填、`newer: false`，记 `ARCH_UNSUPPORTED`。
- 有包 `newer: true` 时记 `UPDATE_AVAILABLE`（每个包、每个新版本只记一次）。
- **缓存过期**（2026-10-20 定，backlog B14 第 1 条）：`updates.json` 的 `installed` 是检查那一刻的。之后若有人用包管理器直接装、删包（opkg/apk 命令、LuCI 软件包页面），它就不再可信——
  r8 窗口中缓存写于装着 r5 时，装回 r8 后更新页仍显示「已安装 r5」并给出「立即更新」到 r6 的按钮，点了会降级。
  判断：包管理器数据库（`pm` 为 `opkg` 时 `/usr/lib/opkg/status`，`apk` 时 `/lib/apk/db/installed`）的修改时间**晚于** `checked` → 过期。
  只做一次 `stat`，不运行包管理器（`status` 每次刷新都要读它）。数据库文件不存在或读不到修改时间 → 不算过期（无从判断时不隐藏）。任何包的变动都会让它过期（宁可多检查一次）。
  过期的效果：`status` 的 `updates_available` 为 `null`、不产生 `UPDATE_AVAILABLE` 提示（LuCI 因此显示「尚未检查」、不给安装与回滚按钮）；`xray_auto=auto` 不据此自动安装。
  不删除文件，下一次 `update check`（每天的调度或用户点「检查更新」）照常覆盖。`update package` 装完会重新检查并写 `updates.json`（T7.4），它写入的 `checked` 晚于这次安装，不会被判为过期。
  `data status` 只用其中的 `data` 部分，与软件包无关，不受影响。判断写成一个函数，`status` 与 daemon 的自动安装共用。

### 软件包安装（`aether-proxy update package <包> [--previous]`，T7.4）

1. 下载并验签清单；取本机架构与包管理器对应的资产（`--previous` 时取 `previous`），按清单校验 `size` 与 `sha256`。
2. 记下当前已装版本（用于回滚判断）。
3. 安装：opkg 用 `opkg install <文件>`；apk 用 `apk add --allow-untrusted <文件>`。**只在第 1 步的验签与哈希都通过之后**才这样调用——
   完整性由我们的签名清单保证，`--allow-untrusted` 只是跳过 apk 对 SDK 临时构建密钥的签名检查。
4. 安装后检查（失败 → 安装清单中的 `previous` 资产回滚，记 ERR `UPDATE_ROLLED_BACK`）：
   - `aether-xray`：服务在运行时向 daemon 发 SIGUSR2（只重启 Xray，04「信号一览」；经 procd：`ubus call service signal '{"name":"aether-proxy","signal":12}'`，`signal` 必须是整数，不带 `instance`），之后 60 秒内 `state.json` 的 `last_probe` 出现一次晚于安装时刻的成功；更新前就不健康（`state` 不是 `running`）时，只检查 TPROXY 端口在 5 秒内进入监听。服务未运行时只检查 `/usr/bin/aether-xray version` 输出的版本等于清单版本的上游部分。
   - `aether-proxy`：`/etc/init.d/aether-proxy restart`（超时 90 秒：stop 最多等 daemon 30 秒，即 `term_timeout`，再加 `cleanup` 与 start 中的 `check`）后 120 秒内 `state` 进入 `running` 或 `degraded`；服务原本未运行时 restart 之后只检查 `aether-proxy check` 通过。
   - luci 包：不做检查（页面文件在下次加载时生效）。
   - **回滚之后要让旧版生效**（2026-10-20 T7.7 发现：只重装不重启，内存里跑的仍是检查失败的那一版）：`aether-proxy` 在更新前服务处于 `starting`、`running` 或 `degraded` 时执行一次 restart（同样 90 秒超时）；`aether-xray` 在更新前服务处于 `running`、`degraded` 或 `starting` 时发一次 SIGUSR2。回滚后不再做检查，结果仍是 `UPDATE_VERIFY_FAILED`（`rolled_back: true`）；restart 或信号失败记 `CMD_FAILED`。`--previous` 的检查失败、改装回 `current` 时同样处理。
5. 成功记 `UPDATE_INSTALLED`。

~~**回滚一起回滚**~~（2026-10-22 定，r11 窗口；**2026-10-23 随「取消三包手动回滚」废止**，见下文，保留原文备查）：只回滚 `aether-proxy` 而页面（`luci-app-aether-proxy`）仍是新版时，新页面用到的新接口（`probe_sites`、`node_use`、`node_parse` 等）在旧后端上一律 `USAGE`，
页面长期处于半坏状态（r11 窗口 R7 回滚期间实际看到「站点列表读取失败（USAGE）」）。所以：
- `update package aether-proxy --previous` 与 `update package luci-app-aether-proxy --previous` 都回滚**同一组三个包**：`aether-proxy`、`luci-app-aether-proxy`、`luci-i18n-aether-proxy-zh-cn`。
- 顺序：先 `aether-proxy`，照上面第 3、4 步安装并检查；**检查通过之后**才依次安装两个 luci 包的 `previous` 资产（不做检查，同上）。`aether-proxy` 检查失败而恢复原版时，luci 包不动——页面与后端始终同一版。
- 某个 luci 包本机没装、或清单中没有它对本机可用的 `previous` → 跳过它；某个 luci 包安装失败 → 记 `CMD_FAILED`，不再回滚已装好的 `aether-proxy`（旧后端配新页面会报 `USAGE`，但服务本身正常），在结果中如实报告。
- 有 luci 包失败（安装、下载或校验）时：整体退出码 1，`code`/`detail` 取第一个失败的；其余 luci 包照常各自处理；已检查通过的 `aether-proxy` 不回退（2026-10-22 T9.16 复核定）。
  从 `luci-app-aether-proxy` 发起时，结果的 `package`、`from`、`to` 仍描述 `aether-proxy` 这一主事务，两个 luci 包写在 `companions` 里。
- 结果在原有字段之外加 `companions: { "<包>": "rolled_back" | "skipped" | "failed", … }`；`update package luci-i18n-aether-proxy-zh-cn --previous` 与 `aether-xray` 的回滚不变（只回滚自己）。
- 正向的安装（不带 `--previous`）不变：新后端配旧页面时，旧页面只调用旧接口，能正常工作。

**取消三包手动回滚**（2026-10-23 仓库所有者定，r13 窗口）：r13 R7 实测，用过新配置项（`udp://` 可信 DNS、`wan`、设备覆盖模式、`config sub`）后回滚到 r5，旧版读不懂配置、检查失败、自动恢复，期间服务停止；手动回滚也只能回到通道里的上一版、不能选版本。所以：
- `update package <包> --previous` **只接受 `aether-xray`**；`aether-proxy`、`luci-app-aether-proxy`、`luci-i18n-aether-proxy-zh-cn` 带 `--previous` → `USAGE`（退出码 2）。三包一起回滚的逻辑与结果中的 `companions` 删除。
- **保留**：安装后检查失败时的自动恢复（上面第 4 步）——恢复到的版本不低于原来装的版本，配置兼容；保留 `aether-xray` 的手动回滚（新版 Xray 偶有运行时问题，回滚它不涉及我们的配置格式）。
- `updates.json` 的 `packages.<包>.previous` 照旧写出（页面只对 `aether-xray` 显示回滚按钮）。
- 需要别的版本时：从发布页下载对应版本的三个包，在 LuCI 的「软件包」页面上传安装或 `opkg install`；降级前注意新版本的设置旧版本可能不认识，必要时先恢复默认配置（用户文档第 6 节、更新页说明）。

**更新一起更新**（2026-10-25 定，仓库所有者；backlog B17）：0.3.0-r1 发布后在更新页逐个点「立即更新」，仓库所有者担心先更新的一个与另一个不匹配，最坏时页面坏掉、无法再更新另一个。所以正向更新也按组处理（与上面已废止的「回滚一起回滚」同一结构，方向相反）：
- 组：`aether-proxy`、`luci-app-aether-proxy`、`luci-i18n-aether-proxy-zh-cn`。`update package aether-proxy` 与 `update package luci-app-aether-proxy`（不带 `--previous`）都处理**整组**，主事务是 `aether-proxy`；`update package luci-i18n-aether-proxy-zh-cn` 与 `aether-xray` 只装自己。
- 顺序：先 `aether-proxy`——清单里它比已装的新时，照上面第 1–4 步安装并检查；不比已装的新（只有页面改了）就跳过它。**`aether-proxy` 装好且检查通过（或被跳过）之后**，才依次安装两个 luci 包的 `current` 资产（不做检查，同上）。`aether-proxy` 检查失败而自动恢复原版时，luci 包不动——页面与后端始终同一版。
  先后端、后页面的理由：新后端必须继续服务上一个正式版的页面（下面「更新接口」），反过来不保证。
- luci 包本机没装、清单里没有它对本机可用的 `current`、或 `current` 不比已装的新（08「版本比较」）→ 跳过它；某个 luci 包下载、校验或安装失败 → 记 `CMD_FAILED`，不回退已装好的 `aether-proxy`，其余 luci 包照常处理；整体退出码 1，`code`/`detail` 取第一个失败的。
- 结果：`package`、`from`、`to`、`rolled_back` 等原有字段仍描述 `aether-proxy` 主事务（被跳过时 `from` = `to` = 已装版本）；新增 `companions: { "<包>": "installed" | "skipped" | "failed", … }`。旧页面不认识 `companions`，照旧只显示主事务——这是下面「更新接口」允许的「只加字段」。
- 组里没有一个包需要更新时，结果与现在「已是最新」相同（退出码 0）。
- 清单里没有本机可用的 `aether-proxy` `current` 资产（`ARCH_UNSUPPORTED`）时整组拒绝、页面包也不装，`companions` 全为 `skipped`：不在后端未知的情况下改页面（2026-10-25 T9.38 复核定，原为实现中的 TODO(design)）。

**更新接口（固定）**（2026-10-25 定，backlog B17）：页面与 rpcd 插件都在 `luci-app-aether-proxy` 里，只有它们调用的命令行属于 `aether-proxy`。为保证「先更新了后端，旧页面仍能把自己更新掉」，下面这些对**上一个正式版**的页面与插件保持兼容：以后的后端**只能加字段、加可选参数，不能删除、改名或改变含义**。
- 命令：`aether-proxy status`（JSON）、`aether-proxy job start update check`、`aether-proxy job start update package <包>`、`aether-proxy job status <id>`，以及它们的退出码含义。
- `status` 中更新页用到的字段：`components`、`updates_available` 及其下的 `checked`、`arch`、`packages.<包>.installed` / `available` / `previous` / `newer`；失败时的 `ok: false`、`code`。
- 作业：`job start` 成功时输出 `{ "job": <id> }`（不带 `ok`），失败时带 `ok: false`、`code`；`job status` 成功时输出**平铺**的作业记录，其中 `state`（`running` / `ok` / `failed`）、`code`、`error`、`result`；`update package` 结果（即 `result`）的 `ok`、`package`、`code`、`detail`、`from`、`to`、`rolled_back`；`update check` 结果的 `packages`。
  成功时不带 `ok` 的写法也是接口的一部分：上一正式版的页面按 `ok !== false` 判断成功（2026-10-25 T9.39 复核按实际输出更正，原写「`ok`」「`job` 对象」有误）。
- 检查办法：发布正式版时，把**这一版**的 `luci-app-aether-proxy` 中更新页用到的文件（`view/aether-proxy/updates.js`、`aether-proxy/model/updates.js`、`aether-proxy/common.js` 的作业部分所在文件、rpcd 插件 `aetherproxy.uc` 与 ACL）冻结到 `tests/compat/fixtures/<版本>/`（不放 `tests/fixtures/`：那里每个子目录都是渲染夹具，2026-10-25 T9.39 开工时发现），替换上一版的冻结件；兼容测试用冻结的旧插件调用当前命令行、用冻结的旧模型解析当前输出，走一遍「读状态 → 检查更新 → 更新 `luci-app-aether-proxy`」。CI 的检出不带标签，所以不在运行时从标签取旧文件。
- 确实要改这些接口时，先在设计里写明迁移办法（例如新旧两种输出并存一个版本），再改。

更新 `aether-proxy` 自身时，执行更新的是作业进程：ucode 在启动时就加载完了全部模块，安装过程中替换磁盘上的文件不影响它跑完。
不提供「手动上传二进制」：没有通道时，用户可以在 LuCI 的软件包页面或 `opkg install` 直接安装软件源里的包。

### 数据更新（`aether-proxy update data`）

> 包内基线（`/usr/share/aether-proxy/data/`）必须包含全部 5 个数据文件，内容可以为空（例如 `gfw_static4.txt`），但文件必须存在。下载的数据中只要有一行不符合 [05](05-config.md)「列表文件的解析规则」，就拒绝本次更新、保留旧数据（记 `UPDATE_VERIFY_FAILED`）。

1. 下载清单，对比本地各数据项的 `sha256`（`/etc/aether-proxy/data/*.sha256`）。没有变化就结束。
2. 下载变化的数据项，校验 `sha256`，解压后再做一次设备端合理性检查（行数 ≥ 清单中 `lines` 的 90%）。
3. 写入 `/etc/aether-proxy/data/<名称>.txt.tmp` → `mv` 为正式文件，同时更新 `.sha256`。
4. 应用：服务在运行时执行一次 reload（`/etc/init.d/aether-proxy reload`），**不另写一套应用逻辑**（2026-10-15 改）。
   增量重载会按产物哈希判断（04「重载」）：`chnroute4`、`gfw_static4` 写在 nft 产物里 → 整表原子替换（先导出动态集合，不中断流量）；
   `gfwlist`、`chnlist`、`apple` 由 `chinadns.conf` 按路径引用、其内容已计入哈希 → 重启 chinadns-ng 并 HUP dnsmasq。
**本机数据的哈希**（2026-10-16 定，T8.8）：`/etc/aether-proxy/data/<名称>.sha256` 存在就用它，否则用包内基线文件的 sha256。`update check` 判断 `changed`、
`update data` 判断是否要下载、`data status` 显示版本，**三处用同一个函数**（之前 `update check` 在没有 `.sha256` 时一律判为有变化，刚装好的设备会永远提示数据可更新）。

5. 读取数据的顺序：`/etc/aether-proxy/data/` 中存在就用它，否则使用包内的 `/usr/share/aether-proxy/data/` 基线。

清单本身取不到或验签失败时，`update data` 与 `update check` 用同样的结果码和退出码（`UPDATE_FETCH_FAILED` 退出 1、`MANIFEST_BAD_SIGNATURE` 退出 4）。清单中本版本不认识的数据项（以后的通道新增的）直接忽略，不算失败。

flash 写入量：数据只在内容变化时写，按每天最多一次计，每次约 1–2MB，可以接受。

### 调度

daemon 内部计时，不修改 crontab：

- 数据：每天 `data_hour:data_minute`。
- 软件包：每天检查一次新版本（`update check`），结果写 `updates.json`，由 LuCI 显示；`xray_auto=auto` 时对 `aether-xray` 直接发起安装作业。`aether-proxy` 自身只提示。
- 所有更新都以作业方式执行（[10](10-cli-luci.md)），同一时间只运行一个更新作业。

细节（2026-10-16 定，T7.6）：

- **时间点**：每天本地时间 `data_hour:data_minute`（`data_minute` 为空按 30；本地时间取 ucode `localtime()`，即设备的 `/etc/TZ`）。
  「最近一次时间点」= 不晚于现在的最近一个 `hh:mm`。数据更新与软件包检查用同一个时间点（`data_minute` 已在安装时随机，各设备的请求本来就错开）。
- **到期**：某项（`data`、`check`）的 `last_attempt` 早于最近一次时间点 → 到期。没有记录时以 daemon 启动时刻代替 `last_attempt`（与订阅一致）：
  刚安装或记录丢失时不会在启动时立即执行，等下一个时间点。关机错过时间点的设备，开机后（daemon 进入 `running`/`degraded`）补做一次，每天最多一次。
- **顺序**：同一分钟只发起一个更新作业；`data` 先于 `check`（`data_auto=0` 时跳过 `data`）。两者共用更新锁，`data` 作业未结束时发起 `check` 得到退出码 3，下一分钟再试，自然先后执行。
- **记录**：`/etc/aether-proxy/state/update-schedule.json`：`{ "data": { "last_attempt": <秒> }, "check": { "last_attempt": <秒> }, "auto_install": { "version": "<版本>", "at": <秒> } }`。
  `job start` 退出码 3 时不记录（下一分钟再试）；其他结果（含失败）都记录 `last_attempt`，避免每分钟重试。每天最多写几次 flash。文件损坏或字段格式不对按「没有记录」处理，损坏只记一次 `FS_FAILED`。
- **`xray_auto=auto`**：每分钟检查 `updates.json`：`packages["aether-xray"].newer == true` 且 `asset` 不为空，且 `auto_install.version` 不等于该 `available` 版本 →
  发起 `job start update package aether-xray`，成功发起后记录 `auto_install`。**同一个版本只自动安装一次**：安装后检查失败会回滚（T7.4），不会每分钟重装；下一个新版本再试。
  只在状态为 `running` 时发起（`degraded` 时健康检测本身不可信，不做无人值守的升级）。
- `xray_auto` 为 `off`/`notify` 时设备端行为相同：照常每天 `check`、写 `updates.json`；`off` 只影响 LuCI 是否提示 `aether-xray` 的新版本。`aether-proxy` 自身永远只提示。
- daemon 不在 `running`/`degraded` 时不发起任何更新作业；reload 后按新的配置快照计算（改了 `data_hour` 等立即生效）。
- 与订阅调度共用同一个 60 秒定时器（[06](06-nodes-subscription.md)「调度」）：订阅锁与更新锁互不影响，同一分钟可以各发起一个。

## 首次安装引导

新包由包管理器通过 `aether-xray` 依赖安装 Xray；旧版安装、手工复制文件或组件被删除时仍可能缺失 Xray。chinadns-ng 仍须另装。组件缺失时（`COMPONENT_MISSING`），LuCI 首页提示：

1. Xray：「从发布通道安装 `aether-xray`」（`update package aether-xray`，会依次尝试 `channel_urls` 中的镜像地址）；也可以在软件包页面从软件源安装。
2. chinadns-ng：从软件源安装，或从发布页手工下载通道打包的 `chinadns-ng`（只有 `aarch64_generic`、`x86_64`）；设备不会替用户安装或更新它。显示本机的 `DISTRIB_ARCH`，方便用户找到对应的包。
