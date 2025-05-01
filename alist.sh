#!/bin/sh

# 定义变量
ALIST_DOWNLOAD_URL="https://github.com/alist-org/alist/releases/download"
ALIST_FILE="alist-linux-musl-amd64.tar.gz"
DOWNLOAD_DIR="/opt/alist"
ALIST_BINARY="$DOWNLOAD_DIR/alist"
SUPERVISOR_CONF_DIR="/etc/supervisord_conf"
SUPERVISOR_CONF_FILE="$SUPERVISOR_CONF_DIR/alist.ini"
GREEN_COLOR="\033[32m"
YELLOW_COLOR="\033[33m"
RES="\033[0m"
DATA_DIR="$DOWNLOAD_DIR/data"

# 检查依赖
check_dependencies() {
    local dependencies="wget tar apk supervisord"
    echo "当前 PATH 环境变量: $PATH"
    for dep in $dependencies; do
        if ! command -v $dep >/dev/null 2>&1; then
            echo "错误: 缺少依赖 $dep，请安装。"
            return 1
        fi
    done
    return 0
}

# 获取下载链接（支持代理）
get_download_url() {
    local proxy="$1"
    wget -q --no-check-certificate ${proxy:+"--proxy=$proxy"} -O- https://api.github.com/repos/alist-org/alist/releases/latest |
    grep -o '"browser_download_url": "[^"]*alist-linux-musl-amd64.tar.gz"' | cut -d'"' -f4
}

# 清理残留进程和配置
cleanup_residuals() {
    # 终止残留的 Alist 进程
    alist_pids=$(ps -ef | grep "$ALIST_BINARY server" | grep -v grep | awk '{print $2}')
    if [ -n "$alist_pids" ]; then
        kill -9 $alist_pids
    fi
    # 清理残留配置文件
    rm -f "$SUPERVISOR_CONF_FILE"
    rm -rf ~/.alist
}

# 获取当前版本号
get_current_version() {
    if [ -f "$ALIST_BINARY" ]; then
        "$ALIST_BINARY" version 2>/dev/null || echo "未安装"
    else
        echo "未安装"
    fi
}

