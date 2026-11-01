# B25 概览页热力图设计（T12.1）

状态：设计草案（实验分支 `experiment/b25-heatmap`）。默认关闭；达不到预期可整分支撤掉。
依据：`docs/backlog.md` B25、`docs/02-dataplane.md` 计数器、`docs/04-lifecycle.md` monitor、
`docs/05-config.md`、`docs/10-cli-luci.md`、`docs/09-logging.md`。

## 1. 目标与非目标

目标：在概览页显示最近 90 天的每日代理流量 × 服务健康度热力图。

非目标：
- 不做域名、节点、目的地、访问记录；
- 不做历史回填；
- 不把 90 天数据塞进 5 秒轮询的 `stats`；
- 不引入图表库；不改变现有 `stats` 口径。

## 2. 开关与配置

新增：

```uci
config stats 'stats'
    option heatmap_enabled '0'
```

- 默认 `0`；配置缺省、空值、非 `1` 均视为关闭。
- 关闭：monitor 不读 nft 计数器、不写 `usage.json`；`stats history` 返回
  `{ok:true, enabled:false, days:[]}`；概览不渲染热力图卡片。
- 开启：从开启时刻开始记录；关闭时保留已有文件但停止更新；重新开启继续累计。
- 开关属于普通配置，走现有 apply/reload；不新增 rpcd 写接口。
- 高级设置页加一个 bool 开关，文案「启用使用热力图（记录每日流量与健康度）」。

## 3. 数据模型

文件：`/etc/aether-proxy/usage.json`，权限 `0600`，由 `sys.write_atomic` 写。

```json
{
  "schema": 1,
  "updated_at": 1790000000,
  "days": {
    "2026-11-01": {
      "tx": 123456,
      "rx": 987654,
      "observed": 86400,
      "healthy": 82000
    }
  }
}
```

- `tx/rx`：当日代理计数的增量字节；计数器清零时按“清零后当前值”累加，不产生负数。
- `observed`：服务处于应运行状态、且本轮能观测的秒数；用于健康比例分母。
- `healthy`：`observed` 中服务健康（running 且 proxy_ok）的秒数；不超过 `observed`。
- 只保留最近 90 个本地日期（含今天）；裁剪在每次落盘时做。
- 未知字段保留；损坏/不可解析文件按空历史启动，记一次 warn 事件，不阻塞服务。

## 4. 采样

在 monitor 现有 tick 内采样，不新增定时器：

1. 从 `daemon.snapshot.stats.heatmap_enabled` 判断；关闭直接返回。
2. 用 `nft -j list counters table inet aetherproxy` 读 `proxy_tx/proxy_rx`；读不到/解析失败
   只跳过本轮字节，不记 error（避免 30 秒刷日志）。
3. 用 `clock(true)` 计算与上次样本的 `elapsed`，上限为当前 monitor 间隔的 2 倍，避免休眠后
   一次性灌入大量秒数。
4. 计数增量：
   - `current >= previous`：`delta = current - previous`；
   - `current < previous`：视为计数器重建，`delta = current`；
   - 首次样本只记录基线，不增加字节。
5. 当前本地日期与上次不同：先把旧日写入内存并落盘，再开始新日；时钟回退/跳跃时保留旧条目，
   不把负时间写入。
6. `observed` 只在服务应运行（`running`/`degraded`/`failsafe`）且本轮读到代理计数器时增加；
   `healthy` 只在 `state == 'running'` 且 `proxy_ok == true` 时增加。
7. 当天数据只在内存；跨天或干净停止时落盘。**v1 不做 6 小时 checkpoint**，避免额外 flash
   写入；异常掉电最多丢失当天数据（已落盘的过去日期不受影响）。

## 5. 持久化与失败

- 跨天/daemon 干净停止时写；写入失败记 warn 事件，保留内存数据，下次再试。
- 每天一次写，90 天文件约 10–20 KB；远低于 flash 寿命预算。
- 不把 usage 写入 `/var/run`，避免重启丢失；不写 `/tmp`。
- 裁剪严格按日期字符串排序，保留最近 90 条。
- 文件损坏/权限错误：读失败返回空历史并记一次 warn；不自动删除原文件，下一次成功写入时覆盖。

## 6. API

### CLI

```text
aether-proxy stats history [--days N] [--json] [--sys-root DIR] [--run-dir DIR]
```

- `--days`：1–90，默认 90；超出范围返回 `USAGE`。
- 成功：
  ```json
  {
    "ok": true,
    "enabled": true,
    "days": [
      {"date": "2026-11-01", "tx": 123, "rx": 456, "observed": 3600, "healthy": 3500}
    ],
    "updated_at": 1790000000
  }
  ```
- 关闭：`enabled:false, days:[]`，不读文件。
- 只读；不写配置、不写 usage、不触发 monitor。

### rpcd

新增 `stats_history`，参数 `{days?: number}`，返回同上；ACL 归 read。
概览页只在需要热力图时调用；关闭时可直接使用 `enabled:false` 结果。

