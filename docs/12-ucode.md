# 12 ucode 实现规范

D1 已定为 ucode（[ADR-0002](adr/0002-backend-language.md)）。本文规定代码怎么组织、怎么写、怎么测。
**所有实现任务都必须遵守**，与本文冲突的写法在评审时一律退回。

## 目标运行环境

- 最低 ucode 版本：OpenWrt 24.10 自带的 `2025.07.18`（`3f64c808`）。不准使用这之后才出现的函数。
  拿不准时到该提交的源码 `lib/<模块>.c` 中查函数表。
- 允许使用的模块：`fs`、`uci`、`uloop`、`socket`、`log`、`struct`、`math`，以及 ucode 内置函数（不再使用 `digest`、`resolv`，见 [01](01-architecture.md)「包拆分」）。
  需要其他模块时先改本文档。
- 包依赖与此一致：`ucode`、`ucode-mod-fs`、`ucode-mod-uci`、`ucode-mod-uloop`、`ucode-mod-socket`、`ucode-mod-log`。

## 目录布局

```
aether-proxy/                         后端包目录
├── Makefile
├── files/
│   ├── aether-proxy.init             → /etc/init.d/aether-proxy
│   ├── aether-proxy.config           → /etc/config/aetherproxy
│   ├── aether-proxy.hotplug          → /etc/hotplug.d/iface/90-aether-proxy
│   ├── 30-aether-proxy.nft           → /usr/share/nftables.d/chain-pre/input/30-aether-proxy.nft
│   ├── keys/                         → /etc/aether-proxy/keys/
│   └── data/                         → /usr/share/aether-proxy/data/（规则数据基线）
└── src/
    ├── aether-proxy                  → /usr/bin/aether-proxy（入口，只做参数解析和分发）
    └── lib/                          → /usr/share/ucode/aetherproxy/
        ├── const.uc                  常量（01 常量表的唯一实现）
        ├── log.uc                    事件与 syslog（09）
        ├── sys.uc                    外部命令、文件原子写入、锁
        ├── schema.uc                 UCI 字段表（05 的机器可读版本）
        ├── config.uc                 读取 UCI → 快照；校验
        ├── data.uc                   读取规则数据与自定义列表
        ├── state.uc                  state.json 读写
        ├── net.uc                    IPv4/CIDR/域名等纯函数，/proc/net/tcp(6) 监听解析
        ├── pipeline.uc               读配置 → 快照 → 四个渲染产物（check、render、daemon、reload 共用）
        ├── render/
        │   ├── nft.uc  chinadns.uc  dnsmasq.uc  xray.uc  outbound.uc
        ├── apply.uc                  有副作用的原语：nft、ip rule、dnsmasq、集合导出、节点解析、产物哈希
        ├── supervise.uc              子进程监督（uloop.process、退避、pid 文件）
        ├── daemon.uc  monitor.uc  reload.uc  schedule.uc   daemon 主循环、monitor 状态机、增量重载、订阅调度
        ├── uri.uc  identity.uc  sub.uc                       订阅解析、身份匹配、sub update
        ├── probe.uc  job.uc                                  节点检测、作业机制
        └── cmd/                      每个子命令一个文件：check、render、status、events、probe、daemon、cleanup、sub、job
（M7 再加 update.uc。实际布局以代码为准，增减模块时同步改这里。）
```

模块按点号路径导入，`aetherproxy.render.nft` 对应 `/usr/share/ucode/aetherproxy/render/nft.uc`
（ucode 的 `require` 把点号替换为 `/`，已核实）：

```js
import * as nft from 'aetherproxy.render.nft';
```

入口 `/usr/bin/aether-proxy` 第一行为 `#!/usr/bin/ucode -S`（`-S` 为严格模式，未声明的变量直接报错）。
所有 `.uc` 文件第一行写 `'use strict';`。

### ucode 2025.07.18 的语法限制（2026-10-14 实测）

