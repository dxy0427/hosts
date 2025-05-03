#!/bin/sh

# 创建符号链接到 /usr/local/bin/
SCRIPT_NAME="alist-alpine.sh"
SYMLINK_PATH="/usr/local/bin/alist"
if [ ! -L "$SYMLINK_PATH" ]; then
    sudo ln -s "$(pwd)/$SCRIPT_NAME" "$SYMLINK_PATH"
    if [ $? -ne 0 ]; then
        echo "创建符号链接失败，请检查权限。"
        exit 1
    fi
fi

# 确保脚本可执行
if [ ! -x "./$SCRIPT_NAME" ]; then
    chmod +x "./$SCRIPT_NAME"
    if [ $? -ne 0 ]; then
        echo "设置脚本可执行权限失败，请检查权限。"
        exit 1
    fi
fi

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
CRON_JOB="0 4 * * * $(pwd)/$SCRIPT_NAME auto-update"
INSTALL_PATH="$DOWNLOAD_DIR"
ARCH="amd64"
if [ "$1" = "auto-update" ]; then
    # 记录开始时间
    start_time=$(date +%s)
    
    # 执行自动更新检查
    auto_update_alist
    
    # 计算运行时间
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    echo "自动更新检查完成，用时 ${duration} 秒"
    
    # 确保退出
    exit 0
fi

