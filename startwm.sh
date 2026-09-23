#!/bin/sh
set -eu

export LANG=zh_CN.UTF-8
export LANGUAGE=zh_CN:zh
export LC_ALL=zh_CN.UTF-8

DATA_DIR=/home/taoli/data
SESSION_LOCK="$DATA_DIR/.chromium-session.lock"
SESSION_OWNER="$DATA_DIR/.chromium-session.owner"
SINGLETON_LOCK="$DATA_DIR/SingletonLock"

fail() {
  printf 'Chromium 会话启动失败：%s\n' "$*" >&2
  exit 1
}

# Keep this inode: unlinking the guard could let two containers lock different
# files. FD 9 is inherited by Chromium; the waiting shell also retains it in
# case a future Chromium version closes inherited descriptors.
if [ "${1:-}" != --locked ]; then
  [ ! -L "$SESSION_LOCK" ] || fail '会话保护锁不能是符号链接。'
  [ ! -e "$SESSION_LOCK" ] || [ -f "$SESSION_LOCK" ] ||
    fail '会话保护锁不是普通文件。'
  exec 9>>"$SESSION_LOCK"
  flock -n 9 || fail '浏览器数据卷正由另一个会话或容器使用，请先退出已有会话。'

  sh "$0" --locked &
  browser_pid=$!
  # Forward session shutdown; never restart Chromium. Waiting again handles
  # wait being interrupted by the signal rather than by the browser's exit.
  trap 'kill -TERM "$browser_pid" 2>/dev/null || true' TERM INT HUP
  status=0
  wait "$browser_pid" || status=$?
  while kill -0 "$browser_pid" 2>/dev/null; do
    wait "$browser_pid" || status=$?
  done
  exit "$status"
fi

# The private entry point must inherit the already locked descriptor.
flock -n 9 || fail '缺少已持有的数据卷保护锁。'
namespace="$(cat /proc/sys/kernel/random/boot_id) $(readlink /proc/self/ns/pid)"

if [ -e "$SINGLETON_LOCK" ] || [ -L "$SINGLETON_LOCK" ]; then
  [ -L "$SINGLETON_LOCK" ] || fail 'SingletonLock 格式异常，保留原文件，请先核对数据卷占用。'
  owner=$(readlink "$SINGLETON_LOCK")
  owner_pid=${owner##*-}
  case "$owner_pid" in
    ''|*[!0-9]*) fail 'SingletonLock 的进程标识异常，保留原锁。' ;;
  esac
  [ "$owner_pid" -gt 0 ] 2>/dev/null || fail 'SingletonLock 的进程标识异常，保留原锁。'

  # A hostname and PID alone cannot distinguish containers, even when their
  # hostnames match. Only locks created under this volume guard are recoverable.
  if [ -L "$SESSION_OWNER" ] || [ ! -f "$SESSION_OWNER" ] ||
    [ "$(sed -n '1p' "$SESSION_OWNER")" != taoli-startwm-v1 ] ||
    [ "$(sed -n '2p' "$SESSION_OWNER")" != "$owner" ]; then
    fail '检测到未受保护的 Chromium 旧锁；无法确认其他容器是否仍在使用数据卷。请停止所有使用此卷的实例并确认浏览器已退出，再由管理员移除 SingletonLock 后重试。'
  fi
  owner_namespace=$(sed -n '3p' "$SESSION_OWNER")
  [ -n "$owner_namespace" ] || fail '会话记录不完整，保留 SingletonLock，请核对数据卷占用。'
  if [ "$owner_namespace" = "$namespace" ] && [ -d "/proc/$owner_pid" ]; then
    fail 'SingletonLock 对应的进程仍然存在，保留原锁，请先退出已有浏览器。'
  fi

  # The exclusive volume guard is free and the matching managed session is
  # gone. Its old PID may belong to another process in a recreated container.
  rm -- "$SINGLETON_LOCK"
  printf '已清理退出会话遗留的 Chromium SingletonLock。\n' >&2
fi

# Record the exact hostname/PID Chromium will put in SingletonLock. Atomic
# replacement prevents a crash from leaving a partially written owner record.
owner_tmp=$(mktemp "$DATA_DIR/.chromium-owner.XXXXXX")
trap 'rm -f -- "$owner_tmp"' EXIT
printf '%s\n' taoli-startwm-v1 "$(hostname)-$$" "$namespace" > "$owner_tmp"
mv -f -- "$owner_tmp" "$SESSION_OWNER"
trap - EXIT

# Openbox must not keep the volume locked after Chromium exits.
openbox-session 9>&- &
exec chromium --disable-dev-shm-usage --disable-gpu --use-gl=disabled --no-default-browser-check --no-first-run --lang=zh-CN --user-data-dir=/home/taoli/data https://taoli.tools
