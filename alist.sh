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
RED_COLOR="\033[31m"
RES="\033[0m"
DATA_DIR="$DOWNLOAD_DIR/data"

# 检查并安装依赖
check_and_install_dependencies() {
    local dependencies="wget tar supervisor curl"
    echo "正在检查依赖项..."
    for dep in $dependencies; do
        if ! command -v $dep >/dev/null 2>&1; then
            echo -e "${YELLOW_COLOR}缺少依赖: $dep，正在安装...${RES}"
            apk add --no-cache "$dep"
            if [ $? -ne 0 ]; then
                echo -e "${RED_COLOR}安装依赖 $dep 失败，请检查网络连接或软件源。${RES}"
                exit 1
            fi
        fi
    done
    echo -e "${GREEN_COLOR}所有依赖项已安装。${RES}"
}

# 获取 Alist 下载链接
get_download_url() {
    local proxy="$1"
    curl -s ${proxy:+"--proxy $proxy"} https://api.github.com/repos/alist-org/alist/releases/latest |
    grep -o '"browser_download_url": "[^"]*alist-linux-musl-amd64.tar.gz"' | cut -d'"' -f4
}

# 清理残留文件和服务
cleanup_residuals() {
    echo "正在清理残留文件和配置..."
    supervisorctl stop alist 2>/dev/null || true
    rm -f "$SUPERVISOR_CONF_FILE"
    rm -rf "$DATA_DIR"
    rm -f "$ALIST_BINARY"
    echo "清理完成。"
}

# 安装 Alist
install_alist() {
    check_and_install_dependencies
    echo "开始安装 Alist..."

    # 清理旧版本
    cleanup_residuals

    # 创建安装目录
    mkdir -p "$DOWNLOAD_DIR" && cd "$DOWNLOAD_DIR"

    # 获取下载链接
    echo -e "${GREEN_COLOR}输入 GitHub 代理（可选，格式：http://proxy:port）${RES}"
    read -p "代理地址: " proxy
    local url=$(get_download_url "$proxy")
    if [ -z "$url" ]; then
        echo -e "${RED_COLOR}获取 Alist 下载链接失败，请检查网络或代理设置。${RES}"
        exit 1
    fi

    # 下载并解压
    echo "正在下载 Alist..."
    wget "$url" -O alist.tar.gz
    if [ $? -ne 0 ]; then
        echo -e "${RED_COLOR}下载失败，请检查网络连接。${RES}"
        exit 1
    fi
    echo "正在解压 Alist..."
    tar -zxvf alist.tar.gz && chmod +x "$ALIST_BINARY"
    rm -f alist.tar.gz

    # 配置 Supervisor
    echo "正在配置 Supervisor..."
    rc-update add supervisord boot
    service supervisord restart
    mkdir -p "$SUPERVISOR_CONF_DIR"
    cat << EOF > "$SUPERVISOR_CONF_FILE"
[program:alist]
directory=$DOWNLOAD_DIR
command=$ALIST_BINARY server
autostart=true
autorestart=true
stderr_logfile=/var/log/alist.err.log
stdout_logfile=/var/log/alist.out.log
EOF

    # 启动服务
    supervisorctl reread
    supervisorctl update
    supervisorctl start alist
    echo -e "${GREEN_COLOR}Alist 安装完成！${RES}"
}

# 更新 Alist
update_alist() {
    echo "正在检查 Alist 是否已安装..."
    if [ ! -f "$ALIST_BINARY" ]; then
        echo -e "${RED_COLOR}Alist 未安装，无法更新。${RES}"
        return
    fi

    # 获取当前版本和最新版本
    local proxy=""
    echo -e "${GREEN_COLOR}输入 GitHub 代理（可选，格式：http://proxy:port）${RES}"
    read -p "代理地址: " proxy
    local latest_version=$(curl -s ${proxy:+"--proxy $proxy"} https://api.github.com/repos/alist-org/alist/releases/latest | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4)
    local current_version=$("$ALIST_BINARY" version 2>/dev/null)

    echo -e "${GREEN_COLOR}当前版本: ${current_version}${RES}"
    echo -e "${YELLOW_COLOR}最新版本: ${latest_version}${RES}"

    if [ "$current_version" = "$latest_version" ]; then
        echo -e "${GREEN_COLOR}Alist 已是最新版本，无需更新。${RES}"
        return
    fi

    echo "开始更新 Alist..."
    cleanup_residuals
    install_alist
    echo -e "${GREEN_COLOR}Alist 更新完成！${RES}"
}

# 卸载 Alist
uninstall_alist() {
    echo "警告：卸载操作将删除所有数据和配置。"
    read -p "确认卸载 Alist 吗？(y/n): " confirm
    if [ "$confirm" != "y" ]; then
        echo "卸载操作已取消。"
        return
    fi
    cleanup_residuals
    supervisorctl remove alist 2>/dev/null || true
    echo -e "${GREEN_COLOR}Alist 已成功卸载。${RES}"
}

# 重置管理员密码
reset_password() {
    if [ ! -f "$ALIST_BINARY" ]; then
        echo -e "${RED_COLOR}Alist 未安装，无法重置密码。${RES}"
        return
    fi

    echo "正在重置管理员密码..."
    local output=$("$ALIST_BINARY" admin random 2>/dev/null)
    if [ -z "$output" ]; then
        echo -e "${RED_COLOR}重置密码失败，请检查 Alist 是否正常运行。${RES}"
        return
    fi

    local username=$(echo "$output" | grep -oP '(?<=username: ).*')
    local password=$(echo "$output" | grep -oP '(?<=password: ).*')
    echo -e "${GREEN_COLOR}新账号: $username${RES}"
    echo -e "${GREEN_COLOR}新密码: $password${RES}"
}

# 服务管理
start_service() {
    echo "正在启动 Alist 服务..."
    supervisorctl start alist
    echo -e "${GREEN_COLOR}服务已启动。${RES}"
}

stop_service() {
    echo "正在停止 Alist 服务..."
    supervisorctl stop alist
    echo -e "${YELLOW_COLOR}服务已停止。${RES}"
}

restart_service() {
    echo "正在重启 Alist 服务..."
    supervisorctl restart alist
    echo -e "${GREEN_COLOR}服务已重启。${RES}"
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n${GREEN_COLOR}Alist 管理工具${RES}"
        echo "1. 安装 Alist"
        echo "2. 更新 Alist"
        echo "3. 卸载 Alist"
        echo "4. 重置管理员密码"
        echo "5. 启动服务"
        echo "6. 停止服务"
        echo "7. 重启服务"
        echo "0. 退出"
        read -p "请选择操作 [0-7]: " choice
        case "$choice" in
            1) install_alist ;;
            2) update_alist ;;
            3) uninstall_alist ;;
            4) reset_password ;;
            5) start_service ;;
            6) stop_service ;;
            7) restart_service ;;
            0) echo "退出"; break ;;
            *) echo -e "${RED_COLOR}无效选项，请重新输入。${RES}" ;;
        esac
    done
}

# 程序入口
main_menu