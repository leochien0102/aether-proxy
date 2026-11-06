# tests/dns — dnsmasq 能否替代 ChinaDNS-NG（手动）

`check.py` 是**手动**验证脚本，不在 `tests/run.uc` 里：它需要一个宿主机的 dnsmasq（≥ 2.90，
要有 `--filter-rr`），CI 里没有这个二进制。设计依据见 [docs/03-dns.md](../../docs/03-dns.md)「替换 ChinaDNS-NG」。

```sh
# 任意一份 dnsmasq 源码，或系统自带
make -C <dnsmasq-source>
DNSMASQ_BIN=<dnsmasq-source>/src/dnsmasq python3 tests/dns/check.py
```

脚本在 loopback 上起若干个 dnsmasq 实例和几个假上游（不同 IP、可加延迟），断言的是**设计依赖的行为**：

| 断言 | 为什么重要 |
|---|---|
| `server=/gfw.test/` 命中 `gfw.test`、`www.gfw.test`，不命中 `supergfw.test` | 我们的域名表都是后缀语义 |
| 更具体的 `server=` 覆盖更宽的一条 | 服务级分流规则要能压过默认分组 |
| `filter-rr=AAAA,HTTPS` 去掉应答里的记录（上游确实答了） | 替代 chinadns-ng 的 `no-ipv6` / `filter-qtype 65` |
| 4,300 / 109,893 条 `server=` 全部路由正确，并打印启动耗时、RSS、p50 | 决定要不要把 chnlist 也塞进 dnsmasq |
| 一个挂住的上游不影响其它域名 | 隧道挂掉时不能拖垮整个 DNS |
| 同组内有活服务器时，死服务器 0 ms 让位 | 能否用「同组多上游」表达 T1→T2→T3 |
| 默认按 RTT 选服务器，`--strict-order` 才按声明顺序 | 决定了级别切换必须重写配置并重启，而不是靠多写几行 |

## 2026-11-02 的记录（dnsmasq 2.93，x86_64 宿主机编译，非设备）

```
-- startup 111 ms, RSS 3260 kB
-- n=  4300 conf= 0.16 MiB startup=111 ms rss= 4260 kB p50=0.16 ms ok=200/200
-- n=109893 conf= 4.05 MiB startup=111 ms rss=28160 kB p50=0.16 ms ok=200/200
17 项断言全部 PASS
```

x86 数字只用来比较量级：设备上的启动耗时和 RSS 要单独测（见 docs/03 结尾的「真机上仍需验证的」）。

## 已知限制（脚本不覆盖）

- 上游端口关闭时 dnsmasq 不返回 SERVFAIL，10 秒后直接丢弃查询（`config.h` 的 `TIMEOUT`）。降级必须由 monitor 主动切换。
- 命中缓存后不再询问上游，所以上面关于「让位」的断言只在缓存未命中时有意义。
- 没有覆盖 DNSSEC / EDNS 交互：本设计不使用。
