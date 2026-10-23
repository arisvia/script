#!/bin/sh

# ---------------------------------------------------------
# Sing-Box / mihomo OpenWrt TProxy NFTables Setup Script
#
# 数据流：
#   LAN 转发流量    → prerouting → tproxy → 本地 socket
#   路由器本机流量  → output 打 mark → 策略路由回 lo → prerouting → tproxy
#
# 关键点：
#   1. prerouting 里 **绝不能** 对 $PROXY_FWMARK 做 return。
#      本机流量正是靠 output 打上该 mark 后重入 prerouting 才被 tproxy 接走；
#      若在此 return，包会绕过 tproxy 直奔本地 1.1.1.1:53 这类不存在的 socket，
#      dnsmasq 上游查询全部失败 → LAN 客户端解析不了任何域名 → 表现为全网断。
#   2. divert 链只处理 TCP：socket transparent 命中后重新打 mark 并 accept，
#      跳过 tproxy。UDP 无连接状态、只有通配 socket，该匹配恒不命中，
#      因此 divert 不覆盖 UDP。
#   3. 代理进程自身的出站流量由 $ROUTING_MARK 放行（sing-box default_mark /
#      mihomo routing-mark），必须与 $PROXY_FWMARK 取不同值。
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
  # DIVERT：已被 tproxy 接管的 TCP 连接重新打标后放行，跳过下面的 tproxy。
  # 等价于 iptables 的 `-m socket --transparent -j DIVERT`，需 kmod-nft-socket。
  #
  # 只对 TCP 有效：tproxy accept 会为每条连接创建一个绑定到原始目标地址的
  # 透明 socket，后续包能按四元组查到。UDP 没有连接状态，sing-box/mihomo
  # 只开一个 0.0.0.0:12345 的通配 socket，靠 IP_RECVORIGDSTADDR 取原目标，
  # 四元组查不到任何 socket，socket transparent 恒不命中，每个包都必须
  # 落到下面的 tproxy 处理。
  # -----------------------
  chain divert {
    meta l4proto tcp socket transparent 1 meta mark set $PROXY_FWMARK accept
  }

  # -----------------------
  # PREROUTING：拦截 LAN 转发流量 / 本机 output 回灌流量
  # -----------------------
  chain prerouting {
    type filter hook prerouting priority mangle; policy accept;

    meta l4proto != { tcp, udp } return

    jump divert

    # 目标是路由器本机地址 / 组播 / 广播，不走代理
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
