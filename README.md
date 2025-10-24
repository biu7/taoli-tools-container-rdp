# Taoli Tools Container

添加中文支持

将 novnc 改为 xrdp 以支持 Windows 远程桌面访问

移除 signer 容器。如果没有单独部署的话，建议保留（我单独部署了，有一起部署的需求的话自行 fork  修改）

## Setup

```bash
curl -fsSL https://taoli.tools/setup | sh
```

启动后查看容器日志，扫描 Tailscale QR 码将容器加入你的 Tailscale 网络：

```bash
docker-compose logs -f container
```

## 连接方式

⚠️ **注意：已配置无密码自动登录，完全通过 Tailscale VPN 访问，不暴露端口到公网**

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

# 或使用 rdesktop
rdesktop 100.x.x.x:3389 -u taoli
```

## Update

```bash
docker-compose pull
docker-compose up -d
docker-compose logs -f container
```

## Remove

```bash
docker-compose down -v
```