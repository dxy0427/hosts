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

# 检查依赖
check_dependencies() {
    local dependencies="wget tar apk supervisor"
    echo "当前 PATH 环境变量: $PATH"
    for dep in $dependencies; do
        if ! command -v $dep >/dev/null 2>&1; then
            echo "错误: 缺少依赖 $dep，正在尝试安装..."
            if ! apk add $dep; then
                echo "错误: 安装 $dep 失败，请手动安装。"
                return 1
            fi
        fi
    done
    return 0
}

# 清理残留进程和配置
cleanup_residuals() {
    # 终止残留的 Alist 进程
    alist_pids=$(ps -ef | grep "$ALIST_BINARY server" | grep -v grep | awk '{print $2}')
    for pid in $alist_pids; do
        if [ "$pid" -eq "$pid" ] 2>/dev/null; then
            kill -9 $pid
        fi
    done
    # 清理残留配置文件
    rm -f "$SUPERVISOR_CONF_FILE"
    rm -rf ~/.alist
}

# 获取当前版本号
get_current_version() {
    if [ -f "$ALIST_BINARY" ]; then
        local version_output="$($ALIST_BINARY version 2>/dev/null)"
        local version=$(echo "$version_output" | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        echo "${version:-未安装}"
    else
        echo "未安装"
    fi
}

# 获取最新版本号
get_latest_version() {
    local proxy="$1"
    local url="https://api.github.com/repos/alist-org/alist/releases/latest"
    if [ -n "$proxy" ]; then
        url="${proxy}${url}"
    fi
    local latest=$(wget -q --no-check-certificate -O- "$url" 2>/dev/null)
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

    # 清理残留的 Supervisor 配置
    rm -f /etc/supervisord.conf
    rm -rf /etc/supervisord_conf
    rm -f /tmp/supervisor.sock

    # 重新生成 Supervisor 配置文件
    echo_supervisord_conf > /etc/supervisord.conf

    # 编辑 Supervisor 配置
    cat << EOF >> /etc/supervisord.conf
[include]
files = /etc/supervisord_conf/*.ini
EOF

    mkdir -p "$DOWNLOAD_DIR" && cd "$DOWNLOAD_DIR"
    echo -e "${GREEN_COLOR}是否使用 GitHub 代理？（默认无代理）${RES}"
    echo -e "${GREEN_COLOR}代理地址必须为 https 开头，斜杠 / 结尾 ${RES}"
    echo -e "${GREEN_COLOR}例如：https://ghproxy.com/ ${RES}"
    read -p "请输入代理地址或直接按回车继续: " proxy_input
    local GH_DOWNLOAD_URL
    if [ -n "$proxy_input" ]; then
        GH_DOWNLOAD_URL="${proxy_input}https://github.com/alist-org/alist/releases/latest/download"
        echo -e "${GREEN_COLOR}已使用代理地址: $proxy_input${RES}"
    else
        GH_DOWNLOAD_URL="https://github.com/alist-org/alist/releases/latest/download"
        echo -e "${GREEN_COLOR}使用默认 GitHub 地址进行下载${RES}"
    fi

    local url="${GH_DOWNLOAD_URL}/${ALIST_FILE}"
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

    # 获取初始账号密码
    ACCOUNT_INFO=$("$ALIST_BINARY" admin random 2>&1)
    ADMIN_USER=$(echo "$ACCOUNT_INFO" | grep "username:" | sed 's/.*username://')
    ADMIN_PASS=$(echo "$ACCOUNT_INFO" | grep "password:" | sed 's/.*password://')
    echo -e "${GREEN_COLOR}初始账号信息：${RES}"
    echo -e "${GREEN_COLOR}用户名: $ADMIN_USER${RES}"
    echo -e "${GREEN_COLOR}密码: $ADMIN_PASS${RES}"
}

# 更新 Alist
update_alist() {
    local current_version=$(get_current_version)
    if [ "$current_version" = "未安装" ]; then
        echo "Alist 未安装，无法进行更新。"
        return
    fi
    echo -e "${GREEN_COLOR}是否使用 GitHub 代理？（默认无代理）${RES}"
    echo -e "${GREEN_COLOR}代理地址必须为 https 开头，斜杠 / 结尾 ${RES}"
    echo -e "${GREEN_COLOR}例如：https://ghproxy.com/ ${RES}"
    read -p "请输入代理地址或直接按回车继续: " proxy_input
    local GH_DOWNLOAD_URL
    if [ -n "$proxy_input" ]; then
        GH_DOWNLOAD_URL="${proxy_input}https://github.com/alist-org/alist/releases/latest/download"
        echo -e "${GREEN_COLOR}已使用代理地址: $proxy_input${RES}"
    else
        GH_DOWNLOAD_URL="https://github.com/alist-org/alist/releases/latest/download"
        echo -e "${GREEN_COLOR}使用默认 GitHub 地址进行下载${RES}"
    fi

    local latest_version=$(get_latest_version "$proxy_input")
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

    echo -e "${GREEN_COLOR}开始更新 Alist ...${RES}"

    # 停止 Alist 服务
    echo -e "${GREEN_COLOR}停止 Alist 进程${RES}\r\n"
    supervisorctl stop alist

    # 备份二进制文件
    cp "$ALIST_BINARY" /tmp/alist.bak

    # 下载新版本
    echo -e "${GREEN_COLOR}下载 Alist ...${RES}"
    wget "$GH_DOWNLOAD_URL/$ALIST_FILE" -O /tmp/alist.tar.gz
    if [ $? -ne 0 ]; then
        echo -e "${RED_COLOR}下载失败，更新终止${RES}"
        echo -e "${GREEN_COLOR}正在恢复之前的版本...${RES}"
        mv /tmp/alist.bak "$ALIST_BINARY"
        supervisorctl start alist
        return 1
    fi

    # 解压文件
    if ! tar zxf /tmp/alist.tar.gz -C "$DOWNLOAD_DIR"; then
        echo -e "${RED_COLOR}解压失败，更新终止${RES}"
        echo -e "${GREEN_COLOR}正在恢复之前的版本...${RES}"
        mv /tmp/alist.bak "$ALIST_BINARY"
        supervisorctl start alist
        rm -f /tmp/alist.tar.gz
        return 1
    fi

    # 验证更新是否成功
    if [ -f "$ALIST_BINARY" ]; then
        echo -e "${GREEN_COLOR}下载成功，正在更新${RES}"
    else
        echo -e "${RED_COLOR}更新失败！${RES}"
        echo -e "${GREEN_COLOR}正在恢复之前的版本...${RES}"
        mv /tmp/alist.bak "$ALIST_BINARY"
        supervisorctl start alist
        rm -f /tmp/alist.tar.gz
        return 1
    fi

    # 清理临时文件
    rm -f /tmp/alist.tar.gz /tmp/alist.bak

    # 重启 Alist 服务
    echo -e "${GREEN_COLOR}启动 Alist 进程${RES}\r\n"
    supervisorctl restart alist

    echo -e "${GREEN_COLOR}更新完成！${RES}"
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

    # 检查 Supervisor 是否正在运行
    if service supervisord status >/dev/null 2>&1; then
        echo "正在停止 Alist 服务..."
        supervisorctl stop alist
    else
        echo "Supervisor 未运行，跳过停止 Alist 服务。"
    fi

    # 删除 Alist 安装目录
    if [ -d "$DOWNLOAD_DIR" ]; then
        echo "正在删除 Alist 安装目录..."
        rm -rf "$DOWNLOAD_DIR"
    else
        echo "Alist 安装目录不存在，跳过删除操作。"
    fi

    # 删除 Alist 进程配置文件
    rm -f "$SUPERVISOR_CONF_FILE"

    # 移除 /etc/supervisord.conf 中的 [include] 部分
    sed -i '/\[include\]/d' /etc/supervisord.conf
    sed -i '/files = \/etc\/supervisord_conf\/\*.ini/d' /etc/supervisord.conf

    # 检查 Supervisor 是否正在运行
    if service supervisord status >/dev/null 2>&1; then
        echo "正在更新 Supervisor 配置..."
        supervisorctl reread
        supervisorctl update
    else
        echo "Supervisor 未运行，跳过更新配置。"
    fi

    # 删除脚本自身
    SCRIPT_PATH=$(realpath "$0")
    if [ -f "$SCRIPT_PATH" ]; then
        echo "正在删除脚本自身..."
        rm -f "$SCRIPT_PATH"
    else
        echo "脚本文件不存在，跳过删除操作。"
    fi

    # 删除快捷键
    if [ -f "/usr/local/bin/alist" ]; then
        echo "正在删除快捷键..."
        rm -f "/usr/local/bin/alist"
    else
        echo "快捷键不存在，跳过删除操作。"
    fi

    echo "Alist 和相关配置已完全卸载。"
}

# 查看状态
check_status() {
    supervisorctl status alist
}

# 重置密码
reset_password() {
    if [ ! -f "$DOWNLOAD_DIR/alist" ]; then
        echo -e "\r\n${RED_COLOR}错误：系统未安装 Alist，请先安装！${RES}\r\n"
        return 1
    fi

    echo -e "\n请选择密码重置方式"
    echo -e "${GREEN_COLOR}1、生成随机密码${RES}"
    echo -e "${GREEN_COLOR}2、设置新密码${RES}"
    echo -e "${GREEN_COLOR}0、返回主菜单${RES}"
    echo
    read -p "请输入选项 [0-2]: " choice

    # 切换到 Alist 目录，并添加错误处理
    cd "$DOWNLOAD_DIR" || {
        echo -e "${RED_COLOR}错误：无法切换到 Alist 目录${RES}"
        return 1
    }

    case "$choice" in
        1)
            echo -e "${GREEN_COLOR}正在生成随机密码...${RES}"
            echo -e "\n${GREEN_COLOR}账号信息：${RES}"
            # 执行命令并获取输出
            output=$("./alist" admin random 2>&1)
            # 使用 awk 提取用户名和密码
            username=$(echo "$output" | awk -F': ' '/username:/ {print $2}')
            password=$(echo "$output" | awk -F': ' '/password:/ {print $2}')
            echo -e "${GREEN_COLOR}账号: $username${RES}"
            echo -e "${GREEN_COLOR}密码: $password${RES}"
            ;;
        2)
            read -p "请输入新密码: " new_password
            if [ -z "$new_password" ]; then
                echo -e "${RED_COLOR}错误：密码不能为空${RES}"
                return 1
            fi
            echo -e "${GREEN_COLOR}正在设置新密码...${RES}"
            echo -e "\n${GREEN_COLOR}账号信息：${RES}"
            # 执行命令并获取输出
            output=$("./alist" admin set "$new_password" 2>&1)
            # 使用 awk 提取用户名和密码
            username=$(echo "$output" | awk -F': ' '/username:/ {print $2}')
            password=$(echo "$output" | awk -F': ' '/password:/ {print $2}')
            echo -e "${GREEN_COLOR}账号: $username${RES}"
            echo -e "${GREEN_COLOR}密码: $password${RES}"
            ;;
        0)
            return 0
            ;;
        *)
            echo -e "${RED_COLOR}无效的选项${RES}"
            return 1
            ;;
    esac
    read -p "按回车返回主菜单..."
    return 0
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
    echo -e "${GREEN_COLOR}是否使用 GitHub 代理？（默认无代理）${RES}"
    echo -e "${GREEN_COLOR}代理地址必须为 https 开头，斜杠 / 结尾 ${RES}"
    echo -e "${GREEN_COLOR}例如：https://ghproxy.com/ ${RES}"
    read -p "请输入代理地址或直接按回车继续: " proxy_input
    local latest=$(get_latest_version "$proxy_input")

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
    echo "4. 查看状态"
    echo "5. 重置密码"
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
            check_status
            ;;
        5)
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