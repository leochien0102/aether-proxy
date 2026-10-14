# ADR-0003 不拦截路由器本机流量

- 状态：**已定**（2026-10-14，设计阶段）
- 背景：ssr-plus 拦截 OUTPUT 链，因此需要节点 IP 旁路、防环 mark，以及「拿哪张表的哪个钩子」这类细节，相关缺陷反复出现。
- 决定：nft 只挂 prerouting（以及用于保护和 QUIC 的 input / forward / nat 链）。aether-proxy 自己需要走代理的流量（订阅、更新、健康检测）
  显式通过 Xray 的本机 HTTP 入站发出；DNS 走代理由 Xray 的 tunnel 入站完成。
- 后果：不需要防环 mark，Xray 出站天然不会被重定向。路由器上的其他程序（opkg 等）不走代理，这一点写入用户文档。
  将来如果需要代理本机流量，再按用户 gid 增加 OUTPUT 规则，作为独立的新功能设计。
