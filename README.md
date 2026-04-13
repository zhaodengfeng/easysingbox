# easy-sing-box

sing-box 代理协议一键部署脚本，支持 10 种协议、多用户管理、流量统计与限额管控。

## 特性

- **10 种代理协议**: VLESS-Reality、VLESS-WS、VLESS-gRPC、VMess-WS、Trojan、Shadowsocks、ShadowTLS、Hysteria 2、TUIC v5、AnyTLS
- **分级菜单**: 清晰的 4 级菜单结构，支持字母快捷键
- **一键更新**: 内置脚本自更新功能，主菜单按 `u` 即可更新
- **环境检测**: 安装前自动检测操作系统、架构、依赖、网络、防火墙、端口占用，缺失依赖自动安装
- **多用户管理**: 添加/删除/启用/禁用用户，支持用户跨协议使用
- **流量统计**: cron 每 5 分钟自动采集，月度/累计流量统计
- **流量限额**: 月度 + 总限额，超限自动封禁，到期自动解封
- **证书管理**: acme.sh 自动申请，6 种状态检测，跨协议复用
- **分享链接**: 自动生成，支持二维码
- **安全加固**: systemd 服务安全配置（NoNewPrivileges、ProtectSystem 等）
- **下载验证**: sha256sum 校验和验证
- **纯 Bash**: 零外部依赖（除系统包），单文件入口

## 快速开始

```bash
# 一键安装
curl -fsSL https://raw.githubusercontent.com/zhaodengfeng/easysingbox/main/install.sh | sudo bash

# 运行
sudo easysingbox
```

也支持 `git clone` 方式安装：

```bash
git clone https://github.com/zhaodengfeng/easysingbox.git
cd easysingbox
sudo bash install.sh
```

安装脚本会自动检测系统环境，缺失的必要依赖会自动安装。

## 更新脚本

```bash
# 如果是旧版本，先更新主脚本（带更新功能）
curl -fsSL https://raw.githubusercontent.com/zhaodengfeng/easysingbox/main/easysingbox.sh | sudo tee /opt/easy-singbox/easysingbox.sh >/dev/null && sudo chmod +x /opt/easy-singbox/easysingbox.sh

# 之后所有更新：运行 easysingbox，在主菜单输入 u
sudo easysingbox
```

更新时会自动备份当前文件到 `/opt/easy-singbox/.backup/` 目录。

## 管理菜单

```
easy-sing-box v0.2.0

┌─────────────────────────────────────┐
│  【1】协议管理                      │
│  【2】用户管理                      │
│  【3】服务管理                      │
│  【4】流量统计                      │
│  【u】更新脚本                      │
│  【0】退出                          │
└─────────────────────────────────────┘
```

### 协议管理子菜单

```
【安装协议】
  1.  VLESS + Reality     (无需域名)
  2.  VLESS + WS + TLS    (需域名+证书)
  3.  VLESS + gRPC + TLS  (需域名+证书)
  4.  VMess + WS + TLS    (需域名+证书)
  5.  Trojan + TLS        (需域名+证书)
  6.  Shadowsocks         (无需域名)
  7.  ShadowTLS + SS      (需域名+证书)
  8.  Hysteria 2         (需域名+证书)
  9.  TUIC v5            (需域名+证书)
  10. AnyTLS             (需域名+证书)

【管理已安装协议】
  s.  查看所有协议状态
  u.  启动/停止/重启协议
  d.  卸载协议
  q.  查看分享链接

  0.  返回主菜单
```

## 支持的系统

- Debian / Ubuntu
- CentOS / Rocky Linux / AlmaLinux / Fedora
- Alpine Linux
- Arch Linux / Manjaro
- openSUSE / SLES

支持 amd64 和 arm64 架构。

## 环境检测

安装脚本运行时会依次检测：

