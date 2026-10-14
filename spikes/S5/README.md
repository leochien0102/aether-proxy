# S5 SDK 容器与 apk 产物（实测记录）

日期：2026-10-14。分支 `m0/s5-sdk`。没有在 GitHub 上运行 Action、没有跑容器；`gh-action-sdk` 的行为靠读源码确认，
包的产物靠本地解开官方 SDK 实测。`build.sh` 是本地编译用的脚本（SDK 解压路径写死为 `/workspace/openwrt/sdk-spike/sdk-<版本>`，仅作记录）。

## 1. `openwrt/gh-action-sdk` 的 ARCH 写法

读取的文件：`action.yml`、`entrypoint.sh`、`Dockerfile`、`README.md`（`gh api repos/openwrt/gh-action-sdk/contents/<file>`，main 分支，最近提交 2026-08-04 `f5813d3`）。
仓库没有 GitHub Release，只有浮动大版本 tag `v1`…`v11`（最新 `v11`）。

- `Dockerfile`：`ARG CONTAINER=ghcr.io/openwrt/sdk`，`ARG ARCH=mips_24kc`，`FROM $CONTAINER:$ARCH`。
  即**镜像 = `ghcr.io/openwrt/sdk:$ARCH`**，环境变量 `ARCH` 原样就是标签。README：`ARCH` 例如 `x86_64` 或 `x86_64-22.03.2`。
- 标签格式：`<包架构>-<版本>`，包架构用下划线（`x86_64`）；另有一套 `<target>-<subtarget>` 写法（`x86-64-<版本>`）指向同一 SDK。
- 公开 API 核对（ghcr 匿名 token 查 manifest，HTTP 200）：

```
x86_64-24.10.8 200
x86_64-25.12.5 200
x86-64-24.10.8 200
x86-64-25.12.5 200
```

  Docker Hub（`hub.docker.com/v2/repositories/openwrt/sdk/tags?name=x86_64-2`）上同样存在 `x86_64-24.10.8`（2026-07-25）和 `x86_64-25.12.5`（2026-09-23），
  但 Action 实际拉取的是 ghcr。注意只写 `x86_64` 得到的是 master 的 SDK，必须带版本后缀。
- 结论：矩阵里 `ARCH: x86_64-24.10.8` 与 `ARCH: x86_64-25.12.5`。

### action 的参数与行为（源码）

- `action.yml` 是 composite action：先 `chown -R 1000:1000` 产物目录和 feed 目录，然后 `docker build`（构建参数 `CONTAINER`、`ARCH`），再 `docker run`，
  把宿主 `ARTIFACTS_DIR`（默认 `$GITHUB_WORKSPACE`）挂到 `/artifacts`，`FEED_DIR`（默认 `$GITHUB_WORKSPACE`）挂到 `/feed`。
  传入容器的环境变量：`BUILD BUILD_LOG EXTRA_FEEDS FEEDNAME IGNORE_ERRORS KEY_BUILD PRIVATE_KEY NO_DEFAULT_FEEDS NO_REFRESH_CHECK NO_SHFMT_CHECK PACKAGES INDEX V`。
  注意 `ARCH`、`CONTAINER` 要用**步骤级 `env:`** 提供（`docker/build-push-action` 的 `build-args: CONTAINER ARCH` 从环境读取）。
- `entrypoint.sh`：
  - `FEEDNAME` 默认 `action`；把默认 feeds（镜像里 `feeds.conf.default`，把 git.openwrt.org 换成 github 镜像）+ `src-link action /feed/` 写进 `feeds.conf`，
    `./scripts/feeds update -a`，`make defconfig`。
  - 未设 `PACKAGES`：`feeds install -p action -f -a`，然后不带目标的 `make -j$(nproc)`（编译整个 feed）。
  - 设了 `PACKAGES`（空格分隔）：逐个 `feeds install -p action -f <pkg>`、`package/<pkg>/download`、`package/<pkg>/check`，
    若包目录下有 `patches/` 做 refresh 检查，若有 `files/*.init` 做 `shfmt` 检查（`NO_REFRESH_CHECK`、`NO_SHFMT_CHECK` 可关），再 `package/<pkg>/compile`。
  - **`INDEX` 默认不生成索引**；`INDEX=1` 才执行 `make package/index`。本项目只上传 artifact、手动 `--allow-untrusted` 安装，不需要索引。
  - **签名**：`KEY_BUILD`（ipk，usign 私钥）、`PRIVATE_KEY`（apk，PEM 私钥）仅在非空时写入并设 `CONFIG_SIGNED_PACKAGES=y`。**不设也能编**：SDK 的 `.config` 默认已是 `CONFIG_SIGNED_PACKAGES=y`，
    apk 会用 SDK 内置的临时密钥签名，`apk verify` 报 `UNTRUSTED signature`，所以在虚拟机上安装要 `apk add --allow-untrusted`。
    正式发布（M7）才需要提供固定密钥，M0 不需要。
  - **产物位置**：结束时 `mv bin/ /artifacts/`，所以宿主上是 `$GITHUB_WORKSPACE/bin/packages/<包架构>/<FEEDNAME>/`，即默认 `bin/packages/x86_64/action/`。
    另有 `logs/`（`BUILD_LOG=1` 默认开启）。
  - 退出码：`PACKAGES` 模式下，若包在该架构不可用只会 `::warning` 跳过（不失败），所以 CI 里要检查产物确实存在。

