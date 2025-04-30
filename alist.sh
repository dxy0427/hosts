l#!/bin/bash
###############################################################################
# Alist Manager Script
# Version: 1.1.0
# Last Updated: 2025-04-30
# Description: Alpine Linux 下 Alist 管理脚本，支持安装、更新、卸载、密码重置等功能
# Requirements: Alpine Linux (with Supervisor), root privileges, wget, tar
# Author: 参考 v3.sh 优化，增强兼容性与用户体验
###############################################################################

# 全局变量
DOWNLOAD_DIR="/opt/alist"
ALIST_BINARY="$DOWNLOAD_DIR/alist"
ALIST_SERVICE_FILE="/etc/init.d/alist"
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

# 获取已安装的 Alist 路径（通过 Supervisor 配置）
get_installed_path() {
    if [ -f "$SUPERVISOR_CONF_DIR/alist.ini" ]; then
        grep -Eo "directory=[^ ]+" "$SUPERVISOR_CONF_DIR/alist.ini" | cut -d'=' -f2
    else
        echo "$DOWNLOAD_DIR"
    fi
}

# 检查系统依赖
check_dependencies() {
    check_root
    for cmd in wget tar supervisorctl; do
        if ! command -v "$cmd" >/dev/null; then
            echo -e "${RED_COLOR}错误：未找到 $cmd，请先安装 (apk add $cmd)${RES}"
            log_action "依赖错误：未找到 $cmd"
            exit 1
        fi
    done
}

# 获取 Alist 下载链接（支持代理）
get_download_url() {
    local api_url="https://api.github.com/repos/alist-org/alist/releases/latest"
    local proxy="$1"
    local download_url=$(wget -q --no-check-certificate ${proxy:+"--proxy=$proxy"} -O- "$api_url" |
        grep -o '"browser_download_url": "[^"]*alist-linux-musl-amd64.tar.gz"' | cut -d'"' -f4)
    if [ -z "$download_url" ]; then
        echo -e "${RED_COLOR}错误：无法从 GitHub 获取 Alist 的下载链接，请检查网络或代理设置。${RES}"
        log_action "错误：无法获取下载链接，API URL: $api_url，代理: $proxy"
        exit 1
    fi
    echo "$download_url"
}

# 检测当前版本与最新版本
check_version() {
    if ! [ -x "$ALIST_BINARY" ]; then
        echo -e "${YELLOW_COLOR}Alist 未安装，无法检测版本。${RES}"
        return 1
    fi

    local current_version=$("$ALIST_BINARY" version 2>/dev/null || echo "UNKNOWN")
    local latest_version=$(wget -q -O- https://api.github.com/repos/alist-org/alist/releases/latest |
        grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)

    if [ "$current_version" = "$latest_version" ]; then
        echo -e "${GREEN_COLOR}当前已是最新版本：$current_version${RES}"
        log_action "版本检测：当前版本 $current_version 已是最新版本"
        return 1
    else
        echo -e "${YELLOW_COLOR}检测到新版本：$latest_version，当前版本：$current_version${RES}"
        log_action "版本检测：发现新版本 $latest_version，当前版本 $current_version"
        return 0
    fi
}

# 安装 Alist
install_alist() {
    check_dependencies
    apk update && apk add supervisor wget tar 2>/dev/null

    mkdir -p "$DOWNLOAD_DIR"
    cd "$DOWNLOAD_DIR"

    echo -e "${GREEN_COLOR}是否使用 GitHub 代理？（格式：http://proxy:port 或留空）${RES}"
    read -p "代理地址: " proxy
    local download_url=$(get_download_url "$proxy")

    wget "$download_url" -O alist.tar.gz || {
        echo -e "${RED_COLOR}下载失败${RES}"
        log_action "错误：下载失败，URL: $download_url"
        exit 1
    }
    tar -zxvf alist.tar.gz && chmod +x "$ALIST_BINARY"

    cat > "$SUPERVISOR_CONF_DIR/alist.ini" <<EOF
[program:alist]
directory=$DOWNLOAD_DIR
command=$ALIST_BINARY server
autostart=true
autorestart=true
environment=CODENATION_ENV=prod
EOF

    rc-update add supervisord boot
    service supervisord restart
    supervisorctl update alist && supervisorctl start alist

    echo -e "${GREEN_COLOR}安装完成！服务已启动${RES}"
    log_action "安装完成并启动 Alist 服务"
}