1. **操作系统** — 识别发行版和包管理器（apt/yum/dnf/apk/pacman/zypper）
2. **CPU 架构** — amd64 / arm64，不支持则退出
3. **systemd** — 未安装则退出
4. **必要依赖** — jq、openssl、curl、wget、cron，缺失时自动安装
5. **可选依赖** — qrencode（二维码）、git，询问后安装
6. **网络连通性** — 检测 GitHub 是否可达
7. **防火墙状态** — firewalld / ufw / iptables，给出放行端口示例
8. **端口占用** — 检查 80/443/8443/8388 是否被占用

## 目录结构

```
/opt/easy-singbox/
├── easysingbox.sh              # 主入口
├── bin/
│   └── sing-box                # sing-box 二进制
├── config/
│   └── {protocol}/
│       ├── inbound.json        # 协议配置
│       └── share-link/
│           └── {username}.txt  # 分享链接
├── tls/                        # 证书目录
├── service/                    # systemd 服务
├── state.json                  # 全局状态
├── users.json                  # 用户数据库
└── traffic/
    ├── monthly/                # 月度流量
    └── total.json              # 累计流量
```

## 项目结构

```
easysingbox/
├── easysingbox.sh              # 主入口 — 菜单 + 协议分发
├── install.sh                  # 安装脚本（环境检测 + 依赖安装）
├── lib/
│   ├── common.sh               # 公共函数（端口、UUID、证书、服务管理）
│   ├── install.sh              # sing-box 安装与升级
│   ├── users.sh                # 用户管理（增删改查、限额）
│   ├── traffic.sh              # 流量采集、统计、限额检查、月度重置
│   ├── rebuild.sh              # 配置重建（用户变更后自动重建）
│   └── share-link.sh           # 10 种协议分享链接生成
└── protocols/
    ├── vless-reality.sh        # VLESS + Reality（无需域名）
    ├── vless-ws.sh             # VLESS + WebSocket + TLS
    ├── vless-grpc.sh           # VLESS + gRPC + TLS
    ├── vmess-ws.sh             # VMess + WebSocket + TLS
    ├── trojan.sh               # Trojan + TLS
    ├── shadowsocks.sh          # Shadowsocks 2022（无需域名）
    ├── shadowtls.sh            # ShadowTLS + Shadowsocks
    ├── hysteria2.sh            # Hysteria 2（QUIC）
    ├── tuic.sh                 # TUIC v5（QUIC）
    └── anytls.sh               # AnyTLS（sing-box 1.10 新增）
```

## 协议说明

| 协议 | 需域名 | 需证书 | 传输层 | 说明 |
|------|--------|--------|--------|------|
| VLESS + Reality | ❌ | ❌ | TCP | 无需域名，内置 Reality 伪装 |
| VLESS + WS + TLS | ✅ | ✅ | WS | 可套 CDN |
| VLESS + gRPC + TLS | ✅ | ✅ | gRPC | 可套 CDN |
| VMess + WS + TLS | ✅ | ✅ | WS | 可套 CDN |
| Trojan + TLS | ✅ | ✅ | TCP | 标准 Trojan |
| Shadowsocks | ❌ | ❌ | TCP/UDP | 2022 多用户 AEAD |
| ShadowTLS | ✅ | ✅ | TCP | TLS 伪装层 + SS |
| Hysteria 2 | ✅ | ✅ | QUIC | 抗封锁，UDP-based |
| TUIC v5 | ✅ | ✅ | QUIC | 低延迟 |
| AnyTLS | ✅ | ✅ | TCP | sing-box 1.10 新增 |

## 流量统计

流量统计通过 sing-box 的 `clash_api` 实现：

1. 每个协议实例配置独立的 `clash_api` 端口（19090-19099）
2. cron 每 5 分钟执行一次 `easysingbox.sh --collect-traffic`
3. 通过 `/connections` 端点采集活跃连接的上行/下行字节数
4. 计算 delta 增量，累加到月度 + 总流量
5. 自动检查流量限额，超限封禁，月度到期解封

> **注意**: sing-box 的 clash_api 不提供精确的 per-user 统计，当前方案通过连接级数据做均匀分配近似值。

## 许可证

MIT
