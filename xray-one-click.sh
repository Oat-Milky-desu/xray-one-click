#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Xray + Caddy 一键安装脚本
# XTLS(Vision)+Reality & XHTTP 五合一
# 版本: v1.0
# =============================================================================

# ---------------------------------------------------------------------------
# 全局常量
# ---------------------------------------------------------------------------
readonly SCRIPT_NAME="xray-one-click"
readonly SCRIPT_VERSION="v1.0"
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly CADDY_CONFIG="/etc/caddy/Caddyfile"
readonly PARAMS_FILE="/usr/local/etc/xray/params.conf"
readonly LOG_FILE="/var/log/xray-one-click.log"
readonly OPENLIST_PORT="5244"
readonly OPENLIST_INSTALL_SCRIPT="https://res.oplist.org/script/v4.sh"
readonly XRAY_RUN_DIR="/run/xray"
readonly XHTTP_SOCK="/run/xray/xhttp_in.sock"
readonly TLS_SOCK="/run/xray/tls_gate.sock"

# ---------------------------------------------------------------------------
# 颜色输出
# ---------------------------------------------------------------------------
red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[0;34m%s\033[0m\n' "$*"; }
plain()  { printf '%s\n' "$*"; }

# ---------------------------------------------------------------------------
# 日志函数
# ---------------------------------------------------------------------------
log_info()  { local msg="[INFO]  $(date '+%Y-%m-%d %H:%M:%S') $*"; echo "$msg" >> "$LOG_FILE"; }
log_warn()  { local msg="[WARN]  $(date '+%Y-%m-%d %H:%M:%S') $*"; echo "$msg" >> "$LOG_FILE"; }
log_error() { local msg="[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*"; echo "$msg" >> "$LOG_FILE"; }
log_step()  { local msg="[STEP]  $(date '+%Y-%m-%d %H:%M:%S') $*"; echo "$msg" >> "$LOG_FILE"; }

# ---------------------------------------------------------------------------
# 错误捕获
# ---------------------------------------------------------------------------
trap 'log_error "错误发生在第 $LINENO 行"; red "错误发生在第 $LINENO 行，请检查日志: $LOG_FILE"; exit 1' ERR
trap 'rm -f /tmp/xray_* /tmp/caddy_*' EXIT

# ---------------------------------------------------------------------------
# 通用工具函数
# ---------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        red "错误: 此脚本需要 root 权限运行"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        red "错误: 无法识别操作系统"
        exit 1
    fi
    source /etc/os-release
    if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
        red "错误: 仅支持 Debian/Ubuntu 系统"
        exit 1
    fi
    log_info "操作系统: $PRETTY_NAME"
}

command_exists() {
    command -v "$1" &>/dev/null
}

press_any_key() {
    plain ""
    yellow "按任意键继续..."
    read -n 1 -s -r
    plain ""
}

# ---------------------------------------------------------------------------
# 验证函数
# ---------------------------------------------------------------------------
validate_domain() {
    local domain="$1"
    if [[ -z "$domain" ]]; then
        return 1
    fi
    if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 0
    fi
    return 1
}

validate_uuid() {
    local uuid="$1"
    if [[ -z "$uuid" ]]; then
        return 1
    fi
    if [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; then
        return 0
    fi
    return 1
}

validate_path() {
    local path="$1"
    if [[ -z "$path" ]]; then
        return 1
    fi
    if [[ "$path" == /* ]]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# 生成函数
# ---------------------------------------------------------------------------
generate_uuids() {
    if command_exists uuidgen; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || \
        python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || \
        python -c "import uuid; print(uuid.uuid4())" 2>/dev/null
    fi
}

generate_reality_keys() {
    if command_exists xray; then
        xray x25519
    else
        # 临时下载 xray 来生成密钥
        local tmp_xray
        tmp_xray="/tmp/xray_tmp_$$"
        mkdir -p "$tmp_xray"
        local arch
        arch=$(uname -m)
        case "$arch" in
            x86_64)  arch="64" ;;
            aarch64) arch="arm64-v8a" ;;
            armv7l)  arch="armv7a" ;;
            *)       arch="64" ;;
        esac
        wget -q -O "$tmp_xray/xray" "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$arch" 2>/dev/null || true
        chmod +x "$tmp_xray/xray" 2>/dev/null || true
        if [[ -x "$tmp_xray/xray" ]]; then
            "$tmp_xray/xray" x25519
        fi
        rm -rf "$tmp_xray"
    fi
}

generate_short_id() {
    openssl rand -hex 4 2>/dev/null || \
    xxd -l 4 -p /dev/urandom 2>/dev/null || \
    od -An -tx4 -N4 /dev/urandom | tr -d ' \n'
}

# ---------------------------------------------------------------------------
# 参数持久化
# ---------------------------------------------------------------------------
save_params() {
    mkdir -p "$(dirname "$PARAMS_FILE")"
    cat > "$PARAMS_FILE" <<EOF
DIRECT_DOMAIN="$DIRECT_DOMAIN"
CDN_DOMAIN="$CDN_DOMAIN"
REALITY_DOMAIN="$REALITY_DOMAIN"
XHTTP_PATH="$XHTTP_PATH"
REALITY_PRIVATE_KEY="$REALITY_PRIVATE_KEY"
REALITY_PUBLIC_KEY="$REALITY_PUBLIC_KEY"
SHORT_ID="$SHORT_ID"
UUID_01="$UUID_01"
UUID_02="$UUID_02"
EOF
    chmod 600 "$PARAMS_FILE"
    log_info "参数已保存到 $PARAMS_FILE"
}

load_params() {
    if [[ -f "$PARAMS_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$PARAMS_FILE"
        log_info "参数已从 $PARAMS_FILE 加载"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# 配置生成函数
# ---------------------------------------------------------------------------
generate_xray_config() {
    log_step "生成 Xray 配置文件..."

    local tmp_config
    tmp_config="/tmp/xray_config_$$.json"

    cat > "$tmp_config" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID_01}",
            "level": 0,
            "email": "vision-user",
            "flow": "xtls-rprx-vision"
          },
          {
            "id": "${UUID_02}",
            "level": 0,
            "email": "xhttp-user"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "dest": "${XHTTP_SOCK}",
            "xver": 0
          }
        ]
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${TLS_SOCK}",
          "xver": 0,
          "serverNames": [
            "${REALITY_DOMAIN}",
            "${CDN_DOMAIN}"
          ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        },
        "sockopt": {
          "tcpFastOpen": true,
          "tcpcongestion": "bbr",
          "tcpMptcp": true,
          "tcpNoDelay": true
        }
      },
      "tag": "REALITY_INBOUND"
    },
    {
      "listen": "${XHTTP_SOCK},0666",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID_02}",
            "level": 0,
            "email": "xhttp-user"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "host": "",
          "path": "${XHTTP_PATH}",
          "mode": "auto",
          "xPaddingObfsMode": true,
          "xPaddingMethod": "tokenish",
          "xPaddingPlacement": "queryInHeader",
          "xPaddingHeader": "X-Cache",
          "xPaddingKey": "_dc",
          "extra": {
            "noSSEHeader": true,
            "scMaxEachPostBytes": 1000000,
            "xPaddingBytes": "100-1000"
          }
        }
      },
      "tag": "XHTTP_INBOUND"
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct", "settings": {} },
    { "protocol": "blackhole", "tag": "blocked", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "blocked" }
    ]
  }
}
EOF

    # 验证 JSON
    if command_exists jq; then
        if jq empty "$tmp_config" 2>/dev/null; then
            mv "$tmp_config" "$XRAY_CONFIG"
            chmod 644 "$XRAY_CONFIG"
            green "Xray 配置文件生成成功"
            log_info "Xray 配置文件已生成: $XRAY_CONFIG"
        else
            red "Xray 配置文件 JSON 格式验证失败"
            log_error "Xray 配置文件 JSON 格式验证失败"
            rm -f "$tmp_config"
            return 1
        fi
    else
        mv "$tmp_config" "$XRAY_CONFIG"
        chmod 644 "$XRAY_CONFIG"
        yellow "jq 未安装，跳过 JSON 验证"
        log_warn "jq 未安装，跳过 JSON 验证"
    fi
}

generate_caddy_config() {
    log_step "生成 Caddy 配置文件..."

    cat > "$CADDY_CONFIG" <<EOF
${DIRECT_DOMAIN}, ${CDN_DOMAIN} {
    bind unix//${TLS_SOCK}

    log {
        output file /var/log/caddy/access.log
    }

    handle ${XHTTP_PATH}/* {
        reverse_proxy unix//${XHTTP_SOCK} {
            transport http {
                versions 2
            }
        }
    }

    handle {
        reverse_proxy 127.0.0.1:${OPENLIST_PORT}
    }
}
EOF

    chmod 644 "$CADDY_CONFIG"
    green "Caddy 配置文件生成成功"
    log_info "Caddy 配置文件已生成: $CADDY_CONFIG"
}

install_openlist() {
    log_step "安装 OpenList 伪装站..."

    if command_exists openlist || [[ -f /usr/local/bin/openlist ]]; then
        yellow "OpenList 已安装，跳过安装"
        log_info "OpenList 已安装"
        return 0
    fi

    local tmp_script
    tmp_script="/tmp/openlist_install_$$.sh"

    yellow "正在下载 OpenList 安装脚本..."
    if ! curl -fsSL "$OPENLIST_INSTALL_SCRIPT" -o "$tmp_script"; then
        yellow "官方源下载失败，尝试 GitHub 直连..."
        curl -fsSL "https://raw.githubusercontent.com/OpenListTeam/OpenList-Resource/refs/heads/main/script/v4.sh" -o "$tmp_script" || {
            red "OpenList 安装脚本下载失败"
            log_error "OpenList 安装脚本下载失败"
            return 1
        }
    fi

    chmod +x "$tmp_script"

    yellow "正在安装 OpenList（默认选项）..."
    # OpenList 脚本通过交互式菜单接受数字输入，传入选项 1 执行安装
    bash "$tmp_script" <<'OPENLIST_INPUT'
1
OPENLIST_INPUT

    rm -f "$tmp_script"
    sleep 2

    if systemctl is-active openlist &>/dev/null; then
        green "OpenList 安装并启动成功"
        log_info "OpenList 已安装并运行"

        yellow "OpenList 管理员密码："
        journalctl -u openlist --no-pager -n 20 | grep -i "password" || true
        systemctl status openlist --no-pager | grep -i "password" || true
    else
        yellow "OpenList 安装完成，但服务未自动启动"
        log_warn "OpenList 服务未自动启动"
    fi

    # OpenList 仅监听 127.0.0.1:5244，通过 Caddy 反代对外提供服务，防止直接暴露
    local openlist_config
    openlist_config="/opt/openlist/data/config.json"
    if [[ -f "$openlist_config" ]] && command_exists jq; then
        local tmp_cfg
        tmp_cfg="/tmp/openlist_cfg_$$.json"
        jq '.scheme.address = "127.0.0.1" | .scheme.http_port = 5244' "$openlist_config" > "$tmp_cfg" 2>/dev/null && mv "$tmp_cfg" "$openlist_config" || true
        systemctl restart openlist 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# 配置验证函数
# ---------------------------------------------------------------------------
validate_xray_config() {
    log_step "验证 Xray 配置..."
    if command_exists xray; then
        if xray run -test -config "$XRAY_CONFIG" 2>&1 | tee -a "$LOG_FILE"; then
            green "Xray 配置验证通过"
            log_info "Xray 配置验证通过"
            return 0
        else
            red "Xray 配置验证失败"
            log_error "Xray 配置验证失败"
            return 1
        fi
    else
        yellow "Xray 未安装，跳过配置验证"
        log_warn "Xray 未安装，跳过配置验证"
        return 0
    fi
}

validate_caddy_config() {
    log_step "验证 Caddy 配置..."
    if command_exists caddy; then
        if caddy validate --config "$CADDY_CONFIG" 2>&1 | tee -a "$LOG_FILE"; then
            green "Caddy 配置验证通过"
            log_info "Caddy 配置验证通过"
            return 0
        else
            red "Caddy 配置验证失败"
            log_error "Caddy 配置验证失败"
            return 1
        fi
    else
        yellow "Caddy 未安装，跳过配置验证"
        log_warn "Caddy 未安装，跳过配置验证"
        return 0
    fi
}

# ---------------------------------------------------------------------------
# 服务管理函数
# ---------------------------------------------------------------------------
start_services() {
    log_step "启动服务..."
    systemctl daemon-reload
    systemctl start xray caddy 2>/dev/null || true
    green "服务已启动"
    log_info "服务已启动"
}

stop_services() {
    log_step "停止服务..."
    systemctl stop xray caddy 2>/dev/null || true
    yellow "服务已停止"
    log_info "服务已停止"
}

restart_services() {
    log_step "重启服务..."
    systemctl daemon-reload
    systemctl restart xray caddy 2>/dev/null || true
    green "服务已重启"
    log_info "服务已重启"
}

check_services() {
    log_step "检查服务状态..."
    local xray_status caddy_status
    xray_status=$(systemctl is-active xray 2>/dev/null || echo "unknown")
    caddy_status=$(systemctl is-active caddy 2>/dev/null || echo "unknown")

    plain ""
    blue "========================================"
    blue "服务状态"
    blue "========================================"
    if [[ "$xray_status" == "active" ]]; then
        green "Xray  : 运行中"
    else
        red "Xray  : $xray_status"
    fi
    if [[ "$caddy_status" == "active" ]]; then
        green "Caddy : 运行中"
    else
        red "Caddy : $caddy_status"
    fi
    blue "========================================"
    plain ""

    log_info "Xray 状态: $xray_status, Caddy 状态: $caddy_status"
}

# ---------------------------------------------------------------------------
# 参数收集函数
# ---------------------------------------------------------------------------
collect_params() {
    log_step "收集配置参数..."
    plain ""
    blue "══════════════════════════════════════════════════════════"
    blue "  请输入配置参数（直接回车使用自动生成的值）"
    blue "══════════════════════════════════════════════════════════"
    plain ""

    # Direct 域名
    while true; do
        read -rp "Direct 域名 (如 direct.example.com): " DIRECT_DOMAIN
        if validate_domain "$DIRECT_DOMAIN"; then
            break
        fi
        red "无效的域名格式，请重新输入"
    done

    # CDN 域名
    while true; do
        read -rp "CDN 域名 (如 cdn.example.com): " CDN_DOMAIN
        if validate_domain "$CDN_DOMAIN"; then
            break
        fi
        red "无效的域名格式，请重新输入"
    done

    # Reality 域名
    while true; do
        read -rp "Reality 域名 (如 reality.example.com): " REALITY_DOMAIN
        if validate_domain "$REALITY_DOMAIN"; then
            break
        fi
        red "无效的域名格式，请重新输入"
    done

    # XHTTP 路径
    while true; do
        read -rp "xhttp 路径 (如 /xhttp-path，必须以 / 开头): " XHTTP_PATH
        if validate_path "$XHTTP_PATH"; then
            break
        fi
        red "路径必须以 / 开头，请重新输入"
    done

    # Reality 私钥
    read -rp "Reality 私钥 (留空则自动生成): " REALITY_PRIVATE_KEY
    if [[ -z "$REALITY_PRIVATE_KEY" ]]; then
        yellow "正在自动生成 Reality 密钥对..."
        local key_output
        key_output=$(generate_reality_keys)
        if [[ -n "$key_output" ]]; then
            REALITY_PRIVATE_KEY=$(echo "$key_output" | grep 'Private key:' | awk '{print $3}')
            REALITY_PUBLIC_KEY=$(echo "$key_output" | grep 'Public key:' | awk '{print $3}')
            green "Reality 密钥对已生成"
        else
            red "Reality 密钥生成失败"
            exit 1
        fi
    else
        read -rp "Reality 公钥: " REALITY_PUBLIC_KEY
    fi

    # Short ID
    read -rp "Short ID (留空则自动生成 8 位十六进制): " SHORT_ID
    if [[ -z "$SHORT_ID" ]]; then
        SHORT_ID=$(generate_short_id)
        green "Short ID 已生成: $SHORT_ID"
    fi

    # UUID_01
    read -rp "UUID_01 Vision 用户 (留空则自动生成): " UUID_01
    if [[ -z "$UUID_01" ]]; then
        UUID_01=$(generate_uuids)
        green "UUID_01 已生成: $UUID_01"
    elif ! validate_uuid "$UUID_01"; then
        yellow "UUID 格式似乎不正确，将继续使用"
    fi

    # UUID_02
    read -rp "UUID_02 xhttp 用户 (留空则自动生成): " UUID_02
    if [[ -z "$UUID_02" ]]; then
        UUID_02=$(generate_uuids)
        green "UUID_02 已生成: $UUID_02"
    elif ! validate_uuid "$UUID_02"; then
        yellow "UUID 格式似乎不正确，将继续使用"
    fi

    log_info "参数收集完成"
}

collect_params_with_defaults() {
    log_step "收集配置参数（带有默认值）..."
    plain ""
    blue "══════════════════════════════════════════════════════════"
    blue "  请修改配置参数（直接回车保留当前值）"
    blue "══════════════════════════════════════════════════════════"
    plain ""

    local input

    # Direct 域名
    while true; do
        read -rp "Direct 域名 [$DIRECT_DOMAIN]: " input
        if [[ -n "$input" ]]; then
            if validate_domain "$input"; then
                DIRECT_DOMAIN="$input"
                break
            fi
            red "无效的域名格式，请重新输入"
        else
            break
        fi
    done

    # CDN 域名
    while true; do
        read -rp "CDN 域名 [$CDN_DOMAIN]: " input
        if [[ -n "$input" ]]; then
            if validate_domain "$input"; then
                CDN_DOMAIN="$input"
                break
            fi
            red "无效的域名格式，请重新输入"
        else
            break
        fi
    done

    # Reality 域名
    while true; do
        read -rp "Reality 域名 [$REALITY_DOMAIN]: " input
        if [[ -n "$input" ]]; then
            if validate_domain "$input"; then
                REALITY_DOMAIN="$input"
                break
            fi
            red "无效的域名格式，请重新输入"
        else
            break
        fi
    done

    # XHTTP 路径
    while true; do
        read -rp "xhttp 路径 [$XHTTP_PATH]: " input
        if [[ -n "$input" ]]; then
            if validate_path "$input"; then
                XHTTP_PATH="$input"
                break
            fi
            red "路径必须以 / 开头，请重新输入"
        else
            break
        fi
    done

    # Reality 私钥
    read -rp "Reality 私钥 [$REALITY_PRIVATE_KEY]: " input
    if [[ -n "$input" ]]; then
        REALITY_PRIVATE_KEY="$input"
        read -rp "Reality 公钥 [$REALITY_PUBLIC_KEY]: " input
        [[ -n "$input" ]] && REALITY_PUBLIC_KEY="$input"
    fi

    # Short ID
    read -rp "Short ID [$SHORT_ID]: " input
    [[ -n "$input" ]] && SHORT_ID="$input"

    # UUID_01
    while true; do
        read -rp "UUID_01 [$UUID_01]: " input
        if [[ -n "$input" ]]; then
            if validate_uuid "$input"; then
                UUID_01="$input"
                break
            fi
            red "无效的 UUID 格式，请重新输入"
        else
            break
        fi
    done

    # UUID_02
    while true; do
        read -rp "UUID_02 [$UUID_02]: " input
        if [[ -n "$input" ]]; then
            if validate_uuid "$input"; then
                UUID_02="$input"
                break
            fi
            red "无效的 UUID 格式，请重新输入"
        else
            break
        fi
    done

    log_info "参数更新完成"
}

# ---------------------------------------------------------------------------
# 显示连接信息
# ---------------------------------------------------------------------------
show_connection_info() {
    local vps_ip
    vps_ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    if [[ -z "$vps_ip" ]]; then
        vps_ip=$(curl -s -4 ifconfig.me 2>/dev/null || echo "未知")
    fi

    plain ""
    green "╔══════════════════════════════════════════════════════════╗"
    green "║          连接信息                                        ║"
    green "╚══════════════════════════════════════════════════════════╝"
    plain ""
    blue "VPS IP:        $vps_ip"
    blue "Direct 域名:   $DIRECT_DOMAIN"
    blue "CDN 域名:      $CDN_DOMAIN"
    blue "Reality 域名:  $REALITY_DOMAIN"
    blue "XHTTP 路径:    $XHTTP_PATH"
    blue "UUID_01:       $UUID_01 (Vision)"
    blue "UUID_02:       $UUID_02 (xhttp)"
    blue "Reality 公钥:  $REALITY_PUBLIC_KEY"
    blue "Short ID:      $SHORT_ID"
    plain ""
    green "╔══════════════════════════════════════════════════════════╗"
    green "║          客户端配置示例 (YAML)                           ║"
    green "╚══════════════════════════════════════════════════════════╝"
    plain ""
    cat <<EOF
# VLESS + Reality + Vision
- name: "Vision-Reality"
  type: vless
  server: ${vps_ip}
  port: 443
  uuid: ${UUID_01}
  network: tcp
  tls: true
  flow: xtls-rprx-vision
  servername: ${REALITY_DOMAIN}
  reality-opts:
    public-key: ${REALITY_PUBLIC_KEY}
    short-id: ${SHORT_ID}
  client-fingerprint: chrome

# VLESS + xhttp
- name: "XHTTP"
  type: vless
  server: ${CDN_DOMAIN}
  port: 443
  uuid: ${UUID_02}
  network: xhttp
  tls: true
  servername: ${CDN_DOMAIN}
  xhttp-opts:
    path: ${XHTTP_PATH}
    mode: auto

# VLESS + Reality + xhttp
- name: "Reality-XHTTP"
  type: vless
  server: ${vps_ip}
  port: 443
  uuid: ${UUID_02}
  network: xhttp
  tls: true
  servername: ${REALITY_DOMAIN}
  reality-opts:
    public-key: ${REALITY_PUBLIC_KEY}
    short-id: ${SHORT_ID}
  xhttp-opts:
    path: ${XHTTP_PATH}
    mode: auto

# VLESS + CDN + xhttp
- name: "CDN-XHTTP"
  type: vless
  server: ${CDN_DOMAIN}
  port: 443
  uuid: ${UUID_02}
  network: xhttp
  tls: true
  servername: ${CDN_DOMAIN}
  xhttp-opts:
    path: ${XHTTP_PATH}
    mode: auto

# VLESS + Reality + Vision (CDN)
- name: "Vision-CDN"
  type: vless
  server: ${CDN_DOMAIN}
  port: 443
  uuid: ${UUID_01}
  network: tcp
  tls: true
  flow: xtls-rprx-vision
  servername: ${REALITY_DOMAIN}
  reality-opts:
    public-key: ${REALITY_PUBLIC_KEY}
    short-id: ${SHORT_ID}
  client-fingerprint: chrome
EOF
    plain ""
    green "══════════════════════════════════════════════════════════"
    plain ""
}

# ---------------------------------------------------------------------------
# 核心功能: 安装
# ---------------------------------------------------------------------------
do_install() {
    log_step "开始安装 Xray + Caddy..."
    check_root
    check_os

    # 1. 安装依赖
    log_step "安装依赖..."
    apt-get update
    apt-get install -y curl jq uuid-runtime wget debian-keyring debian-archive-keyring apt-transport-https openssl gnupg
    green "依赖安装完成"

    # 2. 安装 Xray-core
    log_step "安装 Xray-core..."
    if bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install 2>&1 | tee -a "$LOG_FILE"; then
        green "Xray 安装成功"
    else
        yellow "官方脚本安装失败，尝试手动下载..."
        local arch
        arch=$(uname -m)
        case "$arch" in
            x86_64)  arch="64" ;;
            aarch64) arch="arm64-v8a" ;;
            armv7l)  arch="armv7a" ;;
            *)       arch="64" ;;
        esac
        local latest_tag
        latest_tag=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r '.tag_name')
        local download_url="https://github.com/XTLS/Xray-core/releases/download/${latest_tag}/Xray-linux-${arch}.zip"
        wget -q -O /tmp/xray.zip "$download_url"
        apt-get install -y unzip
        unzip -o /tmp/xray.zip -d /tmp/xray_extract
        mv /tmp/xray_extract/xray /usr/local/bin/xray
        chmod +x /usr/local/bin/xray
        mkdir -p /usr/local/etc/xray /usr/local/share/xray
        green "Xray 手动安装完成"
    fi

    # 3. 安装 Caddy
    log_step "安装 Caddy..."
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
    green "Caddy 安装完成"

    # 4. 创建 caddy 用户
    if ! id caddy &>/dev/null; then
        useradd -r -s /usr/sbin/nologin caddy
        green "用户 caddy 已创建"
    fi

    collect_params

    generate_xray_config
    generate_caddy_config
    install_openlist

    # 8. 设置 systemd 覆盖
    log_step "设置 systemd 覆盖..."
    mkdir -p /etc/systemd/system/xray.service.d
    cat > /etc/systemd/system/xray.service.d/override.conf <<EOF
[Service]
User=caddy
EOF

    # 9. 设置目录权限
    log_step "设置目录权限..."
    mkdir -p "$XRAY_RUN_DIR"
    chown -R caddy:caddy "$XRAY_RUN_DIR"
    chmod 755 "$XRAY_RUN_DIR"
    :
    chown -R caddy:caddy /usr/local/etc/xray
    chown -R caddy:caddy /usr/local/share/xray 2>/dev/null || true

    # 10. 验证配置
    validate_xray_config || true
    validate_caddy_config || true

    # 11. 启动服务
    log_step "启动服务..."
    systemctl daemon-reload
    systemctl enable --now xray caddy
    sleep 2
    check_services

    # 12. 保存参数
    save_params

    # 13. 显示连接信息
    show_connection_info

    green "══════════════════════════════════════════════════════════"
    green "安装完成!"
    green "日志文件: $LOG_FILE"
    green "配置文件: $XRAY_CONFIG"
    green "Caddyfile: $CADDY_CONFIG"
    green "══════════════════════════════════════════════════════════"
    log_step "安装完成"
}

# ---------------------------------------------------------------------------
# 核心功能: 更新配置
# ---------------------------------------------------------------------------
do_update_config() {
    log_step "开始更新配置..."
    check_root

    if ! load_params; then
        red "未找到现有配置，请先运行安装"
        return 1
    fi

    if ! command_exists xray || ! command_exists caddy; then
        red "Xray 或 Caddy 未安装，请先运行安装"
        return 1
    fi

    # 显示当前参数并允许修改
    collect_params_with_defaults

    # 重新生成配置
    generate_xray_config
    generate_caddy_config
    install_openlist

    # 验证配置
    validate_xray_config || true
    validate_caddy_config || true

    # 保存参数
    save_params

    # 重启服务
    restart_services
    sleep 2
    check_services

    # 显示连接信息
    show_connection_info

    green "配置更新完成!"
    log_step "配置更新完成"
}

# ---------------------------------------------------------------------------
# 核心功能: 查看配置
# ---------------------------------------------------------------------------
do_view_config() {
    log_step "查看配置..."

    if ! load_params; then
        red "未找到现有配置，请先运行安装"
        return 1
    fi

    show_connection_info
    press_any_key
}

# ---------------------------------------------------------------------------
# 核心功能: 重启服务
# ---------------------------------------------------------------------------
do_restart() {
    log_step "重启服务..."
    check_root

    systemctl daemon-reload
    restart_services
    sleep 2
    check_services

    log_step "重启完成"
    press_any_key
}

# ---------------------------------------------------------------------------
# 核心功能: 卸载
# ---------------------------------------------------------------------------
do_uninstall() {
    log_step "开始卸载..."
    check_root

    yellow "警告: 此操作将完全移除 Xray 和 Caddy 及其配置"
    read -rp "确定要卸载吗? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        yellow "已取消卸载"
        return 0
    fi

    # 停止并禁用服务
    log_step "停止并禁用服务..."
    systemctl disable --now xray caddy 2>/dev/null || true

    # 卸载 Xray
    log_step "卸载 Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove 2>&1 | tee -a "$LOG_FILE" || true
    rm -f /usr/local/bin/xray 2>/dev/null || true

    # 卸载 Caddy
    log_step "卸载 Caddy..."
    apt-get remove -y caddy 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/caddy-stable.list

    # 删除配置目录
    log_step "删除配置文件..."
    rm -rf /usr/local/etc/xray
    rm -rf /etc/caddy
    rm -rf "$XRAY_RUN_DIR"
    rm -rf /etc/systemd/system/xray.service.d

    log_step "卸载 OpenList..."
    systemctl disable --now openlist 2>/dev/null || true
    if command_exists openlist; then
        openlist uninstall 2>/dev/null || true
    fi
    rm -rf /opt/openlist /usr/local/bin/openlist /etc/systemd/system/openlist.service

    # 可选: 删除 caddy 用户
    read -rp "是否删除 caddy 用户? (y/N): " del_user
    if [[ "$del_user" =~ ^[Yy]$ ]]; then
        userdel caddy 2>/dev/null || true
        yellow "caddy 用户已删除"
    fi

    green "══════════════════════════════════════════════════════════"
    green "卸载完成!"
    green "══════════════════════════════════════════════════════════"
    log_step "卸载完成"
}

# ---------------------------------------------------------------------------
# 主菜单
# ---------------------------------------------------------------------------
show_menu() {
    clear
    blue "╔══════════════════════════════════════════════════════════╗"
    blue "║          Xray + Caddy 一键脚本  ${SCRIPT_VERSION}                     ║"
    blue "║          XTLS(Vision)+Reality & XHTTP 五合一             ║"
    blue "╚══════════════════════════════════════════════════════════╝"
    plain ""
    plain "  1) 安装 Xray 服务端"
    plain "  2) 更新配置"
    plain "  3) 查看配置 / 连接信息"
    plain "  4) 重启服务"
    plain "  5) 卸载 Xray"
    plain "  6) 退出"
    plain ""
}

main() {
    # 先检查 root 权限，避免非 root 用户因日志创建失败而崩溃
    check_root

    # 确保日志目录存在
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"

    log_info "脚本启动: $SCRIPT_NAME $SCRIPT_VERSION"

    while true; do
        show_menu
        read -rp "请选择 [1-6]: " choice
        case "$choice" in
            1)
                do_install
                press_any_key
                ;;
            2)
                do_update_config
                press_any_key
                ;;
            3)
                do_view_config
                press_any_key
                ;;
            4)
                do_restart
                press_any_key
                ;;
            5)
                do_uninstall
                press_any_key
                ;;
            6)
                green "再见!"
                log_info "脚本退出"
                exit 0
                ;;
            *)
                red "无效选项，请重新选择"
                sleep 1
                ;;
        esac
    done
}

main "$@"
