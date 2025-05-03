#!/bin/sh

# 创建符号链接到 /usr/local/bin/
SCRIPT_NAME="alist-alpine.sh"
SYMLINK_PATH="/usr/local/bin/alist"
if [ ! -L "$SYMLINK_PATH" ]; then
    sudo ln -s "$(pwd)/$SCRIPT_NAME" "$SYMLINK_PATH"
    if [ $? -ne 0 ]; then
        echo "错误：创建符号链接失败，请检查权限。" >&2
        exit 1
    fi
fi

# 确保脚本可执行
if [ ! -x "./$SCRIPT_NAME" ]; then
    chmod +x "./$SCRIPT_NAME"
    if [ $? -ne 0 ]; then
        echo "错误：设置脚本可执行权限失败，请检查权限。" >&2
        exit 1
    fi
fi

# 全局变量定义
ALIST_DOWNLOAD_URL="https://github.com/alist-org/alist/releases/download"
ALIST_ARCHIVE="alist-linux-musl-amd64.tar.gz"
INSTALL_DIR="/opt/alist"
ALIST_BINARY="$INSTALL_DIR/alist"
SUPERVISOR_DIR="/etc/supervisord_conf"
SUPERVISOR_CONFIG="$SUPERVISOR_DIR/alist.ini"
DATA_DIR="$INSTALL_DIR/data"
CRON_JOB="0 4 * * * $(pwd)/$SCRIPT_NAME auto-update"
ARCH="amd64"

# 颜色定义
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

# 依赖检查函数
check_dependencies() {
    local required=("wget" "tar" "apk" "supervisor" "curl")
    echo -e "${GREEN}检查依赖项...${RESET}"
    
    for dep in "${required[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo -e "${YELLOW}缺少依赖：$dep，正在安装...${RESET}"
            apk add "$dep" >/dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo -e "${RED}错误：安装 $dep 失败，请手动安装后重试。${RESET}" >&2
                return 1
            fi
        fi
    done
    echo -e "${GREEN}所有依赖项已安装。${RESET}"
    return 0
}

# 残留清理函数
cleanup_residuals() {
    echo -e "${YELLOW}清理残留进程和配置...${RESET}"
    
    # 终止Alist进程
    local pids=$(ps -ef | grep "$ALIST_BINARY server" | grep -v grep | awk '{print $2}')
    for pid in $pids; do
        kill -9 "$pid" >/dev/null 2>&1
        [ $? -eq 0 ] && echo -e "${GREEN}已终止进程 $pid${RESET}"
    done
    
    # 删除残留配置
    rm -f "$SUPERVISOR_CONFIG"
    rm -rf ~/.alist
    rm -rf "$INSTALL_DIR"
}

# 获取当前版本号
get_current_version() {
    if [ -f "$ALIST_BINARY" ]; then
        local ver=$("$ALIST_BINARY" version 2>/dev/null)
        echo "$ver" | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+'
    else
        echo "未安装"
    fi
}

# 获取最新版本号（直连GitHub API，不使用代理）
get_latest_version() {
    local api_url="https://api.github.com/repos/alist-org/alist/releases/latest"
    local response=$(curl -s -H "Accept: application/vnd.github.v3+json" "$api_url")
    
    if [ -z "$response" ]; then
        echo "无法获取版本信息"
        return 1
    fi
    
    echo "$response" | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4
}

# 版本比较函数
version_gt() {
    [ "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1" ]
}

# 安装目录检查
check_install_dir() {
    echo -e "${GREEN}准备安装目录...${RESET}"
    
    if [ -d "$INSTALL_DIR" ]; then
        echo -e "${YELLOW}检测到已有安装目录，正在清除...${RESET}"
        rm -rf "$INSTALL_DIR"
    fi
    
    mkdir -p "$INSTALL_DIR"
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：无法创建安装目录 $INSTALL_DIR${RESET}" >&2
        exit 1
    fi
    echo -e "${GREEN}安装目录准备就绪：$INSTALL_DIR${RESET}"
}

# 带重试的下载函数
download_with_retry() {
    local url=$1
    local output=$2
    local retries=3
    local delay=5
    
    for ((i=1; i<=$retries; i++)); do
        echo -e "${GREEN}开始第 $i 次下载...${RESET}"
        if curl -L --connect-timeout 10 --retry 3 --retry-delay 3 "$url" -o "$output"; then
            [ -s "$output" ] && return 0
            echo -e "${YELLOW}下载文件为空，重试...${RESET}"
        else
            echo -e "${YELLOW}下载失败，$delay 秒后重试...${RESET}"
            sleep "$delay"
            delay=$((delay + 5))
        fi
    done
    echo -e "${RED}下载失败，已达最大重试次数${RESET}" >&2
    return 1
}

