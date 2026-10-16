# 08 更新

## 范围

| 对象 | 方式 | 默认策略 |
|---|---|---|
| `xray-core` | **软件包**：发布仓库按 Makefile 从源码编译，**先过我们的测试再改 Makefile 的版本**，产物（ipk/apk）随签名清单发布；设备经包管理器安装 | `notify`：发现新版本只提示，用户点击后安装；可改为 `auto` |
| `aether-proxy`、`luci-app-aether-proxy` | **软件包**：同上，由仓库所有者决定何时把新版本放进通道 | `notify`（不提供自动安装） |
| `chinadns-ng` | **不进通道**，只随固件或软件源更新：DNS 出问题影响全网解析，代价远大于 Xray（2026-10-15 定，与 helloworld 一致） | — |
| 规则数据 | `gfwlist`、`chnlist`、`apple`、`chnroute4`、`gfw_static4`，经签名清单每天更新 | 每天自动 |

（2026-10-15 改为软件包方案，取代此前的「下载官方预编译二进制、自管版本目录」。参照 helloworld 的发布方式——用官方 SDK 编译软件包发到 GitHub Release、设备下载后用包管理器安装——并补上它缺少的两点：**签名与哈希校验**（它直接安装下载的包，apk 还加了 `--allow-untrusted`）和**安装后检查与回滚**。）

## 发布通道（服务端）

**编译、测试、数据转换都在 CI 中完成**，设备只负责下载、验签、校验哈希、调用包管理器。

发布 CI 在**单独的发布仓库** `leochien0102/aether-proxy-channel`（见下方「发布仓库」）。生成发布目录与清单的代码在 aether-proxy 仓库的 `tools/channel/`，发布仓库的 workflow 负责编译、运行它、签名、发布：

1. **软件包**：用 OpenWrt 官方 SDK 编译，矩阵为「SDK 版本 × 目标」——24.10（ipk）与 25.12（apk）各编 `aarch64_generic`、`x86_64`（首版范围，以后按需增加）。
   编译的包：`xray-core`（发布仓库自己维护的 Makefile，从上游源码包编译，`PKG_HASH` 校验源码包）、`aether-proxy`、`luci-app-aether-proxy`、`luci-i18n-aether-proxy-zh-cn`（取 aether-proxy 仓库的指定提交）。
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
| `gfw_static4.txt` | 每行一个 CIDR | 手工维护（如 Telegram 网段），放在 aether-proxy 仓库中 | 可以为空 |

合理性检查不通过 → CI 失败，不发布。设备会继续使用上一版数据。

**生成器只做格式转换，不增删条目。** 合理性检查用来发现上游异常（例如下载到错误页、列表被清空），检查不通过时应当失败，而不是改数据去迎合检查。

**数据来源的再分发**（2026-10-14 确认）：gfwlist 为 LGPL-2.1、dnsmasq-china-list 为 WTFPL，按许可证在 `SOURCES.md` 中注明即可；
APNIC 的 delegated 统计文件是公开发布的注册数据，被大量 chnroute 项目再分发，转换后的 CIDR 列表可以随包分发；
Telegram 公布的网段是事实性的 IP 地址列表，同样可以随包分发。这些数据不受 README 规则 8（不准复制第三方代码）约束。

### `manifest.json`