## 7. UI

（T12.7 返工后的最终口径；实现细节见 docs/10「B25：概览页使用热力图」。）

- 位置：概览页提示区（notice）之后、「运行状态」之前；关闭时完全不渲染、零 API。
- 无卡片背景、无「使用热力图」标题、无星期表头；网格直接渲染在容器里。
- CSS grid：**3 行 × 30 列 = 90 格**的连续日期网格，row-major——最近 90 个本地日期
  （含今天），无前导空格，今天恒在右下角（index 89），与星期几无关。
- 每格：日期、总代理流量（tx+rx）、健康比例 `healthy/observed`。
- 容器 `.ap-heat-wrap` 宽 75%、水平居中（`margin-inline: auto`），与「运行状态」卡之间
  保留 `margin-bottom: 1.25em` 间距；关闭时区域为空 div，`:empty { display: none }`
  让它完全不占位。
- 网格 30 列等宽铺满容器（`repeat(30, minmax(0, 1fr))`、`gap: 3px`、`width: 100%`）；
  每格圆角正方形（`aspect-ratio: 1`、`border-radius: 20%`，桌面约 25px 一格），
  3 行总高约 80–100px，不把页面顶出竖向滚动。
- 颜色：对 `log1p(tx+rx)` 做 0–1 归一化，映射 5 档；0 流量为浅色。
- 健康度：格子边框/角标表示 `healthy/observed`；`observed=0` 用中性色，不画成故障。
- tooltip：日期、代理流量（自动单位）、健康占比、观测时长；空白格无 tooltip。
- 无数据的日子空白中性色，不补 0、不回填、不缩短窗口；空历史也渲染完整 90 格中性网格；
  读取失败保留最后网格并在上方显示一句错误。
- 窄屏：格子随容器等比压缩，外层 `overflow-x: auto` 兜底横向滚动；不依赖外部图表库。
- i18n：所有文案进入 `po/zh_Hans`；只显示日期/数字/流量，不显示节点或域名。

## 8. 失败/边界

| 场景 | 行为 |
|---|---|
| 关闭 | 不采样、不写、API `enabled:false`、UI 不渲染 |
| 首次开启 | 从当前时刻开始，不为过去日期补 0 |
| 关闭再开 | 保留历史，继续累计 |
| 计数器清零/重启 | 加当前值，不产生负数 |
| 跨天 | 旧日写盘，新日从 0 开始 |
| 时钟跳变 | 不写负时间；保留已有日期；跳变后的样本按新日期 |
| usage 损坏 | 空历史 + 一次 warn；不阻塞服务 |
| 写失败 | 保留内存，下次重试；不阻塞 monitor |
| 无数据/未运行 | UI 中性色，不标红 |

## 9. 测试与验收

后端：
- 采样纯函数（假时钟）：首次基线、增量、清零、跨天、时钟回退、elapsed 上限；
- 开关默认 0：关闭时无 nft 调用、无文件写入、无历史；
- 开启/关闭/重开；90 天裁剪；损坏文件；写失败；
- `stats history` CLI/rpcd 契约、`--days` 边界、ACL；
- 不改变现有 `stats` 输出。

前端：
- 3×30 网格（90 格、今天右下角、无前导空格）、颜色归一化、健康度、tooltip、
  无数据/关闭/失败保留；无标题/无表头/无卡片背景、圆角正方形、容器 75% 居中、
  与运行状态间距、`:empty` 隐藏、格子尺寸/高度、窄屏滚动；
- i18n；关闭时无 API 调用/无渲染。

真机：H28K 开启一天，确认 `usage.json`、API、UI；关闭后停止写；重开继续。

## 10. 实现拆分

每张卡只做一个可独立验收的层，不把后端全塞一张：

1. **T12.2 配置与关闭路径**：`config stats`、`heatmap_enabled` 默认 0、schema/default、
   高级页开关、关闭时无采样/无文件/无历史的骨架；测试只覆盖开关与关闭路径。
2. **T12.3 采样与内存聚合**：monitor tick 读计数器、增量/清零/跨天/elapsed 上限的纯函数，
   假时钟测试；暂不落盘。
3. **T12.4 持久化**：`usage.json` schema、0600 原子写、跨天/干净停止、90 天裁剪、损坏/写失败；
   测试覆盖文件与 flash 预算说明。
4. **T12.5 历史 API**：`stats history`、rpcd `stats_history`、ACL、`--days`/空数据/关闭返回；
   不碰 UI。
5. **T12.6 概览热力图 UI**：颜色、健康度、tooltip、空态/窄屏/i18n；关闭不渲染
   （T12.7 把 7×13 周网格返工成 3×30 连续日期网格，见 §7）。
6. 文档收尾与 H28K 验收。

依赖顺序：T12.2 → T12.3 → T12.4 → T12.5 → T12.6。每张卡都在
`experiment/b25-heatmap`，完成后单独审查；未达预期可整分支撤掉。
