# T16.112 定向返工：半组新凭据与旧来源选择

```sh
NODE_PATH=/tmp/t16.23-evidence/node_modules \
  node tests/luci/t16.112-native-preview.js \
  /workspace/openwrt/openwrt-actions/build/rockchip/build_dir/target-aarch64_generic_musl/root-rockchip/www \
  tests/luci/evidence/t16.112-credential-rework --credentials-only
```

真实 SDK form/uci、原生 Save 和跨页 Pending Changes / Revert；所有 HTTP/ubus 请求由内存 fixture 截获，无设备操作。候选地址固定，不执行 LAN 变化、真实 Xray 或防火墙验收。

`run.log` / `results.json`：**18 PASS**。两种初始状态（仅新用户名 / 仅新密码）各覆盖三条决议路径（显式选旧 SOCKS5、显式选旧 HTTP、补齐新凭据）。每条路径先验证冲突选择可见、半组新输入保留、未决 Save 失败且原配置逐字不变；选旧来源时刻意不清空残留新输入，验证保存的是所选来源整组，绝不跨来源拼接。有效 Save 只暂存，原生 Revert 恢复两组旧凭据及原来的半组新输入，重新打开仍显示冲突。

所有凭据均虚构且仅在内存比较，证据仅记录字段名、路径名和断言结果，不含凭据值、原始 DOM 或截图。原生全局摘要脱敏不在本次复测范围内。
