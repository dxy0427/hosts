#!/bin/sh

# Hysteria 2 All-in-One Management Script for Alpine Linux
# Author: Gemini
# Version: 1.3 - Removed qrencode dependency and QR code feature

# --- Colors and Formatting ---
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_NC='\033[0m' # No Color

# --- Configuration ---
HY2_DIR="/etc/hysteria"
HY2_CONFIG_FILE="${HY2_DIR}/config.yaml"
HY2_BIN_FILE="/usr/local/bin/hysteria"
HY2_SERVICE_FILE="/etc/init.d/hysteria"
MANAGER_SHORTCUT="/usr/local/bin/hy2"
IPTABLES_CLEANUP_SCRIPT="${HY2_DIR}/cleanup_iptables.sh"
LATEST_RELEASE_URL="https://api.github.com/repos/apernet/hysteria/releases/latest"

# --- Utility Functions ---
print_error() { echo -e "${C_RED}错误: $1${C_NC}"; }
print_success() { echo -e "${C_GREEN}$1${C_NC}"; }
print_warning() { echo -e "${C_YELLOW}$1${C_NC}"; }
print_info() { echo -e "${C_BLUE}$1${C_NC}"; }

# Pause and wait for user to press Enter
press_any_key() {
  echo ""
  print_warning "按回车键继续..."
  read -r
}

# Pre-run checks
pre_run_checks() {
  if [ "$(id -u)" -ne 0 ]; then
    print_error "此脚本必须以 root 权限运行。"
    exit 1
  fi

  if ! grep -q "Alpine" /etc/os-release; then
    print_error "此脚本仅为 Alpine Linux 设计。"
    exit 1
  fi
  
  print_info "正在更新软件包列表并安装依赖..."
  apk update
  # [FIX v1.3] Removed qrencode from dependencies
  if ! apk add --no-cache curl openssl iptables; then
      print_error "依赖包 (curl, openssl, iptables) 安装失败，请检查网络。"
      exit 1
  fi
  print_success "核心依赖已安装。"
}


# Create a shortcut for this manager script
create_shortcut() {
    if [ ! -f "$MANAGER_SHORTCUT" ]; then
        print_info "正在创建快捷命令 'hy2'..."
        # Use a reliable download source for the shortcut
        cat << EOF > "$MANAGER_SHORTCUT"
#!/bin/sh
wget -O /tmp/hy2.sh https://gist.githubusercontent.com/MoeClub/c64c126b3b2413e5a781f44b415a13c3/raw/hysteria2-alpine-manager.sh && sh /tmp/hy2.sh
EOF
        chmod +x "$MANAGER_SHORTCUT"
        print_success "快捷命令 'hy2' 已创建。您现在可以随时输入 'hy2' 来运行此脚本。"
    fi
}

# --- Core Functions ---

# 1. Installation
install_hysteria() {
  clear
  print_info "Hysteria 2 安装向导"
  echo "----------------------------------------"
  echo "1. 安装最新版本"
  echo "2. 安装指定版本 (例如: 2.3.1)"
  echo "0. 返回主菜单"
  echo "----------------------------------------"
  read -p "请输入您的选择: " choice

  case $choice in
    1)
      print_info "正在获取最新版本信息..."
      DOWNLOAD_URL=$(curl -s $LATEST_RELEASE_URL | grep "browser_download_url" | grep "hysteria-linux-amd64" | cut -d '"' -f 4)
      if [ -z "$DOWNLOAD_URL" ]; then
        print_error "无法获取最新版本下载地址，请检查网络或稍后再试。"
        press_any_key
        return
      fi
      ;;
    2)
      read -p "请输入您想安装的版本号 (例如: 2.3.1): v" version
      if [ -z "$version" ]; then
        print_error "版本号不能为空。"
        press_any_key
        return
      fi
      DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/v${version}/hysteria-linux-amd64"
      ;;
    0) return ;;
    *) print_error "无效输入"; press_any_key; return ;;
  esac

  print_info "正在从以下地址下载 Hysteria 2: $DOWNLOAD_URL"
  if ! curl -fL -o "$HY2_BIN_FILE" "$DOWNLOAD_URL"; then
    print_error "下载失败！请检查 URL 或您的网络连接。"
    press_any_key
    return
  fi
  chmod +x "$HY2_BIN_FILE"
  print_success "Hysteria 2 已成功安装到 $HY2_BIN_FILE"
  press_any_key
}

