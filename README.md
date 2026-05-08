# Xray + Caddy 一键安装脚本

**XTLS(Vision)+Reality & XHTTP 五合一服务端部署方案**

一键在 Linux VPS 上部署 Xray + Caddy + OpenList 伪装站，提供交互式菜单管理安装、配置更新、查看连接信息、重启服务和卸载等操作。

---

## 功能特性

- **一键安装**：自动安装 Xray-core、Caddy，配置 XTLS(Vision)+Reality+xHTTP 五合一方案
- **自动参数生成**：UUID、Reality x25519 密钥对、Short ID 支持自动生成
- **交互式配置更新**：保留现有参数作为默认值，逐项修改无需重新输入
- **OpenList 伪装站**：安装多网盘文件列表程序作为真实网站伪装
- **xPadding 流量混淆**：内置 xPaddingObfsMode 防护，降低特征检测风险
- **配置验证**：安装后自动验证 Xray 和 Caddy 配置文件合法性
- **连接信息展示**：安装完成后输出客户端连接配置（Mihomo YAML 格式）
- **完整卸载**：一键清理 Xray、Caddy、OpenList 及所有配置文件

---

## 前置要求

- 一台 VPS（Debian/Ubuntu 系统）
- root 权限
- 一个个人域名（解析到 VPS IP）
- Cloudflare 账号（用于 CDN）
- 域名解析：
  - `cdn.example.com` → VPS IP（开启小黄云，过 CDN）
  - `reality.example.com` → VPS IP（关闭小黄云，直连，用于 Reality 握手）
- **确保 443 端口开放**，Caddy 会自动通过 Let's Encrypt / ZeroSSL 申请 TLS 证书

---

## 快速开始

```bash
# 下载脚本
curl -fsSL -o xray-one-click.sh https://raw.githubusercontent.com/Oat-Milky-desu/xray-one-click/main/xray-one-click.sh

# 赋予执行权限并运行
chmod +x xray-one-click.sh
sudo ./xray-one-click.sh
```

---

## 菜单说明

```
╔══════════════════════════════════════════════════════════╗
║          Xray + Caddy 一键脚本  v1.0                     ║
║          XTLS(Vision)+Reality & XHTTP 五合一             ║
╚══════════════════════════════════════════════════════════╝

  1) 安装 Xray 服务端
  2) 更新配置
  3) 查看配置 / 连接信息
  4) 重启服务
  5) 卸载 Xray
  6) 退出

请选择 [1-6]:
```

### 1. 安装 Xray 服务端

完整安装流程：
1. 检查 root 权限和操作系统
2. 安装依赖（curl、jq、uuid-runtime 等）
3. 安装 Xray-core（官方脚本，失败则手动下载最新 release）
4. 安装 Caddy（官方 apt 仓库）
5. 交互式收集参数：
   - Direct 域名（如 `direct.example.com`）
   - CDN 域名（如 `cdn.example.com`）
   - Reality 域名（如 `reality.example.com`）
   - xHTTP 路径（如 `/xhttp-path`）
   - Reality 私钥/公钥（留空自动生成）
   - Short ID（留空自动生成）
   - UUID_01（Vision 用户，留空自动生成）
   - UUID_02（xhttp 用户，留空自动生成）
6. 安装 OpenList 伪装站（官方一键脚本，监听 127.0.0.1:5244）
7. 生成 Xray 配置文件（含 xPadding 防护）
8. 生成 Caddy 配置文件（反代 XHTTP 和 OpenList）
9. 设置 systemd 用户覆盖（Xray 以 `caddy` 用户运行）
10. 验证配置并启动服务
11. 显示客户端连接信息

> **注意**：Caddy 会自动通过 Let's Encrypt / ZeroSSL 为配置的域名申请 TLS 证书，无需手动上传。

### 2. 更新配置

读取现有参数作为默认值，允许逐项修改：
- 直接回车保留当前值
- 输入新值覆盖
- 重新生成配置文件并重启服务

### 3. 查看配置 / 连接信息

显示当前所有连接参数：
- VPS IP、域名、UUID、Reality 公钥、Short ID
- 5 个出站节点的 Mihomo YAML 配置示例

