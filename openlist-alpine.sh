#!/bin/sh

# --- Script Setup & Configuration ---
# Resolve the script's actual directory, not the current working directory
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT_NAME=$(basename "$0") # More robust way to get script name
SYMLINK_PATH="/usr/local/bin/openlist"

# Ensure script is executable (referencing its actual location)
if [ ! -x "$SCRIPT_DIR/$SCRIPT_NAME" ]; then
    chmod +x "$SCRIPT_DIR/$SCRIPT_NAME"
    if [ $? -ne 0 ]; then
        echo "设置脚本可执行权限失败，请检查权限。可能需要手动执行: chmod +x $SCRIPT_DIR/$SCRIPT_NAME"
    fi
fi

# Create symlink if it doesn't exist (referencing its actual location)
if [ ! -L "$SYMLINK_PATH" ]; then
    echo "正在尝试创建符号链接 $SYMLINK_PATH 指向 $SCRIPT_DIR/$SCRIPT_NAME"
    if [ ! -w "/usr/local/bin" ]; then
        echo "需要 sudo 权限来创建符号链接到 /usr/local/bin/"
        if command -v sudo >/dev/null 2>&1; then
            sudo ln -s "$SCRIPT_DIR/$SCRIPT_NAME" "$SYMLINK_PATH"
        else
            echo "sudo 命令未找到，无法自动创建符号链接。请手动创建或使用 root 权限运行此脚本一次。"
        fi
    else
        ln -s "$SCRIPT_DIR/$SCRIPT_NAME" "$SYMLINK_PATH"
    fi

    if [ $? -ne 0 ] && [ ! -L "$SYMLINK_PATH" ]; then
        echo "创建符号链接失败。脚本仍可直接运行，但 'openlist' 命令可能无效。"
    elif [ -L "$SYMLINK_PATH" ]; then
        echo "符号链接 $SYMLINK_PATH 创建成功。"
    fi
fi

# --- Variables ---
ARCH_RAW=$(uname -m)
case "$ARCH_RAW" in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *)
        echo -e "\033[31m错误: 不支持的系统架构: $ARCH_RAW\033[0m"
        echo "此脚本仅支持 x86_64 (amd64) 和 aarch64 (arm64) 架构。"
        exit 1
        ;;
esac

OPENLIST_FILE="openlist-linux-musl-${ARCH}.tar.gz"
DOWNLOAD_DIR="/opt/openlist"
OPENLIST_BINARY="$DOWNLOAD_DIR/openlist"
DATA_DIR="$DOWNLOAD_DIR/data"
SUPERVISOR_CONF_DIR="/etc/supervisor.d"
OPENLIST_SUPERVISOR_CONF_FILE="$SUPERVISOR_CONF_DIR/openlist.ini"

GREEN_COLOR="\033[32m"
YELLOW_COLOR="\033[33m"
RED_COLOR="\033[31m"
RES="\033[0m"

CRON_JOB_COMMAND="$SCRIPT_DIR/$SCRIPT_NAME auto-update"

# --- Helper Functions ---

_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo -e "${RED_COLOR}错误: 此操作需要 root 权限，并且 sudo 命令未找到。${RES}"
        return 1
    fi
    return $?
}

check_dependencies() {
    local missing_deps=""
    local dependencies="wget tar curl supervisor file"
    echo "正在检查依赖: $dependencies..."
    for dep in $dependencies; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps="$missing_deps $dep"
        fi
    done

    if [ -n "$missing_deps" ]; then
        echo -e "${RED_COLOR}错误: 缺少核心依赖$missing_deps，正在尝试安装...${RES}"
        if ! _sudo apk add --no-cache$missing_deps; then
            echo -e "${RED_COLOR}错误: 安装依赖$missing_deps失败，请手动安装。${RES}"
            return 1
        fi
        echo -e "${GREEN_COLOR}依赖$missing_deps安装成功。${RES}"
    fi
    echo "依赖检查完成。"
    return 0
}

