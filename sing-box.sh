#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99

# 固定实例名：直接 `sh /etc/init.d/sing-box start` 时 $initscript 为空，
# readlink 推导会得到 NAME="."，导致 config_load 失败。
NAME=sing-box
PROG=/usr/bin/sing-box

CONF=/etc/sing-box/config.json
WORKDIR=/usr/share/sing-box
TPROXY=/etc/sing-box/tproxy.sh
PROXY_PORT=12345   # 与 tproxy.sh 的 PROXY_PORT 保持一致

start_service() {
  config_load "$NAME"

  local enabled user group conffile workdir ifaces tproxy
  local log_stdout log_stderr port_hex i
  config_get_bool enabled "main" "enabled" "0"
  [ "$enabled" -eq "1" ] || return 0

  config_get user "main" "user" "root"
  config_get conffile "main" "conffile" "$CONF"
  config_get ifaces "main" "ifaces"
  config_get workdir "main" "workdir" "$WORKDIR"
  config_get tproxy "main" "tproxy" "$TPROXY"
  config_get_bool log_stdout "main" "log_stdout" "1"
  config_get_bool log_stderr "main" "log_stderr" "1"

  mkdir -p "$workdir"
  group="$(id -ng "$user")"
  chown "$user:$group" "$workdir"

  procd_open_instance "$NAME.main"
  procd_set_param command "$PROG" run -c "$conffile" -D "$workdir"

  # Use root user if you want to use the TUN mode.
  # tproxy 模式同样需要 root（IP_TRANSPARENT socket）。
  procd_set_param user "$user"
  procd_set_param file "$conffile"
  [ -z "$ifaces" ] || procd_set_param netdev "$ifaces"
  procd_set_param stdout "$log_stdout"
  procd_set_param stderr "$log_stderr"
  procd_set_param limits core="unlimited"
  procd_set_param limits nofile="1000000 1000000"
  procd_set_param respawn

  procd_close_instance

  # 等 tproxy 端口就绪再挂规则，否则启动瞬间流量会被转到尚未监听的端口。
  # 读 /proc/net/tcp{,6}（tproxy 监听 :: 为双栈），不依赖 ss/netstat。
  port_hex=$(printf '%04X' "$PROXY_PORT")
  i=0
  while [ "$i" -lt 5 ] && ! grep -q ":${port_hex} " /proc/net/tcp /proc/net/tcp6 2>/dev/null; do
    i=$((i + 1))
    sleep 1
  done

  echo "Loading NFTables rules..."
  sh "$tproxy" start
}

stop_service() {
  # 不检查 enabled：即使服务已禁用，也必须清理已应用的 nft 规则与策略路由，
  # 否则残留规则会把流量转发到已停止的端口，造成断网。
  local tproxy
  config_load "$NAME"
  config_get tproxy "main" "tproxy" "$TPROXY"

  echo "Cleaning up NFTables rules..."
  sh "$tproxy" stop
}

service_triggers() {
  config_load "$NAME"

  local ifaces
  config_get ifaces "main" "ifaces"
  procd_open_trigger
  for iface in $ifaces; do
    procd_add_interface_trigger "interface.*.up" "$iface" /etc/init.d/"$NAME" restart
  done
  procd_close_trigger
  procd_add_reload_trigger "$NAME"
}
