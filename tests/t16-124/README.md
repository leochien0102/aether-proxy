# T16.124 定向验收

在本卡 worktree 根目录运行：

```sh
python3 tests/t16-124/run.py
bash tests/luci/run.sh
bash tests/sub/run.sh
```

## 前置条件（不自动安装）

- 已有 `tests/host/prefix/bin/ucode` 及宿主机库，使用现有 `tests/host/ucode` 包装器。
- Python 3、Node.js、真实 curl。
- 已有 Playwright 与 Chromium。默认 `require('playwright')`；不在当前 Node 搜索路径时，用
  `PLAYWRIGHT_MODULE=/已有安装/node_modules/playwright` 指定。可用 `CHROMIUM_PATH` 指定已有 Chromium。
- 默认只读使用现有 SDK：
  `/workspace/openwrt/openwrt-actions/build/rockchip/feeds/luci/modules/luci-base/htdocs/luci-static/resources`。
  其他安装位置通过 `LUCI_SDK_RESOURCES` 指定。

缺少任一条件即失败，不下载、不安装、不以 SKIP 当通过。临时配置、浏览器临时目录均位于本卡
`tests/t16-124/tmp.*` 内，测试退出清理，不连接路由器或修改 SDK。

## 真实 SDK 保存

`sdk-save.cjs` 在真实 Chromium DOM 中读取并执行 SDK 原文件：`luci.js`、`cbi.js`、
`validation.js`、`ui.js`、`form.js`、`uci.js`。复用现有 `tests/luci/loader.js` 的依赖扫描器，
**不加载 `tests/luci/form-sdk.js`，不重写 SDK parse/save**。运行时只额外导出 SDK 内建类，跳过
会联系路由器的 `LuCI.__init__()`；执行应用的真实订阅块、通用设置、GridSection modal clone 和保存保护。
断言 `Map.parse/save` 仍为 SDK 原方法。

远程 RPC 边界接隔离的内存配置存储：真实 SDK UCI 缓存、变更检测、`uci.save()` 的
get/set/delete 请求实际执行；不启动 rpcd，也不测试设备上的 UCI RPC/ACL、应用服务重载。
测试将 **RPC 保存后的配置** 导出，不用手写期望配置代替 SDK 输出。

覆盖通用设置及订阅弹窗的不改、显式预设、自定义、切回默认/继承、自定义草稿往返、
历史值及只改名称不重写 UA，含显式值恰等于通用值/应用默认值。输出 SDK 路径与源文件 SHA256 便于复核。

## 实际 HTTP 与解析

`run.py` 复用 `tests/sub/fixtures/one-node.txt`，启动 loopback 随机端口 HTTP 服务，记录服务器
收到的实际 User-Agent。把 SDK 保存结果序列化为隔离 UCI 文件，然后运行真实应用 CLI、真实 curl。
每个 SDK 场景分别返回明文 URI 与整包 Base64，断言：

1. 实际请求恰有一个且 UA 完全匹配；
2. 应用报告订阅更新成功；
3. 生产 `config.load()` 读回恰一个 VLESS 节点，地址、UUID、来源正确；
4. `sub.json` 的节点数、last_ok 与 error 符合成功状态；
5. 获取方式仍为 direct。

真实 HTTP 验收仅覆盖本机直连受控端点，不代表公网订阅站会按相同 UA 返回相同格式。
proxy/auto 的参数与重试行为沿用 `tests/sub/run.sh` 中 T9.17 定向断言；本卡不改下载器。
浏览器保存验证不加载生产主题，不代替 T16.122 的按钮命中区/主题验收；本卡不引入清空或密码按钮。
