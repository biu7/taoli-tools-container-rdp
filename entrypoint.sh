#!/bin/sh
set -eu

TAILSCALED_PID=""
TAILSCALE_PID=""

cleanup() {
  echo "Cleaning up..."
  for pid in "$TAILSCALED_PID" "$TAILSCALE_PID"; do
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  # 停止 XRDP 服务
  killall xrdp 2>/dev/null || true
  killall xrdp-sesman 2>/dev/null || true
}
trap cleanup INT TERM

# 创建必要的目录
mkdir -p /var/run/xrdp
mkdir -p /var/log

# 启动 XRDP Session Manager
echo "Starting XRDP Session Manager..."
/usr/sbin/xrdp-sesman

sleep 2

# 启动 XRDP
echo "Starting XRDP..."
/usr/sbin/xrdp -n &

sleep 2

# 启动 Tailscale 守护进程
echo "Starting Tailscale daemon..."
su - taoli -c "tailscaled --tun=userspace-networking --socket=/home/taoli/tailscale.socket" &
TAILSCALED_PID=$!

sleep 5

# 启动 Tailscale 并显示 QR 码
echo "Starting Tailscale and showing QR code..."
su - taoli -c "tailscale --socket=/home/taoli/tailscale.socket up --hostname=taoli-tools-container --qr" &
TAILSCALE_PID=$!

echo "========================================"
echo "XRDP is ready!"
echo "========================================"
echo ""
echo "Scan the QR code above to add this container to your Tailscale network."
echo "Then connect using RDP client to the Tailscale IP (100.x.x.x:3389)"
echo ""
echo "Username: taoli"
echo "Password: (no password required - auto login enabled)"
echo ""
echo "Check Tailscale IP at: https://login.tailscale.com/admin/machines"
echo "========================================"

# 保持容器运行
wait