## 2. 本地实测

### 环境

- 下载并校验（同目录 `sha256sums`）：
  `openwrt-sdk-24.10.8-x86-64_gcc-13.3.0_musl.Linux-x86_64.tar.zst`（259 MB）、
  `openwrt-sdk-25.12.5-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst`（285 MB），`sha256sum -c` 均 OK。
- 宿主缺 `zstd`：从 facebook/zstd v1.5.7 release 源码（`zstd-1.5.7.tar.gz`，sha256 与官方 `.sha256` 一致）`make PREFIX=… install` 到 `/workspace/openwrt/sdk-spike/tools/`。
- 两个 SDK 的 `feeds.conf.default` 不同：24.10 是 `src-git-full base …;v24.10.8`，25.12 是 `src-git --root=package base …`（目录名 `feeds/base_root`）。
  我只保留 `base` 和 `luci` 两行（沿用 SDK 固定的提交），再加 `src-link aetherproxy /workspace/openwrt/aether-proxy-wt/s5`。

```
./scripts/feeds update base luci aetherproxy
./scripts/feeds install aether-proxy luci-app-aether-proxy     # 依赖会自动连带安装
make defconfig
make package/feeds/aetherproxy/aether-proxy/compile V=s
make package/feeds/aetherproxy/luci-app-aether-proxy/compile V=s
```

不带 `-j`，两个 SDK 同时跑，各约 25 分钟（大部分时间花在编译依赖 `kmod-nft-tproxy`、`curl`、`ucode` 等目标依赖及其内核模块；Action 里 `-j$(nproc)` 会快很多）。

### 结果

| | 24.10.8 | 25.12.5 |
|---|---|---|
| `aether-proxy` 编译 | 成功 | 成功 |
| `luci-app-aether-proxy` 编译 | 成功 | 成功 |
| 包格式 | `.ipk` | `.apk`（`CONFIG_USE_APK=y`） |
| 产物目录 | `bin/packages/x86_64/aetherproxy/` | `bin/packages/x86_64/aetherproxy/` |

目录名等于 feed 名（这里 `aetherproxy`；在 Action 里是 `action`）。`PKGARCH:=all` 的包**也放在 `bin/packages/<SDK包架构>/<feed>/` 下**（这里是 `x86_64`），没有 `all/` 目录。
编译依赖时产生的 `base`、`luci` 目录在同级，Action 的 `PACKAGES` 模式下也一样出现，上传 artifact 时要按 feed 目录过滤，否则会带上依赖包。

24.10.8（`bin/packages/x86_64/aetherproxy/`）：

```
aether-proxy_0.1.0-r1_all.ipk
luci-app-aether-proxy_0.1.0-r1_all.ipk
luci-i18n-aether-proxy-zh-cn_26.287.20981~ba764d5_all.ipk
```

25.12.5（`bin/packages/x86_64/aetherproxy/`）：

```
aether-proxy-0.1.0-r1.apk
luci-app-aether-proxy-0.1.0-r1.apk
luci-i18n-aether-proxy-zh-cn-26.287.20981~ba764d5.apk
```

- **翻译子包会自动生成**：`luci-i18n-aether-proxy-zh-cn` 由 `luci.mk` 按 `po/zh_Hans/aether-proxy.po` 生成（`zh_Hans` → `zh-cn`），在 `luci-app` 的 compile 中一并产出，不需要单独的 make 目标。
  内容 `/usr/lib/lua/luci/i18n/aether-proxy.zh-cn.lmo` 和 `/etc/uci-defaults/luci-i18n-aether-proxy-zh-cn`；依赖 `libc, luci-app-aether-proxy`，架构 `all`/`noarch`。
