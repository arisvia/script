#!/bin/sh

# ---------------------------------------------------------
# Sing-Box OpenWrt TProxy NFTables Setup Script
#
# 设计要点：
#   1. 不使用 `socket transparent` 匹配器 —— 它对 UDP 不可靠，
#      且需要额外 kmod-nft-socket。改用 fwmark 防环，TCP/UDP 统一处理。
#   2. prerouting / output 开头都以 `meta mark $PROXY_FWMARK return`
#      拦截已打标流量，阻断本机 output → prerouting 的回环。
#   3. 依赖检测用 `nft -c` 实测内核能力，避免 lsmod 对
#      built-in (=y) 模块的误判。
# ---------------------------------------------------------

# Configuration
# 全部可用环境变量覆盖，例如跑 mihomo：
#   NFT_TABLE=mihomo PROXY_PORT=12345 ./tproxy.sh start
PROXY_PORT=${PROXY_PORT:-12345}         # tproxy inbound 的 listen_port
PROXY_FWMARK=${PROXY_FWMARK:-0x1}       # 被代理流量打的 mark（与 ip rule 匹配）
PROXY_TABLE=${PROXY_TABLE:-100}         # 策略路由表号
PROXY_RULE_PREF=${PROXY_RULE_PREF:-100} # ip rule 优先级，显式指定避免被 mwan3/Docker 插队
ROUTING_MARK=${ROUTING_MARK:-0xff}      # 代理进程自身出站流量 mark（sing-box default_mark / mihomo routing-mark）
NFT_TABLE=${NFT_TABLE:-sing-box}        # nft table 名，sing-box 与 mihomo 各用一张，互不干扰

check_dependencies() {
  echo "🔍 Checking dependencies..."

  if ! command -v nft >/dev/null 2>&1; then
    echo "❌ nft 不可用，请安装 nftables-json 或 firewall4"
    exit 1
  fi

  # 用真实规则做能力探测：nft -c 只校验不加载
  # 若内核未提供 nft_tproxy，此处会失败（无论模块是 =y 还是 =m）
  if ! nft -c -f - >/dev/null 2>&1 <<'EOF'
table inet _sb_probe {
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    meta l4proto tcp tproxy to :1
  }
}
EOF
  then
    echo "❗nft_tproxy 不可用，尝试加载模块..."
    modprobe nft_tproxy 2>/dev/null || true
    if ! nft -c -f - >/dev/null 2>&1 <<'EOF'
table inet _sb_probe {
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;
    meta l4proto tcp tproxy to :1
  }
}
EOF
    then
      echo "❌ 内核缺少 nft_tproxy，请执行: opkg install kmod-nft-tproxy"
      exit 1
    fi
  fi

  echo "✅ nft_tproxy 可用"
}

setup_policy_routing() {
  # IPv4
  if ! ip rule show | grep -q "fwmark $PROXY_FWMARK.*lookup $PROXY_TABLE"; then
    ip rule add pref $PROXY_RULE_PREF fwmark $PROXY_FWMARK table $PROXY_TABLE
  fi
  # “local 0.0.0.0/0 dev lo” 是 TProxy 常规搭配：让被标记包本地投递
  if ! ip route show table $PROXY_TABLE | grep -q "^local 0.0.0.0/0 dev lo"; then
    ip route add local 0.0.0.0/0 dev lo table $PROXY_TABLE
  fi

  # IPv6
  if ! ip -6 rule show | grep -q "fwmark $PROXY_FWMARK.*lookup $PROXY_TABLE"; then
    ip -6 rule add pref $PROXY_RULE_PREF fwmark $PROXY_FWMARK table $PROXY_TABLE
  fi
  if ! ip -6 route show table $PROXY_TABLE | grep -q "^local ::/0 dev lo"; then
    ip -6 route add local ::/0 dev lo table $PROXY_TABLE
  fi
}

