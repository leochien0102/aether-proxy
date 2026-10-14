# Rule-data baseline sources

| Output | Upstream URL | Downloaded (UTC) | Raw SHA-256 | License / terms | Generated lines |
|---|---|---|---|---|---:|
| `gfwlist.txt` | https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt | 2026-10-14T09:43:47+00:00 | `d9fe4835167f0039fa6909df23de4b7c3ead5c439b5b80d8e6c21184d98d93f5` | LGPL-2.1 | 4357 |
| `chnlist.txt` | https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/accelerated-domains.china.conf | 2026-10-14T09:43:48+00:00 | `3cefab03714344276c95aec7d25980d31f7b9d084b4c4032dd2367ebeb54e0f3` | WTFPL | 109893 |
| `apple.txt` | https://raw.githubusercontent.com/felixonmars/dnsmasq-china-list/master/apple.china.conf | 2026-10-14T09:43:49+00:00 | `5b85e3febd8067233d86483299f257806428b5d520c65e3da3c0ce9465568f64` | WTFPL | 166 |
| `chnroute4.txt` | https://ftp.apnic.net/stats/apnic/delegated-apnic-latest | 2026-10-14T09:43:51+00:00 | `4e0fef66ae1a74726a21f479a5b94530f42d1e863c16664f2a6b8bede8591322` | APNIC statistics; APNIC terms of use | 5496 |
| `gfw_static4.txt` | https://core.telegram.org/resources/cidr.txt | 2026-10-14T09:39:09+00:00 | `3ecd072cedf72eceee6961b18a51e37f905d5ce4a656a5d24cf5fea63e6ec651` | No explicit license identified; review upstream terms before redistribution | 7 |

## gfwlist skipped-entry counts

- `comment`: 112
- `duplicate`: 6
- `header`: 1
- `ip_address`: 1
- `regex`: 1
- `whitelist`: 33
- `wildcard`: 12

## Required baseline additions

- `apple.com` is added to `apple.txt`: the current upstream `apple.china.conf` contains Apple subdomains but not the required apex domain.
