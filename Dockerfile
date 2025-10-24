FROM alpine:3.22.2

RUN apk add --no-cache \
  openbox \
  xrdp \
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

RUN cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

# 设置中文语言环境
ENV LANG=zh_CN.UTF-8 \
    LANGUAGE=zh_CN:zh \
    LC_ALL=zh_CN.UTF-8

RUN addgroup -S taoli && adduser -S -G taoli -h /home/taoli -s /bin/sh taoli

RUN mkdir -p /home/taoli/data && \
  chown -R taoli:taoli /home/taoli

# 配置 PAM 允许无密码登录
RUN echo 'auth sufficient pam_permit.so' > /etc/pam.d/xrdp-sesman && \
  echo 'account sufficient pam_permit.so' >> /etc/pam.d/xrdp-sesman && \
  echo 'session required pam_unix.so' >> /etc/pam.d/xrdp-sesman

# 配置 XRDP 会话启动脚本
RUN echo '#!/bin/sh' > /etc/xrdp/startwm.sh && \
  echo 'export LANG=zh_CN.UTF-8' >> /etc/xrdp/startwm.sh && \
  echo 'export LANGUAGE=zh_CN:zh' >> /etc/xrdp/startwm.sh && \
  echo 'export LC_ALL=zh_CN.UTF-8' >> /etc/xrdp/startwm.sh && \
  echo '' >> /etc/xrdp/startwm.sh && \
  echo 'rm -f /home/taoli/data/SingletonLock' >> /etc/xrdp/startwm.sh && \
  echo 'openbox-session &' >> /etc/xrdp/startwm.sh && \
  echo 'exec chromium --disable-dev-shm-usage --disable-gpu --use-gl=disabled --no-default-browser-check --no-first-run --lang=zh-CN --user-data-dir=/home/taoli/data https://taoli.tools' >> /etc/xrdp/startwm.sh && \
  chmod +x /etc/xrdp/startwm.sh

ADD entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
