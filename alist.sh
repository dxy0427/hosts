#!/bin/bash
###############################################################################
# Alist Manager Script
# Version: 1.2.0
# Last Updated: 2025-04-30
# Description: 完整功能版，支持1-9选项，操作后返回主菜单
# Requirements: Alpine Linux (with Supervisor), root privileges, wget, tar
# Author: 实现全功能菜单与交互优化
###############################################################################

# 全局变量
DOWNLOAD_DIR="/opt/alist"
ALIST_BINARY="$DOWNLOAD_DIR/alist"
SUPERVISOR_CONF_DIR="/etc/supervisord/conf.d"
LOG_FILE="/var/log/alist_manager.log"

# 颜色配置
RED_COLOR='\e[1;31m'
GREEN_COLOR='\e[1;32m'
YELLOW_COLOR='\e[1;33m'
RES='\e[0m'

# 日志记录函数
log_action() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
}

# 检查 root 权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED_COLOR}错误：请使用 root 权限运行此脚本！${RES}"
        log_action "权限错误：非 root 用户运行脚本"
        exit 1
    fi
}

# 获取已安装路径
get_installed_path() {
    grep -Eo "directory=[^ ]+" "$SUPERVISOR_CONF_DIR/alist.ini" | cut -d'=' -f2 2>/dev/null || echo "$DOWNLOAD_DIR"
}

# 检查依赖
check_dependencies() {
    check_root
    for cmd in wget tar supervisorctl; do
        [ ! $(command -v "$cmd") ] && {
            echo -e "${RED_COLOR}错误：缺少依赖 $cmd，请运行 apk add $cmd${RES}"
            exit 1
        }
    done
}

# 获取下载链接（支持代理）
get_download_url() {
    local proxy="$1"
    wget -q --no-check-certificate ${proxy:+"--proxy=$proxy"} -O- https://api.github.com/repos/alist-org/alist/releases/latest |
    grep -o '"browser_download_url": "[^"]*alist-linux-musl-amd64.tar.gz"' | cut -d'"' -f4
}

# 安装 Alist（选项1）
install_alist() {
    check_dependencies
    apk add supervisor wget tar --no-cache -y

    mkdir -p "$DOWNLOAD_DIR" && cd "$DOWNLOAD_DIR"
    echo -e "${GREEN_COLOR}输入 GitHub 代理（可选，格式：http://proxy:port）${RES}"
    read -p "代理地址: " proxy
    local url=$(get_download_url "$proxy") || { echo "获取链接失败"; return; }

    wget "$url" -O alist.tar.gz || { echo "下载失败"; return; }
    tar -zxvf alist.tar.gz && chmod +x "$ALIST_BINARY"

    # 配置 Supervisor
    cat > "$SUPERVISOR_CONF_DIR/alist.ini" <<EOF
[program:alist]
directory=$DOWNLOAD_DIR
command=$ALIST_BINARY server
autostart=true
autorestart=true
EOF

    rc-update add supervisord boot && service supervisord restart
    supervisorctl start alist

    echo -e "${GREEN_COLOR}安装完成！服务已启动${RES}"
    read -p "按回车返回主菜单..."
}

