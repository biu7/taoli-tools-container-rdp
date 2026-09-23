#!/bin/sh
# Validate the real RDP listener/TLS path without network access or host ports.
# Requires Docker and an existing host Python 3 with the standard ssl module.
set -eu

IMAGE=${1:-taoli-tools-container-rdp:test}
DOCKER_BIN=${DOCKER_BIN:-docker}
PYTHON_BIN=${PYTHON_BIN:-python3}
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_PREFIX="taoli-rdp-config-test-$(date +%s)-$$"
CONTAINERS=""
VOLUMES=""

cleanup() {
  for container in $CONTAINERS; do
    "$DOCKER_BIN" rm -f "$container" >/dev/null 2>&1 || true
  done
  for volume in $VOLUMES; do
    "$DOCKER_BIN" volume rm "$volume" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

"$DOCKER_BIN" image inspect "$IMAGE" >/dev/null
"$PYTHON_BIN" -c 'import ssl; assert ssl.HAS_TLSv1_3' ||
  fail 'Python 3 with TLS 1.3 support is required; set PYTHON_BIN to an existing interpreter'

expected_version=$(sed -n 's/^XRDP_VERSION=//p' "$PROJECT_DIR/build-xrdp.sh")
[ -n "$expected_version" ] || fail 'could not read the pinned XRDP version'
CONTAINERS="$CONTAINERS $TEST_PREFIX-image"
"$DOCKER_BIN" run --rm --name "$TEST_PREFIX-image" --network none "$IMAGE" \
  sh -eu -c '
    version=$(xrdp --version 2>&1)
    printf "%s\n" "$version" | grep -Fqx "xrdp $1" || {
      echo "FAIL: image does not contain the pinned XRDP release" >&2
      exit 1
    }
    for identity in /etc/xrdp/key.pem /etc/xrdp/cert.pem /etc/xrdp/rsakeys.ini \
      /var/lib/xrdp/tls/key.pem /var/lib/xrdp/tls/cert.pem /var/lib/xrdp/rsakeys.ini; do
      test ! -e "$identity" || {
        echo "FAIL: XRDP identity exists before initialization: $identity" >&2
        exit 1
      }
    done
    for directory in /etc/xrdp /var/lib/xrdp; do
      if [ -d "$directory" ] && grep -r -E -q -- "BEGIN (RSA |EC |ENCRYPTED )?PRIVATE KEY" "$directory"; then
        echo "FAIL: XRDP private key found before initialization" >&2
        exit 1
      fi
    done
    echo "PASS: pinned XRDP release and no pre-generated XRDP private key in image"
  ' sh "$expected_version"

for suffix in a b; do
  volume="$TEST_PREFIX-$suffix"
  "$DOCKER_BIN" volume create "$volume" >/dev/null
  VOLUMES="$VOLUMES $volume"
done

start_container() {
  ACTIVE_CONTAINER="$TEST_PREFIX-$1"
  CONTAINERS="$CONTAINERS $ACTIVE_CONTAINER"
  "$DOCKER_BIN" run --detach --name "$ACTIVE_CONTAINER" \
    --network none \
    --security-opt "seccomp=$PROJECT_DIR/chromium.json" \
    --mount "type=volume,source=$TEST_PREFIX-$2,target=/var/lib/xrdp" \
    "$IMAGE" >/dev/null
  attempt=0
  until "$DOCKER_BIN" exec "$ACTIVE_CONTAINER" sh -c '
    pidof xrdp >/dev/null && pidof xrdp-sesman >/dev/null &&
    test -S /run/xrdp/sesman.socket &&
    test -s /var/lib/xrdp/tls/cert.pem &&
    test -s /var/lib/xrdp/tls/key.pem &&
    awk '\''$2 == "0100007F:0D3D" && $4 == "0A" { found=1 } END { exit !found }'\'' /proc/net/tcp
  ' >/dev/null 2>&1; do
    [ "$("$DOCKER_BIN" inspect --format '{{.State.Running}}' "$ACTIVE_CONTAINER")" = true ] ||
      fail 'container exited before the RDP listener became ready'
    attempt=$((attempt + 1))
    [ "$attempt" -lt 150 ] || fail 'RDP listener/certificate did not become ready within 30 seconds'
    sleep 0.2
  done
}

stop_container() {
  "$DOCKER_BIN" stop --time 10 "$ACTIVE_CONTAINER" >/dev/null
  [ "$("$DOCKER_BIN" inspect --format '{{.State.ExitCode}}' "$ACTIVE_CONTAINER")" -eq 0 ] ||
    fail 'container did not stop cleanly'
  "$DOCKER_BIN" rm "$ACTIVE_CONTAINER" >/dev/null
}

check_rdp() {
  "$PYTHON_BIN" - "$DOCKER_BIN" "$ACTIVE_CONTAINER" <<'PYTHON'
import configparser
import os
import select
import ssl
import struct
import subprocess
import sys
import time

docker, container = sys.argv[1:]


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def execute(*args):
    return subprocess.check_output([docker, "exec", container, *args], timeout=15)


def read_config(path):
    # sesman.ini deliberately repeats the Xorg 'param' key.
    config = configparser.ConfigParser(interpolation=None, strict=False,
                                       inline_comment_prefixes=(";", "#"))
    config.read_string(execute("cat", path).decode())
    return config


def check_configuration():
    rdp = read_config("/etc/xrdp/xrdp.ini")
    sesman = read_config("/etc/xrdp/sesman.ini")
    require(rdp["Globals"]["security_layer"] == "tls", "RDP must require TLS")
    require(rdp["Globals"]["certificate"] == "/var/lib/xrdp/tls/cert.pem",
            "RDP certificate is not in the persistent volume")
    require(rdp["Globals"]["key_file"] == "/var/lib/xrdp/tls/key.pem",
            "RDP private key is not in the persistent volume")
    non_backends = {"Globals", "Logging", "LoggingPerLogger", "Channels"}
    require(set(rdp.sections()) - non_backends == {"Xorg"}, "Only the Xorg backend may remain")
    require("Xvnc" not in sesman, "sesman still exposes the Xvnc backend")
    require(sesman.getint("Sessions", "MaxSessions") == 1, "MaxSessions must be 1")
    require(not sesman.getboolean("Sessions", "KillDisconnected"),
            "Disconnecting must preserve the session")
    require(sesman.getint("Sessions", "DisconnectedTimeLimit") == 0,
            "DisconnectedTimeLimit must remain 0")

    uid = int(execute("id", "-u", "xrdp"))
    gid = int(execute("id", "-g", "xrdp"))
    require(uid not in (0, int(execute("id", "-u", "taoli"))),
            "xrdp must have a dedicated non-root identity")
    require(gid != 0, "xrdp must not use the root group")
    for name, expected_uid in (("xrdp", uid), ("xrdp-sesman", 0)):
        pids = execute("pidof", name).decode().split()
        require(bool(pids), f"{name} is not running")
        for pid in pids:
            status = execute("cat", f"/proc/{pid}/status").decode().splitlines()
            uids = next(line.split()[1:] for line in status if line.startswith("Uid:"))
            require(all(int(value) == expected_uid for value in uids),
                    f"{name} has incorrect real/effective/saved/filesystem UIDs")
            if name == "xrdp":
                gids = next(line.split()[1:] for line in status if line.startswith("Gid:"))
                groups = next(line.split()[1:] for line in status if line.startswith("Groups:"))
                require(all(int(value) == gid for value in gids) and "0" not in groups,
                        "xrdp retains an incorrect group identity or the root group")

    listeners = []
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        for line in execute("cat", path).decode().splitlines()[1:]:
            fields = line.split()
            address = fields[1]
            if address.endswith(":0D3D") and fields[3] == "0A":
                listeners.append(address)
    require(listeners == ["0100007F:0D3D"],
            f"Expected only 127.0.0.1:3389, found {listeners}")

    for account, readable in (("xrdp", True), ("taoli", False)):
        result = subprocess.run([docker, "exec", "--user", account, container,
                                 "test", "-r", "/var/lib/xrdp/tls/key.pem"], timeout=15)
        require((result.returncode == 0) == readable,
                f"Unexpected TLS private key readability for {account}")
    execute("openssl", "x509", "-in", "/var/lib/xrdp/tls/cert.pem", "-checkend", "0", "-noout")


class RDPTransport:
    """Tunnel bytes through Docker exec, keeping the container network isolated."""

    def __enter__(self):
        self.process = subprocess.Popen(
            [docker, "exec", "-i", container, "nc", "-w", "10", "127.0.0.1", "3389"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            bufsize=0)
        self.deadline = time.monotonic() + 15
        return self

    def __exit__(self, *_):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=2)
        self.process.stdout.close()

    def write(self, data):
        while data:
            written = self.process.stdin.write(data)
            require(written, "RDP transport closed while sending")
            data = data[written:]

    def read(self, length):
        remaining = self.deadline - time.monotonic()
        require(remaining > 0 and select.select([self.process.stdout], [], [], remaining)[0],
                "RDP server response timed out")
        data = os.read(self.process.stdout.fileno(), length)
        require(data, "RDP connection closed unexpectedly")
        return data

    def read_exactly(self, length):
        result = bytearray()
        while len(result) < length:
            result.extend(self.read(length - len(result)))
        return bytes(result)

    def negotiate(self, protocols):
        # MS-RDPBCGR: X.224 connection request with RDP_NEG_REQ (8 bytes).
        self.write(b"\x03\x00\x00\x13\x0e\xe0\x00\x00\x00\x00\x00"
                   + struct.pack("<BBHI", 1, 0, 8, protocols))
        header = self.read_exactly(4)
        require(header[:2] == b"\x03\x00", "Invalid RDP TPKT response")
        length = struct.unpack(">H", header[2:])[0]
        require(length == 19, f"Unexpected RDP negotiation response length: {length}")
        response = self.read_exactly(length - 4)
        require(response[1] == 0xD0, "Expected an X.224 connection confirm")
        kind, flags, size, selected = struct.unpack("<BBHI", response[7:])
        require(size == 8, "Invalid RDP negotiation structure size")
        return kind, selected


def check_tls(version):
    expected_certificate = execute("openssl", "x509", "-in", "/var/lib/xrdp/tls/cert.pem",
                                   "-outform", "DER")
    with RDPTransport() as connection:
        require(connection.negotiate(1) == (2, 1), "Server did not select TLS for RDP")
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        context.minimum_version = version
        context.maximum_version = version
        incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
        session = context.wrap_bio(incoming, outgoing, server_side=False)
        while True:
            try:
                session.do_handshake()
                connection.write(outgoing.read())
                break
            except ssl.SSLWantReadError:
                connection.write(outgoing.read())
                incoming.write(connection.read(65536))
        require(session.getpeercert(binary_form=True) == expected_certificate,
                "TLS handshake served a certificate other than the persisted deployment certificate")
        print(f"PASS: RDP {session.version()} handshake serves the persisted certificate")


try:
    check_configuration()
    print("PASS: loopback-only RDP, dedicated xrdp identity, root sesman, Xorg-only single session")
    for version in (ssl.TLSVersion.TLSv1_2, ssl.TLSVersion.TLSv1_3):
        check_tls(version)
    # MS-RDPBCGR 2.2.1.2.2: failure 1 is SSL_REQUIRED_BY_SERVER.
    with RDPTransport() as connection:
        require(connection.negotiate(0) == (3, 1), "Classic RDP encryption was not explicitly rejected")
    print("PASS: classic RDP encryption is rejected with SSL_REQUIRED_BY_SERVER")
except (RuntimeError, OSError, subprocess.SubprocessError) as error:
    sys.exit(f"FAIL: {error}")
PYTHON
}

start_container a-first a
check_rdp
certificate_a=$("$DOCKER_BIN" exec "$ACTIVE_CONTAINER" openssl x509 -in /var/lib/xrdp/tls/cert.pem -outform PEM)
public_key_a=$("$DOCKER_BIN" exec "$ACTIVE_CONTAINER" openssl x509 -in /var/lib/xrdp/tls/cert.pem -pubkey -noout)
stop_container

start_container a-recreated a
certificate_recreated=$("$DOCKER_BIN" exec "$ACTIVE_CONTAINER" openssl x509 -in /var/lib/xrdp/tls/cert.pem -outform PEM)
[ "$certificate_a" = "$certificate_recreated" ] || fail 'certificate changed after recreating a container with the same volume'
check_rdp
stop_container
echo 'PASS: the deployment certificate survives container recreation'

start_container b-first b
public_key_b=$("$DOCKER_BIN" exec "$ACTIVE_CONTAINER" openssl x509 -in /var/lib/xrdp/tls/cert.pem -pubkey -noout)
[ "$public_key_a" != "$public_key_b" ] || fail 'different deployment volumes share a TLS public key'
check_rdp
stop_container
echo 'PASS: different deployments receive different TLS key pairs'
