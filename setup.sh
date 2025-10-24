#!/bin/sh

# 安装 Docker
curl -fsSL https://get.docker.com | sh

# 下载配置文件
curl -fsSL https://github.com/biu7/taoli-tools-container-rdp/raw/refs/heads/main/docker-compose.yml > docker-compose.yml
curl -fsSL https://github.com/biu7/taoli-tools-container-rdp/raw/refs/heads/main/chromium.json > chromium.json

# 拉取最新镜像并启动服务
docker-compose pull
docker-compose up -d

# 查看日志
docker-compose logs -f container