get_current_version() {
    if [ -x "$OPENLIST_BINARY" ]; then
        local version_output=$(_sudo "$OPENLIST_BINARY" version 2>/dev/null)
        local version=$(echo "$version_output" | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        echo "${version:-未安装或无法获取}"
    else
        echo "未安装"
    fi
}

get_latest_version() {
    local url="https://api.github.com/repos/OpenListTeam/OpenList/releases/latest"
    local latest_json=$(curl -sL --connect-timeout 10 "$url" 2>/dev/null)
    if [ -z "$latest_json" ] || echo "$latest_json" | grep -q "API rate limit exceeded"; then
        echo "无法获取"
    else
        echo "$latest_json" | grep -o '"tag_name": *"[^"]*"' | sed 's/"tag_name": *"//; s/"$//'
    fi
}

version_gt() {
    test "$(printf '%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2"
}

download_with_retry() {
    local url="$1"
    local output_path="$2"
    echo -e "${GREEN_COLOR}正在下载: $url ${RES}"
    if ! curl -L --connect-timeout 15 --retry 3 --retry-delay 5 "$url" -o "$output_path" || [ ! -s "$output_path" ]; then
        echo -e "${RED_COLOR}下载失败。${RES}"; return 1
    fi
    if ! file "$output_path" | grep -q "gzip compressed data"; then
        echo -e "${RED_COLOR}下载的文件不是有效的压缩包。${RES}"; return 1
    fi
    echo -e "${GREEN_COLOR}下载成功。${RES}"
    return 0
}

# --- Main Operations ---

setup_supervisor() {
    echo "正在配置 Supervisor..."
    # Ensure supervisor is installed
    if ! command -v supervisord >/dev/null 2>&1; then
        echo "正在安装 Supervisor..."
        _sudo apk add --no-cache supervisor
    fi
    
    # Create config file
    _sudo sh -c "cat > '$OPENLIST_SUPERVISOR_CONF_FILE'" << EOF
[program:openlist]
directory=$DOWNLOAD_DIR
command=$OPENLIST_BINARY server --data $DATA_DIR
autostart=true
autorestart=true
startsecs=5
stopsignal=QUIT
stdout_logfile=/var/log/openlist_stdout.log
stderr_logfile=/var/log/openlist_stderr.log
environment=GIN_MODE=release
EOF

    # Force kill any running supervisor and restart with new config
    _sudo pkill supervisord
    sleep 1
    _sudo supervisord -c /etc/supervisord.conf
    sleep 1
    
    _sudo supervisorctl reread
    _sudo supervisorctl update
    _sudo supervisorctl start openlist

    sleep 2
    if ! _sudo supervisorctl status openlist | grep -q "RUNNING"; then
        echo -e "${RED_COLOR}OpenList 服务启动失败，请检查日志。${RES}"
        return 1
    fi
    return 0
}

do_install_openlist() {
    if [ "$(get_current_version)" != "未安装" ]; then
        echo -e "${YELLOW_COLOR}OpenList 已安装，如需重装请先卸载。${RES}"
        return
    fi
    check_dependencies || return 1
    
    local latest_version=$(get_latest_version)
    if [ "$latest_version" = "无法获取" ]; then
        echo -e "${RED_COLOR}无法获取最新版本信息，安装中止。${RES}"; return 1
    fi
    
    _sudo mkdir -p "$DOWNLOAD_DIR" "$DATA_DIR"
    
    local download_url="https://github.com/OpenListTeam/OpenList/releases/download/${latest_version}/$OPENLIST_FILE"
    local temp_path="/tmp/$OPENLIST_FILE"
    download_with_retry "$download_url" "$temp_path" || return 1
    
    echo "正在解压..."
    _sudo tar zxf "$temp_path" -C "$DOWNLOAD_DIR/" || { echo -e "${RED_COLOR}解压失败!${RES}"; _sudo rm -f "$temp_path"; return 1; }
    _sudo rm -f "$temp_path"
    _sudo chmod +x "$OPENLIST_BINARY"
    
    setup_supervisor
}

do_update_openlist() {
    local current_version=$(get_current_version)
    if [ "$current_version" = "未安装" ]; then echo -e "${RED_COLOR}OpenList 未安装，无法更新。${RES}"; return; fi
    
    local latest_version=$(get_latest_version)
    if [ "$latest_version" = "无法获取" ]; then echo -e "${RED_COLOR}无法获取最新版本信息。${RES}"; return; fi
    
    echo "当前版本: $current_version, 最新版本: $latest_version"
    if ! version_gt "$latest_version" "$current_version"; then echo -e "${GREEN_COLOR}当前已是最新版本。${RES}"; return; fi

    read -p "检测到新版本 ${latest_version}，是否更新? (y/n): " confirm
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && { echo "更新已取消。"; return; }

    echo "正在停止 OpenList 服务..."
    _sudo supervisorctl stop openlist

    local download_url="https://github.com/OpenListTeam/OpenList/releases/download/${latest_version}/$OPENLIST_FILE"
    local temp_path="/tmp/$OPENLIST_FILE"
    download_with_retry "$download_url" "$temp_path" || { _sudo supervisorctl start openlist; return 1; }
    
    _sudo rm -f "$OPENLIST_BINARY"
    echo "正在解压新版本..."
    _sudo tar zxf "$temp_path" -C "$DOWNLOAD_DIR/" || { echo -e "${RED_COLOR}解压失败!${RES}"; _sudo rm -f "$temp_path"; _sudo supervisorctl start openlist; return 1; }
    _sudo rm -f "$temp_path"
    _sudo chmod +x "$OPENLIST_BINARY"
    
    echo "正在重启 OpenList 服务..."
    _sudo supervisorctl start openlist
    
    sleep 2; local new_version=$(get_current_version)
    echo -e "${GREEN_COLOR}OpenList 更新成功！当前版本: $new_version${RES}"
}

do_uninstall_openlist() {
    read -p "${RED_COLOR}警告：此操作将删除所有 OpenList 文件和配置，是否继续? (y/n): ${RES}" confirm
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && { echo "卸载已取消。"; return; }
    
    _sudo supervisorctl stop openlist >/dev/null 2>&1
    _sudo supervisorctl remove openlist >/dev/null 2>&1
    _sudo rm -f "$OPENLIST_SUPERVISOR_CONF_FILE"
    _sudo supervisorctl update >/dev/null 2>&1
    _sudo rm -rf "$DOWNLOAD_DIR"
    (crontab -l 2>/dev/null | grep -vF "$CRON_JOB_COMMAND") | crontab -
    _sudo rm -f /var/log/openlist_*.log
    [ -L "$SYMLINK_PATH" ] && _sudo rm -f "$SYMLINK_PATH"
    echo -e "${GREEN_COLOR}OpenList 卸载完成。${RES}"
}

do_check_status() {
    echo "--- OpenList 服务状态 ---"
    if ! command -v supervisorctl >/dev/null 2>&1; then echo -e "${RED_COLOR}错误: supervisorctl 命令未找到。${RES}"; return; fi
    
    local status_output=$(_sudo supervisorctl status openlist 2>&1)
    if echo "$status_output" | grep -q "RUNNING"; then
        echo -e "状态: ${GREEN_COLOR}运行中${RES}"
    elif echo "$status_output" | grep -q "STOPPED" || echo "$status_output" | grep -q "EXITED"; then
        echo -e "状态: ${RED_COLOR}已停止${RES}"
    else
        echo -e "状态: ${YELLOW_COLOR}未知 (或未安装)${RES}"
    fi

    echo "--- 自动更新任务 ---"
    if crontab -l 2>/dev/null | grep -qF "$CRON_JOB_COMMAND"; then
        local job_line=$(crontab -l | grep "$CRON_JOB_COMMAND")
        echo -e "状态: ${GREEN_COLOR}已开启${RES} (执行时间: ${job_line%%$CRON_JOB_COMMAND*})"
    else
        echo -e "状态: ${RED_COLOR}未开启${RES}"
    fi
}

do_reset_password() {
    if [ ! -f "$OPENLIST_BINARY" ]; then echo -e "${RED_COLOR}OpenList 未安装。${RES}"; return; fi
    
    echo -e "\n请选择密码重置方式:"
    echo "  1. 生成随机密码"
    echo "  2. 设置新密码"
    read -p "请输入选项 [1-2]: " choice

    case "$choice" in
        1)
            echo "正在生成随机密码..."
            local output=$(_sudo "$OPENLIST_BINARY" admin random --data "$DATA_DIR" 2>&1)
            local user=$(echo "$output" | grep "username:" | awk '{print $NF}')
            local pass=$(echo "$output" | grep "password:" | awk '{print $NF}')
            echo -e "${GREEN_COLOR}账号：${RES}${user}"
            echo -e "${GREEN_COLOR}密码：${RES}${pass}"
            ;;
        2)
            read -p "请输入新密码: " new_pass
            if [ -z "$new_pass" ]; then echo -e "${RED_COLOR}密码不能为空。${RES}"; return; fi
            echo "正在为 'admin' 用户设置新密码..."
            _sudo "$OPENLIST_BINARY" admin set "$new_pass" --data "$DATA_DIR" >/dev/null 2>&1
            echo -e "${GREEN_COLOR}账号：${RES}admin"
            echo -e "${GREEN_COLOR}密码：${RES}${new_pass}"
            ;;
        *) echo -e "${RED_COLOR}无效的选项。${RES}";;
    esac
}

