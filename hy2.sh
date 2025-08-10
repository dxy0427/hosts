#!/bin/sh

# Hysteria 2 Management Script for Alpine Linux (v1.6)
# FIX: Correctly generate multi-line YAML config snippets.

# --- Formatting ---
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_NC='\033[0m'

# --- Configuration ---
HY2_DIR="/etc/hysteria"
HY2_CONFIG_FILE="${HY2_DIR}/config.yaml"
HY2_BIN_FILE="/usr/local/bin/hysteria"
HY2_SERVICE_FILE="/etc/init.d/hysteria"
MANAGER_SHORTCUT="/usr/local/bin/hy2"
IPTABLES_CLEANUP_SCRIPT="${HY2_DIR}/cleanup_iptables.sh"

# --- Utility Functions ---
print_error() { echo -e "${C_RED}错误: $1${C_NC}"; }
print_success() { echo -e "${C_GREEN}$1${C_NC}"; }
print_warning() { echo -e "${C_YELLOW}$1${C_NC}"; }
print_info() { echo -e "${C_BLUE}$1${C_NC}"; }

press_any_key() {
  echo ""
  print_warning "按回车键继续..."
  read -r
}

# --- System Checks and Setup ---
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
  if ! apk add --no-cache curl openssl iptables; then
      print_error "依赖包 (curl, openssl, iptables) 安装失败，请检查网络。"
      exit 1
  fi
  print_success "核心依赖已安装。"
}

create_shortcut() {
    if [ ! -f "$MANAGER_SHORTCUT" ]; then
        print_info "正在创建快捷命令 'hy2'..."
        cat << EOF > "$MANAGER_SHORTCUT"
#!/bin/sh
wget -O /tmp/hy2.sh https://gist.githubusercontent.com/MoeClub/c64c126b3b2413e5a781f44b415a13c3/raw/hysteria2-alpine-manager.sh && sh /tmp/hy2.sh
EOF
        chmod +x "$MANAGER_SHORTCUT"
        print_success "快捷命令 'hy2' 已创建。您现在可以随时输入 'hy2' 来运行此脚本。"
    fi
}

# --- Core Functions ---
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
      DOWNLOAD_URL="https://download.hysteria.network/app/latest/hysteria-linux-amd64"
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

uninstall_hysteria() {
  clear
  print_warning "您确定要完全卸载 Hysteria 2 吗？"
  read -p "请输入 'yes' 来确认: " confirmation

  if [ "$confirmation" != "yes" ]; then
    print_info "卸载已取消。"
    press_any_key
    return
  fi

  if [ -f "$HY2_SERVICE_FILE" ]; then rc-service hysteria stop; rc-update del hysteria default; fi
  if [ -f "$IPTABLES_CLEANUP_SCRIPT" ]; then sh "$IPTABLES_CLEANUP_SCRIPT"; fi
  rm -f "$HY2_BIN_FILE" "$HY2_SERVICE_FILE"
  rm -rf "$HY2_DIR"
  
  read -p "是否删除 'hy2' 快捷命令? [y/N]: " del_shortcut
  if [ "$del_shortcut" = "y" ] || [ "$del_shortcut" = "Y" ]; then rm -f "$MANAGER_SHORTCUT"; fi

  print_success "Hysteria 2 已被完全卸载。"
  press_any_key
}

