FROM alpine:3.22.2 AS xrdp-builder

# Alpine 3.22 still packages XRDP 0.10.3; build only XRDP from a verified release.
RUN apk add --no-cache \
  build-base curl ca-certificates pkgconf openssl-dev \
  libx11-dev libxfixes-dev libxrandr-dev libjpeg-turbo-dev fuse3-dev \
  linux-headers nasm linux-pam-dev opus-dev check-dev cmocka-dev
COPY build-xrdp.sh /usr/local/bin/build-xrdp.sh
RUN sh /usr/local/bin/build-xrdp.sh /xrdp-install

FROM alpine:3.22.2

RUN apk add --no-cache \
  openbox \
  bash \
  xinit \
  linux-pam \
  fuse3-libs \
  libturbojpeg \
  opus \
  xorgxrdp \
  xorg-server \
  xf86-video-dummy \
  chromium \
  chromium-lang \
  ca-certificates \
  openssl \
  tailscale \
  tzdata \
  font-noto-cjk \
  font-noto \
  musl-locales \
  musl-locales-lang

COPY --from=xrdp-builder /xrdp-install/ /

RUN cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

# 设置中文语言环境
ENV LANG=zh_CN.UTF-8 \
    LANGUAGE=zh_CN:zh \
    LC_ALL=zh_CN.UTF-8

RUN addgroup -S taoli && adduser -S -G taoli -h /home/taoli -s /bin/sh taoli && \
  addgroup -S xrdp && adduser -S -D -H -G xrdp -s /sbin/nologin xrdp

RUN mkdir -p /home/taoli/data && \
  chown -R taoli:taoli /home/taoli

# 仅允许 taoli 无密码登录，拒绝 root 和其他系统账户
RUN printf '%s\n' \
  'auth requisite pam_succeed_if.so user = taoli' \
  'auth required pam_permit.so' \
  'account requisite pam_succeed_if.so user = taoli' \
  'account required pam_permit.so' \
  'session required pam_unix.so' > /etc/pam.d/xrdp-sesman

# 固定 Xorg 单用户会话；Chromium 退出即结束桌面会话。
COPY xrdp.ini sesman.ini startwm.sh /etc/xrdp/

COPY entrypoint.sh init-xrdp.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/init-xrdp.sh /etc/xrdp/startwm.sh

CMD ["/usr/local/bin/entrypoint.sh"]
