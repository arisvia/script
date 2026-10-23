# AGENTS.md

本仓库做两件事：维护代理客户端配置，以及从上游构建 sing-box 二进制与 Android APK。

## 目录

| 路径 | 内容 |
|---|---|
| `sing-box.json` | sing-box 完整配置 |
| `mihomo.yaml` | mihomo 完整配置 |
| `loon.conf` / `quanx.conf` | Loon / Quantumult X 配置 |
| `resource/loon/` `resource/quanx/` | 分模块规则与插件，命名 `service.type` |
| `resource/ip.min.js` | 压缩过的 JS，改动需谨慎 |
| `tproxy.sh` | OpenWrt NFTables TProxy 规则 |
| `sing-box.sh` | OpenWrt procd 启动脚本 |
| `uci-defaults.sh` | OpenWrt 首启配置，含占位符需替换 |
| `.github/workflows/build.yml` | CI 构建 |

## 双配置同步

`sing-box.json` 与 `mihomo.yaml` 的分流语义逐条对齐，改规则必须同时改两边。

| sing-box | mihomo |
|---|---|
| `rule_set` | `rule-providers`（同为 MetaCubeX/meta-rules-dat） |
| `selector` | `proxy-groups`（`select`） |
| `urltest` | `proxy-groups`（`url-test`） |
| `geoip-cn` / `geoip-private` | `GEOIP,CN` / `GEOIP,LAN`，用内置 mmdb，无需 provider |

`mihomo.yaml` 用 `---- route.rules[N] ----` 注释标注对应下标。

## 构建

外部仓库构建，不在本仓库编译。

- `target`：`official-stable` / `official-testing` / `ref1nd-stable` / `ref1nd-testing`
- `profile`：`lean`（仅当前配置所需）/ `standard`（全部非 naive）/ `full`（上游默认）
- `build`：`Binary` 或 `Apps`
- 定时任务：每周一 03:00 UTC，`target=ref1nd-testing` + `profile=lean`，不发 APK
- `ref1nd-*` 目标需用 `reF1nd/sing-box-for-android`，官方客户端缺 `createAutoRedirectListener` 等接口会编译失败
- APK 签名依赖 environment `build` 下的 `ANDROID_KEYSTORE_BASE64` 与 `ANDROID_LOCAL_PROPERTIES_BASE64`
- 定时任务自动发布 `nightly-YYYYMMDD` release，只留最近 8 期

## 配置要点

### sing-box.json

- `dns`：`global`（8.8.8.8 走 `Available`）、`local`（223.5.5.5）、`remote`（fakeip `198.18.0.0/16`）；用 `evaluate` + `geoip-cn match_response` 分流
- `route`：`final` 是 `Available`，`default_domain_resolver` 是 `local`
- 规则集用 `.srs`，`format` 与 `update_interval` 由后缀/默认值推断，均省略
- `inbounds` 里 `tun` 仅作参考，实际部署用 `tproxy`。两者同时启用会产生两套 nftables 规则
- JSON 解析器支持 `//` 注释，但**本仓库保持纯 JSON**，便于 `jq` / `json.load`

### mihomo.yaml

- 用 YAML 锚点压缩：`&mrs`（provider）、`&test`（url-test 组）
- `fake-ip-range` 会被推导成 TUN 的 IPv4 地址（取前 30 位），改它等于改 TUN 网段
- `fake-ip-range6` 不参与推导，v6 侧用 `tun.inet6-address` 默认值 `fdfe:dcba:9876::1/126`
- `global-client-fingerprint` 已移除，改用节点级 `tls.utls.fingerprint`
- `proxy-providers.override` 只支持固定键（`tfo`/`udp`/`skip-cert-verify`/`ip-version` 等），改任意字段用 `override.override-expr`
- `tun.dns-mode` 留空即按 `dns-hijack` 劫持，日志 `dns mode:` 为空属正常
- IPv6 有意与 sing-box 不同：mihomo 双栈（`ipv6: true` + `fake-ip-range6`），sing-box 是 `prefer_ipv4`

### tproxy.sh

- `prerouting` 里**不能**对 `$PROXY_FWMARK` 做 return：本机流量靠该 mark 经策略路由回 `prerouting` 才被 tproxy 接走，return 会让它绕过 tproxy 直奔不存在的本地 socket，导致断网
- `divert` 链只处理 TCP：`socket transparent` 按四元组查 socket，UDP 无连接状态、代理只开通配 socket，匹配恒不命中
- 变量均可环境变量覆盖，多内核共存时各用独立 `NFT_TABLE` 与 `PROXY_FWMARK`
- 纯 tproxy 模式下 TCP 在路由器终结，无需 MSS 钳制

## 约束

- 外部源码的编译错误无法在本仓库修复
- 硬编码值：fakeip `198.18.0.0/16`、tproxy 端口 `12345`、`PROXY_FWMARK=0x1`、`PROXY_TABLE=100`
- `uci-defaults.sh` 的 `Username` / `Password` / `WiFi_PWD` 是占位符，执行前必须替换
- 5GHz WiFi 需设 `option country`，否则 AP 不启用
