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
    alist_pids=$(ps -ef | grep "$ALIST_BINARY server" | grep -v grep | awk '{print $2}')
    for pid in $alist_pids; do
        kill -9 "$pid" 2>/dev/null
    done
    rm -f "$SUPERVISOR_CONF_FILE"
    rm -rf ~/.alist
}

# 获取当前版本号（直连）
get_current_version() {
    [ -f "$ALIST_BINARY" ] && "$ALIST_BINARY" version 2>/dev/null | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "未安装"
}

# 获取最新版本号（强制直连GitHub API，不使用代理）
get_latest_version() {
    local url="https://api.github.com/repos/alist-org/alist/releases/latest"
    local latest=$(curl -s -H "Accept: application/vnd.github.v3+json" "$url")
    echo "$latest" | grep -o '"tag_name": "[^"]*' | cut -d'"' -f4
}

# 比较版本号
version_gt() {
    test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"
}

# 检查安装目录
CHECK() {
    mkdir -p "$(dirname "$INSTALL_PATH")" || {
        echo -e "${RED_COLOR}错误：无法创建目录 $(dirname "$INSTALL_PATH")${RES}"
        exit 1
    }
    [ -f "$INSTALL_PATH/alist" ] && {
        echo "此位置已安装，请使用更新功能或选择其他目录"
        exit 0
    }
    rm -rf "$INSTALL_PATH" && mkdir -p "$INSTALL_PATH"
    echo -e "${GREEN_COLOR}安装目录准备就绪：$INSTALL_PATH${RES}"
}

# 带重试的下载函数
download_file() {
    local url="$1"
    local output="$2"
    local max_retries=3 retry_count=0 wait_time=5
    until [ $retry_count -ge $max_retries ]; do
        if curl -L --connect-timeout 10 --retry 3 --retry-delay 3 "$url" -o "$output"; then
            [ -s "$output" ] && return 0
        fi
        retry_count=$((retry_count + 1))
        [ $retry_count -lt $max_retries ] && echo -e "${YELLOW_COLOR}下载失败，${wait_time}秒后重试（第$retry_count次）${RES}" && sleep $wait_time && wait_time=$((wait_time + 5))
    done
    echo -e "${RED_COLOR}下载失败，已达最大重试次数${RES}"
    return 1
}

# 安装Alist（可选代理下载）
INSTALL() {
    local CURRENT_DIR=$(pwd)
    echo -e "${GREEN_COLOR}可选：输入GitHub下载代理（格式：https://ghproxy.com/，留空直连）${RES}"
    read -p "代理地址（以/结尾）: " GH_PROXY
    local DOWNLOAD_URL="${GH_PROXY:-$ALIST_DOWNLOAD_URL}/latest"
    
    echo -e "\r\n${GREEN_COLOR}开始下载Alist安装包...${RES}"
    if ! download_file "${DOWNLOAD_URL}/alist-linux-musl-$ARCH.tar.gz" "/tmp/alist.tar.gz"; then
        echo -e "${RED_COLOR}下载失败，安装终止${RES}"
        exit 1
    }
    
    tar zxf /tmp/alist.tar.gz -C "$INSTALL_PATH" || {
        echo -e "${RED_COLOR}解压失败，安装终止${RES}"
        rm -f /tmp/alist.tar.gz
        exit 1
    }
    
    [ -f "$INSTALL_PATH/alist" ] || {
        echo -e "${RED_COLOR}安装文件丢失，安装失败${RES}"
        rm -rf "$INSTALL_PATH"
        exit 1
    }
    
    cd "$INSTALL_PATH" && {
        ADMIN_USER=$("./alist" admin random 2>&1 | awk -F': ' '/username:/ {print $2}')
        ADMIN_PASS=$("./alist" admin random 2>&1 | awk -F': ' '/password:/ {print $2}')
    } && cd "$CURRENT_DIR"
    rm -f /tmp/alist.tar.gz
}

# 初始化Supervisor
INIT() {
    echo_supervisord_conf > /etc/supervisord.conf
    {
        echo "[include]"
        echo "files = /etc/supervisord_conf/*.ini"
    } >> /etc/supervisord.conf
    
    mkdir -p "$SUPERVISOR_CONF_DIR"
    {
        echo "[program:alist]"
        echo "directory=$DOWNLOAD_DIR"
        echo "command=$ALIST_BINARY server"
        echo "autostart=true"
        echo "autorestart=true"
        echo "environment=CODENATION_ENV=prod"
    } > "$SUPERVISOR_CONF_FILE"
    
    supervisorctl reread && supervisorctl update
}

