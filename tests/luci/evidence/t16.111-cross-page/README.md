# T16.111 定向返工：跨页面真实 LuCI 摘要回归

**安全验收 FAIL，未修复，不可据此认定 T16.111 凭据脱敏完成。**

从 `3b296af090d10fa4ca7da221790b884be9960788` 继续，仅新增回归和证据。没有修改应用或系统 LuCI 源码。

## 重跑

工作树根目录执行，依赖已有离线 SDK、Playwright 和 Chromium：

```sh
NODE_PATH=/tmp/t16.23-evidence/node_modules \
node tests/luci/t16.111-cross-page-preview.js \
/workspace/openwrt/openwrt-actions/build/rockchip/build_dir/target-aarch64_generic_musl/root-rockchip/www
```

默认是安全门禁：完成应用/撤销检查、写出 `results.json` 后，若跨页弹窗包含凭据则退出 **1**。对应 `security-gate.log`，最后一行为 SECURITY FAIL。

同一命令追加 `--expect-leak` 是**已知缺陷复现模式**，确认恰好四个凭据字段泄露时退出 **0**；不是安全通过。对应 `reproduction.log`。`results.json` 始终保留 `securityAcceptance: FAIL`，不会因复现模式变为 PASS。

## 真实交互与观察

1. 真实 SDK + 当前高级页表单填入两个协议各自的虚构凭据及端口；点击标准 Save。fixture 确认只暂存，未调用 apply/revert，也未修改已提交配置。
2. 同一个 browser context、同一个 page、同一个 LuCI session ID，通过 `page.goto()` 全文档导航到独立页面；shell 加载未经修改的 SDK `view/system/reboot.js`。该页不引入 common，资源请求记录确认没有任何 Aether Proxy 模块。重启按钮只等待显示，**从未点击**。
3. 点击真实 `[data-indicator="uci-changes"]`；等待原生 `.uci-change-list`，检查实际 modal DOM。两个协议的用户名和密码均明文出现，普通端口值仍可读。没有直接调用 `displayChanges()`，也没有在新文档手工加载 common。
4. 点击该 modal 的原生 Save & Apply，走真实 SDK HTTP 请求至受控 fixture；fixture 确认四个凭据都按原值应用，不是星号或替代值。
5. 再次在高级页修改两个密码和两个端口并 Save；全文档导航回无 common 的页面，点击原生指示器，再点击原生 Revert。fixture 确认撤销暂存修改、保留先前应用原值；再次整页加载，指示器消失。

`results.json` 仅输出字段名、加载资源名、断言结果与不含值的写入记录。DOM 文本只在进程内比较，不输出或落盘；不保存含凭据截图、HAR、trace、请求体或原始 DOM。错误日志也不输出虚构凭据。

## 边界

所有 HTTP/ubus 由 Playwright route 截获，外部请求被拒绝。apply/revert 是内存 fixture，证明原生 UI 链路和数据语义，不证明实际 rpcd、后端事务、监听或设备应用。没有设备、真实网络或系统配置操作。原有单页 40 PASS 验收仍成立，但无法覆盖这个整页导航安全边界。
