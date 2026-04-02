# AI Agent Guide for `script` Repository

This repository serves two primary functions:
1. **Configuration Management**: Hosting modular configuration files and plugins for network proxy tools (Quantumult X, Loon, Sing-box).
2. **Build Orchestration**: A CI/CD pipeline to build custom `sing-box` binaries and Android apps from upstream sources.

## Data Structures & Architecture

### Configuration Files (`resource/` & Root)
- **Root Configs**: `sing-box.json`, `loon.conf`, `quanx.conf` are base templates or complete configurations.
- **Resource Directory** (`resource/{loon,quanx}/`): Contains modular rule sets.
  - **Loon**: `.plugin` files. structure usually involves `[Rule]`, `[Rewrite]`, `[Script]`, `[MITM]` sections.
  - **Quantumult X**: `.conf` files (partial configurations) and `.json` (likely for `task` or specific overrides).
  - **Naming Convention**: `service.type` (e.g., `netflix.plugin`, `apple.conf`).
- **Scripts**: `resource/ip.min.js` is a JS script (likely for response manipulation/visualization in proxy apps).

### Build System (`.github/workflows/build.yml`)
- **External Source**: The workflow checks out an *external* repository (defined in vars `REPOSITORY`) to build `sing-box`. It does **not** build code from this strictly local repo.
- **cmd/internal/read_tag**: Used in the workflow to calculate versions.
- **Platform Matrix**: Builds for Linux (amd64/arm64, glibc/musl), Windows, macOS, Android.
- **Package Managers**: Generates `.deb`, `.rpm`, `.pkg.tar.zst` (Pacman), `.ipk` (OpenWRT).

## key Workflows & Commands

### 1. Manual Build Trigger
The build workflow is `workflow_dispatch` only.
- **Input `build`**: Choose `Binary` (core executables) or `Apps` (Android APKs).
- **Versioning**: Uses `cmd/internal/read_tag` (from the *target* repo) to determine the version.

### 2. OpenWRT & TProxy Setup
- **`tproxy.nftables`**: Shell script generating NFTables rules for Transparent Proxying.
  - **Key Variables**: `PROXY_PORT` (12345), `PROXY_FWMARK` (0x1), `PROXY_TABLE` (100).
  - **Usage**: Runs on a Linux router/gateway to divert traffic to `sing-box`. Supports `start`, `stop`, `restart` commands.
  - **Bypassing**: Includes `byp4` and `byp6` sets for RFC1918 and local addresses.
- **`sing-box.sh`**: OpenWRT init script (`/etc/init.d/sing-box`).
  - **Function**: Manages the `sing-box` lifecycle using `procd`.
  - **Integration**: Automatically calls `tproxy.nftables` (configured via `tproxy` variable, default `/etc/sing-box/tproxy.sh`) during `start` and `stop`.
- **`uci-defaults.sh`**: OpenWRT initialization script.
  - **Warning**: Contains placeholders (`Username`, `Password`, `WiFi_PWD`) that must be replaced before execution.
  - **Execution**: Can be injected into `/etc/uci-defaults/` for first-boot configuration.

### 3. Sing-box Configuration (`sing-box.json`)
- **Structure**:
  - `dns`: Defines `https`, `quic`, `fakeip` servers.
  - `route`: Uses `rule_set`, `clash_mode`, `logical` rules.
  - **Tags**: `google`, `aliyun`, `remote` are key node tags.

## Development Constraints & Patterns

- **Build Isolation**: Since the source code is external, you cannot "fix compilation errors" in *this* repo unless they are related to the workflow YAML itself or the scripts (`sing-box.sh`, `tproxy.nftables`, `uci-defaults.sh`).
- **Config Modularity**: When asked to add a rule for a specific service (e.g., "Add Disney+ support"), check `resource/{app}/` first. If a dedicated file exists, edit it. If not, consider creating `disney.plugin`/`disney.conf`.
- **Hardcoded Values**: Watch out for hardcoded IP ranges (`198.18.0.1/16` for fakeip) and ports (`12345` for tproxy).
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
File: `tproxy.nftables`
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
