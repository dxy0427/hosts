#!/bin/bash

# Color definitions for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "$1"
}

log_success() {
    echo -e "${GREEN}$1${NC}"
}

log_error() {
    echo -e "${RED}$1${NC}"
}

log_step() {
    echo -e "${YELLOW}$1${NC}"
}


# Global variables
INSTALL_DIR="/opt/komari"
DATA_DIR="/opt/komari"
SERVICE_NAME="komari"
BINARY_PATH="$INSTALL_DIR/komari"
LOG_FILE="/var/log/${SERVICE_NAME}.log"
DEFAULT_PORT="25774"
LISTEN_PORT=""

# Show banner
show_banner() {
    clear
    echo "=============================================================="
    echo "            Komari Monitoring System Installer"
    echo "       (Alpine Linux / OpenRC compatible version)"
    echo "       https://github.com/komari-monitor/komari"
    echo "=============================================================="
    echo
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 权限运行此脚本"
        exit 1
    fi
}

# Check for OpenRC
check_openrc() {
    if ! command -v rc-service >/dev/null 2>&1; then
        return 1
    else
        return 0
    fi
}

# Detect system architecture
detect_arch() {
    local arch=$(uname -m)
    case $arch in
        x86_64)
            echo "amd64"
            ;;
        aarch64)
            echo "arm64"
            ;;
        i386|i686)
            echo "386"
            ;;
        riscv64)
            echo "riscv64"
            ;;
        *)
            log_error "不支持的架构: $arch"
            exit 1
            ;;
    esac
}

# Check if Komari is already installed
is_installed() {
    if [ -f "$BINARY_PATH" ]; then
        return 0
    else
        return 1
    fi
}

# Install dependencies
install_dependencies() {
    log_step "检查并安装依赖..."

    if command -v apk >/dev/null 2>&1; then
        log_info "使用 apk 更新并安装依赖 (curl, bash)..."
        apk update
        apk add curl bash
    else
        log_error "未找到 apk 包管理器，此脚本专为 Alpine Linux 设计。"
        log_error "请手动安装 'curl' 和 'bash' 后重试。"
        exit 1
    fi
}

# Binary installation
install_binary() {
    log_step "开始二进制安装..."

    if is_installed; then
        log_info "Komari 已安装。要升级，请使用升级选项。"
        return
    fi

    while true; do
        read -p "请输入监听端口 [默认: $DEFAULT_PORT]: " input_port
        if [[ -z "$input_port" ]]; then
            LISTEN_PORT="$DEFAULT_PORT"
            break
        elif [[ "$input_port" =~ ^[0-9]+$ ]] && (( input_port >= 1 && input_port <= 65535 )); then
            LISTEN_PORT="$input_port"
            break
        else
            log_error "端口号无效，请输入 1-65535 之间的数字。"
        fi
    done

    install_dependencies

    local arch=$(detect_arch)
    log_info "检测到架构: $arch"

    log_step "创建安装目录: $INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    log_step "创建数据目录: $DATA_DIR"
    mkdir -p "$DATA_DIR"

    local file_name="komari-linux-${arch}"
    local download_url="https://github.com/komari-monitor/komari/releases/latest/download/${file_name}"

    log_step "下载 Komari 二进制文件..."
    log_info "URL: $download_url"

    if ! curl -L -o "$BINARY_PATH" "$download_url"; then
        log_error "下载失败"
        return 1
    fi

    chmod +x "$BINARY_PATH"
    log_success "Komari 二进制文件安装完成: $BINARY_PATH"

    if ! check_openrc; then
        log_step "警告：未检测到 OpenRC，跳过服务创建。"
        log_step "您可以从命令行手动运行 Komari："
        log_step "    $BINARY_PATH server -l [::]:$LISTEN_PORT"
        echo
        log_success "安装完成！"
        return
    fi

    create_openrc_service "$LISTEN_PORT"

    rc-update add ${SERVICE_NAME} default
    rc-service ${SERVICE_NAME} start

    if rc-service ${SERVICE_NAME} status >/dev/null 2>&1; then
        log_success "Komari 服务启动成功"

        log_step "正在获取初始密码..."
        sleep 5
        local password=$(grep "admin account created." "$LOG_FILE" | tail -n 1 | sed -e 's/.*admin account created.//')
        if [ -z "$password" ]; then
            log_error "未能获取初始密码，请检查日志: $LOG_FILE"
        fi
        show_access_info "$password" "$LISTEN_PORT"
    else
        log_error "Komari 服务启动失败"
        log_info "查看日志: tail -f $LOG_FILE"
        return 1
    fi
}

