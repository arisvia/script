# AI Agent Guide for `script` Repository

This repository serves two primary functions:
1. **Configuration Management**: Hosting modular configuration files and plugins for network proxy tools (Quantumult X, Loon, Sing-box).
2. **Build Orchestration**: A CI/CD pipeline to build custom `sing-box` binaries and Android apps from upstream sources.

## Data Structures & Architecture

### Configuration Files (`resource/` & Root)
- **Root Configs**: `sing-box.json`, `mihomo.yaml`, `loon.conf`, `quanx.conf` are base templates or complete configurations.
  - `sing-box.json` 与 `mihomo.yaml` 的分流语义**逐条对齐**：规则顺序、出口分组、DNS 策略必须同步修改，否则两套客户端行为不一致。`mihomo.yaml` 的注释里用 `---- sing-box rule N: ... ----` 标注对应关系。
- **Resource Directory** (`resource/{loon,quanx}/`): Contains modular rule sets.
  - **Loon**: `.plugin` files. structure usually involves `[Rule]`, `[Rewrite]`, `[Script]`, `[MITM]` sections.
  - **Quantumult X**: `.conf` files (partial configurations) and `.json` (likely for `task` or specific overrides).
  - **Naming Convention**: `service.type` (e.g., `netflix.plugin`, `apple.conf`).
- **Scripts**: `resource/ip.min.js` is a JS script (likely for response manipulation/visualization in proxy apps).

### Build System (`.github/workflows/build.yml`)
- **External Source**: The workflow checks out an *external* repository to build `sing-box`; it does **not** build from this local repo. Target is chosen by the `target` input (`official-stable`, `official-testing`, `ref1nd-stable`, `ref1nd-testing`), mapped to repo/branch in the `Resolve target` step.
- **cmd/internal/read_tag**: Used in the workflow to calculate versions.
- **Platform Matrix**: Builds for Linux (amd64/arm64, static or purego/glibc/musl), Windows, macOS, Android.
- **Package Managers**: Generates `.deb`, `.rpm`, `.pkg.tar.zst` (Pacman), `.ipk` (OpenWRT, aarch64 + x86_64).
- **Build Profile**: `profile` input selects tag set — `lean` (only what `sing-box.json` needs), `standard` (all non-naive), `full` (upstream `release/DEFAULT_BUILD_TAGS*`). Boolean toggles (`with_naive`, `with_cloudflared`, `with_tailscale`, `with_gvisor`, `with_dhcp`, `with_acme`) and `extra_tags` append on top.
- **Android Signing**: Requires repo/environment secrets `ANDROID_KEYSTORE_BASE64` and `ANDROID_LOCAL_PROPERTIES_BASE64` (both Base64). Missing either fails the `build: Apps` run.

## key Workflows & Commands

### 1. Build Triggers
The build workflow runs on `workflow_dispatch` and weekly on `schedule` (Mon 03:00 UTC). Scheduled runs use `target=ref1nd-testing` + `profile=lean` and skip the APK job.
- **Input `build`**: Choose `Binary` (core executables) or `Apps` (Android APKs).
- **Versioning**: Uses `cmd/internal/read_tag` (from the *target* repo). `--nightly` is applied automatically for `*-testing` targets.

### 2. OpenWRT & TProxy Setup
- **`tproxy.sh`**: Shell script generating NFTables rules for Transparent Proxying.
  - **Key Variables**: `PROXY_PORT` (12345), `PROXY_FWMARK` (0x1), `PROXY_TABLE` (100).
  - **Usage**: Runs on a Linux router/gateway to divert traffic to `sing-box`. Supports `start`, `stop`, `restart` commands.
  - **Bypassing**: Includes `byp4` and `byp6` sets for RFC1918 and local addresses.
- **`sing-box.sh`**: OpenWRT init script (`/etc/init.d/sing-box`).
  - **Function**: Manages the `sing-box` lifecycle using `procd`.
  - **Integration**: Automatically calls `tproxy.sh` (configured via `tproxy` variable, default `/etc/sing-box/tproxy.sh`) during `start` and `stop`.
- **`uci-defaults.sh`**: OpenWRT initialization script.
  - **Warning**: Contains placeholders (`Username`, `Password`, `WiFi_PWD`) that must be replaced before execution.
  - **Execution**: Can be injected into `/etc/uci-defaults/` for first-boot configuration.