1. **`export function` 后面必须加分号**：写成 `export function f() { … };`，否则整个模块编译失败（`Syntax error: Unexpected token`）。
2. **函数声明不会提升**：必须先定义、后使用。
3. **`require()` 不能加载带 `export` 的模块**：模块之间一律用 `import * as x from 'aetherproxy.xxx';` 或 `import { a } from '…';`。
   需要按名称动态加载模块时（例如测试运行器），用 `loadstring("import * as m from '<模块>'; return m;")`。
4. **数组没有 `.join()` 方法**：用内置函数 `join(sep, arr)`。
5. **`fs.open()` / `fs.popen()` 失败后 `fs.error()` 可能返回 `null`**：取错误原因时要兜底（`fs.error() ?? 'unknown error'`）。
6. **`rindex()` 在匹配位于偏移 0 时报告未命中**：需要时在字符串前补一个字符再查找。
7. **宿主机（glibc）上 getopt 会重排参数**：`ucode script version --json` 中的 `--json` 会被 ucode 自己吃掉，宿主机上要写成 `ucode script -- version --json` 或设置 `POSIXLY_CORRECT=1`。OpenWrt 用 musl，不受影响。

## 编码规则

1. **纯函数与副作用分离。** `render/*`、`uri.uc`、`identity.uc`、`schema.uc` 以及 `config.uc` 中的校验部分**不准**调用 `fs`、`uci`、
   `system`、`sys.*`。它们的输入是普通对象，输出是字符串或普通对象。读写文件、执行命令只出现在 `cmd/*`、`daemon.uc`、`sys.uc`、
   `state.uc`、`data.uc` 中。
2. **外部命令只通过 `sys.run()` 执行**，不准在其他地方直接调用 `system()` 或 `fs.popen()`：
   ```js
   // 返回 { code, stdout, stderr }；code != 0 时自动记 CMD_FAILED（opts.quiet 为 true 时除外，调用方必须自己处理）
   sys.run(['nft', '-f', path], { timeout: 10 });
   ```
   参数必须以**数组**传入，由 `sys.run` 负责 shell 转义（单引号包裹，内部单引号转写为 `'\''`）。不准拼接 shell 字符串。
3. **文件写入只通过 `sys.write_atomic(path, content)`**：写到同目录下的临时文件，然后 `fs.rename`。不准就地覆盖。
4. **错误必须显式处理**：`fs.*` 返回 `null` 时，用 `fs.error()` 取得原因并记事件。禁止 `try { … } catch {}` 吞掉异常；
   捕获后必须记事件或继续向上抛出。
5. **常量只从 `const.uc` 读取。** 端口、mark、表名、路径都不准在其他文件中以字面量出现（golden 夹具中的期望输出除外）。
6. **渲染输出必须确定**：同样的输入必须产生逐字节相同的输出。对象键按模板中的书写顺序插入；集合元素在渲染前排序
   （IP 按数值排序，域名按字典序排序）；不准把时间戳、随机数写进渲染产物。
7. JSON 输出统一用 `sprintf('%.J', obj)`（xray.json 用 `'%.2J'` 便于阅读）。
8. 命名：文件与函数用 `snake_case`；常量用 `UPPER_SNAKE`；事件码只能使用 [09](09-logging.md) 目录中已有的值。
9. 注释用英文，只解释「为什么」；用户可见的文字（LuCI）用英文原文加 po 翻译。

## 配置快照

`config.load(cursor)` 返回：

```js
{ ok: true, snapshot: { main: {…}, dns: {…}, update: {…}, probe: {…}, hosts: [ … ], subscriptions: { s_xxx: {…} }, nodes: { n_xxx: {…} } },
  warnings: [ { code: "NODE_STALE_IN_USE", args: {…} } ] }
{ ok: false, errors: [ { field: "host[2].mac", code: "duplicate", detail: "aa:bb:… also in host[0]" } ] }
```

