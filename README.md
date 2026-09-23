# Taoli Tools Container

添加中文支持

将 novnc 改为 xrdp 以支持 Windows 远程桌面访问

移除 signer 容器。如果没有单独部署的话，建议保留（我单独部署了，有一起部署的需求的话自行 fork  修改）

## Setup

在 Linux 服务器的独立部署目录中执行。需要 `curl` 和 Docker 访问权限；脚本仅在 Docker 未安装时安装 Docker，已有 Docker 需提供 Compose 插件（`docker compose`）。

```bash
curl -fsSL https://raw.githubusercontent.com/biu7/taoli-tools-container-rdp/main/setup.sh -o setup.sh && sh setup.sh
```

启动后扫描日志中的 Tailscale QR 码，将容器加入你的 Tailscale 网络。退出日志查看不会停止容器；之后可在部署目录重新查看日志：

```bash
docker compose logs -f container
```

浏览器数据保存在 `data` 卷。Tailscale 以 `taoli` 用户运行，显式使用 `/var/lib/tailscale` 保存节点状态，并挂载 `tailscale` 卷；正常重建容器不需要重新认证。XRDP、会话管理器或 Tailscale daemon 退出时，容器会退出，由 Compose 的 `restart: always` 策略重启。

XRDP 固定使用 [0.10.6.1 官方版本](https://github.com/neutrinolabs/xrdp/releases/tag/v0.10.6.1)，在 Alpine 3.22.2 中从校验过 SHA256 的源码构建，并运行上游测试。RDP 进程使用独立的 `xrdp` 用户，仅监听容器内 `127.0.0.1:3389`，由 Tailscale 用户态网络转发连接。不要添加宿主机端口映射。

只提供 Xorg 桌面，最多保留一个会话。断线和空闲不会结束会话，重新连接会恢复原桌面；**关闭或崩溃的 Chromium 会结束桌面会话**，下次登录再启动浏览器。客户端指定的启动程序以及用户目录里的 `startwm.sh` 不会覆盖系统启动流程。

Chromium 使用 `--disable-web-security`，使页面可以直接调用未提供 CORS 支持的交易所 API。该设置对这个浏览器中的所有页面生效；浏览器使用专用的 `/home/taoli/data` 配置目录，用于此服务的交易所业务。

为支持 PGlite 的 OPFS 文件句柄池，默认将浏览器继承的 `nofile` 软限制设为 `65535`，Compose 同时设置 `65535` 的软、硬限制。需要降低时，可在 `container` 服务下添加：

```yaml
environment:
  CHROMIUM_NOFILE_LIMIT: "32768"
```

直接运行镜像也可传入 `-e CHROMIUM_NOFILE_LIMIT=32768`。该值必须为正整数，超过容器硬限制时会自动裁剪；由入口脚本在启动会话管理器前设置，并传递给实际的 RDP 浏览器进程。

该变量设置启动时继承的软限制；Chromium 可能自行提高较低的软限制。例如当前版本会把 `4096` 提高到 `8192`（不超过硬限制）。若需要严格限制文件句柄数量，请同时调整 Compose 的 `ulimits.nofile.hard`，且 `soft` 不得超过 `hard`。

## 连接方式

⚠️ **仅允许 `taoli` 账户免密登录，禁止 `root` 和其他账户通过 RDP 登录。通过 Tailscale VPN 访问，不向宿主机发布 RDP 端口；请在 Tailscale 中限制可访问该设备的成员。**

客户端必须支持 TLS 1.2 或 1.3。首次启动会生成此部署独有的自签名证书和私钥，保存在 `xrdp` 卷的 `/var/lib/xrdp/tls` 中，后续重建不会重新生成。首次连接出现证书提示时，可在服务器核对 SHA256 指纹后信任：

```bash
docker compose exec container openssl x509 -in /var/lib/xrdp/tls/cert.pem -noout -fingerprint -sha256 -dates
```

默认自签名证书有效期为 825 天；到期前可在该目录替换配套的 `cert.pem` 与 `key.pem` 并重启服务，也可使用自己签发的证书。已有证书损坏或与私钥不匹配时，容器会停止并报错，需恢复配套文件。

### 获取 Tailscale IP

查看容器日志获取 Tailscale IP，或在 [Tailscale 管理面板](https://login.tailscale.com/admin/machines) 查看 `taoli-tools-container` 的 IP 地址。

### Windows
使用内置的"远程桌面连接"：
1. 按 `Win + R`，输入 `mstsc`
2. 输入容器的 Tailscale IP 地址（如 `100.x.x.x:3389`）
3. 用户名输入 `taoli`，密码留空或随意输入

### macOS
1. 安装 [Microsoft Remote Desktop](https://apps.apple.com/app/microsoft-remote-desktop/id1295203466)
2. 添加新的 PC 连接
3. 输入容器的 Tailscale IP 地址，用户名 `taoli`

### Linux
```bash
# 使用 xfreerdp（替换为实际的 Tailscale IP）
xfreerdp /v:100.x.x.x:3389 /u:taoli
```

## Update

在原部署目录执行。旧版本首次升级前，请先按下面两节更新卷配置、处理 Tailscale 状态，再重建容器。已有浏览器旧锁时，按“浏览器数据卷锁”一节处理。

```bash
docker compose pull
docker compose up -d
docker compose logs -f container
```

### 旧版本首次升级：更新运行配置与证书卷

镜像更新不会自动更新部署目录里的配置文件。请将 `docker-compose.yml` 中 `container` 服务的 `volumes` 增加 `xrdp:/var/lib/xrdp`，同时在顶层 `volumes` 增加 `xrdp:`，并补充 `ulimits`。保留已有配置和部署目录，示意如下：

```yaml
services:
  container:
    # 保留原有 image、security_opt 等配置
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
    volumes:
      - data:/home/taoli/data
      - tailscale:/var/lib/tailscale
      - xrdp:/var/lib/xrdp
volumes:
  data:
  tailscale:
  xrdp:
```

未挂载此卷时，每次重建都会生成新证书，客户端会再次提示身份变化。

同时同步本仓库的 `chromium.json`，其中新增了 `openat2` 和 `statx` 权限。若使用自定义 seccomp 策略，请合并这两条规则并保留其他自定义内容。新的 Compose 限制和 seccomp 策略均需重建容器才能生效。

### 旧版本首次升级：迁移 Tailscale 状态

旧版本的节点状态位于容器内部 `/home/taoli/.local/share/tailscale`，没有保存在原先挂载的 `tailscale` 卷中。直接重建会丢失原节点身份，需要重新扫描二维码认证，节点 IP 也可能变化。浏览器的 `data` 卷不受此次迁移影响。

如需保留原节点身份，在**旧容器仍存在、尚未执行 `up` 重建或 `down` 删除时**，于原部署目录执行下面的迁移。它会拉取新镜像、停止旧服务、备份状态，然后复制到持久化卷；任一步失败都会停止，不覆盖已有的目标状态。备份包含节点密钥，请妥善保管，不要提交到 Git 或分享。

```bash
(
  set -eu
  docker compose pull
  docker compose stop container
  backup_dir=$(mktemp -d "$PWD/tailscale-state-backup.XXXXXX")
  printf 'Tailscale 备份目录：%s\n' "$backup_dir"
  docker cp taoli-tools-container:/home/taoli/.local/share/tailscale/. "$backup_dir/"
  test -s "$backup_dir/tailscaled.state"

  # 覆盖镜像 CMD，仅复制状态，不启动第二个 Tailscale 节点。
  docker compose run --rm --no-deps --user root \
    -v "$backup_dir:/backup:ro" container sh -ec '
      if [ -e /var/lib/tailscale/tailscaled.state ]; then
        echo "目标卷已有节点状态，停止迁移，请先核对。" >&2
        exit 1
      fi
      cp -a /backup/. /var/lib/tailscale/
    '
  docker compose up -d
)
docker compose logs -f container
```

新容器启动时会自动设置状态目录的所有者和权限。若旧容器已被删除、备份路径不存在或从未认证，请执行常规更新并重新扫描二维码；不要从其他设备复制节点状态。

### 浏览器数据卷锁

启动脚本会在整个浏览器会话期间持有数据卷独占锁，阻止多个实例并发使用同一个 Chromium 配置。由本版本管理的会话意外退出或容器重建后，可自动恢复遗留的 `SingletonLock`。

旧版本或其他程序创建的锁无法安全判断归属，启动时会保留并报错。只有在**停止所有使用该数据卷的容器并确认 Chromium 已退出后**，才可在部署目录手动清理：

```bash
docker compose stop container
docker compose run --rm --no-deps --user taoli container sh -ec 'rm -f /home/taoli/data/SingletonLock'
docker compose up -d
```

不要删除 `.chromium-session.lock`，它是并发保护锁文件，正常情况下会一直保留。

## Remove

停止并删除容器，保留浏览器数据、Tailscale 节点状态和 XRDP 证书：

```bash
docker compose down
```

如需一并永久删除三个数据卷，使用 `docker compose down -v`。

## 本地回归验证

在仓库根目录执行：

```bash
docker build -t taoli-tools-container-rdp:test .
sh tests/test-setup.sh
sh tests/test-auth.sh taoli-tools-container-rdp:test
sh tests/test-runtime.sh taoli-tools-container-rdp:test
sh tests/test-browser-lock.sh taoli-tools-container-rdp:test
sh tests/test-rdp-config.sh taoli-tools-container-rdp:test
```

RDP 配置测试需要已有的 Python 3（标准库 `ssl` 支持 TLS 1.3，可用 `PYTHON_BIN` 指定解释器）。测试使用隔离网络，不加入 Tailnet、不发布端口；覆盖认证、实际 Xorg/Chromium 生命周期、守护进程、数据锁、RDP/TLS 握手及证书持久化，不覆盖真实图形 RDP 客户端或跨设备连接。

## 上游同步

2026-09-23 核对了 [taoli-tools/taoli-tools-container](https://github.com/taoli-tools/taoli-tools-container) 从共同基线 `0f636b7` 到 `94b35bc` 的全部 11 个提交，选择性移植适用的变更：

- [2f33f21](https://github.com/taoli-tools/taoli-tools-container/commit/2f33f21)：增加 `openat2`、`statx`，保留本项目 `chromium.json` 的文件名和其他规则。
- [94b35bc](https://github.com/taoli-tools/taoli-tools-container/commit/94b35bc)：合入浏览器跨域 API 支持和文件句柄限制，按 XRDP 创建会话的方式传递限制。
- 上游的 Tailscale 状态持久化修复已由本项目显式使用 `/var/lib/tailscale` 的方式覆盖。

noVNC 前端、Swarm/signer 部署与 Docker daemon 全局配置改动不适用于此 RDP 分支；本项目继续使用服务级配置。
