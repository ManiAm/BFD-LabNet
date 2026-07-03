#!/bin/bash
set -e

sysctl -w net.ipv4.ip_forward=1

CONF_DIR="/etc/frr/hosts/$HOSTNAME"

if [ -d "$CONF_DIR" ]; then
    cp "$CONF_DIR/frr.conf" /etc/frr/frr.conf
fi

cp /etc/frr/hosts/daemons /etc/frr/daemons
chown frr:frr /etc/frr/daemons /etc/frr/frr.conf

/usr/lib/frr/frrinit.sh start
exec tail -f /dev/null