# 安装成功提示
SUCCESS() {
    clear
    local LOCAL_IP=$(ip -4 addr show up | grep -v ' lo' | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)
    local PUBLIC_IPV4=$(curl -s4 icanhazip.com || curl -s4 ipinfo.io/ip || echo "获取失败")
    local PUBLIC_IPV6=$(curl -s6 icanhazip.com || curl -s6 ipinfo.io/ip || echo "获取失败")
    
    echo "Alist 安装成功！"
    [ -n "$LOCAL_IP" ] && echo "  局域网访问：http://${LOCAL_IP}:5244"
    [ "$PUBLIC_IPV4" != "获取失败" ] && echo "  公网IPv4访问：http://${PUBLIC_IPV4}:5244"
    [ "$PUBLIC_IPV6" != "获取失败" ] && echo "  公网IPv6访问：http://[${PUBLIC_IPV6}]:5244"
    echo "  配置文件：$DATA_DIR/config.json"
    
    [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASS" ] && {
        echo -e "\n${GREEN_COLOR}初始管理员账号：${RES}"
        echo "  用户名：$ADMIN_USER"
        echo "  密  码：$ADMIN_PASS"
    }
    
    echo -e "\n${GREEN_COLOR}启动服务中...${RES}"
    supervisorctl start alist
    echo -e "管理工具：在任意目录输入 ${GREEN_COLOR}alist${RES} 打开菜单"
    
    echo -e "\n${YELLOW_COLOR}提示：若无法访问，请检查防火墙/安全组开放5244端口${RES}"
    read -p "按回车返回主菜单..."
    clear
}

# 安装主流程
install_alist() {
    [ "$(get_current_version)" != "未安装" ] && {
        echo "Alist已安装，当前版本：$(get_current_version)"
        return
    }
    
    cleanup_residuals
    check_dependencies || return 1
    CHECK
    INSTALL
    INIT
    SUCCESS
}

# 更新Alist（可选代理下载）
update_alist() {
    local CUR_VERSION=$(get_current_version)
    [ "$CUR_VERSION" = "未安装" ] && {
        echo "未安装Alist，无法更新"
        read -p "按回车继续..."
        clear
        return
    }
    
    local LATEST_VERSION=$(get_latest_version)
    [ -z "$LATEST_VERSION" ] && {
        echo "无法获取最新版本信息，更新终止"
        read -p "按回车继续..."
        clear
        return
    }
    
    version_gt "$LATEST_VERSION" "$CUR_VERSION" || {
        echo "当前已是最新版本：$CUR_VERSION"
        read -p "按回车继续..."
        clear
        return
    }
    
    read -p "检测到新版本 $LATEST_VERSION，是否更新？(y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && {
        echo "更新已取消"
        read -p "按回车继续..."
        clear
        return
    }
    
    echo -e "${GREEN_COLOR}停止Alist服务...${RES}"
    supervisorctl stop alist
    
    cp "$ALIST_BINARY" /tmp/alist.bak || {
        echo -e "${RED_COLOR}备份旧版本失败，更新终止${RES}"
        supervisorctl start alist
        read -p "按回车继续..."
        clear
        return
    }
    
    echo -e "${GREEN_COLOR}可选：输入GitHub下载代理（格式：https://ghproxy.com/，留空直连）${RES}"
    read -p "代理地址（以/结尾）: " GH_PROXY
    local DOWNLOAD_URL="${GH_PROXY:-$ALIST_DOWNLOAD_URL}/$LATEST_VERSION"
    
    echo -e "${GREEN_COLOR}下载新版本...${RES}"
    wget -q "${DOWNLOAD_URL}/$ALIST_FILE" -O /tmp/alist.tar.gz || {
        echo -e "${RED_COLOR}下载失败，恢复旧版本...${RES}"
        mv /tmp/alist.bak "$ALIST_BINARY"
        supervisorctl start alist
        rm -f /tmp/alist.tar.gz
        read -p "按回车继续..."
        clear
        return
    }
    
    tar zxf /tmp/alist.tar.gz -C "$DOWNLOAD_DIR" || {
        echo -e "${RED_COLOR}解压失败，恢复旧版本...${RES}"
        mv /tmp/alist.bak "$ALIST_BINARY"
        supervisorctl start alist
        rm -f /tmp/alist.tar.gz
        read -p "按回车继续..."
        clear
        return
    }
    
    [ -f "$ALIST_BINARY" ] || {
        echo -e "${RED_COLOR}更新文件丢失，更新失败${RES}"
        mv /tmp/alist.bak "$ALIST_BINARY"
        supervisorctl start alist
        rm -f /tmp/alist.tar.gz
        read -p "按回车继续..."
        clear
        return
    }
    
    rm -f /tmp/alist.tar.gz /tmp/alist.bak
    echo -e "${GREEN_COLOR}重启Alist服务...${RES}"
    supervisorctl restart alist
    echo -e "${GREEN_COLOR}更新完成，当前版本：$(get_current_version)${RES}"
    read -p "按回车继续..."
    clear
}