- 快照中的值都已归一化：bool 为 `true`/`false`，int 为数字，list 一律是数组（单值也是），未设置的字段填上默认值，MAC 统一为小写冒号格式。
- `config.uc` 是纯模块，不能自己写日志，所以需要记录的非致命问题放在 `warnings` 中返回，由调用方用 `log.event` 记录。
- 已定的归一化细节（T1.1 实现，2026-10-14 确认）：bool 只接受 `0`/`1`；空字符串视为未设置；未知 UCI 选项忽略；CIDR 带主机位（如 `192.168.1.5/24`）为非法；判重时 `x.x.x.x` 与 `x.x.x.x/32` 视为同一项；`enabled=0` 的 host 也参与冲突校验；Shadowsocks 允许的加密方式列表 `SS_METHODS` 定义在 `schema.uc`。
- `schema.uc` 用一张声明式的表描述 [05](05-config.md) 中的每个字段（类型、默认值、枚举、是否必填、所属协议）。
  `config.uc` 依据这张表完成读取和第一层校验；跨字段的规则（主机冲突、协议必填项）写成单独的函数。
- 渲染器只接收快照，绝不自己读 UCI。

渲染上下文：

```js
render(snapshot, {
  data:    { chnroute4: [...], gfw_static4: [...], direct_ip4: [...], proxy_ip4: [...] },   // data.uc 读取
  runtime: { node_ip: "203.0.113.10", dns_tier: "T2", restored: { gfw4: [...], udirect4: [...], uproxy4: [...] } },
  paths:   { gfwlist: "...", chnlist: "...", apple: "...",                                   // chinadns 配置中引用的文件，
             proxy_domain: "...", direct_domain: "...", boot_list: "..." }                    // 每个都是完整路径
})
```

渲染器约定（M1 的四个渲染器都必须遵守）：

- 每个渲染器模块导出 `export function render(snapshot, ctx) { … };`，**返回字符串**，以恰好一个 `\n` 结尾。
  Xray 渲染器另外导出 `build(snapshot, ctx)` 返回配置对象，`render` 为 `sprintf('%.2J', build(…)) + '\n'`。
- 渲染器只读取 `snapshot` 与 `ctx`，不读文件、不调用 `sys`、不取当前时间。`ctx` 中缺少的字段按空值处理
  （空数组、`null`），不准抛异常；`ctx.paths` 中的路径由调用方（`check` / daemon）解析好再传入，渲染器只负责原样写进配置。
  chinadns 渲染器遇到缺失的路径会省略对应行（T1.4 的实现），这在 `gfw` 模式下等于静默地不代理任何域名，所以**调用方必须总是传入全部 6 个路径**；规则数据文件不存在时由 `data` 层报错（[05](05-config.md)「列表文件的解析规则」），而不是传空路径。
- 需要新增常量时，追加到 `const.uc` 末尾、以注释标明任务卡编号的独立区块中，不要改动已有常量的位置（多张卡并行时便于合并）。

## 测试

### 宿主机环境

`tests/host/bootstrap.sh` 在 Ubuntu 上从源码编译并安装到 `tests/host/prefix/`：`json-c`（系统包）、`libubox`、`uci`、`ucode`。
ucode 固定为提交 `3f64c808`（即最低支持版本），cmake 选项：`-DUCI_SUPPORT=ON -DULOOP_SUPPORT=ON -DUBUS_SUPPORT=OFF -DRTNL_SUPPORT=OFF -DNL80211_SUPPORT=OFF`。
脚本必须幂等，CI 和本地开发共用。

### 测试运行器

运行方式：`tests/host/ucode tests/run.uc`。`tests/host/ucode` 是包装脚本：设置库路径，并通过 `-L` 加入模块搜索路径
（`tests/host/modules/aetherproxy` 是指向 `aether-proxy/src/lib` 的符号链接，使 `aetherproxy.sys` 解析到 `aether-proxy/src/lib/sys.uc`）。
传给运行器的选项要放在 `--` 之后（ucode 自己会解析以 `-` 开头的参数）：`tests/host/ucode tests/run.uc -- --update`。

