#!/bin/sh
# Isolated Docker regression checks: no display, tailnet, ports, or credentials.
set -eu

IMAGE=${1:-taoli-tools-container-rdp:test}
DOCKER_BIN=${DOCKER_BIN:-docker}
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_PREFIX="taoli-browser-test-$(date +%s)-$$"
DATA_VOLUME="$TEST_PREFIX-data"
CONTAINERS=""
VOLUME_CREATED=false

cleanup() {
  for test_container in $CONTAINERS; do
    "$DOCKER_BIN" rm -f "$test_container" >/dev/null 2>&1 || true
  done
  if [ "$VOLUME_CREATED" = true ]; then
    "$DOCKER_BIN" volume rm "$DATA_VOLUME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { echo "FAIL: $*" >&2; exit 1; }

"$DOCKER_BIN" image inspect "$IMAGE" >/dev/null
"$DOCKER_BIN" volume create "$DATA_VOLUME" >/dev/null
VOLUME_CREATED=true
"$DOCKER_BIN" run --rm --network none --entrypoint sh \
  --mount "type=volume,source=$DATA_VOLUME,target=/home/taoli/data" \
  "$IMAGE" -c 'chown taoli:taoli /home/taoli/data'

start_fixture() {
  FIXTURE="$TEST_PREFIX-$1"
  CONTAINERS="$CONTAINERS $FIXTURE"
  "$DOCKER_BIN" run --detach --name "$FIXTURE" --hostname "$1" \
    --network none --user taoli --entrypoint sh \
    --mount "type=volume,source=$DATA_VOLUME,target=/home/taoli/data" \
    --mount "type=bind,source=$PROJECT_DIR/startwm.sh,target=/test/startwm.sh,readonly" \
    "$IMAGE" -c '
      set -eu
      mkdir /tmp/browser-test-bin
      cat > /tmp/browser-test-bin/openbox-session <<"STUB"
#!/bin/sh
touch /tmp/openbox-started
exec sleep 300
STUB
      cat > /tmp/browser-test-bin/chromium <<"STUB"
#!/bin/sh
set -eu
printf "%s\n" "$@" > /tmp/browser-arguments
printf "%s\n" "$LANG" "$LANGUAGE" "$LC_ALL" > /tmp/browser-locale
# The waiting parent must retain the lock even if Chromium closes its copy.
if [ -f /tmp/close-browser-fd ]; then exec 9>&-; fi
# Pause before creating SingletonLock to cover the startup race explicitly.
while [ -f /tmp/delay-browser ]; do sleep 0.05; done
[ ! -L /home/taoli/data/SingletonLock ] || exit 90
ln -s "$(hostname)-$$" /home/taoli/data/SingletonLock
touch /tmp/browser-ready
trap "exit 0" TERM INT
while [ ! -f /tmp/exit-browser ]; do sleep 0.05; done
exit "$(cat /tmp/exit-browser)"
STUB
      chmod +x /tmp/browser-test-bin/*
      touch /tmp/fixture-ready
      exec sleep 300
    ' >/dev/null
  wait_file "$FIXTURE" /tmp/fixture-ready
}

wait_file() {
  attempt=0
  until "$DOCKER_BIN" exec "$1" test -e "$2"; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 100 ] || fail "timed out waiting for $2 in $1"
    sleep 0.1
  done
}

start_session() {
  "$DOCKER_BIN" exec --detach "$1" sh -c '
    export PATH=/tmp/browser-test-bin:$PATH
    sh /test/startwm.sh >/tmp/session.log 2>&1
    printf "%s\n" "$?" > /tmp/session-status
  '
}

expect_refusal() {
  if "$DOCKER_BIN" exec "$1" sh -c '
    export PATH=/tmp/browser-test-bin:$PATH
    exec sh /test/startwm.sh
  ' >/dev/null 2>&1; then
    fail "$2"
  fi
}

start_fixture first-container
FIRST=$FIXTURE
start_fixture second-container
SECOND=$FIXTURE

# Unknown legacy and malformed locks must survive without even starting Openbox.
for target in legacy-container-777 malformed; do
  "$DOCKER_BIN" exec "$FIRST" ln -s "$target" /home/taoli/data/SingletonLock
  expect_refusal "$FIRST" "unknown SingletonLock was accepted"
  [ "$("$DOCKER_BIN" exec "$FIRST" readlink /home/taoli/data/SingletonLock)" = "$target" ] ||
    fail 'unknown SingletonLock was modified'
  "$DOCKER_BIN" exec "$FIRST" test ! -e /tmp/openbox-started || fail 'refusal started Openbox'
  "$DOCKER_BIN" exec "$FIRST" rm /home/taoli/data/SingletonLock
done
echo 'PASS: unknown and malformed locks are preserved'

"$DOCKER_BIN" exec "$FIRST" touch /tmp/delay-browser /tmp/close-browser-fd
start_session "$FIRST"
wait_file "$FIRST" /tmp/browser-arguments
expect_refusal "$FIRST" 'concurrent local session was accepted before Chromium created its lock'
expect_refusal "$SECOND" 'concurrent container was accepted before Chromium created its lock'
"$DOCKER_BIN" exec "$FIRST" rm /tmp/delay-browser
wait_file "$FIRST" /tmp/browser-ready
first_owner=$("$DOCKER_BIN" exec "$FIRST" readlink /home/taoli/data/SingletonLock)
expect_refusal "$FIRST" 'concurrent local session was accepted'
expect_refusal "$SECOND" 'concurrent container was accepted'
[ "$("$DOCKER_BIN" exec "$FIRST" readlink /home/taoli/data/SingletonLock)" = "$first_owner" ] ||
  fail 'concurrent attempt changed the live lock'
"$DOCKER_BIN" exec "$FIRST" sh -c '
  set -eu
  printf "%s\n" --disable-dev-shm-usage --disable-gpu --use-gl=disabled --disable-web-security \
    --no-default-browser-check --no-first-run --lang=zh-CN \
    --user-data-dir=/home/taoli/data https://taoli.tools > /tmp/expected-arguments
  cmp /tmp/expected-arguments /tmp/browser-arguments
  printf "%s\n" zh_CN.UTF-8 zh_CN:zh zh_CN.UTF-8 > /tmp/expected-locale
  cmp /tmp/expected-locale /tmp/browser-locale
' || fail 'Chromium arguments or Chinese locale changed'
echo 'PASS: local and cross-container concurrent starts are rejected throughout startup'

"$DOCKER_BIN" exec "$FIRST" sh -c 'echo 17 > /tmp/exit-browser'
wait_file "$FIRST" /tmp/session-status
[ "$("$DOCKER_BIN" exec "$FIRST" cat /tmp/session-status)" = 17 ] || fail 'Chromium exit status was not propagated'
"$DOCKER_BIN" exec "$FIRST" sh -c '
  pidof sleep >/dev/null && flock -n /home/taoli/data/.chromium-session.lock true
' || fail 'Openbox retained the volume lock after Chromium exited'
echo 'PASS: Chromium exit ends the session and releases the guard while Openbox is alive'

# A managed stale lock is recoverable even after changing hostname/PID namespace.
"$DOCKER_BIN" rm -f "$FIRST" >/dev/null
start_session "$SECOND"
wait_file "$SECOND" /tmp/browser-ready
second_owner=$("$DOCKER_BIN" exec "$SECOND" readlink /home/taoli/data/SingletonLock)
[ "$second_owner" != "$first_owner" ] || fail 'container recreation did not replace the stale lock'
"$DOCKER_BIN" exec "$SECOND" sh -c 'echo 0 > /tmp/exit-browser'
wait_file "$SECOND" /tmp/session-status
[ "$("$DOCKER_BIN" exec "$SECOND" cat /tmp/session-status)" = 0 ] || fail 'clean Chromium exit did not end the session'
echo 'PASS: managed stale locks recover after container recreation'

# Same namespace + live PID is never deleted, even with a matching owner record.
"$DOCKER_BIN" exec "$SECOND" sh -c '
  set -eu
  rm /home/taoli/data/SingletonLock
  owner="$(hostname)-1"
  ln -s "$owner" /home/taoli/data/SingletonLock
  printf "%s\n" taoli-startwm-v1 "$owner" \
    "$(cat /proc/sys/kernel/random/boot_id) $(readlink /proc/self/ns/pid)" \
    > /home/taoli/data/.chromium-session.owner
'
expect_refusal "$SECOND" 'live same-namespace PID was accepted'
[ "$("$DOCKER_BIN" exec "$SECOND" readlink /home/taoli/data/SingletonLock)" = second-container-1 ] ||
  fail 'live same-namespace lock was modified'
"$DOCKER_BIN" exec "$SECOND" rm /home/taoli/data/SingletonLock
echo 'PASS: a live process prevents managed lock cleanup'

# Shutdown is forwarded to Chromium, and the desktop session exits without a
# restart. Afterwards, kill a live container to leave a genuinely stale lock.
"$DOCKER_BIN" exec "$SECOND" rm /tmp/browser-ready /tmp/session-status /tmp/exit-browser
start_session "$SECOND"
wait_file "$SECOND" /tmp/browser-ready
"$DOCKER_BIN" exec "$SECOND" sh -c '
  set -eu
  owner=$(readlink /home/taoli/data/SingletonLock)
  browser_pid=${owner##*-}
  session_pid=$(awk '\''/^PPid:/ { print $2 }'\'' /proc/$browser_pid/status)
  kill -TERM "$session_pid"
'
wait_file "$SECOND" /tmp/session-status
[ "$("$DOCKER_BIN" exec "$SECOND" cat /tmp/session-status)" = 143 ] ||
  fail 'session shutdown did not forward SIGTERM and terminate'
"$DOCKER_BIN" exec "$SECOND" rm /tmp/browser-ready /tmp/session-status
start_session "$SECOND"
wait_file "$SECOND" /tmp/browser-ready
"$DOCKER_BIN" rm -f "$SECOND" >/dev/null
start_fixture recreated-container
SECOND=$FIXTURE
start_session "$SECOND"
wait_file "$SECOND" /tmp/browser-ready
"$DOCKER_BIN" exec "$SECOND" sh -c 'echo 0 > /tmp/exit-browser'
wait_file "$SECOND" /tmp/session-status
echo 'PASS: SIGTERM ends the session and a killed container leaves a recoverable lock'

# Real Chromium additionally verifies that this image preserves the guard FD.
# Headless/no-sandbox flags are confined to this isolated non-root test container.
"$DOCKER_BIN" exec "$SECOND" sh -c '
  set -eu
  exec 9>/tmp/real-chromium-guard
  flock -n 9
  chromium --headless --no-sandbox --disable-dev-shm-usage \
    --user-data-dir=/tmp/real-chromium-profile about:blank >/tmp/real-chromium.log 2>&1 &
  browser_pid=$!
  exec 9>&-
  trap '\''kill -TERM "$browser_pid" 2>/dev/null || true'\'' EXIT
  attempt=0
  until [ -L /tmp/real-chromium-profile/SingletonLock ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 100 ] || exit 1
    sleep 0.1
  done
  [ "$(readlink /proc/$browser_pid/fd/9)" = /tmp/real-chromium-guard ]
  if flock -n /tmp/real-chromium-guard true; then exit 1; fi
  kill -TERM "$browser_pid"
  wait "$browser_pid"
  trap - EXIT
  attempt=0
  until flock -n /tmp/real-chromium-guard true; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 100 ] || exit 1
    sleep 0.1
  done
' || fail 'real Chromium did not retain and release the inherited guard'
echo 'PASS: real Chromium retains the inherited lock until browser exit'