### 3. Sing-box Configuration (`sing-box.json`)
- **Structure**:
  - `log` / `dns` / `providers` / `inbounds` / `outbounds` / `route` / `services` / `experimental`。
  - `dns`: 三个 server —— `global`（8.8.8.8，detour 走 `Available`）、`local`（223.5.5.5，QUIC）、`remote`（fakeip `198.18.0.0/16`）。DNS 规则用 `evaluate` + `geoip-cn match_response` 做国内外分流。
  - `route`: `rule_set` + `logical` 规则，`final` 是 `Available`，`default_domain_resolver` 是 `global`。
  - `outbounds`: `selector` 分组（`Available`/`AI`/`Google`/`Media`/`TikTok`/`Spotify`/`Bypass`）+ `urltest` 分组（`Auto`/`HK`/`TW`/`JP`/`KR`/`US`/`SG`/`EU`）。
  - **规则集**: 全部来自 `MetaCubeX/meta-rules-dat` 的 `.srs`，`format` 由 url 后缀自动推断，`update_interval` 默认 `1d`，均省略。
- **JSON 注释**: sing-box 的 JSON 解析器支持 `//` 和 `/* */` 注释（`sing-box check` 可验证）。`sing-box format` 会保留注释。可用于标注规则分组。

## Development Constraints & Patterns

- **Build Isolation**: Since the source code is external, you cannot "fix compilation errors" in *this* repo unless they are related to the workflow YAML itself or the scripts (`sing-box.sh`, `tproxy.sh`, `uci-defaults.sh`).
- **Config Modularity**: When asked to add a rule for a specific service (e.g., "Add Disney+ support"), check `resource/{app}/` first. If a dedicated file exists, edit it. If not, consider creating `disney.plugin`/`disney.conf`.
- **Hardcoded Values**: Watch out for hardcoded IP ranges (`198.18.0.0/16` for fakeip) and ports (`12345` for tproxy).
- **双配置同步**: 改分流规则时 `sing-box.json` 和 `mihomo.yaml` 必须同时改。对应关系：
  - sing-box `rule_set` ↔ mihomo `rule-providers`（同为 `MetaCubeX/meta-rules-dat` 的 mrs/srs）
  - sing-box `selector` ↔ mihomo `proxy-groups`（`select` 类型）
  - sing-box `urltest` ↔ mihomo `url-test` 类型分组
  - `geoip-cn` / `geoip-private` 在 mihomo 侧由 `GEOIP,CN` / `GEOIP,LAN` 的内置 mmdb 承担，无需 provider
- **配置体积**: `mihomo.yaml` 用 YAML 锚点（`&mrs` / `&test`）压缩重复字段；sing-box 侧依靠省略 `format`、`update_interval` 等有默认值的字段。新增 provider 时沿用锚点，不要展开。
- **IPv6 差异（有意为之）**: `mihomo.yaml` 是 `ipv6: true` + `dns.fake-ip-range6`，双栈；`sing-box.json` 的 `dns.strategy` 是 `prefer_ipv4`，`fakeip.inet6_range` 虽配置但仅作兜底。两者面向不同设备：桌面端 mihomo 走双栈，路由器 sing-box 优先 v4。
- **mihomo 字段坑**:
  - `global-client-fingerprint` 在 v1.19.33 已移除，改用节点级 `tls.utls.fingerprint`。
  - `proxy-providers.override` 只支持固定键（`tfo`/`udp`/`skip-cert-verify`/`ip-version` 等），**不支持 `client-fingerprint`**；要改任意字段用 `override.override-expr`。
  - `tun.dns-mode` 留空即默认按 `dns-hijack` 劫持，日志里 `dns mode:` 后面为空属正常。
  - `fake-ip-range` 会被推导成 TUN 的 IPv4 地址（取前 30 位），改它等于改 TUN 网段；`fake-ip-range6` 不参与推导，v6 侧用 `tun.inet6-address` 默认值 `fdfe:dcba:9876::1/126`。
- **Script Minification**: `ip.min.js` is minified. If complex logic changes are needed, ask for the source or structure the edit carefully around the existing minified logic.
- **OpenWRT WiFi**: 5GHz WiFi requires `option country` to be set (e.g. 'CN', 'US') to enable AP mode; otherwise, it stays disabled.

## Common Task Examples

### Adding a new rule to Loon
File: `resource/loon/universal.plugin` or create `resource/loon/new_service.plugin`
```ini
[Rule]
DOMAIN-SUFFIX,example.com,PROXY
```

### Modifying TProxy Redirection Port
File: `tproxy.sh`
```bash
# Change default port 12345 to 7890
PROXY_PORT=7890
```

### Update Sing-box Service Logic
File: `sing-box.sh`
- Uses `procd` for process management and respawning.
- Ensure `WORKDIR` exists and permissions are set.
- Triggers restart on interface events (see `service_triggers`).

### Update OpenWRT Init Script
File: `uci-defaults.sh`
- Ensure secret placeholders are managed.
- Use `uci batch` for atomic updates.
- Set country code for 5GHz functionality.
