#!/bin/bash
###############################################################################
# Alpine Linux脚本工具箱 v2.0.0
# Version: 2.0.0
# Last Updated: 2025-04-30
# Description: 集成系统管理与Alist工具，支持系统信息、更新、清理、时区设置等功能
# Requirements: Alpine Linux, root privileges, wget, tar
# Author: 提供交互式多功能菜单，增强用户体验与日志记录
###############################################################################

# 全局变量
TOOL_NAME="Alpine脚本工具箱"
VERSION="v2.0.0"
BORDER_WIDTH=48
BORDER_CHAR="─"
DOWNLOAD_DIR="/opt/alist"
ALIST_BINARY="$DOWNLOAD_DIR/alist"
SUPERVISOR_CONF_DIR="/etc/supervisord/conf.d"
LOG_FILE="/var/log/alpine_toolbox.log"
TIMEZONE_DATA_PACKAGE="tzdata"

# 颜色定义
RED='\e[1;31m'
GREEN='\e[1;32m'
YELLOW='\e[1;33m'
BLUE='\e[1;34m'
RES='\e[0m'

# 边框生成函数
generate_border() {
    local type=$1
    local content=$2
    local left="┌"
    local right="┐"
    local mid="├"
    local bottom="└"

    if [ "$type" == "top" ] || [ "$type" == "bottom" ]; then
        printf "%s%s%s\n" "$left" "$(printf "%*s" "$BORDER_WIDTH" | tr ' ' "$BORDER_CHAR")" "$right"
    elif [ "$type" == "mid" ]; then
        printf "%s%s%s\n" "$mid" "$(printf "%*s" "$BORDER_WIDTH" | tr ' ' "$BORDER_CHAR")" "$mid"
    elif [ "$type" == "title" ]; then
        local padding=$(( (BORDER_WIDTH - ${#content} - 2) / 2 ))
        printf "│ %s%-*s%s │\n" "$BLUE" "${BORDER_WIDTH}" "$content" "$RES"
    fi
}

# 日志记录
log_action() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" >> "$LOG_FILE"
}

# 检查 root 权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：请使用 root 权限运行此脚本！${RES}"
        log_action "权限错误：非 root 用户运行脚本"
        exit 1
    fi
}

# 检查所需依赖
check_dependencies() {
    local missing_deps=()
    for cmd in wget tar supervisorctl jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${RED}错误：缺少以下依赖：${missing_deps[*]}。请使用 'apk add <依赖>' 安装。${RES}"
        log_action "缺少依赖：${missing_deps[*]}"
        exit 1
    fi

    # 检查时区数据
    if ! [ -e /usr/share/zoneinfo/UTC ]; then
        echo -e "${YELLOW}检测到时区数据缺失，正在安装...${RES}"
        apk add --no-cache "$TIMEZONE_DATA_PACKAGE" &> /dev/null
        log_action "安装时区数据 $TIMEZONE_DATA_PACKAGE"
    fi
}

# 获取 Alist 下载链接（带代理支持）
get_download_url() {
    local proxy="$1"
    wget -q --no-check-certificate ${proxy:+"--proxy=$proxy"} -O- https://api.github.com/repos/alist-org/alist/releases/latest |
    grep -o '"browser_download_url": "[^"]*alist-linux-musl-amd64.tar.gz"' | cut -d'"' -f4
}

# 安装 Alist
install_alist() {
    check_dependencies
    apk add supervisor wget tar --no-cache -y &> /dev/null

    mkdir -p "$DOWNLOAD_DIR" && cd "$DOWNLOAD_DIR"
    echo -e "${GREEN}输入GitHub代理（可选，格式：http://proxy:port）${RES}"
    read -p "代理地址: " proxy
    local url=$(get_download_url "$proxy") || { echo "${RED}获取链接失败${RES}"; return; }

    wget "$url" -O alist.tar.gz || { echo "${RED}下载失败${RES}"; return; }
    tar -zxvf alist.tar.gz && chmod +x "$ALIST_BINARY"
    rm -f alist.tar.gz  # 清理临时文件

    # 配置 Supervisor
    cat > "$SUPERVISOR_CONF_DIR/alist.ini" <<EOF
[program:alist]
directory=$DOWNLOAD_DIR
command=$ALIST_BINARY server
autostart=true
autorestart=true
EOF

    rc-update add supervisord boot &> /dev/null
    service supervisord restart &> /dev/null
    supervisorctl start alist &> /dev/null

    echo -e "${GREEN}[√] 安装完成！服务已启动${RES}"
    log_action "安装完成并启动 Alist"
    read -p "按回车返回主菜单..."
}

# 更新 Alist
update_alist() {
    check_dependencies
    local path="$DOWNLOAD_DIR"
    supervisorctl stop alist &> /dev/null

    echo -e "${GREEN}检测到可更新，开始下载新版本...${RES}"
    local url=$(get_download_url) || { echo "${RED}获取更新链接失败${RES}"; supervisorctl start alist; return; }
    wget "$url" -O alist.tar.gz || { echo "${RED}下载新版本失败${RES}"; supervisorctl start alist; return; }

    rm -rf "$path"/*
    tar -zxvf alist.tar.gz -C "$path"
    rm -f alist.tar.gz  # 清理临时文件
    supervisorctl restart alist &> /dev/null

    echo -e "${GREEN}[√] 更新完成！${RES}"
    log_action "更新 Alist 完成"
    read -p "按回车返回主菜单..."
}

# 卸载 Alist
uninstall_alist() {
    check_dependencies
    local path="$DOWNLOAD_DIR"
    read -p "${RED}警告：卸载将删除所有数据！确认请输入 Y${RES}" -n 1 -r
    [[ $REPLY =~ ^[Yy]$ ]] || { echo -e "\n${YELLOW}[i] 操作已取消${RES}"; return; }

    supervisorctl stop alist &> /dev/null
    rc-update del supervisord boot &> /dev/null
    rm -rf "$path" "$SUPERVISOR_CONF_DIR/alist.ini"

    echo -e "${GREEN}[√] 卸载完成！${RES}"
    log_action "卸载 Alist 成功"
    read -p "按回车返回主菜单..."
}

# 查看服务状态
check_status() {
    local status=$(supervisorctl status alist 2>/dev/null)
    if echo "$status" | grep -q "RUNNING"; then
        echo -e "${GREEN}[√] 服务运行中 (PID: $(echo "$status" | awk '{print $4}'))${RES}"
    else
        echo -e "${RED}[!] 服务已停止${RES}"
    fi
    read -p "按回车返回主菜单..."
}

# 重置管理员密码
reset_password() {
    check_dependencies
    local path="$DOWNLOAD_DIR"
    cd "$path" || { echo "${RED}[!] 目录错误，无法访问 Alist 安装路径${RES}"; return; }

    while true; do
        echo -e "\n${GREEN}密码重置菜单${RES}"
        echo -e "1. 生成随机密码"
        echo -e "2. 设置自定义密码"
        echo -e "0. 返回主菜单"
        read -p "选择: " opt

        case $opt in
            1)
                local output=$("$ALIST_BINARY" admin random)
                echo -e "${GREEN}[√] 随机生成的账号信息：${RES}"
                echo "$output"
                log_action "随机生成管理员密码成功"
                break
                ;;
            2)
                read -p "新密码: " new_password
                [ -z "$new_password" ] && { echo -e "${RED}[!] 密码不能为空，请重试${RES}"; continue; }
                "$ALIST_BINARY" admin set "$new_password" && {
                    echo -e "${GREEN}[√] 密码已成功重置${RES}"
                    log_action "管理员密码重置成功"
                } || echo -e "${RED}[!] 设置密码失败，请检查${RES}"
                break
                ;;
            0) return ;;
            *) echo -e "${RED}[!] 无效选项，请重试${RES}" ;;
        esac
    done
    supervisorctl restart alist &> /dev/null
    read -p "按回车返回主菜单..."
}

# 控制服务菜单
control_service_menu() {
    while true; do
        clear
        generate_border top
        generate_border title "Alist 服务控制"
        generate_border mid
        echo -e " ${GREEN}1. 启动服务${RES}"
        echo -e " ${RED}2. 停止服务${RES}"
        echo -e " ${YELLOW}3. 重启服务${RES}"
        echo -e " ${RED}0. 返回上一级菜单${RES}"
        generate_border bottom

        read -p "请选择操作 [0-3]: " sub_choice
        case $sub_choice in
            1)
                supervisorctl start alist &> /dev/null && echo -e "${GREEN}[√] 服务已启动${RES}" || echo -e "${RED}[!] 启动失败，请检查配置${RES}"
                log_action "启动 Alist 服务"
                ;;
            2)
                supervisorctl stop alist &> /dev/null && echo -e "${RED}[!] 服务已停止${RES}" || echo -e "${RED}[!] 停止失败，请检查配置${RES}"
                log_action "停止 Alist 服务"
                ;;
            3)
                supervisorctl restart alist &> /dev/null && echo -e "${GREEN}[√] 服务已重启${RES}" || echo -e "${RED}[!] 重启失败，请检查配置${RES}"
                log_action "重启 Alist 服务"
                ;;
            0) break ;;
            *) echo -e "${RED}[!] 无效选择，请重试${RES}" ;;
        esac
        read -p "按回车继续..."
    done
}

# 检测版本信息
check_version() {
    local current_version="$("$ALIST_BINARY" version 2>/dev/null || echo "未知")"
    local latest_version=$(wget -q -O- https://api.github.com/repos/alist-org/alist/releases/latest | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)

    echo -e "${GREEN}当前版本: ${RES}${current_version}"
    echo -e "${YELLOW}最新版本: ${RES}${latest_version}"
    if [ "$current_version" != "$latest_version" ]; then
        echo -e "${YELLOW}[!] Alist 有新版本可用，建议更新${RES}"
    else
        echo -e "${GREEN}[√] Alist 已是最新版本${RES}"
    fi
    log_action "版本检测：当前版本 $current_version，最新版本 $latest_version"
    read -p "按回车返回主菜单..."
}

# Alist 服务管理子菜单
show_alist_menu() {
    while true; do
        clear
        generate_border top
        generate_border title "Alist 服务管理"
        generate_border mid
        echo -e " ${YELLOW}1. 安装 Alist${RES}"
        echo -e " ${YELLOW}2. 更新 Alist${RES}"
        echo -e " ${YELLOW}3. 卸载 Alist${RES}"
        generate_border mid
        echo -e " ${YELLOW}4. 查看服务状态${RES}"
        echo -e " ${YELLOW}5. 重置管理员密码${RES}"
        generate_border mid
        echo -e " ${YELLOW}6. 控制服务（启动/停止/重启）${RES}"
        echo -e " ${YELLOW}7. 检测版本信息${RES}"
        generate_border mid
        echo -e " ${RED}0. 返回主菜单${RES}"
        generate_border bottom

        read -p "请选择功能 [0-7]: " choice
        case $choice in
            1) install_alist ;;
            2) update_alist ;;
            3) uninstall_alist ;;
            4) check_status ;;
            5) reset_password ;;
            6) control_service_menu ;;
            7) check_version ;;
            0) break ;;
            *) echo -e "${RED}[!] 无效选择，请重试${RES}" ;;
        esac
        read -p "按回车继续..."
    done
}

# 主菜单
show_main_menu() {
    clear
    generate_border top
    generate_border title "${TOOL_NAME} ${VERSION}"
    generate_border mid
    echo -e " ${BLUE}1. 系统信息查询${RES}"
    echo -e " ${BLUE}2. 系统更新与升级${RES}"
    echo -e " ${BLUE}3. 系统清理与优化${RES}"
    echo -e " ${GREEN}4. Alist 服务管理${RES}"
    echo -e " ${YELLOW}5. 时区设置工具${RES}"
    echo -e " ${RED}0. 退出工具箱${RES}"
    generate_border bottom

    read -p "请选择功能 [0-5]: " choice
    return $choice
}

# 程序入口
while true; do
    show_main_menu
    case $? in
        1) system_info ;;
        2) system_update ;;
        3) system_clean ;;
        4) show_alist_menu ;;
        5) show_timezone_menu ;;
        0) echo -e "${GREEN}[√] 退出工具箱，再见！${RES}"; exit 0 ;;
        *) echo -e "${RED}[!] 无效选择，请输入0 - 5${RES}" ;;
    esac
    read -p "\n按回车继续..."
}