- 注意 i18n 包的版本号**不是** `0.1.0-r1`：`luci.mk` 里 `PKG_PO_VERSION` 取 po 目录最后一次 git 提交的 `年.天数.秒数~短哈希`（这里 `26.287.20981~ba764d5`）。
  所以 Action 的检出需要 `fetch-depth: 0`（至少 po 目录有历史），否则版本串会变；apk 接受 `~` 版本串（上面已成功打出 apk）。
- 元数据（24.10.8 ipk，解开 `control.tar.gz`）：

```
Package: aether-proxy
Version: 0.1.0-r1
Depends: libc, kmod-nft-tproxy, kmod-nft-socket, ip-full, curl, ca-bundle, firewall4, resolveip, usign, dnsmasq, ucode, ucode-mod-fs, ucode-mod-uci, ucode-mod-uloop, ucode-mod-socket, ucode-mod-digest, ucode-mod-log, ucode-mod-resolv
Architecture: all
conffiles: /etc/config/aetherproxy        <-- 只有这一项
```

  `luci-app-aether-proxy`：`Version: 0.1.0-r1`，`Depends: libc, aether-proxy, luci-base, rpcd-mod-ucode`，`Architecture: all`。
- 25.12.5 apk（`staging_dir/host/bin/apk adbdump --allow-untrusted <file>.apk`，apk-tools 3.0.5，**宿主机可直接读**）：

```
info:
  name: aether-proxy
  version: 0.1.0-r1
  arch: noarch                      <-- PKGARCH:=all 在 apk 中叫 noarch
  depends: ca-bundle curl dnsmasq firewall4 ip-full kmod-nft-socket kmod-nft-tproxy libc resolveip ucode ucode-mod-{digest,fs,log,resolv,socket,uci,uloop} usign
  provides: aether-proxy-any
scripts: post-install / pre-deinstall / post-deinstall / post-upgrade
```

  `apk verify` 报 `UNTRUSTED signature`（SDK 临时密钥），符合预期。`apk extract --allow-untrusted --destination <目录> <file>.apk` 可解开内容。
  `luci-app` 与 i18n 同样是 `arch: noarch`、`version` 同上。
- **与设计有关的发现**
  1. **postinst/postrm 在 apk 中被包装成 post-install、post-upgrade、post-deinstall**：`post-install` 和 `post-upgrade` 先执行 `add_group_and_user; default_postinst`，再执行我们的脚本，`fw4 reload` 行能执行到；
     `post-deinstall` 只有我们的脚本。结论：`IPKG_INSTROOT` 判断仍然有效，`$$?` 转义正确（脚本里是 `rc=$?`）。
     `post-upgrade` 也会执行 `fw4 reload`（ipk 的 `postinst` 在升级时同样触发）。
  2. **conffiles 只列了 `/etc/config/aetherproxy`**，目录 `/etc/aether-proxy/custom/` 没有进 conffiles（Makefile 里写了该目录，但产物的 `conffiles` 中没有这一行；原因未深究，推测构建系统只保留文件项）。
     `lib/upgrade/keep.d/aether-proxy` 也只含这个文件。如果设计需要 sysupgrade 时保留 `custom/` 下的文件，需要另行处理（见报告，未改动）。
  3. **`const.uc` 版本串**：两种格式都已把占位符替换，内容为 `const RAW_VERSION = '0.1.0-1';`（`$(PKG_VERSION)-$(PKG_RELEASE)`），
     而包管理器看到的版本是 `0.1.0-r1`（OpenWrt 在 PKG_RELEASE 前加 `r`）。运行时版本串与 `opkg/apk` 版本串格式不同，设计中凡是拿两者比较的地方要注意。
  4. 空目录 `/etc/aether-proxy/keys`、`/usr/share/aether-proxy/data` 在 ipk（`tar tzvf data.tar.gz`）和 apk（`paths`）中都存在。

### 日志中的关键行

`build-<版本>.log` 保存在 `/workspace/openwrt/sdk-spike/`（17 MB / 40 MB，没放进仓库）。脚本末尾的 `compile1 rc=0`、`compile2 rc=0` 在两份日志里都有；没有 aether-proxy 相关的 error 或 warning。
