# 08 更新

## 范围

| 对象 | 内容 | 默认策略 |
|---|---|---|
| `xray` | Xray 二进制 | `notify`：发现新版本只提示，用户点击后安装；可改为 `auto` |
| `chinadns-ng` | chinadns-ng 二进制 | `notify`，**不提供自动安装**；安装后必须通过 DNS 自检，否则自动回滚 |
| 规则数据 | `gfwlist`、`chnlist`、`apple`、`chnroute4`、`gfw_static4` | 每天自动 |
| aether-proxy 自身 | 由包管理器（opkg/apk）负责 | aether-proxy 不负责 |

## 发布通道（服务端）

**规则转换、上游校验、架构映射都在 CI 中完成**，设备只负责下载、验签、校验哈希。
这样设备侧的逻辑最简单，转换规则也可以在不升级 aether-proxy 的情况下修正。

CI（**单独的发布仓库** `leochien0102/aether-proxy-channel` 中的 `.github/workflows/channel.yml`，见下方「发布仓库」）每天运行一次，外加手动触发。
生成发布目录的代码在 aether-proxy 仓库的 `tools/channel/`，发布仓库的 workflow 只负责 checkout、运行它、签名、发布：


1. **数据**：拉取上游 → 转换为统一格式 → 合理性检查 → 与上一版比较，没有变化就不发布。
2. **组件**：跟踪 Xray-core、chinadns-ng 的上游**最新版本，含 prerelease**（2026-10-15 定：我们是客户端，新版 Xray 对旧服务端向下兼容，官方也是这样发布的；
   渲染只用最新正式版认识的写法，所以通道里的新版本同样能用，见 06「Xray 配置渲染」）。收录前用该版本对本仓库全部 golden 配置跑 `xray run -test`，有失败就不收录、CI 报错。用上游提供的摘要（Xray 的 `.dgst`）校验下载内容，
   按架构解包出单个二进制并用 gzip 压缩（设备只需要 busybox 的 `gunzip`，不需要 `unzip`）。
3. 生成 `manifest.json`，用 **usign** 私钥签名得到 `manifest.json.sig`。
4. 把清单和所有资产发布到固定 tag（如 `channel-stable`）的 GitHub Release。

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
  "schema": 1,
  "generated": "2026-10-14T04:00:00Z",
  "arch_map": {
    "aarch64_generic": "arm64", "aarch64_cortex-a53": "arm64",
    "x86_64": "amd64",
    "mipsel_24kc": "mipsle-softfloat"
  },
  "components": {
    "xray": {
      "version": "26.3.27",
      "min_app": "1.0.0",
      "assets": { "arm64": { "url": "xray-26.3.27-arm64.gz", "sha256": "…", "size": 12345678, "unpacked_size": 30000000 } }
    },
    "chinadns-ng": { "version": "2025.08.09", "assets": { } }
  },
  "data": {
    "chnroute4": { "version": "20261014", "url": "chnroute4-20261014.txt.gz", "sha256": "…", "size": 0, "lines": 0 }
  }
}
```

- `arch_map` 的键是设备 `/etc/openwrt_release` 中的 `DISTRIB_ARCH`，值是资产键。映射表由 CI 维护
  （mips 的软浮点、arm 的 v5/v6/v7 差异在这里处理；chinadns-ng 的变体选择可参照 helloworld `chinadns-ng/Makefile` 中的判断逻辑）。
- `url` 是相对路径，相对于下载清单所用的那个 `channel_urls` 地址。这样镜像只需要整体镜像目录即可。
- 设备的 `DISTRIB_ARCH` 不在 `arch_map` 中 → `ARCH_UNSUPPORTED`，提示用户手动上传二进制。

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
- 发布仓库是公开仓库，只有仓库所有者可以写入；workflow 只在定时、手动触发与仓库所有者的推送上运行，不在 PR 上运行（PR 拿不到 Secret，也不应发布）。

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
  **没有摘要文件**。校验办法：发布仓库保存「版本 → 各资产 sha256」记录，首次见到某版本时记下（取自 GitHub 的 HTTPS 下载），之后同一版本的文件一旦变化，CI 失败、不发布。

**测试路由器**（aarch64，自建 lede）
- `DISTRIB_ARCH='aarch64_generic'` → Xray `arm64-v8a`、chinadns-ng `aarch64-linux-musl@generic+v8a`。
- 有 `usign`、`gunzip`、`sha256sum`，**没有 `unzip`**（印证「CI 解压后改用 gzip」）。
- 空间：`/tmp` 约 1 GB，overlay 剩约 390 MB。
- 试运行输出：`Xray 26.9.30 (Xray, Penetrates Everything.) …`、`ChinaDNS-NG 2025.06.20 be347b5 | …`——版本号都是第二个字段。

## 设备端流程

### 下载（所有更新共用）

1. 依次尝试 `channel_urls`。每个地址：Xray 正在运行时先经代理（`-x http://127.0.0.1:31081`），失败再直连。
2. 下载 `manifest.json` 和 `.sig` 到 `/tmp/aether-proxy-dl/`，用 `usign -V -m manifest.json -P /etc/aether-proxy/keys` 验签。
3. 按需下载资产，校验 `size` 和 `sha256`，任一不符就删除并换下一个地址。
4. 空间预检：`/tmp` 可用空间 ≥ `size + unpacked_size + 1MB`；目标文件系统可用空间 ≥ `unpacked_size + 1MB`。不足 → `NO_SPACE`，不下载。

### 检查（`aether-proxy update check`，T7.3）

