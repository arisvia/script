#!/bin/sh

WAN_USER='Username'
WAN_PASS='Password'
WIFI_KEY='WiFi_PWD'

echo "[init] configure PPPoE..."
uci batch <<EOF
set network.wan.proto='pppoe'
set network.wan.username='${WAN_USER}'
set network.wan.password='${WAN_PASS}'
commit network
EOF

echo "[init] configure 5GHz WiFi (Country Code CN)..."
uci batch <<EOF
set wireless.radio1.disabled='0'
set wireless.radio1.country='CN'
set wireless.default_radio1.encryption='psk2'
set wireless.default_radio1.key='${WIFI_KEY}'
commit wireless
EOF

echo "[init] restart network & wifi..."
/etc/init.d/network restart
wifi reload || wifi

echo "[init] done."
exit 0
