# aether-proxy

OpenWrt 透明代理：用 Xray 连接代理节点，用 ChinaDNS-NG 分流 DNS，局域网设备无需设置。
只支持 firewall4（nftables）与 IPv4；提供 LuCI 界面、订阅、按设备的访问控制、DNS 分级回退、故障放行，以及带签名校验与自动回滚的更新。

A transparent proxy manager for OpenWrt (fw4/nftables, IPv4) built on Xray and ChinaDNS-NG, with a LuCI UI.

- 使用说明：[docs/user-guide.md](docs/user-guide.md)
- 软件包下载：[aether-proxy-channel / channel-stable](https://github.com/leochien0102/aether-proxy-channel/releases/tag/channel-stable)
- 设计文档：[docs/](docs/README.md)

## 包来源与构建

本仓库维护 `aether-proxy`、LuCI、`aether-xray` 与 `chinadns-ng` 的包源。
`aether-proxy` 显式依赖 `aether-xray` 和 `chinadns-ng`：全量配置选中应用时会自动选中它们，
单独执行 `make package/aether-proxy/compile` 也会先构建依赖；仅打包 DNS 组件可执行
`make package/chinadns-ng/compile`。`chinadns-ng` 保持 2025.08.09 上游静态二进制，
安装到 `/usr/bin/chinadns-ng`，不在 `UPDATE_PACKAGES` 中，仍需手工安装/更新。
channel 从固定应用提交复制这两个独立二进制包的包源，不维护第二份 Makefile。
应用 Release 资产包含二者的 aarch64_generic / x86_64 ipk+apk；首次安装先装这两个依赖，
再装应用、LuCI 与翻译包，不要混用包格式或架构。

许可证：GPL-3.0-or-later，见 [LICENSE](LICENSE)。