# 安装核心函数
install_core() {
    local current_dir=$(pwd)
    
    # 代理配置
    echo -e "${GREEN}是否使用GitHub下载代理？（可选，格式：https://ghproxy.com/）${RESET}"
    read -p "代理地址（留空直连）: " proxy_input
    local download_url="${proxy_input:-$ALIST_DOWNLOAD_URL}/latest"
    
    # 下载安装包
    echo -e "\n${GREEN}开始下载Alist安装包...${RESET}"
    local temp_file="/tmp/$ALIST_ARCHIVE"
    if ! download_with_retry "${download_url}/$ALIST_ARCHIVE" "$temp_file"; then
        rm -f "$temp_file"
        return 1
    fi
    
    # 解压文件
    echo -e "${GREEN}解压安装包...${RESET}"
    tar zxf "$temp_file" -C "$INSTALL_DIR"
    if [ $? -ne 0 ]; then
        echo -e "${RED}解压失败，安装终止${RESET}" >&2
        rm -f "$temp_file"
        return 1
    fi
    rm -f "$temp_file"
    
    # 检查二进制文件
    if [ ! -f "$ALIST_BINARY" ]; then
        echo -e "${RED}安装文件丢失，安装失败${RESET}" >&2
        return 1
    fi
    
    # 获取初始账号密码
    cd "$INSTALL_DIR" || return 1
    local admin_info=$("./alist" admin random 2>&1)
    ADMIN_USER=$(echo "$admin_info" | awk -F': ' '/username:/ {print $2}')
    ADMIN_PASS=$(echo "$admin_info" | awk -F': ' '/password:/ {print $2}')
    cd "$current_dir"
}

# Supervisor初始化
init_supervisor() {
    echo -e "${GREEN}配置Supervisor服务...${RESET}"
    
    # 生成基础配置
    echo_supervisord_conf > /etc/supervisord.conf
    
    # 添加包含配置
    {
        echo "[include]"
        echo "files = /etc/supervisord_conf/*.ini"
    } >> /etc/supervisord.conf
    
    # 创建程序配置
    mkdir -p "$SUPERVISOR_DIR"
    {
        echo "[program:alist]"
        echo "directory=$INSTALL_DIR"
        echo "command=$ALIST_BINARY server"
        echo "autostart=true"
        echo "autorestart=true"
        echo "environment=CODENATION_ENV=prod"
    } > "$SUPERVISOR_CONFIG"
    
    # 应用配置
    supervisorctl reread >/dev/null 2>&1
    supervisorctl update >/dev/null 2>&1
}

# 安装成功提示
display_success() {
    clear
    echo -e "${GREEN}Alist 安装成功！${RESET}"
    
    # 获取网络信息
    local local_ip=$(ip -4 addr show up | grep -v ' lo' | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)
    local public_ipv4=$(curl -s4 icanhazip.com || curl -s4 ipinfo.io/ip || echo "获取失败")
    local public_ipv6=$(curl -s6 icanhazip.com || curl -s6 ipinfo.io/ip || echo "获取失败")
    
    echo -e "\n${GREEN}访问地址：${RESET}"
    [ -n "$local_ip" ] && echo "  局域网：http://$local_ip:5244"
    [ "$public_ipv4" != "获取失败" ] && echo "  公网IPv4：http://$public_ipv4:5244"
    [ "$public_ipv6" != "获取失败" ] && echo "  公网IPv6：http://[$public_ipv6]:5244"
    
    echo -e "\n${GREEN}管理员账号：${RESET}"
    echo "  用户名：$ADMIN_USER"
    echo "  密  码：$ADMIN_PASS"
    
    echo -e "\n${GREEN}启动服务...${RESET}"
    supervisorctl start alist >/dev/null 2>&1
    echo -e "${GREEN}管理工具：输入 ${YELLOW}alist${GREEN} 即可随时管理${RESET}"
    
    echo -e "\n${YELLOW}提示：请检查防火墙开放5244端口${RESET}"
    read -p "按回车返回主菜单..."
    clear
}

# 完整安装流程
install_alist() {
    local current_version=$(get_current_version)
    if [ "$current_version" != "未安装" ]; then
        echo -e "${YELLOW}检测到已安装版本：$current_version${RESET}"
        read -p "是否重新安装？(y/n): " confirm
        [ "$confirm" != "y" ] && return
        cleanup_residuals
    fi
    
    check_dependencies || return
    check_install_dir
    install_core || return
    init_supervisor
    display_success
}

