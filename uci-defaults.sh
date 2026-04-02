#!/bin/sh

WAN_USER='Username'
WAN_PASS='Password'
WIFI_KEY='WiFi_PWD'

uci -q batch <<EOF
# ---- WAN: PPPoE ----
set network.wan.proto='pppoe'
set network.wan.username='${WAN_USER}'
set network.wan.password='${WAN_PASS}'

# ---- 5GHz ----
set wireless.@wifi-device[1].disabled='0'
set wireless.@wifi-iface[1].disabled='0'
set wireless.@wifi-iface[1].mode='ap'
set wireless.@wifi-iface[1].network='lan'
set wireless.@wifi-iface[1].encryption='psk2'
set wireless.@wifi-iface[1].key='${WIFI_KEY}'
EOF

exit 0