# Create OpenRC service file
create_openrc_service() {
    local port="$1"
    log_step "创建 OpenRC 服务..."

    local service_file="/etc/init.d/${SERVICE_NAME}"
    cat > "$service_file" << EOF
#!/sbin/openrc-run

description="Komari Monitor Service"
command="${BINARY_PATH}"
# Listen on all IPv4 and IPv6 addresses for maximum compatibility
command_args="server -l [::]:${port}"
command_user="root"
directory="${DATA_DIR}"
pidfile="/run/${SERVICE_NAME}.pid"

# Correctly tell OpenRC to run the command in the background.
command_background="true"

# Because of command_background=true, these log redirection options will work.
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"

depend() {
    need net
    after net
}
EOF

    chmod +x "$service_file"
    touch "$LOG_FILE"
    chown root:root "$LOG_FILE"
    log_success "OpenRC 服务文件创建完成: $service_file"
}

# Show access information
show_access_info() {
    local password=$1
    local port=${2:-$DEFAULT_PORT}
    local ipv4_address=""
    local ipv6_address=""

    # Detect the primary public/non-local IPv4 address
    ipv4_address=$(ip -4 addr show | grep 'inet' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d'/' -f1 | head -n 1)

    # Detect the primary global IPv6 address
    ipv6_address=$(ip -6 addr show | grep 'inet6' | grep 'global' | awk '{print $2}' | cut -d'/' -f1 | head -n 1)

    echo
    log_success "安装完成！"
    echo
    log_info "访问信息："

    # Display IPv4 URL if found
    if [ -n "$ipv4_address" ]; then
        log_info "  URL (IPv4): http://${ipv4_address}:${port}"
    fi

    # Display IPv6 URL if found
    if [ -n "$ipv6_address" ]; then
        log_info "  URL (IPv6): http://[${ipv6_address}]:${port}"
    fi

    # Fallback message if no IPs were detected
    if [ -z "$ipv4_address" ] && [ -z "$ipv6_address" ]; then
        log_info "  URL: <无法自动检测IP，请手动查看并访问 http://<your-ip>:${port}>"
    fi

    if [ -n "$password" ]; then
        log_info "初始登录信息（仅显示一次）: $password"
    fi
    echo
    log_info "服务管理命令 (OpenRC):"
    log_info "  状态:  rc-service $SERVICE_NAME status"
    log_info "  启动:  rc-service $SERVICE_NAME start"
    log_info "  停止:  rc-service $SERVICE_NAME stop"
    log_info "  重启: rc-service $SERVICE_NAME restart"
    log_info "  日志:  tail -f $LOG_FILE"
}

# Upgrade function
upgrade_komari() {
    log_step "升级 Komari..."

    if ! is_installed; then log_error "Komari 未安装。请先安装它。"; return 1; fi
    if ! check_openrc; then log_error "未检测到 OpenRC。无法管理服务。"; return 1; fi

    log_step "停止 Komari 服务..."
    rc-service ${SERVICE_NAME} stop

    log_step "备份当前二进制文件..."
    cp "$BINARY_PATH" "${BINARY_PATH}.backup.$(date +%Y%m%d_%H%M%S)"

    local arch=$(detect_arch)
    local file_name="komari-linux-${arch}"
    local download_url="https://github.com/komari-monitor/komari/releases/latest/download/${file_name}"

    log_step "下载最新版本..."
    if ! curl -L -o "$BINARY_PATH" "$download_url"; then
        log_error "下载失败，正在从备份恢复"
        mv "${BINARY_PATH}.backup."* "$BINARY_PATH"
        rc-service ${SERVICE_NAME} start
        return 1
    fi

    chmod +x "$BINARY_PATH"

    log_step "重启 Komari 服务..."
    rc-service ${SERVICE_NAME} start

    if rc-service ${SERVICE_NAME} status >/dev/null 2>&1; then
        log_success "Komari 升级成功"
    else
        log_error "服务在升级后未能启动"
    fi
}