### 4. 重启服务

执行 `systemctl daemon-reload && systemctl restart xray caddy`，并检查服务状态。

### 5. 卸载 Xray

完全清理：
- 停止并禁用 xray、caddy、openlist 服务
- 卸载 Xray 和 Caddy
- 删除所有配置文件、证书、伪装站数据
- 可选删除 `caddy` 用户

---

## 架构说明

```
客户端 ──→ 443 端口 ──→ Xray (VLESS + Reality)
                              │
                              ├──→ flow=xtls-rprx-vision (直连 Vision)
                              │
                              ├──→ fallback → /run/xray/xhttp_in.sock
                              │                    │
                              │                    └──→ XHTTP inbound
                              │
                              └──→ 非 VLESS 流量 → /run/xray/tls_gate.sock
                                                        │
                                                        └──→ Caddy
                                                              │
                                                              ├──→ /xhttp-path/* → XHTTP inbound
                                                              │
                                                              └──→ 其他路径 → OpenList (127.0.0.1:5244)
```

**核心组件**：
- **Xray**: 监听 0.0.0.0:443，处理 VLESS + Reality 流量
- **Caddy**: 绑定 unix socket `/run/xray/tls_gate.sock`，处理 TLS 终止和流量分发
- **OpenList**: 监听 127.0.0.1:5244，提供多网盘文件列表伪装站

---

## 五合一节点

在同一 VPS 的 443 端口实现五个出站节点：

| 节点 | 协议 | 适用场景 |
|------|------|----------|
| 1. XTLS(Vision)+Reality | TCP直连 | 低延迟高速度，客户端不支持 xhttp |
| 2. xhttp+Reality | TCP直连 | 去程回程线路都好 |
| 3. 上行 CDN+TLS / 下行 Reality | 上行CDN/下行直连 | 去程差回程好，偏重下载 |
| 4. xhttp+TLS+CDN | CDN全走 | 去程回程都差，IP 已被墙 |
| 5. 上行 Reality / 下行 CDN+TLS | 上行直连/下行CDN | 去程好回程差，偏重上传 |

---

## xPadding 流量混淆

基于 [XTLS/Xray-core#5414](https://github.com/XTLS/Xray-core/pull/5414) 实现，降低流量特征识别风险：

```json
"xhttpSettings": {
  "xPaddingObfsMode": true,
  "xPaddingMethod": "tokenish",
  "xPaddingPlacement": "queryInHeader",
  "xPaddingHeader": "X-Cache",
  "xPaddingKey": "_dc"
}
```

- **xPaddingObfsMode**: 启用混淆模式
- **xPaddingMethod**: `tokenish` 方法生成类 token 填充数据
- **xPaddingPlacement**: `queryInHeader` 将填充数据嵌入请求头

> 客户端需在 `extra` 对象中配置相同参数。

---

## 文件说明

| 文件 | 说明 |
|------|------|
| `xray-one-click.sh` | 一键安装脚本（主文件） |
| `说明1.md` | 原始配置教程文档 |
| `说明2.md` | xPadding 防护配置说明 |
| `/usr/local/etc/xray/config.json` | Xray 服务端配置 |
| `/etc/caddy/Caddyfile` | Caddy 反代配置 |
| `/usr/local/etc/xray/params.conf` | 参数持久化文件 |
| `/var/log/xray-one-click.log` | 脚本运行日志 |

---

## 版本要求

- **Xray-core**: >= v24.12.15
- **Mihomo 客户端**: >= v1.19.23
- **系统**: Debian / Ubuntu

---

## 致谢

- [RPRX](https://github.com/RPRX)、[wwqgtxx](https://github.com/wwqgtxx)、Nemu-x
- [Benjamin1919](https://github.com/XTLS/Xray-core/discussions/4118) - xhttp 五合一配置教程
- [珊瑚哈希](https://github.com/) - 客户端节点配置示例
- [OpenListTeam](https://github.com/OpenListTeam/OpenList) - 开源网盘列表程序

---

## 免责声明

本项目仅供学习研究使用，请遵守当地法律法规。使用者需对自身行为负责。