# 2. Uninstallation
uninstall_hysteria() {
  clear
  print_warning "您确定要完全卸载 Hysteria 2 吗？"
  print_warning "这将删除所有配置文件、服务、证书和端口跳跃规则。"
  read -p "请输入 'yes' 来确认: " confirmation

  if [ "$confirmation" != "yes" ]; then
    print_info "卸载已取消。"
    press_any_key
    return
  fi

  print_info "正在停止并禁用 Hysteria 服务..."
  if [ -f "$HY2_SERVICE_FILE" ]; then
    rc-service hysteria stop
    rc-update del hysteria default
  fi

  print_info "正在执行端口跳跃清理脚本..."
  if [ -f "$IPTABLES_CLEANUP_SCRIPT" ]; then
    sh "$IPTABLES_CLEANUP_SCRIPT"
  fi

  print_info "正在删除所有相关文件..."
  rm -f "$HY2_BIN_FILE"
  rm -f "$HY2_SERVICE_FILE"
  rm -rf "$HY2_DIR"
  
  print_warning "您想要删除 'hy2' 快捷命令吗?"
  read -p "[y/N]: " del_shortcut
  if [ "$del_shortcut" = "y" ] || [ "$del_shortcut" = "Y" ]; then
      rm -f "$MANAGER_SHORTCUT"
      print_info "快捷命令已删除。"
  fi

  print_success "Hysteria 2 已被完全卸载。"
  press_any_key
}