# Uninstall function
uninstall_komari() {
    log_step "卸载 Komari..."

    if ! is_installed; then log_info "Komari 未安装"; return 0; fi

    read -p "这将删除 Komari。您确定吗？(Y/n): " confirm
    if [[ $confirm =~ ^[Nn]$ ]]; then log_info "卸载已取消"; return 0; fi

    if check_openrc; then
        log_step "停止并禁用服务..."
        rc-service ${SERVICE_NAME} stop >/dev/null 2>&1
        rc-update del ${SERVICE_NAME} default >/dev/null 2>&1
        rm -f "/etc/init.d/${SERVICE_NAME}"
        log_success "OpenRC 服务已删除"
    fi

    log_step "删除二进制文件和日志..."
    rm -f "$BINARY_PATH"
    rm -f "$LOG_FILE"
    rmdir "$INSTALL_DIR" 2>/dev/null || log_info "安装目录 $INSTALL_DIR 不为空，未删除"
    log_success "Komari 二进制文件和日志已删除"

    log_success "Komari 卸载完成"
    log_info "数据文件保留在 $DATA_DIR"
}

# Show service status
show_status() {
    if ! is_installed; then log_error "Komari 未安装"; return; fi
    if ! check_openrc; then log_error "未检测到 OpenRC。无法获取服务状态。"; return; fi
    log_step "Komari 服务状态:"
    rc-service ${SERVICE_NAME} status
}

# Show service logs
show_logs() {
    if ! is_installed; then log_error "Komari 未安装"; return; fi
    if [ ! -f "$LOG_FILE" ]; then log_error "日志文件不存在: $LOG_FILE"; return; fi
    log_step "查看 Komari 服务日志 (按 Ctrl+C 退出)..."
    tail -f "$LOG_FILE"
}

# Restart service
restart_service() {
    if ! is_installed; then log_error "Komari 未安装"; return; fi
    if ! check_openrc; then log_error "未检测到 OpenRC。无法重启服务。"; return; fi
    log_step "重启 Komari 服务..."
    rc-service ${SERVICE_NAME} restart
    if rc-service ${SERVICE_NAME} status >/dev/null 2>&1; then
        log_success "服务重启成功"
    else
        log_error "服务重启失败"
    fi
}

# Stop service
stop_service() {
    if ! is_installed; then log_error "Komari 未安装"; return; fi
    if ! check_openrc; then log_error "未检测到 OpenRC。无法停止服务。"; return; fi
    log_step "停止 Komari 服务..."
    rc-service ${SERVICE_NAME} stop
    log_success "服务已停止"
}

# Main menu
main_menu() {
    show_banner
    echo "请选择操作："
    echo "  1) 安装 Komari"
    echo "  2) 升级 Komari"
    echo "  3) 卸载 Komari"
    echo "  4) 查看状态"
    echo "  5) 查看日志"
    echo "  6) 重启服务"
    echo "  7) 停止服务"
    echo "  8) 退出"
    echo

    read -p "输入选项 [1-8]: " choice

    case $choice in
        1) install_binary ;;
        2) upgrade_komari ;;
        3) uninstall_komari ;;
        4) show_status ;;
        5) show_logs ;;
        6) restart_service ;;
        7) stop_service ;;
        8) exit 0 ;;
        *) log_error "无效选项" ;;
    esac
}

# Main execution
check_root
main_menu