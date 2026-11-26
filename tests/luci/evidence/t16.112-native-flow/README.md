# T16.112 原生 LuCI 保存流程（离线）

```sh
NODE_PATH=/tmp/t16.23-evidence/node_modules \
  node tests/luci/t16.112-native-preview.js \
  /workspace/openwrt/openwrt-actions/build/rockchip/build_dir/target-aarch64_generic_musl/root-rockchip/www \
  tests/luci/evidence/t16.112-native-flow
```

真实 SDK 的 form、uci、Pending Changes 指示器与 modal；应用模块来自当前工作树。所有 HTTP/ubus 请求被本地内存 fixture 截获，禁止外部请求，不连接设备。未修改系统 LuCI。

`run.log` / `results.json`：20 PASS。覆盖共用凭据默认遮蔽及保存前提示；Save 只暂存、跨页原生 Save & Apply 按原值应用 fixture；独立端口修改；共用密码修改后的原生 Revert；空候选及 status 失败双关可保存；空候选启用时不写入；CONFIG_INVALID 仍可利用实时候选修复其他字段而无需关闭代理；多候选只选一次；关闭一项保留共用凭据；自动地址不存储；旧异凭据打开及校验失败不迁移、显式选来源才收敛为一份，原生撤销恢复原两份。

预期的无地址/旧凭据冲突校验拒绝会由 SDK 显示原生错误 modal；脚本仅允许这两条固定通用校验拒绝，任何其他浏览器 pageerror 都失败。不输出输入值或含密 DOM。凭据均虚构且仅在内存比较；证据只列字段名和断言结果，无凭据值、原始 DOM 或摘要截图。

原生全局摘要仍观察到凭据字段可见，未宣称脱敏；T16.111 保存前可见性提示保留。本验收的 apply 是内存 HTTP fixture，不证明设备应用、实际监听、网络认证或防火墙效果；后者见 `tests/explicit-proxy/` 和 `reports/T16.112.md`。

历史 `t16.111-*preview.js` 及其证据对应旧表单，不用于当前共用配置验收；本脚本是当前替代入口。
