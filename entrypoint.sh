#!/bin/sh
set -eu

SESMAN_PID=""
XRDP_PID=""
TAILSCALED_PID=""
TAILSCALE_PID=""

cleanup() {
  trap - EXIT INT TERM
  echo "Stopping services..."
  for pid in "$TAILSCALE_PID" "$TAILSCALED_PID" "$XRDP_PID" "$SESMAN_PID"; do
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
    fi
  done

  # 给服务留出保存状态的时间，同时保证容器能及时停止。
  remaining=5
  while [ "$remaining" -gt 0 ]; do
    running=false
    for pid in "$TAILSCALE_PID" "$TAILSCALED_PID" "$XRDP_PID" "$SESMAN_PID"; do
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        running=true
      fi
    done
    [ "$running" = true ] || break
    sleep 1
    remaining=$((remaining - 1))
  done

  for pid in "$TAILSCALE_PID" "$TAILSCALED_PID" "$XRDP_PID" "$SESMAN_PID"; do
    if [ -n "$pid" ]; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
  wait || true
}
trap cleanup EXIT
trap 'exit 0' TERM
trap 'exit 130' INT

check_service() {
  if ! kill -0 "$2" 2>/dev/null; then
    service_status=0
    wait "$2" || service_status=$?
    echo "$1 exited unexpectedly (status $service_status)." >&2
    # 守护进程即使正常返回，也意味着服务已不可用。
    [ "$service_status" -ne 0 ] || service_status=1
    exit "$service_status"
  fi
}

check_services() {
  check_service xrdp-sesman "$SESMAN_PID"
  check_service xrdp "$XRDP_PID"
  check_service tailscaled "$TAILSCALED_PID"
}

# Chromium is spawned by sesman, so set the inherited limit before starting it.
# Adapted from upstream 94b35bc for the RDP session process tree.
CHROMIUM_NOFILE_LIMIT=${CHROMIUM_NOFILE_LIMIT:-65535}
case "$CHROMIUM_NOFILE_LIMIT" in
  *[!0-9]*|'')
    echo "CHROMIUM_NOFILE_LIMIT must be a positive integer." >&2
    exit 1
    ;;
esac
if ! [ "$CHROMIUM_NOFILE_LIMIT" -gt 0 ] 2>/dev/null; then
  echo "CHROMIUM_NOFILE_LIMIT must be a positive integer." >&2
  exit 1
fi
nofile_hard_limit=$(ulimit -Hn)
if [ "$nofile_hard_limit" != unlimited ] && [ "$CHROMIUM_NOFILE_LIMIT" -gt "$nofile_hard_limit" ]; then
  CHROMIUM_NOFILE_LIMIT=$nofile_hard_limit
fi
ulimit -Sn "$CHROMIUM_NOFILE_LIMIT"
echo "Chromium session nofile soft limit: $(ulimit -Sn)"

mkdir -p /var/run/xrdp /var/log /var/lib/tailscale
chown -R taoli:taoli /var/lib/tailscale
chmod 700 /var/lib/tailscale

/usr/local/bin/init-xrdp.sh

# 前台模式使每个守护进程都成为可监督的直接子进程。
echo "Starting XRDP Session Manager..."
/usr/sbin/xrdp-sesman -n &
SESMAN_PID=$!

echo "Starting XRDP..."
/usr/sbin/xrdp -n &
XRDP_PID=$!

echo "Starting Tailscale daemon..."
# 同一容器异常退出后可能留下旧 socket；它不属于任何持久化卷。
rm -f /home/taoli/tailscale.socket
su - taoli -c "exec tailscaled --tun=userspace-networking --socket=/home/taoli/tailscale.socket --statedir=/var/lib/tailscale --state=/var/lib/tailscale/tailscaled.state" &
TAILSCALED_PID=$!

# 等待本地 socket，而不是假定固定延迟后服务一定就绪。
attempt=0
until [ -S /home/taoli/tailscale.socket ]; do
  check_services
  if [ "$attempt" -ge 30 ]; then
    echo "Timed out waiting for the Tailscale socket." >&2
    exit 1
  fi
  sleep 1
  attempt=$((attempt + 1))
done
check_services

echo "Starting Tailscale authentication (if needed)..."
su - taoli -c "exec tailscale --socket=/home/taoli/tailscale.socket up --hostname=taoli-tools-container --qr" &
TAILSCALE_PID=$!

echo "========================================"
echo "Services started. Tailscale authentication may still be pending."
echo "Scan the QR code in these logs to join your Tailscale network."
echo "Then connect to the Tailscale IP (100.x.x.x:3389)."
echo "Username: taoli; password: no password required."
echo "Check Tailscale IP at: https://login.tailscale.com/admin/machines"
echo "========================================"

while :; do
  check_services
  # up 是一次性命令，成功结束后不能被当成守护进程故障。
  if [ -n "$TAILSCALE_PID" ] && ! kill -0 "$TAILSCALE_PID" 2>/dev/null; then
    up_status=0
    wait "$TAILSCALE_PID" || up_status=$?
    TAILSCALE_PID=""
    if [ "$up_status" -ne 0 ]; then
      echo "Tailscale authentication command failed (status $up_status)." >&2
      exit "$up_status"
    fi
    echo "Tailscale authentication completed."
  fi
  sleep 1
done