# 检查依赖
check_dependencies() {
    local dependencies="wget tar apk supervisor curl"
    echo "当前 PATH 环境变量: $PATH"
    for dep in $dependencies; do
        if ! command -v $dep >/dev/null 2>&1; then
            echo "错误: 缺少依赖 $dep，正在尝试安装..."
            apk add $dep || { echo "错误: 安装 $dep 失败，请手动安装。"; return 1; }
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

# 检查安装目录
CHECK() {
    # 检查目标目录是否存在，如果不存在则创建
    if [ ! -d "$(dirname "$INSTALL_PATH")" ]; then
        echo -e "${GREEN_COLOR}目录不存在，正在创建...${RES}"
        mkdir -p "$(dirname "$INSTALL_PATH")" || {
            echo -e "${RED_COLOR}错误：无法创建目录 $(dirname "$INSTALL_PATH")${RES}"
            exit 1
        }
    fi

    # 检查是否已安装
    if [ -f "$INSTALL_PATH/alist" ]; then
        echo "此位置已经安装，请选择其他位置，或使用更新命令"
        exit 0
    fi

    # 创建或清空安装目录
    if [ ! -d "$INSTALL_PATH/" ]; then
        mkdir -p $INSTALL_PATH || {
            echo -e "${RED_COLOR}错误：无法创建安装目录 $INSTALL_PATH${RES}"
            exit 1
        }
    else
        rm -rf $INSTALL_PATH && mkdir -p $INSTALL_PATH
    fi

    echo -e "${GREEN_COLOR}安装目录准备就绪：$INSTALL_PATH${RES}"
}

# 添加全局变量存储账号密码
ADMIN_USER=""
ADMIN_PASS=""

# 添加下载函数，包含重试机制
download_file() {
    local url="$1"
    local output="$2"
    local max_retries=3
    local retry_count=0
    local wait_time=5

    while [ $retry_count -lt $max_retries ]; do
        if curl -L --connect-timeout 10 --retry 3 --retry-delay 3 "$url" -o "$output"; then
            if [ -f "$output" ] && [ -s "$output" ]; then  # 检查文件是否存在且不为空
                return 0
            fi
        fi

        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            echo -e "${YELLOW_COLOR}下载失败，${wait_time} 秒后进行第 $((retry_count + 1)) 次重试...${RES}"
            sleep $wait_time
            wait_time=$((wait_time + 5))  # 每次重试增加等待时间
        else
            echo -e "${RED_COLOR}下载失败，已重试 $max_retries 次${RES}"
            return 1
        fi
    done
    return 1
}

# 安装 Alist（选项1）
INSTALL() {
    # 保存当前目录
    CURRENT_DIR=$(pwd)

    # 询问是否使用代理
    echo -e "${GREEN_COLOR}是否使用 GitHub 代理？（默认无代理）${RES}"
    echo -e "${GREEN_COLOR}代理地址必须为 https 开头，斜杠 / 结尾 ${RES}"
    echo -e "${GREEN_COLOR}例如：https://ghproxy.com/ ${RES}"
    read -p "请输入代理地址或直接按回车继续: " proxy_input

    # 如果用户输入了代理地址，则使用代理拼接下载链接
    if [ -n "$proxy_input" ]; then
        GH_PROXY="$proxy_input"
        GH_DOWNLOAD_URL="${GH_PROXY}https://github.com/alist-org/alist/releases/latest/download"
        echo -e "${GREEN_COLOR}已使用代理地址: $GH_PROXY${RES}"
    else
        # 如果不需要代理，直接使用默认链接
        GH_DOWNLOAD_URL="https://github.com/alist-org/alist/releases/latest/download"
        echo -e "${GREEN_COLOR}使用默认 GitHub 地址进行下载${RES}"
    fi

    # 下载 Alist 程序
    echo -e "\r\n${GREEN_COLOR}下载 Alist ...${RES}"

    # 使用拼接后的 GitHub 下载地址
    if ! download_file "${GH_DOWNLOAD_URL}/alist-linux-musl-$ARCH.tar.gz" "/tmp/alist.tar.gz"; then
        echo -e "${RED_COLOR}下载失败！${RES}"
        exit 1
    fi

    # 解压文件
    if ! tar zxf /tmp/alist.tar.gz -C $INSTALL_PATH/; then
        echo -e "${RED_COLOR}解压失败！${RES}"
        rm -f /tmp/alist.tar.gz
        exit 1
    fi

    if [ -f $INSTALL_PATH/alist ]; then
        echo -e "${GREEN_COLOR}下载成功，正在安装...${RES}"

        # 获取初始账号密码（临时切换目录）
        cd $INSTALL_PATH
        ACCOUNT_INFO=$($INSTALL_PATH/alist admin random 2>&1)
        ADMIN_USER=$(echo "$ACCOUNT_INFO" | grep "username:" | sed 's/.*username://')
        ADMIN_PASS=$(echo "$ACCOUNT_INFO" | grep "password:" | sed 's/.*password://')
        # 切回原目录
        cd "$CURRENT_DIR"
    else
        echo -e "${RED_COLOR}安装失败！${RES}"
        rm -rf $INSTALL_PATH
        mkdir -p $INSTALL_PATH
        exit 1
    fi

    # 清理临时文件
    rm -f /tmp/alist*
}

# 初始化 Supervisor 配置
INIT() {
    if [ ! -f "$INSTALL_PATH/alist" ]; then
        echo -e "\r\n${RED_COLOR}出错了${RES}，当前系统未安装 Alist\r\n"
        exit 1
    fi

    # 重新生成 Supervisor 配置文件
    echo_supervisord_conf > /etc/supervisord.conf

    # 编辑 Supervisor 配置
    cat << EOF >> /etc/supervisord.conf
[include]
files = /etc/supervisord_conf/*.ini
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

    # 重启 Supervisor 服务以应用新配置
    echo "正在重启 Supervisor 服务..."
    supervisorctl reread
    supervisorctl update
}

# 安装成功提示
SUCCESS() {
    clear  # 只在开始时清屏一次
    # 获取本地 IP
    LOCAL_IP=$(ip addr show | grep -w inet | grep -v "127.0.0.1" | awk '{print $2}' | cut -d/ -f1 | head -n1)
    # 获取公网 IPv4
    PUBLIC_IPV4=$(curl -s4 ip.sb || curl -s4 ifconfig.me || echo "获取失败")
    # 获取公网 IPv6
    PUBLIC_IPV6=$(curl -s6 ip.sb 2>/dev/null || curl -s6 ifconfig.me 2>/dev/null || echo "获取失败")

    echo "Alist 安装成功！"
    echo "  访问地址："
    echo "    局域网：http://${LOCAL_IP}:5244/"
    echo "    公网 IPv4：http://${PUBLIC_IPV4}:5244/"
    echo "    公网 IPv6：http://[${PUBLIC_IPV6}]:5244/"
    echo "  配置文件：$INSTALL_PATH/data/config.json"
    if [ ! -z "$ADMIN_USER" ] && [ ! -z "$ADMIN_PASS" ]; then
        echo "  账号信息："
        echo "    默认账号：$ADMIN_USER"
        echo "    初始密码：$ADMIN_PASS"
    fi

    # 安装命令行工具
    if ! INSTALL_CLI; then
        echo -e "${YELLOW_COLOR}警告：命令行工具安装失败，但不影响 Alist 的使用${RES}"
    fi

    echo -e "\n${GREEN_COLOR}启动服务中...${RES}"
    supervisorctl start alist
    echo -e "管理: 在任意目录输入 ${GREEN_COLOR}alist${RES} 打开管理菜单"

    echo -e "\n${YELLOW_COLOR}温馨提示：如果端口无法访问，请检查服务器安全组、防火墙和服务状态${RES}"
    read -p "按回车返回主菜单..."
    clear
}

# 安装命令行工具（假设这里只是一个占位函数）
INSTALL_CLI() {
    return 0
}

# 安装 Alist 整合函数
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
    CHECK
    INSTALL
    INIT
    SUCCESS
}

# 更新 Alist
update_alist() {
    local current_version=$(get_current_version)
    if [ "$current_version" = "未安装" ]; then
        echo "Alist 未安装，无法进行更新。"
        read -p "按回车继续..."
        clear
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
        read -p "按回车继续..."
        clear
        return
    fi

    if version_gt "$latest_version" "$current_version"; then
        read -p "检测到新版本 $latest_version，当前版本为 $current_version，是否进行更新？(y/n): " confirm
        if [ "$confirm" != "y" ]; then
            echo "更新操作已取消。"
            read -p "按回车继续..."
            clear
            return
        fi
    else
        echo "当前已是最新版本，无需更新。"
        read -p "按回车继续..."
        clear
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
        read -p "按回车继续..."
        clear
        return 1
    fi

    # 解压文件
    if ! tar zxf /tmp/alist.tar.gz -C "$DOWNLOAD_DIR"; then
        echo -e "${RED_COLOR}解压失败，更新终止${RES}"
        echo -e "${GREEN_COLOR}正在恢复之前的版本...${RES}"
        mv /tmp/alist.bak "$ALIST_BINARY"
        supervisorctl start alist
        rm -f /tmp/alist.tar.gz
        read -p "按回车继续..."
        clear
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
        read -p "按回车继续..."
        clear
        return 1
    fi

    # 清理临时文件
    rm -f /tmp/alist.tar.gz /tmp/alist.bak

    # 重启 Alist 服务
    echo -e "${GREEN_COLOR}启动 Alist 进程${RES}\r\n"
    supervisorctl restart alist

    echo -e "${GREEN_COLOR}更新完成！${RES}"
    read -p "按回车继续..."
    clear
}

# 自动更新 Alist
auto_update_alist() {
    local current_version=$(get_current_version)
    if [ "$current_version" = "未安装" ]; then
        echo "Alist 未安装，无法进行自动更新。"
        return
    fi
    local proxy=$(grep "^AUTO_UPDATE_PROXY=" /etc/environment | cut -d'=' -f2)
    local latest_version=$(get_latest_version "$proxy")
    if [ "$latest_version" = "无法获取最新版本信息" ]; then
        echo "无法获取最新版本信息，自动更新操作取消。"
        return
    fi

    if version_gt "$latest_version" "$current_version"; then
        echo -e "${GREEN_COLOR}检测到新版本 $latest_version，当前版本为 $current_version，开始自动更新...${RES}"

        # 停止 Alist 服务
        echo -e "${GREEN_COLOR}停止 Alist 进程${RES}\r\n"
        supervisorctl stop alist

        # 备份二进制文件
        cp "$ALIST_BINARY" /tmp/alist.bak

        # 下载新版本
        local GH_DOWNLOAD_URL
        if [ -n "$proxy" ]; then
            GH_DOWNLOAD_URL="${proxy}https://github.com/alist-org/alist/releases/latest/download"
        else
            GH_DOWNLOAD_URL="https://github.com/alist-org/alist/releases/latest/download"
        fi
        echo -e "${GREEN_COLOR}下载 Alist ...${RES}"
        wget "$GH_DOWNLOAD_URL/$ALIST_FILE" -O /tmp/alist.tar.gz
        if [ $? -ne 0 ]; then
            echo -e "${RED_COLOR}下载失败，自动更新终止${RES}"
            echo -e "${GREEN_COLOR}正在恢复之前的版本...${RES}"
            mv /tmp/alist.bak "$ALIST_BINARY"
            supervisorctl start alist
            return 1
        fi

        # 解压文件
        if ! tar zxf /tmp/alist.tar.gz -C "$DOWNLOAD_DIR"; then
            echo -e "${RED_COLOR}解压失败，自动更新终止${RES}"
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

        echo -e "${GREEN_COLOR}自动更新完成！${RES}"
    else
        echo "当前已是最新版本，无需更新。"
    fi
    # 确保服务正在运行
    if ! supervisorctl status alist | grep -q "RUNNING"; then
        echo -e "${YELLOW_COLOR}检测到服务未运行，尝试启动服务...${RES}"
        supervisorctl start alist
        sleep 2
        if ! supervisorctl status alist | grep -q "RUNNING"; then
            echo -e "${RED_COLOR}服务启动失败，请检查日志${RES}"
            return 1
        fi
    fi
}

# 卸载 Alist
uninstall_alist() {
    echo "警告：卸载操作将删除所有与 Alist 相关的数据，包括但不限于配置文件和存储的数据。"
    read -p "你确定要卸载 Alist 并删除所有数据吗？(y/n): " confirm
    if [ "$confirm" != "y" ]; then
        echo "卸载操作已取消。"
        read -p "按回车继续..."
        clear
        return
    fi

    cleanup_residuals

    # 停止 Alist 服务
    echo "正在停止 Alist 服务..."
    supervisorctl stop alist

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

    # 重启 Supervisor 服务以应用配置更改
    echo "正在重启 Supervisor 服务..."
    supervisorctl reread
    supervisorctl update

    # 删除脚本自身
    SCRIPT_PATH=$(realpath "$0")
    if [ -f "$SCRIPT_PATH" ]; then
        echo "正在删除脚本自身..."
        rm -f "$SCRIPT_PATH"
    else
        echo "脚本文件不存在，跳过删除操作。"
    fi

    # 删除快捷键
    if [ -L "$SYMLINK_PATH" ]; then
        echo "正在删除快捷键..."
        sudo rm -f "$SYMLINK_PATH"
    else
        echo "快捷键不存在，跳过删除操作。"
    fi

    # 删除 cron 任务
    crontab -l | grep -Ev "^[[:space:]]*0[[:space:]]+4[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+.*/alist-alpine.sh auto-update" | crontab -

    # 清理临时文件
    rm -f /tmp/alist.tar.gz /tmp/alist.bak

    echo "Alist 和相关配置已完全卸载。"
    clear  # 清屏
    exit 0 # 退出脚本
}

# 查看状态
check_status() {
    supervisorctl status alist
    if crontab -l | grep -qE "^[[:space:]]*0[[:space:]]+4[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+.*/alist-alpine.sh auto-update"; then
        echo "自动更新任务已开启，每天凌晨 4 点执行。"
    else
        echo "自动更新任务未开启。"
    fi
    read -p "按回车继续..."
    clear
}

# 重置密码
reset_password() {
    if [ ! -f "$DOWNLOAD_DIR/alist" ]; then
        echo -e "\r\n${RED_COLOR}错误：系统未安装 Alist，请先安装！${RES}\r\n"
        read -p "按回车继续..."
        clear
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
        read -p "按回车继续..."
        clear
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
                read -p "按回车继续..."
                clear
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
            read -p "按回车继续..."
            clear
            return 0
            ;;
        *)
            echo -e "${RED_COLOR}无效的选项${RES}"
            read -p "按回车继续..."
            clear
            return 1
            ;;
    esac
    read -p "按回车继续..."
    clear
    return 0
}