# 3. Configuration Wizard
configure_hysteria() {
  clear
  print_info "Hysteria 2 配置向导"
  echo "----------------------------------------"

  # Gather user input
  read -p "请输入监听端口 [1-65535]: " LISTEN_PORT
  read -p "请输入认证密码 (留空则随机生成): " AUTH_PASSWORD
  [ -z "$AUTH_PASSWORD" ] && AUTH_PASSWORD=$(head -c 16 /dev/urandom | base64 | tr -d '=+/' )
  read -p "请输入伪装的 URL (例如: https://bing.com): " MASQUERADE_URL
  
  # Advanced options
  read -p "是否开启 Brutal 模式? [y/N]: " ENABLE_BRUTAL
  IGNORE_CLIENT_BANDWIDTH=$([ "$ENABLE_BRUTAL" = "y" ] && echo "false" || echo "true")
  
  read -p "是否开启流量混淆 (Obfuscation)? [y/N]: " ENABLE_OBFS
  OBFS_CONFIG=""
  OBFS_SCHEME=""
  if [ "$ENABLE_OBFS" = "y" ]; then
    read -p "请输入混淆密码: " OBFS_PASSWORD
    OBFS_CONFIG="obfs:\n  type: salamander\n  salamander:\n    password: ${OBFS_PASSWORD}"
    # URL encode the obfs password
    OBFS_PASS_ENCODED=$(echo -n "$OBFS_PASSWORD" | xxd -p | tr -d '\n')
    OBFS_SCHEME="&obfs=salamander&obfs-password=${OBFS_PASS_ENCODED}"
  fi

  read -p "是否开启协议嗅探 (Sniffing)? [y/N]: " ENABLE_SNIFF
  SNIFF_CONFIG=""
  [ "$ENABLE_SNIFF" = "y" ] && SNIFF_CONFIG="sniff:\n  enabled: true"

  # Certificate Management
  clear
  print_info "请选择证书类型:"
  echo "1. 自动申请证书 (ACME / Let's Encrypt, 需要一个域名)"
  echo "2. 生成自签名证书 (无需域名)"
  echo "3. 使用现有的证书文件"
  read -p "请输入您的选择: " cert_choice
  
  ACME_CONFIG=""
  TLS_CONFIG=""
  INSECURE="0"
  SNI=""
  SERVER_NAME=""

  case $cert_choice in
    1)
      read -p "请输入您的域名: " CERT_DOMAIN
      read -p "请输入您的邮箱: " CERT_EMAIL
      ACME_CONFIG="acme:\n  domains:\n    - ${CERT_DOMAIN}\n  email: ${CERT_EMAIL}"
      SNI="$CERT_DOMAIN"
      SERVER_NAME="$CERT_DOMAIN"
      ;;
    2)
      read -p "请输入用于证书的域名 (默认 bing.com): " CERT_CN
      [ -z "$CERT_CN" ] && CERT_CN="bing.com"
      mkdir -p "$HY2_DIR"
      openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "${HY2_DIR}/server.key" -out "${HY2_DIR}/server.crt" \
        -subj "/CN=${CERT_CN}" -days 3650
      TLS_CONFIG="tls:\n  cert: ${HY2_DIR}/server.crt\n  key: ${HY2_DIR}/server.key"
      INSECURE="1"
      SNI="$CERT_CN"
      read -p "请输入服务器的 IP 地址或域名 (用于客户端连接): " SERVER_NAME
      ;;
    3)
      read -p "请输入证书文件 (.crt) 的完整路径: " CERT_PATH
      read -p "请输入私钥文件 (.key) 的完整路径: " KEY_PATH
      read -p "请输入您的域名 (用于 SNI): " CERT_DOMAIN
      TLS_CONFIG="tls:\n  cert: ${CERT_PATH}\n  key: ${KEY_PATH}"
      SNI="$CERT_DOMAIN"
      SERVER_NAME="$CERT_DOMAIN"
      ;;
    *) print_error "无效选择，配置中止。"; press_any_key; return ;;
  esac

  # Port Hopping
  read -p "是否开启端口跳跃 (Port Hopping)? [y/N]: " ENABLE_PORT_HOPPING
  JUMP_PORTS_SCHEME=""
  if [ "$ENABLE_PORT_HOPPING" = "y" ]; then
    ip -o addr | awk '{print $2, $4}' | grep -v 'lo'
    read -p "请从上面选择您的网络接口名称 (例如: eth0): " IFACE
    read -p "请输入起始端口: " START_PORT
    read -p "请输入结束端口: " END_PORT
    
    print_info "正在配置 iptables 规则..."
    iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport "${START_PORT}:${END_PORT}" -j REDIRECT --to-ports "$LISTEN_PORT"
    # Create cleanup script
    echo "#!/bin/sh" > "$IPTABLES_CLEANUP_SCRIPT"
    echo "iptables -t nat -D PREROUTING -i \"$IFACE\" -p udp --dport \"${START_PORT}:${END_PORT}\" -j REDIRECT --to-ports \"$LISTEN_PORT\"" >> "$IPTABLES_CLEANUP_SCRIPT"
    chmod +x "$IPTABLES_CLEANUP_SCRIPT"
    print_success "iptables 规则已添加，清理脚本已创建。"
    JUMP_PORTS_SCHEME="&mport=${START_PORT}-${END_PORT}"
  fi

  # Build config.yaml
  mkdir -p "$HY2_DIR"
  cat << EOF > "$HY2_CONFIG_FILE"
# Generated by hy2-alpine-manager
listen: :${LISTEN_PORT}

${ACME_CONFIG}
${TLS_CONFIG}

auth:
  type: password
  password: ${AUTH_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: ${MASQUERADE_URL}
    rewriteHost: true

# Brutal: ignoreClientBandwidth: false
# Normal: ignoreClientBandwidth: true
ignoreClientBandwidth: ${IGNORE_CLIENT_BANDWIDTH}

${OBFS_CONFIG}
${SNIFF_CONFIG}
EOF

  print_success "配置文件已生成到 $HY2_CONFIG_FILE"
  
  # Generate Client Config
  clear
  print_info "客户端配置信息"
  echo "----------------------------------------"
  # URL encode password
  URL_ENCODED_PASS=$(echo -n "$AUTH_PASSWORD" | xxd -p -c 256 | tr -d '\n' | sed 's/\(..\)/%\1/g')
  SHARE_LINK="hysteria2://${URL_ENCODED_PASS}@${SERVER_NAME}:${LISTEN_PORT}?sni=${SNI}&insecure=${INSECURE}${OBFS_SCHEME}${JUMP_PORTS_SCHEME}#Alpine-HY2"
  
  echo "分享链接 (复制到 v2rayN / NekoBox 等客户端):"
  print_success "$SHARE_LINK"
  echo ""
  
  # [FIX v1.3] QR code generation removed.
  
  echo "----------------------------------------"
  
  # Create OpenRC Service
  create_openrc_service

  press_any_key
}

