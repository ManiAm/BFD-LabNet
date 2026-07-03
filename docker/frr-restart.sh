#!/bin/bash
#
# Graceful FRR restart that avoids the hang in frrinit.sh.
#
# frrinit.sh sends SIGINT and polls each daemon for up to 120 seconds.
# Inside Docker containers daemons sometimes ignore SIGINT, causing the
# script to block indefinitely. This wrapper tries SIGTERM first, then
# falls back to SIGKILL, cleans up PID files, and starts FRR cleanly.

GRACE=5  # seconds to wait after SIGTERM before SIGKILL

echo "Stopping FRR daemons..."
/usr/lib/frr/frrinit.sh stop &
stop_pid=$!

sleep "$GRACE"
if kill -0 "$stop_pid" 2>/dev/null; then
    echo "Graceful stop timed out — force-killing remaining daemons"
    kill "$stop_pid" 2>/dev/null
    killall -9 watchfrr mgmtd zebra staticd ospfd ospf6d bgpd bfdd \
        ripd ripngd isisd babeld pimd pim6d ldpd nhrpd eigrpd \
        sharpd pbrd fabricd vrrpd pathd 2>/dev/null
    sleep 1
fi

rm -f /var/run/frr/*.pid

echo "Starting FRR daemons..."
exec /usr/lib/frr/frrinit.sh start