# 自动更新（使用配置的代理下载，版本检查直连）
auto_update_alist() {
    local CUR_VERSION=$(get_current_version)
    [ "$CUR_VERSION" = "未安装" ] && return
    
    local LATEST_VERSION=$(get_latest_version)
    [ -z "$LATEST_VERSION" ] && {
        echo "无法获取最新版本，自动更新终止"
        return
    }
    
    version_gt "$LATEST_VERSION" "$CUR_VERSION" || {
        echo "当前已是最新版本，无需更新"
        return
    }
    
    echo -e "${GREEN_COLOR}检测到新版本 $LATEST_VERSION，开始自动更新...${RES}"
    supervisorctl stop alist
    
    cp "$ALIST_BINARY" /tmp/alist.bak || return 1
    local GH_PROXY=$(grep "^AUTO_UPDATE_PROXY=" /etc/environment | cut -d'=' -f2)
    local DOWNLOAD_URL="${GH_PROXY:-$ALIST_DOWNLOAD_URL}/$LATEST_VERSION"
    
    wget -q "${DOWNLOAD_URL}/$ALIST_FILE" -O /tmp/alist.tar.gz || {
        echo -e "${RED_COLOR}下载失败，恢复旧版本...${RES}"
        mv /tmp/alist.bak "$ALIST_BINARY"
        supervisorctl start alist
        return 1
    }
    
    tar zxf /tmp/alist.tar.gz -C "$DOWNLOAD_DIR" || {
        echo -e "${RED_COLOR}解压失败，恢复旧版本...${RES}"
        mv /tmp/alist.bak "$ALIST_BINARY"
        supervisorctl start alist
        rm -f /tmp/alist.tar.gz
        return 1
    }
    
    [ -f "$ALIST_BINARY" ] || {
        echo -e "${RED_COLOR}更新文件丢失，更新失败${RES}"
        mv /tmp/alist.bak "$ALIST_BINARY"
        supervisorctl start alist
        rm -f /tmp/alist.tar.gz
        return 1
    }
    
    rm -f /tmp/alist.tar.gz /tmp/alist.bak
    supervisorctl restart alist
    echo -e "${GREEN_COLOR}自动更新完成，当前版本：$(get_current_version)${RES}"
}

# 卸载Alist
uninstall_alist() {
    echo -e "${RED_COLOR}警告：卸载将删除所有数据和配置，无法恢复！${RES}"
    read -p "确认卸载？(y/n): " CONFIRM
    [ "$CONFIRM" != "y" ] && {
        echo "卸载已取消"
        read -p "按回车继续..."
        clear
        return
    }
    
    cleanup_residuals
    supervisorctl stop alist
    
    rm -rf "$DOWNLOAD_DIR"
    rm -f "$SUPERVISOR_CONF_FILE"
    sed -i '/^\[include\]/,/files = \/etc\/supervisord_conf\/\*.ini/d' /etc/supervisord.conf
    supervisorctl reread && supervisorctl update
    
    rm -f "$SYMLINK_PATH"
    crontab -l | grep -Ev "$CRON_JOB" | crontab -
    
    echo "Alist已完全卸载"
    clear
    exit 0
}

# 其他功能函数（状态检查、密码重置、服务控制等）
check_status() {
    echo -e "${GREEN_COLOR}Alist服务状态：${RES}"
    supervisorctl status alist
    crontab -l | grep -qE "$CRON_JOB" && echo -e "${GREEN_COLOR}自动更新已开启（每天4点）${RES}" || echo -e "${YELLOW_COLOR}自动更新未开启${RES}"
    read -p "按回车继续..."
    clear
}