# 更新 Alist
update_alist() {
    check_dependencies
    if ! check_version; then
        echo -e "${GREEN_COLOR}已是最新版本，无需更新。${RES}"
        return
    fi

    local install_path=$(get_installed_path)
    supervisorctl stop alist

    cp "$install_path/alist" "$install_path/alist.bak" || {
        echo -e "${YELLOW_COLOR}警告：备份失败，可能影响回滚${RES}"
        log_action "警告：备份失败"
    }

    echo -e "${GREEN_COLOR}正在下载最新版本...${RES}"
    local proxy=$(get_proxy_input)
    local download_url=$(get_download_url "$proxy")
    wget "$download_url" -O alist.tar.gz || {
        echo -e "${RED_COLOR}下载失败，正在恢复旧版本...${RES}"
        mv "$install_path/alist.bak" "$install_path/alist" && supervisorctl start alist
        log_action "更新失败，恢复旧版本"
        exit 1
    }

    tar -zxvf alist.tar.gz -C "$install_path"
    chmod +x "$install_path/alist"
    rm -f alist.tar.gz "$install_path/alist.bak"

    supervisorctl restart alist
    echo -e "${GREEN_COLOR}更新完成！${RES}"
    log_action "更新完成并重启 Alist 服务"
}

# 卸载 Alist
uninstall_alist() {
    check_dependencies
    local install_path=$(get_installed_path)
    echo -e "${RED_COLOR}警告：卸载将删除所有数据，是否继续？[Y/n]${RES}"
    read -n 1 -p "请输入 Y 确认或 N 取消: " choice
    [[ "$choice" =~ [Yy] ]] || { echo -e "\n取消卸载。"; log_action "用户取消卸载"; exit 0; }

    supervisorctl stop alist
    rc-update del supervisord boot
    rm -f "$SUPERVISOR_CONF_DIR/alist.ini"
    rm -rf "$install_path"

    echo -e "${GREEN_COLOR}卸载完成，残留文件已清除${RES}"
    log_action "成功卸载 Alist"
}

# 查看状态
check_status() {
    local status=$(supervisorctl status alist 2>/dev/null)
    if echo "$status" | grep -q "RUNNING"; then
        echo -e "${GREEN_COLOR}Alist 正在运行 (PID: $(echo "$status" | awk '{print $4}'))${RES}"
        log_action "Alist 运行中：$status"
    else
        echo -e "${RED_COLOR}Alist 未运行${RES}"
        log_action "Alist 未运行"
    fi
}

# 重置密码
reset_password() {
    check_dependencies
    local install_path=$(get_installed_path)
    cd "$install_path" || exit 1

    while true; do
        echo -e "\n${GREEN_COLOR}密码重置菜单${RES}"
        echo "1. 生成随机密码"
        echo "2. 设置自定义密码"
        echo "0. 返回"
        read -p "选择: " opt

        case $opt in
            1)
                local output=$("$ALIST_BINARY" admin random)
                echo -e "${GREEN_COLOR}生成随机账号：${RES}"
                echo "用户名: $(echo "$output" | awk -F': ' '/username:/ {print $2}')"
                echo "密码: $(echo "$output" | awk -F': ' '/password:/ {print $2}')"
                log_action "生成随机密码成功"
                break
                ;;
            2)
                read -p "新密码: " pwd
                [ -z "$pwd" ] && { echo -e "${RED_COLOR}错误：密码不能为空${RES}"; continue; }
                "$ALIST_BINARY" admin set "$pwd" && {
                    echo -e "${GREEN_COLOR}密码设置成功！${RES}"
                    supervisorctl restart alist
                    rm -rf data/cache
                    log_action "自定义密码设置成功"
                    break
                } || echo -e "${RED_COLOR}设置失败，请重试${RES}"
                ;;
            0) return ;;
            *) echo -e "${YELLOW_COLOR}无效选项${RES}" ;;
        esac
    done
}

# 服务控制
start_service() { supervisorctl start alist && echo -e "${GREEN_COLOR}服务已启动${RES}"; log_action "启动 Alist 服务"; }
stop_service() { supervisorctl stop alist && echo -e "${RED_COLOR}服务已停止${RES}"; log_action "停止 Alist 服务"; }
restart_service() { supervisorctl restart alist && echo -e "${GREEN_COLOR}服务已重启${RES}"; log_action "重启 Alist 服务"; }

# 主菜单（去除“彻底删除”标注）
show_menu() {
    clear
    echo -e "┌────────────────────────────────────────┐"
    echo -e "│          Alist 管理工具 (v1.1)         │"
    echo -e "├────────────────────────────────────────┤"
    echo -e "│ 1. 安装 Alist                        │"
    echo -e "│ 2. 更新 Alist                        │"
    echo -e "│ 3. 卸载 Alist                        │"  # 去除“彻底删除”标注
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

    case $choice in
        1) install_alist ;;
        2) update_alist ;;
        3) uninstall_alist ;;
        4) check_status ;;
        5) reset_password ;;
        6) start_service ;;
        7) stop_service ;;
        8) restart_service ;;
        9) check_version ;;
        0) log_action "退出脚本"; exit 0 ;;
        *) echo -e "${YELLOW_COLOR}请输入有效数字${RES}" ;;
    esac
}

# 程序入口
while true; do
    show_menu
    sleep 1
done
