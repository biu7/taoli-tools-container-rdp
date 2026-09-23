#!/bin/sh
# Run against an already built image. No tailnet access or credentials required.
set -eu

IMAGE=${1:-taoli-tools-container-rdp:test}
DOCKER_BIN=${DOCKER_BIN:-docker}
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_PREFIX="taoli-runtime-test-$(date +%s)-$$"
STATE_VOLUME="$TEST_PREFIX-state"
CONTAINERS=""
VOLUME_CREATED=false

cleanup() {
  for test_container in $CONTAINERS; do
    "$DOCKER_BIN" rm -f "$test_container" >/dev/null 2>&1 || true
  done
  if [ "$VOLUME_CREATED" = true ]; then
    "$DOCKER_BIN" volume rm "$STATE_VOLUME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

"$DOCKER_BIN" image inspect "$IMAGE" >/dev/null
"$DOCKER_BIN" volume create "$STATE_VOLUME" >/dev/null
VOLUME_CREATED=true

launch_container() {
  ACTIVE_CONTAINER="$TEST_PREFIX-$1"
  shift
  CONTAINERS="$CONTAINERS $ACTIVE_CONTAINER"
  "$DOCKER_BIN" run --detach --name "$ACTIVE_CONTAINER" \
    --network none \
    --security-opt "seccomp=$PROJECT_DIR/chromium.json" \
    --mount "type=volume,source=$STATE_VOLUME,target=/var/lib/tailscale" \
    "$IMAGE" "$@" >/dev/null
}

wait_until_ready() {
  attempt=0
  while [ "$attempt" -lt 150 ]; do
    running=$("$DOCKER_BIN" inspect --format '{{.State.Running}}' "$ACTIVE_CONTAINER")
    [ "$running" = true ] || fail "container exited before services became ready"
    if "$DOCKER_BIN" exec "$ACTIVE_CONTAINER" sh -c '
      pidof xrdp >/dev/null &&
      pidof xrdp-sesman >/dev/null &&
      pidof tailscaled >/dev/null &&
      test -S /var/run/xrdp/sesman.socket &&
      test -S /home/taoli/tailscale.socket
    ' >/dev/null 2>&1; then
      return
    fi
    attempt=$((attempt + 1))
    sleep 0.2
  done
  fail "services did not become ready within 30 seconds"
}

start_container() {
  launch_container "$@"
  wait_until_ready
}

stop_cleanly() {
  "$DOCKER_BIN" stop --time 10 "$ACTIVE_CONTAINER" >/dev/null
  exit_code=$("$DOCKER_BIN" inspect --format '{{.State.ExitCode}}' "$ACTIVE_CONTAINER")
  [ "$exit_code" -eq 0 ] || fail "SIGTERM shutdown returned $exit_code instead of 0"
  "$DOCKER_BIN" rm "$ACTIVE_CONTAINER" >/dev/null
}

wait_for_failure() {
  attempt=0
  while [ "$attempt" -lt 100 ]; do
    running=$("$DOCKER_BIN" inspect --format '{{.State.Running}}' "$ACTIVE_CONTAINER")
    if [ "$running" = false ]; then
      exit_code=$("$DOCKER_BIN" inspect --format '{{.State.ExitCode}}' "$ACTIVE_CONTAINER")
      [ "$exit_code" -ne 0 ] || fail "$1: daemon termination was reported as success"
      if [ -n "${2:-}" ]; then
        [ "$exit_code" -eq "$2" ] || fail "$1: expected exit $2, got $exit_code"
      fi
      "$DOCKER_BIN" rm "$ACTIVE_CONTAINER" >/dev/null
      return
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
  fail "$1: PID 1 stayed alive after daemon termination"
}

# A killed daemon can leave its Unix socket behind in the same container.
# Delay the replacement daemon, so mistaking the stale inode for readiness
# deterministically makes the one-shot authentication command fail.
launch_container stale-socket sh -eu -c '
  su - taoli -c "exec /usr/sbin/tailscaled --tun=userspace-networking --socket=/home/taoli/tailscale.socket --state=/tmp/stale-socket.state" >/tmp/stale-daemon.log 2>&1 &
  stale_pid=$!
  attempt=0
  until [ -S /home/taoli/tailscale.socket ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 100 ] || exit 1
    sleep 0.1
  done
  kill -KILL "$stale_pid"
  wait "$stale_pid" 2>/dev/null || true
  test -S /home/taoli/tailscale.socket

  cat > /usr/local/bin/tailscaled <<"DAEMON"
#!/bin/sh
sleep 4
touch /tmp/runtime-new-daemon-starting
exec /usr/sbin/tailscaled "$@"
DAEMON
  cat > /usr/local/bin/tailscale <<"CLI"
#!/bin/sh
# Reject calls made against the old socket before the replacement even starts.
test -f /tmp/runtime-new-daemon-starting || exit 17
# A local API read proves the new socket is serving requests; no tailnet login.
/usr/bin/tailscale --socket=/home/taoli/tailscale.socket debug prefs >/dev/null 2>&1 || exit 17
touch /tmp/runtime-live-socket
CLI
  chmod +x /usr/local/bin/tailscaled /usr/local/bin/tailscale
  touch /tmp/runtime-stale-socket-prepared
  exec /usr/local/bin/entrypoint.sh
'
attempt=0
until "$DOCKER_BIN" exec "$ACTIVE_CONTAINER" test -f /tmp/runtime-live-socket >/dev/null 2>&1; do
  [ "$("$DOCKER_BIN" inspect --format '{{.State.Running}}' "$ACTIVE_CONTAINER")" = true ] ||
    fail 'stale Tailscale socket caused authentication before the new daemon was ready'
  attempt=$((attempt + 1))
  [ "$attempt" -lt 150 ] || fail 'replacement Tailscale daemon did not serve the authentication command'
  sleep 0.1
done
wait_until_ready
stop_cleanly
echo 'PASS: stale Tailscale socket is cleared before waiting for the replacement daemon'

start_container persistence-first
"$DOCKER_BIN" exec "$ACTIVE_CONTAINER" sh -c '
  expected="$(id -u taoli):$(id -g taoli):700"
  test "$(stat -c %u:%g:%a /var/lib/tailscale)" = "$expected"
' || fail "Tailscale state directory must be owned by taoli and have mode 700"

# The marker is deliberately public test data; never read or print private keys.
"$DOCKER_BIN" exec --user taoli "$ACTIVE_CONTAINER" sh -c '
  printf "%s\n" runtime-persistence-test > /var/lib/tailscale/runtime-test-marker
' || fail "taoli cannot write to the persistent state volume"

attempt=0
while ! "$DOCKER_BIN" exec "$ACTIVE_CONTAINER" test -s /var/lib/tailscale/tailscaled.state; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 100 ] || fail "tailscaled did not write state to the mounted volume"
  sleep 0.1