configure_hysteria() {
  clear
  print_info "Hysteria 2 配置向导"
  echo "----------------------------------------"

  read -p "请输入监听端口 [1-65535]: " LISTEN_PORT
  read -p "请输入认证密码 (留空则随机生成): " AUTH_PASSWORD
  [ -z "$AUTH_PASSWORD" ] && AUTH_PASSWORD=$(head -c 16 /dev/urandom | base64 | tr -d '=+/' )
  read -p "请输入伪装的 URL (例如: https://bing.com): " MASQUERADE_URL
  
  read -p "是否开启 Brutal 模式? [y/N]: " ENABLE_BRUTAL
  IGNORE_CLIENT_BANDWIDTH=$([ "$ENABLE_BRUTAL" = "y" ] && echo "false" || echo "true")
  
  read -p "是否开启流量混淆 (Obfuscation)? [y/N]: " ENABLE_OBFS
  OBFS_CONFIG=""
  OBFS_SCHEME=""
  if [ "$ENABLE_OBFS" = "y" ]; then
    read -p "请输入混淆密码: " OBFS_PASSWORD
    # [FIX v1.6] Use proper multi-line string assignment for YAML
    OBFS_CONFIG="obfs:
  type: salamander
  salamander:
    password: ${OBFS_PASSWORD}"
    OBFS_PASS_ENCODED=$(echo -n "$OBFS_PASSWORD" | xxd -p | tr -d '\n')
    OBFS_SCHEME="&obfs=salamander&obfs-password=${OBFS_PASS_ENCODED}"
  fi

  read -p "是否开启协议嗅探 (Sniffing)? [y/N]: " ENABLE_SNIFF
  SNIFF_CONFIG=""
  # [FIX v1.6] Use proper multi-line string assignment for YAML
  [ "$ENABLE_SNIFF" = "y" ] && SNIFF_CONFIG="sniff:\n  enabled: true"

  clear
  print_info "请选择证书类型:"
  echo "1. 自动申请证书 (ACME)"
  echo "2. 生成自签名证书"
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
      # [FIX v1.6] Use proper multi-line string assignment for YAML
      ACME_CONFIG="acme:
  domains:
    - ${CERT_DOMAIN}
  email: ${CERT_EMAIL}"
      SNI="$CERT_DOMAIN"; SERVER_NAME="$CERT_DOMAIN"
      ;;
    2)
      read -p "请输入用于证书的域名 (默认 bing.com): " CERT_CN
      [ -z "$CERT_CN" ] && CERT_CN="bing.com"
      mkdir -p "$HY2_DIR"
      openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "${HY2_DIR}/server.key" -out "${HY2_DIR}/server.crt" \
        -subj "/CN=${CERT_CN}" -days 3650
      # [FIX v1.6] Use proper multi-line string assignment for YAML
      TLS_CONFIG="tls:
  cert: ${HY2_DIR}/server.crt
  key: ${HY2_DIR}/server.key"
      INSECURE="1"; SNI="$CERT_CN"
      read -p "请输入服务器的 IP 地址或域名 (用于客户端连接): " SERVER_NAME
      ;;
    3)
      read -p "请输入证书文件 (.crt) 的完整路径: " CERT_PATH
      read -p "请输入私钥文件 (.key) 的完整路径: " KEY_PATH
      read -p "请输入您的域名 (用于 SNI): " CERT_DOMAIN
      # [FIX v1.6] Use proper multi-line string assignment for YAML
      TLS_CONFIG="tls:
  cert: ${CERT_PATH}
  key: ${KEY_PATH}"
      SNI="$CERT_DOMAIN"; SERVER_NAME="$CERT_DOMAIN"
      ;;
    *) print_error "无效选择，配置中止。"; press_any_key; return ;;
  esac

  read -p "是否开启端口跳跃 (Port Hopping)? [y/N]: " ENABLE_PORT_HOPPING
  JUMP_PORTS_SCHEME=""
  if [ "$ENABLE_PORT_HOPPING" = "y" ]; then
    ip -o addr | awk '{print $2, $4}' | grep -v 'lo'
    read -p "请从上面选择您的网络接口名称 (例如: eth0): " IFACE
    read -p "请输入起始端口: " START_PORT
    read -p "请输入结束端口: " END_PORT
    
    iptables -t nat -A PREROUTING -i "$IFACE" -p udp --dport "${START_PORT}:${END_PORT}" -j REDIRECT --to-ports "$LISTEN_PORT"
    echo "#!/bin/sh" > "$IPTABLES_CLEANUP_SCRIPT"
    echo "iptables -t nat -D PREROUTING -i \"$IFACE\" -p udp --dport \"${START_PORT}:${END_PORT}\" -j REDIRECT --to-ports \"$LISTEN_PORT\"" >> "$IPTABLES_CLEANUP_SCRIPT"
    chmod +x "$IPTABLES_CLEANUP_SCRIPT"
    JUMP_PORTS_SCHEME="&mport=${START_PORT}-${END_PORT}"
  fi

  mkdir -p "$HY2_DIR"
  cat << EOF > "$HY2_CONFIG_FILE"
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

