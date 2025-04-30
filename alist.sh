#!/bin/bash
###############################################################################
# Alist Manager Script
# Version: 1.4.0
# Last Updated: 2025-04-30
# Description: 支持快捷键运行，包含完整管理功能
# Usage: ./alist.sh 或 ln -s ./alist.sh /usr/local/bin/alist 后直接输入 alist
# Author: 优化快捷键与菜单逻辑，增强用户体验
###############################################################################

# 全局配置
DOWNLOAD_DIR="/opt/alist"
ALIST_BINARY="$DOWNLOAD_DIR/alist"
SUPERVISOR_CONF="/etc/supervisord/conf.d/alist.ini"
SCRIPT_NAME=$(basename "$0")
LOG_FILE="/var/log/alist_manager.log"

# 颜色定义
RED='\e[1;31m'
GREEN='\e[1;32m'
YELLOW='\e[1;33m'
RESET='\e[0m'

# 日志记录函数
log_action() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# 检查 root 权限
check_root() {
    [[ $EUID -ne 0 ]] && {
        echo -e "${RED}错误：请使用 sudo 或 root 权限运行${RESET}"
        log_action "权限错误：非 root 用户运行脚本"
        exit 1
    }
}

# 检查依赖
check_deps() {
    for cmd in wget tar supervisorctl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "${RED}错误：缺少依赖 $cmd，请运行 apk add $cmd${RESET}"
            log_action "缺少依赖：$cmd"
            exit 1
        fi
    done
}

# 获取安装路径
get_install_path() {
    grep -Eo 'directory=[^ ]+' "$SUPERVISOR_CONF" | cut -d'=' -f2 2>/dev/null || echo "$DOWNLOAD_DIR"
}

# 获取下载链接（支持代理）
get_download_url() {
    local proxy=$1
    wget -q --no-check-certificate ${proxy:+"--proxy=$proxy"} -O- https://api.github.com/repos/alist-org/alist/releases/latest |
    grep -o '"browser_download_url": "[^"]*alist-linux-musl-amd64.tar.gz"' | cut -d'"' -f4
}

# 安装 Alist
install_alist() {
    check_root
    check_deps

    mkdir -p "$DOWNLOAD_DIR" && cd "$DOWNLOAD_DIR" || exit 1

    echo -e "${GREEN}输入 GitHub 代理（可选，格式：http://proxy:port）${RESET}"
    read -r proxy
    local url=$(get_download_url "$proxy")

    if [ -z "$url" ]; then
        echo -e "${RED}错误：无法获取下载链接，请检查网络或代理设置${RESET}"
        log_action "无法获取下载链接"
        exit 1
    fi

    wget "$url" -O alist.tar.gz || { echo -e "${RED}下载失败${RESET}"; log_action "下载失败：$url"; exit 1; }
    tar -zxvf alist.tar.gz && rm -f alist.tar.gz
    chmod +x "$ALIST_BINARY"

    # 配置 Supervisor
    cat > "$SUPERVISOR_CONF" <<EOF
[program:alist]
directory=$DOWNLOAD_DIR
command=$ALIST_BINARY server
autostart=true
autorestart=true
EOF

    rc-update add supervisord boot && service supervisord restart
    supervisorctl start alist

    echo -e "${GREEN}安装完成！服务已启动${RESET}"
    log_action "成功安装 Alist 并启动"
}

# 卸载 Alist
uninstall_alist() {
    check_root
    supervisorctl stop alist
    rm -f "$SUPERVISOR_CONF"
    rm -rf "$DOWNLOAD_DIR"
    service supervisord restart

    echo -e "${GREEN}Alist 已卸载${RESET}"
    log_action "卸载 Alist 成功"
}

# 查看 Alist 状态
check_status() {
    local status
    status=$(supervisorctl status alist 2>/dev/null)
    if echo "$status" | grep -q "RUNNING"; then
        echo -e "${GREEN}Alist 正在运行 (PID: $(echo "$status" | awk '{print $4}'))${RESET}"
        log_action "Alist 正在运行"
    else
        echo -e "${RED}Alist 未运行${RESET}"
        log_action "Alist 未运行"
    fi
}