# 获取最新版本号
get_latest_version() {
    local proxy="$1"
    local latest=$(wget -q --no-check-certificate ${proxy:+"--proxy=$proxy"} -O- https://api.github.com/repos/alist-org/alist/releases/latest 2>/dev/null)
    if [ -z "$latest" ]; then
        echo "无法获取最新版本信息"
    else
        echo "$latest" | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4
    fi
}

# 比较版本号
version_gt() {
    test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1";
}

# 安装 Alist（选项1）
install_alist() {
    local current_version=$(get_current_version)
    if [ "$current_version" = "未安装" ]; then
        read -p "检查到未安装 Alist，是否进行安装？(y/n): " confirm
        if [ "$confirm" != "y" ]; then
            echo "安装操作已取消。"
            return
        fi
    else
        echo "Alist 已安装，当前版本为 $current_version。"
        return
    fi
    cleanup_residuals
    check_dependencies
    if [ $? -ne 0 ]; then
        return 1
    fi
    apk add supervisor wget tar --no-cache --no-interactive

    mkdir -p "$DOWNLOAD_DIR" && cd "$DOWNLOAD_DIR"
    echo -e "${GREEN_COLOR}输入 GitHub 代理（可选，格式：http://proxy:port）${RES}"
    read -p "代理地址: " proxy
    local url=$(get_download_url "$proxy")
    if [ -z "$url" ]; then
        echo "获取链接失败"
        return 1
    fi

    wget "$url" -O alist.tar.gz
    if [ $? -ne 0 ]; then
        echo "下载失败"
        return 1
    fi
    tar -zxvf alist.tar.gz && chmod +x "$ALIST_BINARY"

    # 删除下载的临时文件
    rm -f alist.tar.gz

    # 安装并配置 Supervisor
    echo "正在设置 Supervisor 开机启动..."
    rc-update add supervisord boot
    echo "正在重启 Supervisor 服务..."
    service supervisord restart
    echo "正在生成 Supervisor 配置文件..."
    echo_supervisord_conf > /etc/supervisord.conf

    # 编辑 Supervisor 配置
    echo "正在更新 Supervisor 配置文件..."
    cat << EOF >> /etc/supervisord.conf
[include]
files = $SUPERVISOR_CONF_DIR/*.ini
EOF

    # 创建并配置 alist 进程
    echo "正在创建 Alist 进程配置文件..."
    mkdir -p "$SUPERVISOR_CONF_DIR"
    cat << EOF > "$SUPERVISOR_CONF_FILE"
[program:alist]
directory=$DOWNLOAD_DIR
command=$ALIST_BINARY server
autostart=true
autorestart=true
environment=CODENATION_ENV=prod
EOF

    echo "正在启动 Supervisor 并启动 Alist 服务..."
    supervisorctl reread
    supervisorctl update
    supervisorctl start alist
    supervisorctl status alist
    echo "Alist 安装完成。"
}

# 更新 Alist
update_alist() {
    local current_version=$(get_current_version)
    if [ "$current_version" = "未安装" ]; then
        echo "Alist 未安装，无法进行更新。"
        return
    fi
    echo -e "${GREEN_COLOR}输入 GitHub 代理（可选，格式：http://proxy:port）${RES}"
    read -p "代理地址: " proxy
    local latest_version=$(get_latest_version "$proxy")
    if [ "$latest_version" = "无法获取最新版本信息" ]; then
        echo "无法获取最新版本信息，更新操作取消。"
        return
    fi
    if version_gt "$latest_version" "$current_version"; then
        read -p "检测到新版本 $latest_version，当前版本为 $current_version，是否进行更新？(y/n): " confirm
        if [ "$confirm" != "y" ]; then
            echo "更新操作已取消。"
            return
        fi
    else
        echo "当前已是最新版本，无需更新。"
        return
    fi
    cleanup_residuals
    echo "正在停止 Alist 服务..."
    supervisorctl stop alist
    echo "正在删除旧的 Alist 二进制文件..."
    rm "$ALIST_BINARY"
    mkdir -p "$DOWNLOAD_DIR" && cd "$DOWNLOAD_DIR"
    local url=$(get_download_url "$proxy")
    if [ -z "$url" ]; then
        echo "获取链接失败"
        return 1
    fi

    wget "$url" -O alist.tar.gz
    if [ $? -ne 0 ]; then
        echo "下载失败"
        return 1
    fi
    tar -zxvf alist.tar.gz && chmod +x "$ALIST_BINARY"

    # 删除下载的临时文件
    rm -f alist.tar.gz
    echo "正在启动 Alist 服务..."
    supervisorctl reread
    supervisorctl update
    supervisorctl start alist
    echo "Alist 更新完成。"
}

# 卸载 Alist
uninstall_alist() {
    echo "警告：卸载操作将删除所有与 Alist 相关的数据，包括但不限于配置文件和存储的数据。"
    read -p "你确定要卸载 Alist 并删除所有数据吗？(y/n): " confirm
    if [ "$confirm" != "y" ]; then
        echo "卸载操作已取消。"
        return
    fi
    cleanup_residuals
    echo "正在停止 Alist 服务..."
    supervisorctl stop alist
    echo "正在删除 Alist 二进制文件..."
    rm "$ALIST_BINARY"
    echo "正在删除 Alist 进程配置文件..."
    rm -f "$SUPERVISOR_CONF_FILE"
    echo "正在删除 data 目录..."
    rm -rf "$DATA_DIR"
    echo "正在从 Supervisor 中移除 Alist 配置..."
    supervisorctl remove alist  # 确保 Supervisor 中不再包含 Alist 的配置
    echo "Alist 卸载完成。"
}

# 重置管理员密码
reset_password() {
    local path="$DOWNLOAD_DIR"
    cd "$path" || { echo "目录错误"; return; }

    while true; do
        echo -e "\n${GREEN_COLOR}5. 密码重置菜单${RES}"
        echo "1. 生成随机密码"
        echo "2. 设置自定义密码"
        echo "0. 返回主菜单"
        read -p "选择: " opt

        case $opt in
            1)
                output=$("$ALIST_BINARY" admin random)
                username=$(echo "$output" | grep "username:" | awk -F ': ' '{print $2}')
                password=$(echo "$output" | grep "password:" | awk -F ': ' '{print $2}')
                echo "账号: $username"
                echo "密码: $password"
                break
                ;;
            2)
                read -p "新密码: " new_password
                if [ -n "$new_password" ]; then
                    "$ALIST_BINARY" admin set "$new_password"
                    supervisorctl restart alist
                fi
                break
                ;;
            0)
                return
                ;;
            *)
                echo "无效选项"
                ;;
        esac
    done
    read -p "按回车返回主菜单..."
}

# 启动服务
start_service() {
    echo "正在启动 Alist 服务..."
    supervisorctl start alist
    supervisorctl status alist
    echo "Alist 服务已启动。"
}

# 停止服务
stop_service() {
    echo "正在停止 Alist 服务..."
    supervisorctl stop alist
    echo "Alist 服务已停止。"
}

# 重启服务
restart_service() {
    echo "正在重启 Alist 服务..."
    supervisorctl restart alist
    supervisorctl status alist
    echo "Alist 服务已重启。"
}

# 检测版本信息
check_version() {
    local curr=$(get_current_version)
    local proxy=""
    echo -e "${GREEN_COLOR}输入 GitHub 代理（可选，格式：http://proxy:port）${RES}"
    read -p "代理地址: " proxy
    local latest=$(get_latest_version "$proxy")

    echo -e "${GREEN_COLOR}当前版本: ${curr}${RES}"
    echo -e "${YELLOW_COLOR}最新版本: ${latest}${RES}"
    read -p "按回车返回主菜单..."
}

# 主菜单
while true; do
    echo "Alist 管理工具"
    echo "1. 安装Alist"
    echo "2. 更新Alist"
    echo "3. 卸载Alist"
    echo "4. 重置管理员密码"
    echo "6. 启动服务"
    echo "7. 停止服务"
    echo "8. 重启服务"
    echo "9. 检测版本信息"
    echo "0. 退出脚本"
    read -p "请输入你的选择: " choice

    case $choice in
        1)
            install_alist
            ;;
        2)
            update_alist
            ;;
        3)
            uninstall_alist
            ;;
        4)
            reset_password
            ;;
        6)
            start_service
            ;;
        7)
            stop_service
            ;;
        8)
            restart_service
            ;;
        9)
            check_version
            ;;
        0)
            echo "退出脚本"
            break
            ;;
        *)
            echo "无效的选择，请重新输入。"
            ;;
    esac
done    
