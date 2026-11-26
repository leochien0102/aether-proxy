# T16.111：LAN 显式代理离线 UI 验收

## 重跑

在 worktree 根目录执行（不启动 HTTP server）：

```sh
cd /workspace/openwrt/aether-proxy-wt/T16.111
mkdir -p tests/luci/evidence/t16.111
NODE_PATH=/tmp/t16.23-evidence/node_modules \
  node tests/luci/t16.111-explicit-preview.js \
  /workspace/openwrt/openwrt-actions/build/rockchip/build_dir/target-aarch64_generic_musl/root-rockchip/www \
  > tests/luci/evidence/t16.111/run.log 2>&1
```

依赖：已有 Playwright、其 Chromium、离线构建的 LuCI SDK、Bootstrap/Argon 样式和中文系统字体。不安装依赖、不访问路由器、不使用真实网络。所有浏览器 HTTP 请求由 context.route 截获；非 `http://luci.test` 来源被拒绝，未知 RPC/静态路径使验收失败，service workers 被禁用。

## 已验证

Bootstrap dark / Argon light 均通过，每主题 20 条 PASS，共 40 条。每主题 10 张截图，共 20 张；`results.json` 记录断言摘要、RPC 方法、字段级写入记录（没有值）和实际加载的应用资源路径。

- 复用 t16.24 的真实 LuCI shell/route 方法，仅加载高级页。应用静态资源优先取当前 worktree；SDK 提供 form、ui、uci、widgets 和主题，不复制/伪造表单 DOM。
- 默认 SOCKS5 / HTTP 均关闭，8 个从属输入隐藏。未修改直接 Save 不回填这 10 个字段。
- 只启用 SOCKS5 时 HTTP 输入仍隐藏；双开后填入独立的虚构用户名和密码。两密码 input 均断言 `type=password`。
- 11 类无效输入：通配/回环/IPv6 监听地址、0/65536 端口、内部保留端口、双协议端口冲突、HTTP 用户名含冒号、超长密码、空密码、空用户名。断言真实 LuCI `.cbi-input-invalid`；凭据错误 tooltip 不回显输入。
- 无效 Save 显示标准 Save error modal，且没有 UCI 写入；有效 Save 的 10 个 main 字段在 RPC fixture 中逐一校验，凭据独立保存。Reset 恢复已保存端口与开关。
- **真实表单 Save 后点击原生 Changes 指示器**：modal 无任何虚构凭据，显示 `********`。调用前后 `ui.changes.changes` 对象身份及完整 JSON 内容一致，原始四个凭据变更仍保留。没有修改原生 SDK 或替换 Changes renderer。
- 只开 SOCKS5 / 只开 HTTP 分别 Save，断言两个开关持久值和另一协议的输入隐藏；从双开单独关闭 HTTP、从双开单独关闭 SOCKS5 均验证另一协议仍启用。
- 注入一次 `uci.set` ubus code 9，显示标准保存错误且 fixture 原值不变；重新加载后关闭双协议并 Save，两个 enabled 明确为 `0`。
- 验证期间恰有两个预期 pageerror（无效 Save、注入 RPC 失败）；任何其他 pageerror 或缺失 fixture 均失败。

## 截图与脱敏

每个主题对应 `default-off`、`both-enabled`、`port-conflict`、`credential-validation`、`validation-save-error`、`changes-redacted`、`socks-only-saved`、`http-only-saved`、`both-enabled-360`、`rpc-save-error`。

截图仅临时替换四个凭据 input 的 DOM 值：用户名为 `[REDACTED]`、密码为统一的虚构占位值并由原生 `type=password` 呈现 bullets；不触发输入事件，截图后在 finally 中还原原值。原生输入框和密码按钮保持可见；密码 input 类型另有自动断言。原值只暂存在页面内存中，不导出或记录。Changes 的星号来自当前 common.js，不是截图替换。日志/results 不输出凭据值，也不保存 HAR、trace、视频、DOM 快照或 RPC 请求体。脚本中的所有凭据均虚构；监听地址使用文档保留网段 192.0.2.0/24。

## 边界

这是 UI 验收，不证明 schema/backend 接受配置，不验证真实 LAN 地址归属、服务 reload、监听、认证、防火墙或 CONNECT 行为。`uci.changes` / `uci.set` 是内存 fixtures，不是 rpcd；Save & Apply 仅验证标准按钮存在，未执行 apply/revert。360px 有截图但没有自动无溢出断言，也未覆盖全部模型边界或所有主题。此证据脚本没有修改应用源码；没有设备操作、真实网络、推送或 B29 操作。