# Create OpenRC service file and start the service
create_openrc_service() {
    print_info "正在创建 OpenRC 启动脚本..."
    cat << EOF > "$HY2_SERVICE_FILE"
#!/sbin/openrc-run

name="hysteria"
command="${HY2_BIN_FILE}"
command_args="server --config ${HY2_CONFIG_FILE}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
  need net
  after net
}
EOF
    chmod +x "$HY2_SERVICE_FILE"
    
    print_info "正在启用并重启 Hysteria 服务..."
    rc-update add hysteria default
    rc-service hysteria restart
    
    sleep 2
    rc-service hysteria status
}

# 4. Service Management
manage_service() {
  if [ ! -f "$HY2_BIN_FILE" ]; then
    print_error "Hysteria 尚未安装。"
    press_any_key
    return
  fi

  while true; do
    clear
    print_info "Hysteria 2 服务管理"
    echo "----------------------------------------"
    echo "1. 启动服务"
    echo "2. 停止服务"
    echo "3. 重启服务"
    echo "4. 查看状态"
    echo "5. 查看日志"
    echo "6. 查看版本"
    echo "0. 返回主菜单"
    echo "----------------------------------------"
    read -p "请输入您的选择: " choice

    case $choice in
      1) rc-service hysteria start ;;
      2) rc-service hysteria stop ;;
      3) rc-service hysteria restart ;;
      4) rc-service hysteria status ;;
      5) print_warning "正在显示相关日志 (按 Ctrl+C 退出)..." ; sleep 1; tail -f /var/log/messages | grep hysteria ;;
      6) "$HY2_BIN_FILE" version ;;
      0) break ;;
      *) print_error "无效输入" ;;
    esac
    [ "$choice" != "5" ] && press_any_key
  done
}

# 5. Performance Optimization
optimize_performance() {
  clear
  print_info "性能优化"
  print_warning "此功能将下载并运行来自 'ylx2016' 的 'Linux-NetSpeed' 脚本。"
  print_warning "它会提供更换内核（如BBR、Xanmod）等功能，请确保您了解其作用。"
  read -p "是否继续? [y/N]: " choice
  if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
    wget -O tcpx.sh "https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcpx.sh"
    chmod +x tcpx.sh
    ./tcpx.sh
  else
    print_info "操作已取消。"
  fi
  press_any_key
}


# --- Main Menu ---
main_menu() {
  # Run pre-checks only once at the beginning
  if [ -z "$PRE_CHECKS_DONE" ]; then
      pre_run_checks
      create_shortcut
      export PRE_CHECKS_DONE=1
  fi
  
  while true; do
    clear
    echo "========================================"
    print_info "  Hysteria 2 一站式管理脚本 (Alpine)"
    echo "========================================"
    if [ -f "$HY2_BIN_FILE" ]; then
        VERSION=$("$HY2_BIN_FILE" version | grep Version | awk '{print $2}')
        print_success "  已安装版本: $VERSION"
    else
        print_warning "  状态: Hysteria 尚未安装"
    fi
    echo "----------------------------------------"
    echo "1. 安装 / 更新 Hysteria 2"
    echo "2. 卸载 Hysteria 2"
    echo "3. 配置 Hysteria 2 (会覆盖现有配置)"
    echo "4. 服务管理"
    echo "5. 性能优化 (BBR/Xanmod 内核)"
    echo "0. 退出脚本"
    echo "----------------------------------------"
    read -p "请输入您的选择: " choice

    case $choice in
      1) install_hysteria ;;
      2) uninstall_hysteria ;;
      3) configure_hysteria ;;
      4) manage_service ;;
      5) optimize_performance ;;
      0) exit 0 ;;
      *) print_error "无效输入" ; press_any_key ;;
    esac
  done
}

main_menu