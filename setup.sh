#!/bin/sh
set -eu

if ! command -v curl >/dev/null 2>&1; then
  echo "需要先安装 curl。" >&2
  exit 1
fi

setup_tmpdir=$(mktemp -d)
trap 'rm -rf "$setup_tmpdir"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# 仅在 Docker 不存在时安装；先下载成功，再执行安装脚本。
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com -o "$setup_tmpdir/install-docker.sh"
  sh "$setup_tmpdir/install-docker.sh"
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "需要 Docker Compose 插件（docker compose），请先安装 docker-compose-plugin。" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "无法访问 Docker daemon，请确认 Docker 已启动且当前用户有访问权限。" >&2
  exit 1
fi

# 两个文件都下载成功后再替换，避免下载失败截断已有配置。
config_url=https://raw.githubusercontent.com/biu7/taoli-tools-container-rdp/main
curl -fsSL "$config_url/docker-compose.yml" -o "$setup_tmpdir/docker-compose.yml"
curl -fsSL "$config_url/chromium.json" -o "$setup_tmpdir/chromium.json"
mv "$setup_tmpdir/docker-compose.yml" docker-compose.yml
mv "$setup_tmpdir/chromium.json" chromium.json

# 拉取最新镜像并启动服务
docker compose pull
docker compose up -d

# 查看日志
docker compose logs -f container