# 更新Alist函数
update_alist() {
    local current_version=$(get_current_version)
    if [ "$current_version" = "未安装" ]; then
        echo -e "${RED}错误：未安装Alist，无法更新${RESET}"
        read -p "按回车继续..."
        clear
        return
    fi
    
    echo -e "${GREEN}当前版本：$current_version${RESET}"
    local latest_version=$(get_latest_version)
    if [ -z "$latest_version" ]; then
        echo -e "${RED}错误：无法获取最新版本信息${RESET}"
        read -p "按回车继续..."
        clear
        return
    fi
    
    if ! version_gt "$latest_version" "$current_version"; then
        echo -e "${GREEN}已是最新版本：$latest_version${RESET}"
        read -p "按回车继续..."
        clear
        return
    fi
    
    read -p "检测到新版本 $latest_version，是否更新？(y/n): " confirm
    [ "$confirm" != "y" ] && return
    
    echo -e "${GREEN}停止Alist服务...${RESET}"
    supervisorctl stop alist >/dev/null 2>&1
    
    # 备份旧版本
    cp "$ALIST_BINARY" "/tmp/alist.bak.$(date +%s)"
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：备份旧版本失败${RESET}"
        supervisorctl start alist >/dev/null 2>&1
        read -p "按回车继续..."
        clear
        return
    fi
    
    # 代理配置
    echo -e "${GREEN}是否使用下载代理？（可选）${RESET}"
    read -p "代理地址（留空直连）: " proxy_input
    local download_url="${proxy_input:-$ALIST_DOWNLOAD_URL}/$latest_version"
    
    # 下载新版本
    echo -e "${GREEN}下载新版本...${RESET}"
    local temp_file="/tmp/$ALIST_ARCHIVE"
    wget -q "${download_url}/$ALIST_ARCHIVE" -O "$temp_file"
    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：下载失败，恢复旧版本...${RESET}"
        mv "/tmp/alist.bak.$(date +%s)" "$ALIST_BINARY"
        supervisorctl start alist >/dev/null 2>&1
        rm -f "$temp_file"
        read -p "按回车继续..."
        clear
        return
    fi
    
    # 解压更新
    tar zxf "$temp_file" -C "$INSTALL_DIR"
    rm -f "$temp_file"
    
    echo -e "${GREEN}重启Alist服务...${RESET}"
    supervisorctl restart alist >/dev/null 2>&1
    echo -e "${GREEN}更新完成，当前版本：$(get_current_version)${RESET}"
    read -p "按回车继续..."
    clear
}

# 自动更新函数
auto_update_alist() {
    local current_version=$(get_current_version)
    [ "$current_version" = "未安装" ] && return
    
    local latest_version=$(get_latest_version)
    [ -z "$latest_version" ] && return
    
    if version_gt "$latest_version" "$current_version"; then
        echo -e "${GREEN}检测到新版本 $latest_version，开始自动更新...${RESET}"
        supervisorctl stop alist >/dev/null 2>&1
        
        cp "$ALIST_BINARY" "/tmp/alist.bak.$(date +%s)"
        local proxy=$(grep "^AUTO_UPDATE_PROXY=" /etc/environment | cut -d'=' -f2)
        local download_url="${proxy:-$ALIST_DOWNLOAD_URL}/$latest_version"
        
        wget -q "${download_url}/$ALIST_ARCHIVE" -O "/tmp/alist.tar.gz"
        tar zxf "/tmp/alist.tar.gz" -C "$INSTALL_DIR"
        rm -f "/tmp/alist.tar.gz"
        
        supervisorctl start alist >/dev/null 2>&1
        echo -e "${GREEN}自动更新完成${RESET}"
    fi
}

# 卸载函数
uninstall_alist() {
    echo -e "${RED}警告：卸载将删除所有数据，无法恢复！${RESET}"
    read -p "确认卸载？(y/n): " confirm
    [ "$confirm" != "y" ] && return
    
    cleanup_residuals
    supervisorctl stop alist >/dev/null 2>&1
    
    rm -rf "$INSTALL_DIR"
    rm -f "$SUPERVISOR_CONFIG"
    sed -i '/^\[include\]/,/files = \/etc\/supervisord_conf\/\*.ini/d' /etc/supervisord.conf
    supervisorctl reread >/dev/null 2>&1
    
    rm -f "$SYMLINK_PATH"
    crontab -l | grep -Ev "$CRON_JOB" | crontab -
    
    echo -e "${GREEN}Alist已完全卸载${RESET}"
    clear
    exit 0
}

# 状态检查函数
check_service_status() {
    echo -e "${GREEN}Alist服务状态：${RESET}"
    supervisorctl status alist
    
    echo -e "\n${GREEN}自动更新状态：${RESET}"
    if crontab -l | grep -qE "$CRON_JOB"; then
        echo -e "${GREEN}已开启（每天凌晨4点）${RESET}"
    else
        echo -e "${YELLOW}未开启${RESET}"
    fi
    read -p "按回车继续..."
    clear
}

