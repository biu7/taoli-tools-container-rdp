#!/bin/sh
set -eu

# Only root writes the daemon's persistent identity; xrdp can read it, taoli cannot.
mkdir -p /var/run/xrdp /var/log /var/lib/xrdp
chown root:xrdp /var/lib/xrdp
chmod 750 /var/lib/xrdp

if [ ! -d /var/lib/xrdp/tls ]; then
  tls_tmpdir=$(mktemp -d /var/lib/xrdp/.tls.XXXXXX)
  trap 'rm -rf "$tls_tmpdir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 825 \
    -subj /CN=taoli-tools-container \
    -addext subjectAltName=DNS:taoli-tools-container \
    -keyout "$tls_tmpdir/key.pem" -out "$tls_tmpdir/cert.pem" >/dev/null 2>&1
  chown root:xrdp "$tls_tmpdir" "$tls_tmpdir/key.pem" "$tls_tmpdir/cert.pem"
  chmod 750 "$tls_tmpdir"
  chmod 640 "$tls_tmpdir/key.pem" "$tls_tmpdir/cert.pem"
  mv "$tls_tmpdir" /var/lib/xrdp/tls
  trap - EXIT INT TERM
fi

# Do not silently replace incomplete or damaged identities with a different key.
if ! openssl x509 -in /var/lib/xrdp/tls/cert.pem -noout >/dev/null 2>&1 ||
   ! openssl pkey -in /var/lib/xrdp/tls/key.pem -check -noout >/dev/null 2>&1; then
  echo "Invalid XRDP TLS identity in /var/lib/xrdp/tls; restore the certificate and key together." >&2
  exit 1
fi
cert_public=$(openssl x509 -in /var/lib/xrdp/tls/cert.pem -pubkey -noout)
key_public=$(openssl pkey -in /var/lib/xrdp/tls/key.pem -pubout)
if [ "$cert_public" != "$key_public" ]; then
  echo "XRDP TLS certificate does not match its private key." >&2
  exit 1
fi
chown root:xrdp /var/lib/xrdp/tls /var/lib/xrdp/tls/cert.pem /var/lib/xrdp/tls/key.pem
chmod 750 /var/lib/xrdp/tls
chmod 640 /var/lib/xrdp/tls/cert.pem /var/lib/xrdp/tls/key.pem

# XRDP also expects its protocol key file even when TLS is required.
if [ ! -s /var/lib/xrdp/rsakeys.ini ]; then
  (umask 077; xrdp-keygen xrdp /var/lib/xrdp/rsakeys.ini >/dev/null)
fi
chown root:xrdp /var/lib/xrdp/rsakeys.ini
chmod 640 /var/lib/xrdp/rsakeys.ini
ln -sf /var/lib/xrdp/rsakeys.ini /etc/xrdp/rsakeys.ini

touch /var/log/xrdp.log /var/log/xrdp-sesman.log
chown xrdp:xrdp /var/log/xrdp.log
chown root:root /var/log/xrdp-sesman.log
chmod 640 /var/log/xrdp.log /var/log/xrdp-sesman.log