control_service() {
    local action="$1"
    local action_cn
    case "$action" in
        start) action_cn="启动" ;;
        stop) action_cn="停止" ;;
        restart) action_cn="重启" ;;
    esac
    
    local output=$(_sudo supervisorctl "$action" openlist 2>&1)
    if echo "$output" | grep -q "ERROR (already started)"; then
        echo -e "${YELLOW_COLOR}操作提示: 服务已在运行，无需重复启动。${RES}"
    elif echo "$output" | grep -q "ERROR (not running)"; then
        echo -e "${YELLOW_COLOR}操作提示: 服务当前未运行。${RES}"
        if [ "$action" = "restart" ]; then echo -e "${GREEN_COLOR}操作成功: 服务已启动。${RES}"; fi
    elif echo "$output" | grep -q "started"; then
        echo -e "${GREEN_COLOR}操作成功: 服务已${action_cn}。${RES}"
    elif echo "$output" | grep -q "stopped"; then
        echo -e "${GREEN_COLOR}操作成功: 服务已停止。${RES}"
    else
        echo -e "${RED_COLOR}操作失败或状态未知。${RES}"
    fi
}

do_start_service() { control_service "start"; }
do_stop_service() { control_service "stop"; }
do_restart_service() { control_service "restart"; }

do_check_version_info() {
    local current_version=$(get_current_version)
    local latest_version=$(get_latest_version)
    echo -e "${GREEN_COLOR}当前安装版本: ${current_version}${RES}"
    echo -e "${YELLOW_COLOR}最新可用版本: ${latest_version}${RES}"
}

