# aether-proxy

OpenWrt 透明代理：用 Xray 连接代理节点，用 ChinaDNS-NG 分流 DNS，局域网设备无需设置。
只支持 firewall4（nftables）与 IPv4；提供 LuCI 界面、订阅、按设备的访问控制、DNS 分级回退、故障放行，以及带签名校验与自动回滚的更新。

A transparent proxy manager for OpenWrt (fw4/nftables, IPv4) built on Xray and ChinaDNS-NG, with a LuCI UI.

- 使用说明：[docs/user-guide.md](docs/user-guide.md)
- 软件包下载：[aether-proxy-channel / channel-stable](https://github.com/leochien0102/aether-proxy-channel/releases/tag/channel-stable)
- 设计文档：[docs/](docs/README.md)

许可证：GPL-3.0-or-later，见 [LICENSE](LICENSE)。