reset_password() {
    [ ! -f "$ALIST_BINARY" ] && {
        echo -e "${RED_COLOR}未安装Alist，无法重置密码${RES}"
        read -p "按回车继续..."
        clear
        return
    }
    
    cd "$DOWNLOAD_DIR" || {
        echo -e "${RED_COLOR}无法进入Alist目录${RES}"
        read -p "按回车继续..."
        clear
        return
    }
    
    echo -e "${GREEN_COLOR}密码重置选项：${RES}"
    echo "1. 生成随机密码"
    echo "2. 设置自定义密码"
    echo "0. 返回"
    read -p "选择操作: " CHOICE
    
    case "$CHOICE" in
        1) local OUTPUT=$("./alist" admin random); echo -e "${GREEN_COLOR}新账号：$(echo "$OUTPUT" | awk -F': ' '/username:/ {print $2}')${RES}"; echo -e "${GREEN_COLOR}新密码：$(echo "$OUTPUT" | awk -F': ' '/password:/ {print $2}')${RES}" ;;
        2) read -p "输入新密码: " NEW_PASS; [ -z "$NEW_PASS" ] && { echo -e "${RED_COLOR}密码不能为空${RES}"; return; }; local OUTPUT=$("./alist" admin set "$NEW_PASS"); echo -e "${GREEN_COLOR}新账号：$(echo "$OUTPUT" | awk -F': ' '/username:/ {print $2}')${RES}"; echo -e "${GREEN_COLOR}新密码：$NEW_PASS${RES}" ;;
        0) cd - >/dev/null; return ;;
        *) echo -e "${RED_COLOR}无效选择${RES}" ;;
    esac
    
    cd - >/dev/null
    read -p "按回车继续..."
    clear
}

start_service() {
    supervisorctl start alist
    echo -e "${GREEN_COLOR}Alist服务已启动${RES}"
    read -p "按回车继续..."
    clear
}

stop_service() {
    supervisorctl stop alist
    echo -e "${GREEN_COLOR}Alist服务已停止${RES}"
    read -p "按回车继续..."
    clear
}

restart_service() {
    supervisorctl restart alist
    echo -e "${GREEN_COLOR}Alist服务已重启${RES}"
    read -p "按回车继续..."
    clear
}

check_version() {
    local CUR=$(get_current_version)
    local LATEST=$(get_latest_version)
    echo -e "${GREEN_COLOR}当前版本：${CUR}${RES}"
    echo -e "${YELLOW_COLOR}最新版本：${LATEST}${RES}"
    read -p "按回车继续..."
    clear
}

set_auto_update() {
    echo -e "${GREEN_COLOR}自动更新设置：${RES}"
    read -p "是否开启每天4点自动更新？(y/n): " CONFIRM
    
    case "$CONFIRM" in
        y) 
            read -p "输入下载代理（可选，格式https://xxx/）: " PROXY
            [ -n "$PROXY" ] && echo "AUTO_UPDATE_PROXY=$PROXY" | tee -a /etc/environment >/dev/null
            (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
            echo -e "${GREEN_COLOR}自动更新已开启${RES}"
            [ -n "$PROXY" ] && echo -e "${GREEN_COLOR}代理已设置：$PROXY${RES}"
            ;;
        n) 
            sed -i '/^AUTO_UPDATE_PROXY=/d' /etc/environment
            crontab -l | grep -Ev "$CRON_JOB" | crontab -
            echo -e "${GREEN_COLOR}自动更新已关闭${RES}"
            ;;
        *) echo -e "${RED_COLOR}无效选择${RES}" ;;
    esac
    
    read -p "按回车继续..."
    clear
}

# 主菜单
if [ "$1" = "auto-update" ]; then
    auto_update_alist
else
    while true; do
        echo -e "\n${GREEN_COLOR}Alist 管理工具${RES}"
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
        
        read -p "请输入选项 [0-10]: " CHOICE
        
        case "$CHOICE" in
            1) install_alist ;;
            2) update_alist ;;
            3) uninstall_alist ;;
            4) check_status ;;
            5) reset_password ;;
            6) start_service ;;
            7) stop_service ;;
            8) restart_service ;;
            9) check_version ;;
            10) set_auto_update ;;
            0) echo "退出工具"; clear; break ;;
            *) echo -e "${RED_COLOR}无效选项，请重新输入${RES}" ;;
        esac
    done
fi