```json
{
  "schema": 2,
  "generated": "2026-10-15T04:00:00Z",
  "packages": {
    "xray-core": {
      "current": {
        "version": "26.9.30-r1",
        "assets": {
          "aarch64_generic": {
            "ipk": { "url": "xray-core_26.9.30-r1_aarch64_generic.ipk", "sha256": "…", "size": 0 },
            "apk": { "url": "xray-core-26.9.30-r1_aarch64_generic.apk", "sha256": "…", "size": 0 }
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
- 软件包：`xray-core`、`aether-proxy`、`luci-app-aether-proxy`、`luci-i18n-aether-proxy-zh-cn`。
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
- 发布仓库维护 `xray-core` 的 Makefile（自己编写，不复制 helloworld 或 openwrt/packages 的文件，README 规则 8），以及要打包的 aether-proxy 提交（一个版本文件）。

### 发布仓库的实现（T7.2，2026-10-16）

- **`xray-core` 不用 feeds 里的 golang**：OpenWrt 24.10 packages feed 的 Go 是 1.23，Xray 26.x 的 `go.mod` 要求 1.27。
  Makefile 像源码包一样固定一个官方 Go 工具链（`GO_TOOLCHAIN_VERSION` + sha256，linux-amd64），用它交叉编译静态二进制（`CGO_ENABLED=0`、`-trimpath -ldflags "-s -w -buildid="`），
  两个 SDK、所有目标用同一个工具链。目前只支持 `aarch64`、`x86_64`（ARCH→GOARCH 映射写在 Makefile，其他架构直接失败）。本地 24.10.8 SDK 实测：ipk 约 12.8MB，`xray version` 输出正确。
- 仓库内容：`xray-core/Makefile`、`AETHER_PROXY_REF`（要打包的 aether-proxy 完整提交哈希）、`keys/<指纹>`（与 aether-proxy 中相同的公钥，发布前验签用）、
  `scripts/usign.sh`（从固定提交编译 usign）、`scripts/publish.sh`、三个 workflow：
  - `packages`：`gate`（Makefile 的 Go 版本 ≥ Xray `go.mod` 要求；用该 Xray 版本对 `AETHER_PROXY_REF` 的全部 golden 跑 `xray run -test`，即 `XRAY_CHECK_VERSIONS=<版本> tests/ci/xray.sh`）
    → `build`（`openwrt/gh-action-sdk` 固定提交，2 个 SDK × 2 个目标；检查 4 个包都产出；x86_64 的 xray 实际运行并核对版本）→ `publish`（只在 `main`）。
  - `data`：每天 04:00（北京时间）只发布数据，不编译包；`build.py` 不带 `--packages` 时沿用已发布清单的软件包条目。
  - `xray-bump`：每天检查上游最新版本（含 prerelease），有更新就改 `PKG_VERSION`/`PKG_HASH`（`go.mod` 要求更高时同时改 Go 工具链）并开 PR。
    用 `GITHUB_TOKEN` 开的 PR 不会触发 workflow，所以接着在该分支上 `workflow_dispatch` 一次 `packages`（非 `main` 分支不发布）。
- **`publish.sh` 的资产规则**：Release 中已有的文件**一律不覆盖**。版本不变时 `build.py` 沿用旧条目（旧的 sha256），而重新编译出的包字节不同，覆盖就会让所有设备校验失败。
  顺序：下载并验签已发布的清单 → 生成数据与清单（`unchanged` 则结束）→ 签名并用 `keys/` 验签 → 上传清单引用而 Release 缺少的文件 → 核对引用的文件都在（GitHub 会改名含特殊字符的文件）
  → 上传 `manifest.json.sig`、`manifest.json` → 删除不再被引用的旧资产。
- **资产文件名**只用 `[A-Za-z0-9._-]`，其他字符换成 `.`（`build.py`）：LuCI 翻译包的版本带 `~`（`26.287.20981~ba764d5`），上传后会被 GitHub 改名。包管理器读包内元数据，文件名不影响安装。
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
    "xray-core": { "installed": "26.9.30-r1", "available": "26.10.10-r1", "newer": true },
    "aether-proxy": { "installed": "0.1.0-r1", "available": "0.2.0-r1", "newer": true }
  },
  "data": { "chnroute4": { "changed": true }, "gfwlist": { "changed": false } }
}
```

- `packages.<包>.asset`：本机架构与包管理器对应的资产文件名，包对本机不可用时为 `null`。
- `channel_urls` 为空 → `CONFIG_INVALID`（退出码 2）。至少一个地址返回了清单但都没通过验签 → `MANIFEST_BAD_SIGNATURE`（退出码 4）；所有地址都连不上 → `UPDATE_FETCH_FAILED`（退出码 1）。
  两种失败分开报，LuCI 才能分别提示「连不上发布通道」与「签名校验失败」。
- `pm`：有 `apk` 命令为 `apk`，否则有 `opkg` 为 `opkg`。`installed` 取自包管理器（`opkg status <包>` 的 `Version:`、`apk list -I <包>`）；没装为 `null`。
- 版本比较：先按 `-r` 前的上游版本逐段比较数字，相同再比 `r` 后的数字（`26.10.10-r1` > `26.9.30-r5`）。
- 包对本机架构不可用 → `available` 照常填、`newer: false`，记 `ARCH_UNSUPPORTED`。
- 有包 `newer: true` 时记 `UPDATE_AVAILABLE`（每个包、每个新版本只记一次）。

### 软件包安装（`aether-proxy update package <包> [--previous]`，T7.4）

1. 下载并验签清单；取本机架构与包管理器对应的资产（`--previous` 时取 `previous`），按清单校验 `size` 与 `sha256`。
2. 记下当前已装版本（用于回滚判断）。
3. 安装：opkg 用 `opkg install <文件>`；apk 用 `apk add --allow-untrusted <文件>`。**只在第 1 步的验签与哈希都通过之后**才这样调用——
   完整性由我们的签名清单保证，`--allow-untrusted` 只是跳过 apk 对 SDK 临时构建密钥的签名检查。