# 更新 Alist（选项2）
update_alist() {
    check_dependencies
    local path=$(get_installed_path)
    supervisorctl stop alist

    echo -e "${GREEN_COLOR}检测到可更新，开始下载新版本...${RES}"
    local url=$(get_download_url) || { supervisorctl start alist; return; }
    wget "$url" -O alist.tar.gz || { supervisorctl start alist; return; }

    rm -rf "$path"/*
    tar -zxvf alist.tar.gz -C "$path"
    supervisorctl restart alist

    echo -e "${GREEN_COLOR}更新完成！${RES}"
    read -p "按回车返回主菜单..."
}

# 卸载 Alist（选项3）
uninstall_alist() {
    check_dependencies
    local path=$(get_installed_path)
    read -p "${RED_COLOR}警告：卸载将删除所有数据！确认请输入 Y${RES}" -n 1 -r
    [[ $REPLY =~ ^[Yy]$ ]] || { echo "\n已取消"; return; }

    supervisorctl stop alist
    rc-update del supervisord boot
    rm -rf "$path" "$SUPERVISOR_CONF_DIR/alist.ini"

    echo -e "${GREEN_COLOR}卸载完成！${RES}"
    read -p "按回车返回主菜单..."
}

# 查看状态（选项4）
check_status() {
    local status=$(supervisorctl status alist 2>/dev/null)
    if echo "$status" | grep -q RUNNING; then
        echo -e "${GREEN_COLOR}服务运行中 (PID: $(echo "$status" | awk '{print $4}'))${RES}"
    else
        echo -e "${RED_COLOR}服务已停止${RES}"
    fi
    read -p "按回车返回主菜单..."
}

# 重置密码（选项5）
reset_password() {
    local path=$(get_installed_path)
    cd "$path" || { echo "目录错误"; return; }

    while true; do
        echo -e "\n${GREEN_COLOR}5. 密码重置菜单${RES}"
        echo "1. 生成随机密码"
        echo "2. 设置自定义密码"
        echo "0. 返回主菜单"
        read -p "选择: " opt

        case $opt in
            1) "$ALIST_BINARY" admin random | grep -E "username:|password:" | sed 's/.*:/账号: /'; break ;;
            2) read -p "新密码: "; [ -n "$REPLY" ] && "$ALIST_BINARY" admin set "$REPLY" && supervisorctl restart alist; break ;;
            0) return ;;
            *) echo "无效选项" ;;
        esac
    done
    read -p "按回车返回主菜单..."
}

# 启动服务（选项6）
start_service() {
    supervisorctl start alist && echo -e "${GREEN_COLOR}服务已启动${RES}"
    read -p "按回车返回主菜单..."
}

# 停止服务（选项7）
stop_service() {
    supervisorctl stop alist && echo -e "${RED_COLOR}服务已停止${RES}"
    read -p "按回车返回主菜单..."
}

# 重启服务（选项8）
restart_service() {
    supervisorctl restart alist && echo -e "${GREEN_COLOR}服务已重启${RES}"
    read -p "按回车返回主菜单..."
}

# 检测版本（选项9）
check_version() {
    local curr=$("$ALIST_BINARY" version 2>/dev/null || echo "未安装")
    local latest=$(wget -qO- https://api.github.com/repos/alist-org/alist/releases/latest | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)
    
    echo -e "${GREEN_COLOR}当前版本: ${curr}${RES}"
    echo -e "${YELLOW_COLOR}最新版本: ${latest}${RES}"
    read -p "按回车返回主菜单..."
}

# 主菜单
show_menu() {
    clear
    echo -e "┌────────────────────────────────────────┐"
    echo -e "│          Alist 管理工具 (v1.2)         │"
    echo -e "├────────────────────────────────────────┤"
    echo -e "│ 1. 安装 Alist                        │"
    echo -e "│ 2. 更新 Alist                        │"
    echo -e "│ 3. 卸载 Alist                        │"
    echo -e "├────────────────────────────────────────┤"
    echo -e "│ 4. 查看运行状态                      │"
    echo -e "│ 5. 重置管理员密码                    │"
    echo -e "├────────────────────────────────────────┤"
    echo -e "│ 6. 启动服务                          │"
    echo -e "│ 7. 停止服务                          │"
    echo -e "│ 8. 重启服务                          │"
    echo -e "│ 9. 检测版本信息                      │"
    echo -e "├────────────────────────────────────────┤"
    echo -e "│ 0. 退出脚本                          │"
    echo -e "└────────────────────────────────────────┘"
    read -p "请选择功能 [0-9]: " choice
    return $choice
}

# 程序入口
while true; do
    show_menu
    case $? in
        1) install_alist ;;
        2) update_alist ;;
        3) uninstall_alist ;;
        4) check_status ;;
        5) reset_password ;;
        6) start_service ;;
        7) stop_service ;;
        8) restart_service ;;
        9) check_version ;;
        0) echo "退出脚本"; exit 0 ;;
        *) echo "无效选择，请重试" ;;
    esac
done
