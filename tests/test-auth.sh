#!/bin/sh
# Validate the real XRDP authentication/session path without joining a network.
set -eu

image=${1:-taoli-tools-container-rdp:test}
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_container="taoli-auth-test-$(date +%s)-$$"
trap 'docker rm -f "$test_container" >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker run --rm -i --name "$test_container" --network none \
  --security-opt "seccomp=$project_root/chromium.json" "$image" sh -eu <<'CONTAINER'
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p /run/xrdp
xrdp-sesman -n >/tmp/sesman-test.log 2>&1 &
sesman_pid=$!
attempt=0
until [ -S /run/xrdp/sesman.socket ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 100 ] || fail 'session manager did not become ready'
  sleep 0.1
done

# This ordinary account has a usable shell, so denial must come from access policy.
adduser -D -s /bin/sh regression-denied
for account in root regression-denied; do
  if timeout 10 xrdp-sesrun -t Xorg -p test-placeholder "$account" >/tmp/login-test.log 2>&1; then
    fail "$account was allowed to log in"
  fi
  grep -q 'Login failed' /tmp/login-test.log || fail "$account did not receive an authentication rejection"
done
echo 'PASS: root and other local accounts are rejected'

# A client-supplied app must be ignored; the normal browser session should start.
cat > /tmp/alternate-app.sh <<'APP'
#!/bin/sh
touch /tmp/alternate-app-started
sleep 30
APP
chmod +x /tmp/alternate-app.sh
cp /tmp/alternate-app.sh /home/taoli/startwm.sh
chown taoli:taoli /home/taoli/startwm.sh
if ! timeout 15 su -s /bin/sh xrdp -c 'exec xrdp-sesrun -t Xorg -p "" -S /tmp/alternate-app.sh taoli' >/tmp/login-test.log 2>&1; then
  fail 'taoli passwordless login failed'
fi
grep -q '^ok display=' /tmp/login-test.log || fail 'taoli did not receive a desktop session'
first_display=$(sed -n 's/^ok display=\([0-9]*\).*/\1/p' /tmp/login-test.log)

attempt=0
while :; do
  test ! -e /tmp/alternate-app-started || fail 'client-supplied app was executed'
  processes=$(ps -o user,comm)
  if printf '%s\n' "$processes" | grep -Eq '^taoli[[:space:]]+chromium$' &&
     printf '%s\n' "$processes" | grep -Eq '^taoli[[:space:]]+openbox$'; then
    break
  fi
  attempt=$((attempt + 1))
  [ "$attempt" -lt 100 ] || fail 'the normal taoli browser session did not start'
  sleep 0.1
done
echo 'PASS: taoli blank-password login starts the browser and ignores client/user startup overrides'

# A reconnect must reuse the one session, even if the client changes colour depth.
# Use the same UID/GID as the network-facing daemon to verify socket access.
timeout 15 su -s /bin/sh xrdp -c 'exec xrdp-sesrun -t Xorg -b 16 -p "" taoli' >/tmp/reconnect-test.log 2>&1 ||
  fail 'reconnecting to the existing session failed'
reconnect_display=$(sed -n 's/^ok display=\([0-9]*\).*/\1/p' /tmp/reconnect-test.log)
[ "$reconnect_display" = "$first_display" ] || fail 'reconnection created a different desktop'
echo 'PASS: a reconnect reuses the existing desktop at MaxSessions=1'

# Force a non-matching request only in this disposable container. The production
# Default policy matches every Xorg request by this single permitted user.
sed -i 's/^Policy=Default$/Policy=Separate/' /etc/xrdp/sesman.ini
kill -HUP "$sesman_pid"
attempt=0
until grep -q 'configuration reloaded' /var/log/xrdp-sesman.log; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 100 ] || fail 'sesman configuration did not reload'
  sleep 0.1
done
if timeout 15 xrdp-sesrun -t Xorg -p '' taoli >/tmp/session-limit-test.log 2>&1; then
  fail 'a second desktop bypassed MaxSessions=1'
fi
grep -q 'Max session limit reached' /tmp/session-limit-test.log || fail 'second desktop failed for an unexpected reason'
echo 'PASS: a distinct second desktop is refused by the session limit'

# Chromium owns the desktop lifetime; a crash must terminate it, not restart it.
attempt=0
until [ -L /home/taoli/data/SingletonLock ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 100 ] || fail 'Chromium did not acquire its profile lock'
  sleep 0.1
done
browser_owner=$(readlink /home/taoli/data/SingletonLock)
browser_pid=${browser_owner##*-}
kill -KILL "$browser_pid"
attempt=0
while pidof Xorg >/dev/null || pidof xrdp-sesexec >/dev/null; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 200 ] || fail 'desktop survived Chromium exiting'
  sleep 0.1
done
echo 'PASS: Chromium crashing ends its desktop session'

timeout 15 su -s /bin/sh xrdp -c 'exec xrdp-sesrun -t Xorg -p "" taoli' >/tmp/relogin-test.log 2>&1 ||
  fail 'a new desktop could not start after the browser crash'
attempt=0
until [ -L /home/taoli/data/SingletonLock ] &&
      [ "$(readlink /home/taoli/data/SingletonLock)" != "$browser_owner" ]; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 100 ] || fail 'the new desktop did not recover the stale Chromium lock'
  sleep 0.1
done
echo 'PASS: the next login starts a fresh browser after a crash'
CONTAINER
