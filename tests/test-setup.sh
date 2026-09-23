#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_tmpdir=$(mktemp -d)
trap 'rm -rf "$test_tmpdir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$test_tmpdir/bin"
cat > "$test_tmpdir/bin/docker" <<'EOF'
#!/bin/sh
set -eu
printf 'docker %s\n' "$*" >> "$TEST_CALLS"
if [ "$*" = "${TEST_FAIL_DOCKER:-}" ]; then
  exit 1
fi
case "$*" in
  'compose version'|'info'|'compose pull'|'compose up -d'|'compose logs -f container') ;;
  *) echo "Unexpected Docker command: $*" >&2; exit 1 ;;
esac
EOF
cat > "$test_tmpdir/bin/curl" <<'EOF'
#!/bin/sh
set -eu
url=
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -fsSL) shift ;;
    -o) output=$2; shift 2 ;;
    https://*) url=$1; shift ;;
    *) echo "Unexpected curl argument: $1" >&2; exit 1 ;;
  esac
done
printf 'curl %s\n' "$url" >> "$TEST_CALLS"
case "$url" in
  https://get.docker.com) echo 'Existing Docker must not be reinstalled' >&2; exit 1 ;;
  */docker-compose.yml|*/chromium.json) ;;
  *) echo "Unexpected download: $url" >&2; exit 1 ;;
esac
if [ "${url##*/}" = "${TEST_FAIL_DOWNLOAD:-}" ]; then
  exit 22
fi
printf 'downloaded %s\n' "${url##*/}" > "$output"
EOF
cat > "$test_tmpdir/bin/docker-compose" <<'EOF'
#!/bin/sh
echo 'Legacy docker-compose must not be used' >&2
exit 1
EOF
chmod +x "$test_tmpdir/bin/docker" "$test_tmpdir/bin/curl" "$test_tmpdir/bin/docker-compose"
PATH="$test_tmpdir/bin:$PATH"
export PATH

new_case() {
  case_dir="$test_tmpdir/$1"
  mkdir -p "$case_dir"
  TEST_CALLS="$case_dir/calls"
  TEST_FAIL_DOCKER=
  TEST_FAIL_DOWNLOAD=
  export TEST_CALLS TEST_FAIL_DOCKER TEST_FAIL_DOWNLOAD
  : > "$TEST_CALLS"
}

run_setup() {
  (cd "$case_dir" && sh "$project_root/setup.sh") > "$case_dir/output" 2>&1
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

new_case success
run_setup || fail 'setup with existing Docker should succeed'
cat > "$case_dir/expected" <<'EOF'
docker compose version
docker info
curl https://raw.githubusercontent.com/biu7/taoli-tools-container-rdp/main/docker-compose.yml
curl https://raw.githubusercontent.com/biu7/taoli-tools-container-rdp/main/chromium.json
docker compose pull
docker compose up -d
docker compose logs -f container
EOF
cmp "$TEST_CALLS" "$case_dir/expected" || fail 'unexpected install or Compose commands'
[ "$(cat "$case_dir/docker-compose.yml")" = 'downloaded docker-compose.yml' ] || fail 'Compose config not installed'
[ "$(cat "$case_dir/chromium.json")" = 'downloaded chromium.json' ] || fail 'seccomp config not installed'

for download in docker-compose.yml chromium.json; do
  new_case "failed-$download"
  TEST_FAIL_DOWNLOAD=$download
  printf 'old compose\n' > "$case_dir/docker-compose.yml"
  printf 'old seccomp\n' > "$case_dir/chromium.json"
  if run_setup; then fail 'download failure should stop setup'; fi
  [ "$(cat "$case_dir/docker-compose.yml")" = 'old compose' ] || fail 'download failure overwrote Compose config'
  [ "$(cat "$case_dir/chromium.json")" = 'old seccomp' ] || fail 'download failure overwrote seccomp config'
  case "$(cat "$TEST_CALLS")" in
    *'docker compose pull'*|*'docker compose up'*|*'docker compose logs'*) fail 'download failure continued deployment' ;;
  esac
done

for docker_command in 'compose version' 'info' 'compose pull'; do
  new_case "failed-${docker_command##* }"
  TEST_FAIL_DOCKER=$docker_command
  if run_setup; then fail "Docker failure should stop setup: $docker_command"; fi
  case "$(cat "$TEST_CALLS")" in
    *'docker compose up'*|*'docker compose logs'*) fail 'Docker failure continued deployment' ;;
  esac
done

echo 'PASS: modern Compose, existing Docker, download preservation and failure handling'