apply_nft_rules() {
  # 幂等：先删旧表
  nft delete table inet $NFT_TABLE 2>/dev/null || true

  nft -f - <<EOF
table inet $NFT_TABLE {

  # -----------------------
  # 保留地址集合
  # 注意：不要加入 198.18.0.0/16，那是 fakeip 网段，
  #       一旦加入会让 fakeip 流量绕过 tproxy 导致断网。
  # -----------------------
  set byp4 {
    type ipv4_addr
    flags interval
    elements = {
      0.0.0.0/8,        # 本网络
      10.0.0.0/8,       # RFC1918
      100.64.0.0/10,    # CGNAT
      127.0.0.0/8,      # loopback
      169.254.0.0/16,   # IPv4 link-local
      172.16.0.0/12,    # RFC1918
      192.168.0.0/16,   # RFC1918
      192.0.0.0/24,     # IETF 协议分配
      192.0.2.0/24,     # TEST-NET-1
      198.51.100.0/24,  # TEST-NET-2
      203.0.113.0/24,   # TEST-NET-3
      224.0.0.0/4,      # multicast
      240.0.0.0/4,      # reserved
    }
  }

  set byp6 {
    type ipv6_addr
    flags interval
    elements = {
      ::1/128,       # loopback
      fc00::/7,      # ULA
      fe80::/10,     # link-local
      ff00::/8,      # multicast
    }
  }

  # -----------------------
  # PREROUTING：拦截 LAN 转发流量 / 本机 output 回灌流量
  # -----------------------
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;

    # 已打标（tproxy 命中或 output 回灌）的流量直接放行，
    # 交由 ip rule 投递到 lo，避免 UDP 反复 tproxy 形成回环。
    meta mark $PROXY_FWMARK return

    meta l4proto != { tcp, udp } return

    fib daddr type local return
    fib daddr type { multicast, broadcast } return

    ip  daddr @byp4 return
    ip6 daddr @byp6 return

    meta l4proto { tcp, udp } tproxy to :$PROXY_PORT meta mark set $PROXY_FWMARK accept
  }

  # -----------------------
  # OUTPUT：路由器本机发起流量打 mark，触发策略路由回到 prerouting
  # -----------------------
  chain output {
    type route hook output priority mangle; policy accept;

    # sing-box 自身出站流量，放行
    meta mark $ROUTING_MARK return

    # 已打标，避免重复处理
    meta mark $PROXY_FWMARK return

    meta l4proto != { tcp, udp } return

    fib daddr type local return
    fib daddr type { multicast, broadcast } return

    ip  daddr @byp4 return
    ip6 daddr @byp6 return

    meta l4proto { tcp, udp } meta mark set $PROXY_FWMARK accept
  }
}
EOF
}

start() {
  check_dependencies
  setup_policy_routing
  apply_nft_rules
  echo "✅ sing-box TProxy rules applied."
}

stop() {
  nft delete table inet $NFT_TABLE 2>/dev/null || true

  while ip rule show | grep -q "fwmark $PROXY_FWMARK.*lookup $PROXY_TABLE"; do
    ip rule del fwmark $PROXY_FWMARK table $PROXY_TABLE
  done
  while ip -6 rule show | grep -q "fwmark $PROXY_FWMARK.*lookup $PROXY_TABLE"; do
    ip -6 rule del fwmark $PROXY_FWMARK table $PROXY_TABLE
  done

  # 精确删除本脚本添加的路由，避免 flush 误清同表内其它规则
  ip route del local 0.0.0.0/0 dev lo table $PROXY_TABLE 2>/dev/null || true
  ip -6 route del local ::/0 dev lo table $PROXY_TABLE 2>/dev/null || true

  echo "🧹 sing-box TProxy rules cleaned."
}

case "$1" in
start) start ;;
stop) stop ;;
restart)
  stop
  start
  ;;
*) echo "Usage: $0 {start|stop|restart}" ;;
esac