do_set_auto_update() {
    echo "--- 设置自动更新 ---"
    if crontab -l 2>/dev/null | grep -qF "$CRON_JOB_COMMAND"; then
        read -p "自动更新已开启，是否要关闭? (y/n): " confirm_disable
        if [ "$confirm_disable" = "y" ]; then
            (crontab -l | grep -vF "$CRON_JOB_COMMAND") | crontab -
            echo -e "${GREEN_COLOR}自动更新已关闭。${RES}"
        fi
    else
        read -p "是否要开启自动更新? (y/n): " confirm_enable
        if [ "$confirm_enable" = "y" ]; then
            echo "请输入每日自动检查更新的时间 (24小时制)。"
            read -p "小时 (0-23，默认 4): " hour
            read -p "分钟 (0-59，默认 0): " min
            hour=${hour:-4}
            min=${min:-0}
            
            local cron_schedule="$min $hour * * *"
            local new_cron_job="$cron_schedule $CRON_JOB_COMMAND"
            (crontab -l 2>/dev/null | grep -vF "$CRON_JOB_COMMAND"; echo "$new_cron_job") | crontab -
            echo -e "${GREEN_COLOR}自动更新已开启，每日将在 ${hour}:${min} 执行。${RES}"
            
            if [ "$(cat /etc/timezone 2>/dev/null)" != "Asia/Shanghai" ]; then
                read -p "检测到系统时区不是上海时间，是否设置为上海时间? (y/n): " confirm_tz
                if [ "$confirm_tz" = "y" ]; then
                    if ! command -v setup-timezone >/dev/null 2>&1; then
                        _sudo apk add --no-cache tzdata
                    fi
                    _sudo setup-timezone -z Asia/Shanghai
                    echo "时区已设置为 Asia/Shanghai。"
                fi
            fi
        fi
    fi
}

# --- Main Menu & Script Execution ---
main_menu() {
    while true; do
        clear
        echo -e "\n${GREEN_COLOR}OpenList 管理脚本 (v6.0 - Alpine)${RES}"
        echo "=========================================="
        echo " 1. 安装 OpenList           2. 更新 OpenList"
        echo " 3. 卸载 OpenList           4. 查看状态"
        echo " 5. 重置密码                6. 启动服务"
        echo " 7. 停止服务                8. 重启服务"
        echo " 9. 版本信息               10. 设置自动更新"
        echo " 0. 退出脚本"
        echo "=========================================="
        current_version_display=$(get_current_version)
        echo "当前版本: ${current_version_display} | 系统架构: ${ARCH}"
        read -p "请输入你的选择 [0-10]: " choice_menu

        case "$choice_menu" in
            1) do_install_openlist ;;
            2) do_update_openlist ;;
            3) do_uninstall_openlist ;;
            4) do_check_status ;;
            5) do_reset_password ;;
            6) do_start_service ;;
            7) do_stop_service ;;
            8) do_restart_service ;;
            9) do_check_version_info ;;
            10) do_set_auto_update ;;
            0) echo "退出脚本。"; exit 0 ;;
            *) echo -e "${RED_COLOR}无效的选择。${RES}" ;;
        esac
        read -p $'\n按回车键返回主菜单...' _unused_input
    done
}

# --- Script Entry Point ---
if [ "$1" = "auto-update" ]; then
    LOG_FILE="/var/log/openlist_autoupdate.log"
    echo "--- Auto-Update Starting: $(date) ---" >> "$LOG_FILE"
    # This calls the full update function
    do_update_openlist >> "$LOG_FILE" 2>&1
    exit 0
fi

clear
main_menu