4. 安装后检查（失败 → 安装清单中的 `previous` 资产回滚，记 ERR `UPDATE_ROLLED_BACK`）：
   - `xray-core`：服务在运行时向 daemon 发 SIGUSR2（只重启 Xray，04「信号一览」；经 procd：`ubus call service signal '{"name":"aether-proxy","signal":12}'`，`signal` 必须是整数，不带 `instance`），之后 60 秒内 `state.json` 的 `last_probe` 出现一次晚于安装时刻的成功；更新前就不健康（`state` 不是 `running`）时，只检查 TPROXY 端口在 5 秒内进入监听。服务未运行时只检查 `xray version` 输出的版本等于清单版本的上游部分。
   - `aether-proxy`（及 luci 包）：`/etc/init.d/aether-proxy restart` 后 120 秒内 `state` 进入 `running` 或 `degraded`；服务原本未运行时只检查 `aether-proxy check` 通过。
5. 成功记 `UPDATE_INSTALLED`。

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
5. 读取数据的顺序：`/etc/aether-proxy/data/` 中存在就用它，否则使用包内的 `/usr/share/aether-proxy/data/` 基线。

清单本身取不到或验签失败时，`update data` 与 `update check` 用同样的结果码和退出码（`UPDATE_FETCH_FAILED` 退出 1、`MANIFEST_BAD_SIGNATURE` 退出 4）。清单中本版本不认识的数据项（以后的通道新增的）直接忽略，不算失败。

flash 写入量：数据只在内容变化时写，按每天最多一次计，每次约 1–2MB，可以接受。

### 调度

daemon 内部计时，不修改 crontab：

- 数据：每天 `data_hour:data_minute`。
- 软件包：每天检查一次新版本（`update check`），结果写 `updates.json`，由 LuCI 显示；`xray_auto=auto` 时对 `xray-core` 直接发起安装作业。`aether-proxy` 自身只提示。
- 所有更新都以作业方式执行（[10](10-cli-luci.md)），同一时间只运行一个更新作业。

细节（2026-10-16 定，T7.6）：

- **时间点**：每天本地时间 `data_hour:data_minute`（`data_minute` 为空按 30；本地时间取 ucode `localtime()`，即设备的 `/etc/TZ`）。
  「最近一次时间点」= 不晚于现在的最近一个 `hh:mm`。数据更新与软件包检查用同一个时间点（`data_minute` 已在安装时随机，各设备的请求本来就错开）。
- **到期**：某项（`data`、`check`）的 `last_attempt` 早于最近一次时间点 → 到期。没有记录时以 daemon 启动时刻代替 `last_attempt`（与订阅一致）：
  刚安装或记录丢失时不会在启动时立即执行，等下一个时间点。关机错过时间点的设备，开机后（daemon 进入 `running`/`degraded`）补做一次，每天最多一次。
- **顺序**：同一分钟只发起一个更新作业；`data` 先于 `check`（`data_auto=0` 时跳过 `data`）。两者共用更新锁，`data` 作业未结束时发起 `check` 得到退出码 3，下一分钟再试，自然先后执行。
- **记录**：`/etc/aether-proxy/state/update-schedule.json`：`{ "data": { "last_attempt": <秒> }, "check": { "last_attempt": <秒> }, "auto_install": { "version": "<版本>", "at": <秒> } }`。
  `job start` 退出码 3 时不记录（下一分钟再试）；其他结果（含失败）都记录 `last_attempt`，避免每分钟重试。每天最多写几次 flash。文件损坏或字段格式不对按「没有记录」处理，损坏只记一次 `FS_FAILED`。
- **`xray_auto=auto`**：每分钟检查 `updates.json`：`packages["xray-core"].newer == true` 且 `asset` 不为空，且 `auto_install.version` 不等于该 `available` 版本 →
  发起 `job start update package xray-core`，成功发起后记录 `auto_install`。**同一个版本只自动安装一次**：安装后检查失败会回滚（T7.4），不会每分钟重装；下一个新版本再试。
  只在状态为 `running` 时发起（`degraded` 时健康检测本身不可信，不做无人值守的升级）。
- `xray_auto` 为 `off`/`notify` 时设备端行为相同：照常每天 `check`、写 `updates.json`；`off` 只影响 LuCI 是否提示 `xray-core` 的新版本。`aether-proxy` 自身永远只提示。
- daemon 不在 `running`/`degraded` 时不发起任何更新作业；reload 后按新的配置快照计算（改了 `data_hour` 等立即生效）。
- 与订阅调度共用同一个 60 秒定时器（[06](06-nodes-subscription.md)「调度」）：订阅锁与更新锁互不影响，同一分钟可以各发起一个。

## 首次安装引导

官方 OpenWrt 上安装 aether-proxy 后可能没有 Xray 或 chinadns-ng（`COMPONENT_MISSING`）。LuCI 首页提示：

1. Xray：「从发布通道安装 `xray-core`」（`update package xray-core`，会依次尝试 `channel_urls` 中的镜像地址）；也可以在软件包页面从软件源安装。
2. chinadns-ng：只能从软件源安装（不进通道）。显示本机的 `DISTRIB_ARCH`，方便用户找到对应的包。