# 重置管理员密码
reset_password() {
    check_root
    local install_path
    install_path=$(get_install_path)
    cd "$install_path" || exit 1

    echo -e "${GREEN}重置管理员密码${RESET}"
    read -p "输入新密码（留空随机生成）: " new_password

    if [ -z "$new_password" ]; then
        local output
        output=$("$ALIST_BINARY" admin random)
        echo -e "${GREEN}生成随机账号：${RESET}"
        echo "$output"
        log_action "生成随机密码成功"
    else
        "$ALIST_BINARY" admin set "$new_password" && {
            echo -e "${GREEN}密码重置成功！${RESET}"
            log_action "管理员密码重置成功"
        } || {
            echo -e "${RED}密码重置失败${RESET}"
            log_action "密码重置失败"
        }
    fi

    supervisorctl restart alist
}

# 检测版本
check_version() {
    local current_version latest_version
    current_version=$("$ALIST_BINARY" version 2>/dev/null || echo "未安装")
    latest_version=$(wget -q -O- https://api.github.com/repos/alist-org/alist/releases/latest |
        grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)

    echo -e "${GREEN}当前版本：${RESET} $current_version"
    echo -e "${GREEN}最新版本：${RESET} $latest_version"

    if [[ "$current_version" == "$latest_version" ]]; then
        echo -e "${GREEN}Alist 已是最新版本${RESET}"
        log_action "检测版本：已是最新版本"
    else
        echo -e "${YELLOW}Alist 有新版本可用${RESET}"
        log_action "检测版本：发现新版本 $latest_version"
    fi
}

# 卸载本脚本
uninstall_script() {
    echo -e "${RED}警告：卸载脚本会删除软链接和日志文件，是否继续？[Y/n]${RESET}"
    read -n 1 -r choice
    echo
    if [[ "$choice" =~ [Yy] ]]; then
        rm -f /usr/local/bin/alist "$LOG_FILE"
        echo -e "${GREEN}脚本已卸载${RESET}"
        log_action "卸载脚本成功"
        exit 0
    else
        echo -e "${YELLOW}操作取消${RESET}"
    fi
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "┌────────────────────────────────────────┐"
        echo -e "│          Alist 管理工具 (v1.4)          │"
        echo -e "├────────────────────────────────────────┤"
        echo -e "│ 1. 安装 Alist                        │"
        echo -e "│ 2. 更新 Alist                        │"
        echo -e "│ 3. 卸载 Alist                        │"
        echo -e "├────────────────────────────────────────┤"
        echo -e "│ 4. 查看状态                          │"
        echo -e "│ 5. 重置密码                          │"
        echo -e "├────────────────────────────────────────┤"
        echo -e "│ 6. 检测版本                          │"
        echo -e "│ 7. 卸载本脚本                        │"
        echo -e "├────────────────────────────────────────┤"
        echo -e "│ 0. 退出脚本                          │"
        echo -e "└────────────────────────────────────────┘"

        read -p "请选择功能 [0-7]: " choice
        case $choice in
            1) install_alist ;;
            2) install_alist ;; # 更新逻辑可复用安装逻辑
            3) uninstall_alist ;;
            4) check_status ;;
            5) reset_password ;;
            6) check_version ;;
            7) uninstall_script ;;
            0) echo "退出程序"; exit 0 ;;
            *) echo -e "${YELLOW}无效选项，请重试${RESET}" ;;
        esac
    done
}

# 快捷键支持
if [[ "$SCRIPT_NAME" == "alist" || "$SCRIPT_NAME" == "alist.sh" ]]; then
    main_menu
else
    echo -e "${YELLOW}提示：可创建软链接以使用快捷键：${RESET}"
    echo "ln -s $(realpath "$0") /usr/local/bin/alist"
    echo "之后直接输入 ${GREEN}alist${RESET} 即可调用"
fi