done

state_before=$("$DOCKER_BIN" exec "$ACTIVE_CONTAINER" sha256sum /var/lib/tailscale/tailscaled.state)
stop_cleanly

start_container persistence-second
"$DOCKER_BIN" exec --user taoli "$ACTIVE_CONTAINER" sh -c '
  test "$(cat /var/lib/tailscale/runtime-test-marker)" = runtime-persistence-test &&
  test -s /var/lib/tailscale/tailscaled.state &&
  test ! -e /home/taoli/.local/share/tailscale/tailscaled.state
' || fail "Tailscale state was lost or placed outside its volume after recreation"
state_after=$("$DOCKER_BIN" exec "$ACTIVE_CONTAINER" sha256sum /var/lib/tailscale/tailscaled.state)
[ "$state_before" = "$state_after" ] || fail "unauthenticated Tailscale state changed after recreation"
stop_cleanly
echo 'PASS: Tailscale state survives container recreation and SIGTERM exits cleanly'

for daemon in xrdp xrdp-sesman tailscaled; do
  start_container "failure-$daemon"
  "$DOCKER_BIN" exec "$ACTIVE_CONTAINER" sh -c '
    daemon_pid=$(pidof "$1")
    test -n "$daemon_pid" && kill -TERM "$daemon_pid"
  ' sh "$daemon" || fail "could not terminate $daemon for the regression test"
  wait_for_failure "$daemon"
  echo "PASS: $daemon termination makes the container exit with an error"
done

# Exercise both outcomes of the one-shot authentication command without joining
# a tailnet. The real tailscaled still runs with isolated networking.
start_container up-success sh -c '
  printf "#!/bin/sh\ntouch /tmp/runtime-up-done\nexit 0\n" > /usr/local/bin/tailscale
  chmod +x /usr/local/bin/tailscale
  exec /usr/local/bin/entrypoint.sh
'
attempt=0
until "$DOCKER_BIN" exec "$ACTIVE_CONTAINER" test -f /tmp/runtime-up-done; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 100 ] || fail "successful tailscale up stub was never called"
  sleep 0.1
done
sleep 2
[ "$("$DOCKER_BIN" inspect --format '{{.State.Running}}' "$ACTIVE_CONTAINER")" = true ] ||
  fail "successful tailscale up incorrectly stopped the container"
"$DOCKER_BIN" exec "$ACTIVE_CONTAINER" sh -c 'kill -TERM "$(pidof xrdp)"'
wait_for_failure 'daemon monitoring after successful tailscale up'
echo 'PASS: successful tailscale up leaves daemon supervision active'

launch_container up-failure sh -c '
  printf "#!/bin/sh\nexit 17\n" > /usr/local/bin/tailscale
  chmod +x /usr/local/bin/tailscale
  exec /usr/local/bin/entrypoint.sh
'
wait_for_failure 'failed tailscale up' 17
echo 'PASS: failed tailscale up propagates its exit status'

launch_container early-failure sh -c '
  printf "#!/bin/sh\nexit 19\n" > /usr/sbin/xrdp
  chmod +x /usr/sbin/xrdp
  exec /usr/local/bin/entrypoint.sh
'
wait_for_failure 'daemon failure during startup' 19
echo 'PASS: daemon failure during startup stops the container'