# 启动服务
start_service() {
    echo "正在启动 Alist 服务..."
    supervisorctl start alist
    supervisorctl status alist
    echo "Alist 服务已启动。"
    read -p "按回车继续..."
    clear
}

# 停止服务
stop_service() {
    echo "正在停止 Alist 服务..."
    supervisorctl stop alist
    echo "Alist 服务已停止。"
    read -p "按回车继续..."
    clear
}

# 重启服务
restart_service() {
    echo "正在重启 Alist 服务..."
    supervisorctl restart alist
    supervisorctl status alist
    echo "Alist 服务已重启。"
    read -p "按回车继续..."
    clear
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
    read -p "按回车继续..."
    clear
}

# 设置自动更新
set_auto_update() {
    read -p "是否开启每天凌晨 4 点自动更新？(y/n): " confirm
    if [ "$confirm" = "y" ]; then
        # 询问是否使用代理
        echo -e "${GREEN_COLOR}是否使用 GitHub 代理进行自动更新？（默认无代理）${RES}"
        echo -e "${GREEN_COLOR}代理地址必须为 https 开头，斜杠 / 结尾 ${RES}"
        echo -e "${GREEN_COLOR}例如：https://ghproxy.com/ ${RES}"
        read -p "请输入代理地址或直接按回车继续: " proxy_input
        if [ -n "$proxy_input" ]; then
            echo "AUTO_UPDATE_PROXY=$proxy_input" | sudo tee -a /etc/environment > /dev/null
            echo -e "${GREEN_COLOR}已设置自动更新代理地址: $proxy_input${RES}"
        else
            sudo sed -i '/^AUTO_UPDATE_PROXY=/d' /etc/environment
            echo -e "${GREEN_COLOR}未设置自动更新代理，使用默认地址进行更新${RES}"
        fi

        # 检查 cron 任务是否已存在
        if crontab -l | grep -qE "^[[:space:]]*0[[:space:]]+4[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+.*/alist-alpine.sh auto-update"; then
            echo "自动更新任务已存在，无需重复添加。"
        else
            # 添加 cron 任务
            (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
            if [ $? -eq 0 ]; then
                echo "已开启每天凌晨 4 点自动更新。"
            else
                echo "添加 cron 任务失败，请检查权限。"
            fi
        fi

        # 检查当前时区
        current_timezone=$(cat /etc/timezone 2>/dev/null)
        if [ "$current_timezone" = "Asia/Shanghai" ]; then
            echo "当前时区已经是 Asia/Shanghai，无需更改。"
        else
            # 设置时区
            if apk add tzdata; then
                if ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && echo "Asia/Shanghai" > /etc/timezone; then
                    echo "已将系统时区设置为 Asia/Shanghai"
                    # 显示当前时间
                    date
                else
                    echo "设置时区软链接或写入时区文件失败。"
                fi
            else
                echo "安装 tzdata 失败，请检查网络或权限。"
            fi
        fi
    elif [ "$confirm" = "n" ]; then
        # 检查 cron 任务是否存在
        if crontab -l | grep -qE "^[[:space:]]*0[[:space:]]+4[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+.*/alist-alpine.sh auto-update"; then
            echo "要删除的 cron 任务: $CRON_JOB"
            # 保存当前 crontab 任务到临时文件
            crontab -l > /tmp/crontab.tmp 2>/dev/null
            if [ $? -ne 0 ]; then
                echo "无法将 crontab 内容保存到临时文件，请检查权限。"
                return
            fi
            # 简化正则表达式并过滤掉自动更新任务
            grep -Ev "^[[:space:]]*0[[:space:]]+4[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+.*/alist-alpine.sh auto-update" /tmp/crontab.tmp > /tmp/crontab.filtered
            if [ $? -ne 0 ]; then
                echo "过滤 crontab 任务时出错。"
                return
            fi
            # 打印过滤后的内容
            echo "过滤后的 crontab 内容:"
            cat /tmp/crontab.filtered
            # 将过滤后的任务写回 crontab
            crontab /tmp/crontab.filtered
            if [ $? -eq 0 ]; then
                echo "已关闭每天凌晨 4 点自动更新。"
            else
                echo "删除 cron 任务失败，请检查权限。"
            fi
            # 删除临时文件
            rm -f /tmp/crontab.tmp /tmp/crontab.filtered
        else
            echo "自动更新任务不存在，无需删除。"
        fi
        sudo sed -i '/^AUTO_UPDATE_PROXY=/d' /etc/environment
    else
        echo "无效的选择，请输入 y 或 n。"
    fi
    read -p "按回车继续..."
    clear
}

# 主菜单
if [ "$1" = "auto-update" ]; then
    # 执行自动更新检查并退出
    auto_update_alist
    exit 0
else
    while true; do
        echo "Alist 管理工具"
        echo " 1. 安装Alist"
        echo " 2. 更新Alist"
        echo " 3. 卸载Alist"
        echo " 4. 查看状态"
        echo " 5. 重置密码"
        echo " 6. 启动服务"
        echo " 7. 停止服务"
        echo " 8. 重启服务"
        echo " 9. 检测版本信息"
        echo "10. 设置自动更新"
        echo " 0. 退出脚本"
        read -p "请输入你的选择: " choice

        case "$choice" in
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
            10)
                set_auto_update
                ;;
            0)
                echo "退出脚本"
                clear  # 清屏
                break
                ;;
            *)
                echo "无效的选择，请重新输入。"
                ;;
        esac
    done
fi