# 密码重置函数
reset_admin_password() {
    [ ! -f "$ALIST_BINARY" ] && {
        echo -e "${RED}错误：未安装Alist${RESET}"
        read -p "按回车继续..."
        clear
        return
    }
    
    cd "$INSTALL_DIR" || return
    
    echo -e "${GREEN}密码重置选项：${RESET}"
    echo "1. 生成随机密码"
    echo "2. 设置自定义密码"
    echo "0. 返回"
    read -p "选择操作: " choice
    
    case "$choice" in
        1) local output=$("./alist" admin random); echo_account "$output" ;;
        2) read -p "输入新密码: " pass; [ -z "$pass" ] && echo -e "${RED}错误：密码不能为空${RESET}" && return; local output=$("./alist" admin set "$pass"); echo_account "$output" ;;
        0) cd - >/dev/null; return ;;
        *) echo -e "${RED}错误：无效选择${RESET}" ;;
    esac
    
    cd - >/dev/null
    read -p "按回车继续..."
    clear
}

echo_account() {
    local user=$(echo "$1" | awk -F': ' '/username:/ {print $2}')
    local pass=$(echo "$1" | awk -F': ' '/password:/ {print $2}')
    echo -e "${GREEN}新账号：$user${RESET}"
    echo -e "${GREEN}新密码：$pass${RESET}"
}

# 服务控制函数
start_service() {
    supervisorctl start alist >/dev/null 2>&1
    echo -e "${GREEN}服务已启动${RESET}"
    read -p "按回车继续..."
    clear
}

stop_service() {
    supervisorctl stop alist >/dev/null 2>&1
    echo -e "${GREEN}服务已停止${RESET}"
    read -p "按回车继续..."
    clear
}

restart_service() {
    supervisorctl restart alist >/dev/null 2>&1
    echo -e "${GREEN}服务已重启${RESET}"
    read -p "按回车继续..."
    clear
}

# 版本检查函数
check_version_info() {
    local curr=$(get_current_version)
    local latest=$(get_latest_version)
    
    echo -e "${GREEN}当前版本：$curr${RESET}"
    echo -e "${YELLOW}最新版本：$latest${RESET}"
    
    if version_gt "$latest" "$curr"; then
        echo -e "${YELLOW}提示：有可用更新${RESET}"
    else
        echo -e "${GREEN}当前已是最新版本${RESET}"
    fi
    read -p "按回车继续..."
    clear
}

# 自动更新设置
configure_auto_update() {
    echo -e "${GREEN}自动更新设置：${RESET}"
    read -p "是否开启每天4点自动更新？(y/n): " confirm
    
    case "$confirm" in
        y) 
            read -p "输入下载代理（可选）: " proxy
            [ -n "$proxy" ] && echo "AUTO_UPDATE_PROXY=$proxy" | tee -a /etc/environment >/dev/null
            (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
            echo -e "${GREEN}自动更新已开启${RESET}"
            [ -n "$proxy" ] && echo -e "${GREEN}代理已设置：$proxy${RESET}"
            ;;
        n) 
            sed -i '/^AUTO_UPDATE_PROXY=/d' /etc/environment
            crontab -l | grep -Ev "$CRON_JOB" | crontab -
            echo -e "${GREEN}自动更新已关闭${RESET}"
            ;;
        *) echo -e "${RED}错误：无效选择${RESET}" ;;
    esac
    read -p "按回车继续..."
    clear
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo -e "${GREEN}Alist 管理工具 v1.0${RESET}"
        echo "————————————————————————————————————————"
        echo " 1. 安装 Alist"
        echo " 2. 更新 Alist"
        echo " 3. 卸载 Alist"
        echo " 4. 查看服务状态"
        echo " 5. 重置管理员密码"
        echo " 6. 启动 Alist 服务"
        echo " 7. 停止 Alist 服务"
        echo " 8. 重启 Alist 服务"
        echo " 9. 查看版本信息"
        echo "10. 设置自动更新"
        echo " 0. 退出工具"
        echo "————————————————————————————————————————"
        
        read -p "请输入选项 [0-10]: " choice
        
        case "$choice" in
            1) install_alist ;;
            2) update_alist ;;
            3) uninstall_alist ;;
            4) check_service_status ;;
            5) reset_admin_password ;;
            6) start_service ;;
            7) stop_service ;;
            8) restart_service ;;
            9) check_version_info ;;
            10) configure_auto_update ;;
            0) echo -e "${GREEN}退出工具，再见！${RESET}"; break ;;
            *) echo -e "${RED}错误：无效选项，请重新输入${RESET}" ;;
        esac
    done
}

# 脚本入口
if [ "$1" = "auto-update" ]; then
    auto_update_alist
else
    main_menu
fi