ignoreClientBandwidth: ${IGNORE_CLIENT_BANDWIDTH}

${OBFS_CONFIG}
${SNIFF_CONFIG}
EOF

  print_success "配置文件已生成。"
  
  clear
  print_info "客户端配置信息"
  URL_ENCODED_PASS=$(echo -n "$AUTH_PASSWORD" | xxd -p -c 256 | tr -d '\n' | sed 's/\(..\)/%\1/g')
  SHARE_LINK="hysteria2://${URL_ENCODED_PASS}@${SERVER_NAME}:${LISTEN_PORT}?sni=${SNI}&insecure=${INSECURE}${OBFS_SCHEME}${JUMP_PORTS_SCHEME}#Alpine-HY2"
  echo "----------------------------------------"
  print_success "$SHARE_LINK"
  echo "----------------------------------------"
  
  create_openrc_service
  press_any_key
}

create_openrc_service() {
    cat << EOF > "$HY2_SERVICE_FILE"
#!/sbin/openrc-run
name="hysteria"
command="${HY2_BIN_FILE}"
command_args="server --config ${HY2_CONFIG_FILE}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
depend() { need net; after net; }
EOF
    chmod +x "$HY2_SERVICE_FILE"
    rc-update add hysteria default
    rc-service hysteria restart
    sleep 2
    rc-service hysteria status
}

manage_service() {
  if [ ! -f "$HY2_BIN_FILE" ]; then print_error "Hysteria 尚未安装。"; press_any_key; return; fi
  while true; do
    clear; print_info "Hysteria 2 服务管理"
    echo "1. 启动  2. 停止  3. 重启  4. 状态  5. 日志  6. 版本  0. 返回"
    read -p "请输入您的选择: " choice
    case $choice in
      1) rc-service hysteria start ;;
      2) rc-service hysteria stop ;;
      3) rc-service hysteria restart ;;
      4) rc-service hysteria status ;;
      5) tail -f /var/log/messages | grep hysteria ;;
      6) "$HY2_BIN_FILE" version ;;
      0) break ;;
    esac
    [ "$choice" != "5" ] && press_any_key
  done
}

optimize_performance() {
  read -p "此功能将运行'ylx2016'的'Linux-NetSpeed'脚本, 是否继续? [y/N]: " choice
  if [ "$choice" = "y" ]; then
    wget -O tcpx.sh "https://github.com/ylx2016/Linux-NetSpeed/raw/master/tcpx.sh" && chmod +x tcpx.sh && ./tcpx.sh
  fi
  press_any_key
}

# --- Main Menu ---
main_menu() {
  [ -z "$PRE_CHECKS_DONE" ] && pre_run_checks && create_shortcut && export PRE_CHECKS_DONE=1
  while true; do
    clear
    echo "========================================"
    print_info "  Hysteria 2 一站式管理脚本 (Alpine)"
    if [ -f "$HY2_BIN_FILE" ]; then
        VERSION=$("$HY2_BIN_FILE" version 2>/dev/null | grep Version | awk '{print $2}')
        print_success "  已安装版本: $VERSION"
    else
        print_warning "  状态: Hysteria 尚未安装"
    fi
    echo "----------------------------------------"
    echo "1. 安装/更新   2. 卸载   3. 配置   4. 服务管理   5. 性能优化   0. 退出"
    read -p "请输入您的选择: " choice

    case $choice in
      1) install_hysteria ;;
      2) uninstall_hysteria ;;
      3) configure_hysteria ;;
      4) manage_service ;;
      5) optimize_performance ;;
      0) exit 0 ;;
    esac
  done
}

main_menu