下载并验签清单后，对比本机状态，结果原子写入 `/var/run/aether-proxy/updates.json`，`status` 的 `updates_available` 直接取它（没有该文件时为 `null`）：

```json
{
  "checked": 1760400000,
  "url": "<实际取到清单的 channel_urls 地址>",
  "arch": "aarch64_generic", "asset_key": "arm64",
  "components": {
    "xray": { "installed": "26.9.30", "available": "26.10.10", "newer": true },
    "chinadns-ng": { "installed": "2025.06.20", "available": "2025.08.09", "newer": true }
  },
  "data": { "chnroute4": { "changed": true }, "gfwlist": { "changed": false } }
}
```

- `installed` 取自试运行输出的第二个字段（S7）；组件不存在时为 `null`。版本比较按点号分段的数字逐段比较（`26.10.10` > `26.9.30`）。
- 本机架构不在 `arch_map` 中 → `asset_key: null`，组件的 `available` 照常填写、`newer` 为 `false`，并记 `ARCH_UNSUPPORTED`（数据仍可更新）。
- 有组件 `newer: true` 时记 `UPDATE_AVAILABLE`（每个组件、每个新版本只记一次）。

### 组件安装（`aether-proxy update component <名称> [--version <v>]`）

1. 下载并校验 → `gunzip` → `chmod +x` → 试运行：`xray version` 或 `chinadns-ng -V`，退出码必须为 0，
   输出中必须包含清单里的版本号。
2. 移动到 `/usr/share/aether-proxy/bin/<组件>/<版本>/`。先写到同一文件系统下的临时名，再 `mv`，避免留下半个文件。
3. 用当前配置做校验（Xray：`run -test`）。失败 → 删除新版本，结束（`UPDATE_VERIFY_FAILED`）。
4. 原子切换：`ln -sfn <版本目录> current.tmp && mv -T current.tmp current`。旧版本的路径记入 `previous`（同样是符号链接）。
5. 通知 daemon 重启对应的子进程。
6. 安装后检查（失败 → 切回 `previous`，再重启子进程，记 ERR `UPDATE_ROLLED_BACK`）：
   - Xray：60 秒内代理健康检测至少成功 1 次。如果更新前就处于不健康状态，只检查 TPROXY 端口在 5 秒内进入监听。
   - chinadns-ng：10 秒内经 dnsmasq 成功解析 `baidu.com` 和 `dns_probe_domain`，DNS 级别保持不变。
7. 版本保留：保留 `current` 和 `previous`。空间不足时只删除 `previous`，**绝不删除 `current`**。
   包管理器安装的系统二进制永远作为最终兜底（[01](01-architecture.md) 查找顺序）。

`chinadns-ng` 不提供自动安装，原因：DNS 一旦出问题会影响全网解析，要求用户在场。即便如此，上面的安装后检查和
自动回滚仍然必须执行。

### 手动上传

LuCI 中可以上传二进制（用于首次安装时无法访问 GitHub 的情况）。上传的文件没有签名可以校验，只做第 1 步的试运行、
第 3 步的配置校验，并显示「未经签名校验」的警告。版本号取自试运行的输出。

### 数据更新（`aether-proxy update data`）

> 包内基线（`/usr/share/aether-proxy/data/`）必须包含全部 5 个数据文件，内容可以为空（例如 `gfw_static4.txt`），但文件必须存在。下载的数据中只要有一行不符合 [05](05-config.md)「列表文件的解析规则」，就拒绝本次更新、保留旧数据（记 `UPDATE_VERIFY_FAILED`）。

1. 下载清单，对比本地各数据项的 `sha256`（`/etc/aether-proxy/data/*.sha256`）。没有变化就结束。
2. 下载变化的数据项，校验 `sha256`，解压后再做一次设备端合理性检查（行数 ≥ 清单中 `lines` 的 90%）。
3. 写入 `/etc/aether-proxy/data/<名称>.txt.tmp` → `mv` 为正式文件，同时更新 `.sha256`。
4. 应用：服务在运行时执行一次 reload（`/etc/init.d/aether-proxy reload`），**不另写一套应用逻辑**（2026-10-15 改）。
   增量重载会按产物哈希判断（04「重载」）：`chnroute4`、`gfw_static4` 写在 nft 产物里 → 整表原子替换（先导出动态集合，不中断流量）；
   `gfwlist`、`chnlist`、`apple` 由 `chinadns.conf` 按路径引用、其内容已计入哈希 → 重启 chinadns-ng 并 HUP dnsmasq。
5. 读取数据的顺序：`/etc/aether-proxy/data/` 中存在就用它，否则使用包内的 `/usr/share/aether-proxy/data/` 基线。

flash 写入量：数据只在内容变化时写，按每天最多一次计，每次约 1–2MB，可以接受。

### 调度

daemon 内部计时，不修改 crontab：

- 数据：每天 `data_hour:data_minute`。
- 组件：每天检查一次新版本。`notify` 写入 `state.json` 的 `updates_available`，由 LuCI 显示；
  `auto`（仅 Xray）直接安装。
- 所有更新都以作业方式执行（[10](10-cli-luci.md)），同一时间只运行一个更新作业。

## 首次安装引导

官方 OpenWrt 上安装 aether-proxy 后既没有 Xray 也没有 chinadns-ng，而此时没有代理，直连 GitHub 很可能失败。LuCI 首页检测到
`COMPONENT_MISSING` 时显示引导：

1. 「从发布通道下载」（会依次尝试 `channel_urls` 中的镜像地址）
2. 「手动上传」（显示本机的 `DISTRIB_ARCH` 和应当下载的资产名）
