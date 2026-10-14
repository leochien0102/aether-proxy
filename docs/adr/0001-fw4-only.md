# ADR-0001 只支持 fw4 / nftables

- 状态：**已定**（2026-10-14，用户确认）
- 背景：现有 CI 同时编译 fw3、fw4 两种固件。ssr-plus 的双后端代码在 2026-09 排查中暴露出多类「一侧静默失效」的缺陷：
  错误被 `2>/dev/null` 吞掉、iptables 专属分支圈住了未移植的函数、一个 ipset 拆成多张 nft 表后调用方只改了一半、
  两个后端的创建/清空/清理动作不对称。
- 决定：aether-proxy 只实现 nftables，最低要求 fw4（OpenWrt 22.03+，首版目标固件均满足）。
- 后果：fw3 设备继续使用 ssr-plus。规则代码只有一份，测试矩阵减半。可以放心使用 `socket`、`fib`、`tproxy` 等 nft 表达式。