`tests/run.uc`：

- 遍历 `tests/fixtures/*/`。每个夹具目录中，UCI 配置文件**必须命名为 `aetherproxy`**，运行器用 `uci.cursor(<夹具目录>)` 读取。
- 渲染上下文 `ctx`（`{ data, runtime, paths }`）取自夹具中可选的 `context.json`；没有时使用空上下文。
- **夹具通过它携带的期望文件声明要检查哪些产物**：`expected/` 中没有某个产物的文件，就不渲染、不比较该产物。
  所以每张渲染器卡只需要为自己的产物提供期望文件。
- 运行器顶部有一张「期望文件名 → 渲染模块」的表；对应模块不存在时该产物报 SKIP，存在时调用其导出的 `render(snapshot, ctx)`。
  新增渲染器只需要创建模块文件，不需要改动运行器结构。
- 单元测试 import 的 `aetherproxy.*` 模块不存在时报 SKIP；模块存在但出错时报 FAIL。
- 依次执行 `config.load` → 四个渲染器，把输出与 `expected/` 中的文件逐字节比较，不一致时打印 unified diff。
- `expected/error.json` 存在时，表示该用例期望校验失败，比较 `errors` 数组。
- `--update` 参数用实际输出覆盖期望文件。**使用 `--update` 后必须在 PR 描述中说明每个期望文件为什么改变。**
- `tests/unit/*.uc`：URI 解析、身份匹配等纯函数的表驱动测试，每个文件导出 `cases` 数组和 `run(case)` 函数。
- 退出码：全部通过为 0，否则为 1。

### CI 中的额外校验（`.github/workflows/test.yml`）

1. 运行 `tests/run.uc`。
2. 下载与 `const.uc` 中 `XRAY_MIN_VERSION` 相同版本的官方 Xray（linux-64），以及 `tests/ci/xray.sh` 中固定的一个较新版本（当前为最新 prerelease），对每个 `expected/xray.json` 各执行一次 `xray run -test -c`。
3. `sudo nft -c -f` 检查每个 `expected/aether-proxy.nft`（GitHub 的 Ubuntu runner 内核带有 nft tproxy、socket 模块；
   失败时先确认是否是模块缺失，而不是规则错误）。
4. 下载 chinadns-ng 的 x86_64 静态二进制，用 `timeout 2 chinadns-ng -C <conf>` 启动每个 `expected/chinadns.conf`，
   超时退出（退出码 124）算通过，提前以非零码退出算失败。运行前先用 `sudo nft -f` 创建它引用的表和集合。

## 打包

- 两个包都是 `PKGARCH:=all`，同一份产物适用于所有架构。
- `aether-proxy/Makefile` 使用 `include $(INCLUDE_DIR)/package.mk`，`Build/Compile` 为空，在 `Package/aether-proxy/install` 中按上面的布局安装文件；
  `conffiles` 只列 `/etc/config/aetherproxy`（conffiles 不支持目录）。需要跨 sysupgrade 保留的目录 `/etc/aether-proxy/custom/`、`/etc/aether-proxy/state/` 写在 `files/aether-proxy.keep`，安装为 `/lib/upgrade/keep.d/aether-proxy-data`（sysupgrade 对 keep.d 的每一行执行 find，目录可用）。`/etc/aether-proxy/data/` 不保留，升级后从发布通道重新获取。
