#!/bin/sh
set -eu

# Build inside the Alpine builder stage. Keep version and checksum together.
# https://github.com/neutrinolabs/xrdp/releases/tag/v0.10.6.1
XRDP_VERSION=0.10.6.1
XRDP_SHA256=2f7beb5a3b2529c8d72dc0df9b8cdca31ab0e0c14d1e3421210f5e6ec0ab3b75
DESTDIR=${1:?Usage: build-xrdp.sh DESTDIR}

build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
cd "$build_dir"

curl --fail --location --retry 3 --output xrdp.tar.gz \
  "https://github.com/neutrinolabs/xrdp/releases/download/v${XRDP_VERSION}/xrdp-${XRDP_VERSION}.tar.gz"
printf '%s  %s\n' "$XRDP_SHA256" xrdp.tar.gz | sha256sum -c -
tar -xzf xrdp.tar.gz
cd "xrdp-${XRDP_VERSION}"

export CFLAGS='-O2 -fstack-protector-strong -fstack-clash-protection -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security'
export LDFLAGS='-Wl,-z,relro,-z,now -Wl,--as-needed'
./configure \
  --prefix=/usr \
  --sysconfdir=/etc \
  --localstatedir=/var \
  --sbindir=/usr/sbin \
  --enable-fuse \
  --enable-ipv6 \
  --enable-opus \
  --enable-pam \
  --enable-pam-config=unix \
  --enable-tests \
  --enable-tjpeg \
  --enable-vsock
make -j"$(getconf _NPROCESSORS_ONLN)"
make check
make DESTDIR="$DESTDIR" install

# Match Alpine's non-suid Xorg path. Keep all runtime helpers and assets.
sed -i 's|^param=Xorg$|param=/usr/libexec/Xorg|' "$DESTDIR/etc/xrdp/sesman.ini"

# Keys belong to the running container, never to a shared image layer.
rm -f "$DESTDIR"/etc/xrdp/*.pem "$DESTDIR/etc/xrdp/rsakeys.ini"
# Static libraries are needed during the upstream build, but not at runtime.
find "$DESTDIR/usr" -type f \( -name '*.a' -o -name '*.la' \) -delete
rm -rf "$DESTDIR/usr/include" "$DESTDIR/usr/lib/pkgconfig" "$DESTDIR/usr/share/man"
