# T16.111：可见提示与原生保存流程

## 结论分离

- **插件提示与保存流程：通过。** 两协议共用区域在保存前可见准确中文提示；默认密码遮蔽；保存仅暂存；原生应用使用原值；撤销丢弃暂存修改；单改任一协议不写另一协议字段或凭据。
- **全局摘要脱敏：未通过，也未声称实现。** 在无 common 的全新系统页面点击原生指示器，实际 modal DOM 仍观察到待应用凭据明文。只记录字段名/结论，不保存原始 DOM、凭据值或截图。这不是产品必须永久维持的行为，今后系统改善脱敏不应导致默认流程验收失败。

## 重跑

```sh
NODE_PATH=/tmp/t16.23-evidence/node_modules \
node tests/luci/t16.111-cross-page-preview.js \
/workspace/openwrt/openwrt-actions/build/rockchip/build_dir/target-aarch64_generic_musl/root-rockchip/www
```

默认验收提示与原生流程，退出 0，输出 `run.log`（由调用方重定向）及 `results.json`；全局摘要观察另列，不以明文必须存在或必须消失决定默认退出码。

追加 `--check-redaction` 并指定独立输出目录，是单独的**摘要脱敏诊断**。当前退出 1，见 `redaction-diagnostic.log`，不能把流程验收退出 0 当成摘要脱敏通过。

历史 `--expect-leak` 模式已从当前脚本删除，旧版本复现结果保留在 `../t16.111-cross-page/`；它当时返回 0 只表示缺陷复现，不表示修复。

## 真实交互边界

真实 SDK 高级页 Save 后，通过全文档导航加载未经修改的 `view/system/reboot.js`，确认未加载 Aether Proxy 模块；点击原生待应用指示器，读取实际 modal DOM，再点击其原生 Save & Apply。之后分别仅改 SOCKS5、仅改 HTTP 并 Save，验证只写对应字段，再全文档导航并点击原生 Revert。重新加载后待应用指示器消失。重启按钮从不点击。

HTTP/ubus 全由离线 route fixture 截获，外部请求被拒绝。应用/撤销检查只证明原生 UI 传输链路与内存配置语义，不验证设备、真实 rpcd、服务监听或防火墙。凭据均虚构，仅在内存比较；报告、日志、results 不输出凭据值，不导出 DOM、HAR、trace 或请求体。