- `const.uc` 中的版本号写成 `$(PKG_VERSION)-r$(PKG_RELEASE)`（如 `0.1.0-r1`），与包管理器显示的版本格式一致，便于比较。
- `postinst` / `postrm`：在非 `IPKG_INSTROOT`（即真机安装）时执行 `fw4 reload`，见 [02](02-dataplane.md)「与 fw4 的对接」。
- `luci-app-aether-proxy/Makefile` 使用 `luci.mk`，`LUCI_DEPENDS:=+aether-proxy +rpcd-mod-ucode`。
- 版本号：`PKG_VERSION` 采用 `MAJOR.MINOR.PATCH`，首个版本为 `0.1.0`；`PKG_RELEASE` 从 `1` 开始。apk 要求版本号符合其格式，不要带字母后缀。
- 包构建 CI（`.github/workflows/build.yml`）使用 `openwrt/gh-action-sdk`，矩阵为 x86_64 架构的 24.10.8（产出 ipk）和 25.12.5（产出 apk）。
  以下参数由 S5 确认（[spikes/S5/README.md](../spikes/S5/README.md)）：
  - `ARCH` 是步骤级环境变量，值就是 `ghcr.io/openwrt/sdk` 的镜像标签：`x86_64-24.10.8`、`x86_64-25.12.5`（必须带版本后缀，只写 `x86_64` 得到的是 master）。
  - 检出用 `fetch-depth: 0`：`luci-i18n-*` 的版本号由 po 目录的 git 历史算出（形如 `26.287.20981~ba764d5`），不是 `0.1.0-r1`。
  - 设 `FEEDNAME: aetherproxy` 与设计中的 feed 名一致；产物在 `bin/packages/x86_64/<FEEDNAME>/`，同级的 `base/`、`luci/` 是依赖包，不要上传。
    `PKGARCH:=all` 的包也在这个目录，没有 `all/` 子目录。
  - 不设 `PRIVATE_KEY` / `KEY_BUILD` / `INDEX` 也能编：包用 SDK 临时密钥签名，安装需要 `apk add --allow-untrusted`（ipk 用 `opkg install`）。
    固定签名密钥留给 M7。
  - 产物：24.10.8 为 `aether-proxy_0.1.0-r1_all.ipk`、`luci-app-aether-proxy_0.1.0-r1_all.ipk`、`luci-i18n-aether-proxy-zh-cn_<po版本>_all.ipk`；
    25.12.5 为 `aether-proxy-0.1.0-r1.apk`、`luci-app-aether-proxy-0.1.0-r1.apk`、`luci-i18n-aether-proxy-zh-cn-<po版本>.apk`（apk 中架构字段是 `noarch`）。
  - 包管理器看到的版本是 `0.1.0-r1`（OpenWrt 加了 `r`），而 `const.uc` 中被替换进去的是 `0.1.0-1`；两者格式不同，不要直接比较。
  - 设了 `PACKAGES` 时，若某包在该架构不可用，Action 只打 `::warning` 并跳过，不会失败；CI 要自行检查三个包都在产物目录中。
  - 宿主机可用 `staging_dir/host/bin/apk adbdump --allow-untrusted <file>.apk` 查看 apk 元数据。
  - `conffiles` 中的目录项（`/etc/aether-proxy/custom/`）不会进入产物，实际只有 `/etc/config/aetherproxy`，见 S5 记录。

## 协作流程

- 执行与复审流程见 [tasks/README.md](tasks/README.md)「执行约定」：每张卡一个本地 worktree 和分支，执行者不推送，完成后提交 `reports/<卡号>.md`，
  运行 `tests/review.sh` 自检，由设计负责人复审合并。分支命名 `m<里程碑>/<简短描述>`，例如 `m1/render-nft`。
- 提交信息使用 emoji 格式：`✨ feat(<范围>): …`、`🐞 fix(<范围>): …`、`📝 docs(<范围>): …`、`🧪 test(<范围>): …`、`🐳 chore(<范围>): …`。
  范围取模块名，例如 `render-nft`、`config`、`ci`。提交信息不带 AI 署名尾注（`Co-authored-by` 之类）。
- 报告必须包含：验收命令的实际输出、`tests/review.sh` 的输出、偏离或未覆盖的设计点（`TODO(design)` 列表），格式见执行约定。
- **改设计先改 `docs/`**，与代码放在不同的提交中；设计改动由设计负责人确认后才能合并。
