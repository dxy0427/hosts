#!/bin/sh

# --- Script Setup & Configuration ---
# Resolve the script's actual directory, not the current working directory
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT_NAME=$(basename "$0") # More robust way to get script name
SYMLINK_PATH="/usr/local/bin/openlist"

# Ensure script is executable (referencing its actual location)
if [ ! -x "$SCRIPT_DIR/$SCRIPT_NAME" ]; then
    chmod +x "$SCRIPT_DIR/$SCRIPT_NAME" >/dev/null 2>&1
fi

# Create symlink if it doesn't exist (referencing its actual location)
if [ ! -L "$SYMLINK_PATH" ]; then
    echo "正在尝试创建符号链接 $SYMLINK_PATH 指向 $SCRIPT_DIR/$SCRIPT_NAME"
    if [ ! -w "/usr/local/bin" ]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo ln -s "$SCRIPT_DIR/$SCRIPT_NAME" "$SYMLINK_PATH"
        else
            echo "需要 root 权限来创建符号链接，或手动创建。"
        fi
    else
        ln -s "$SCRIPT_DIR/$SCRIPT_NAME" "$SYMLINK_PATH"
    fi
    if [ -L "$SYMLINK_PATH" ]; then
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
        echo -e "${RED_COLOR}错误: 此操作需要 root 权限，并且 sudo 命令未找到。${RES}"; return 1
    fi
    return $?
}

check_dependencies() {
    local missing_deps=""
    local dependencies="wget tar curl supervisor file psmisc" # psmisc provides pkill
    for dep in $dependencies; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps="$missing_deps $dep"
        fi
    done
    if [ -n "$missing_deps" ]; then
        echo -e "${YELLOW_COLOR}缺少依赖:$(echo "$missing_deps" | sed 's/^ //')，正在尝试安装...${RES}"
        if ! _sudo apk add --no-cache $(echo "$missing_deps"); then
            echo -e "${RED_COLOR}依赖安装失败，请手动安装。${RES}"; return 1
        fi
    fi
}

get_current_version() {
    if [ -x "$OPENLIST_BINARY" ]; then
        _sudo "$OPENLIST_BINARY" version 2>/dev/null | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "未安装或无法获取"
    else
        echo "未安装"
    fi
}

get_latest_version() {
    curl -sL --connect-timeout 10 "https://api.github.com/repos/OpenListTeam/OpenList/releases/latest" | \
    grep -o '"tag_name": *"[^"]*"' | sed 's/"tag_name": *"//; s/"$//' || echo "无法获取"
}

version_gt() {
    test "$(printf '%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2"
}

# --- Main Operations ---
force_cleanup() {
    echo "正在执行强制清理..."
    # Kill any process related to openlist, supervised or not
    _sudo pkill -f "$OPENLIST_BINARY server" 2>/dev/null
    # Stop and remove from supervisor if exists
    if _sudo supervisorctl status openlist >/dev/null 2>&1; then
        _sudo supervisorctl stop openlist >/dev/null 2>&1
        _sudo supervisorctl remove openlist >/dev/null 2>&1
    fi
    # Remove config file
    _sudo rm -f "$OPENLIST_SUPERVISOR_CONF_FILE"
    # Update supervisor
    if command -v supervisorctl >/dev/null 2>&1; then
        _sudo supervisorctl reread >/dev/null 2>&1
        _sudo supervisorctl update >/dev/null 2>&1
    fi
    echo "强制清理完成。"
}

setup_supervisor() {
    echo "正在配置 Supervisor..."
    _sudo mkdir -p "$SUPERVISOR_CONF_DIR"
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
    echo "强制重启 Supervisor 服务以应用新配置..."
    _sudo pkill supervisord >/dev/null 2>&1
    sleep 1
    _sudo supervisord -c /etc/supervisord.conf
    sleep 2
    
    if ! _sudo supervisorctl status openlist | grep -q "RUNNING"; then
        echo -e "${RED_COLOR}OpenList 服务启动失败，以下是相关日志：${RES}"
        echo -e "\n${YELLOW_COLOR}--- Supervisor 状态 ---${RES}"; _sudo supervisorctl status openlist
        echo -e "\n${YELLOW_COLOR}--- OpenList 标准输出日志 (stdout.log) ---${RES}"; _sudo tail -n 20 /var/log/openlist_stdout.log
        echo -e "\n${YELLOW_COLOR}--- OpenList 错误日志 (stderr.log) ---${RES}"; _sudo tail -n 20 /var/log/openlist_stderr.log
        return 1
    fi
    return 0
}

do_install_openlist() {
    if [ "$(get_current_version)" != "未安装" ]; then
        echo -e "${YELLOW_COLOR}OpenList 已安装，如需重装请先卸载。${RES}"; return
    fi
    
    # Run cleanup first to ensure a clean slate
    force_cleanup
    check_dependencies || return 1
    
    local latest_version=$(get_latest_version)
    if [ "$latest_version" = "无法获取" ]; then echo -e "${RED_COLOR}无法获取最新版本，安装中止。${RES}"; return 1; fi
    
    _sudo mkdir -p "$DOWNLOAD_DIR" "$DATA_DIR"
    
    local download_url="https://github.com/OpenListTeam/OpenList/releases/download/${latest_version}/$OPENLIST_FILE"
    local temp_path="/tmp/$OPENLIST_FILE"
    echo -e "${GREEN_COLOR}正在下载: $download_url ${RES}"
    if ! curl -L --fail -o "$temp_path" "$download_url"; then echo -e "${RED_COLOR}下载失败。${RES}"; return 1; fi
    
    echo "正在解压..."
    _sudo tar zxf "$temp_path" -C "$DOWNLOAD_DIR/" || { echo -e "${RED_COLOR}解压失败!${RES}"; _sudo rm -f "$temp_path"; return 1; }
    _sudo rm -f "$temp_path"
    _sudo chmod +x "$OPENLIST_BINARY"
    
    if ! setup_supervisor; then
        return 1
    fi
    echo -e "${GREEN_COLOR}OpenList 安装并启动成功!${RES}"
}

do_update_openlist() {
    local current_version=$(get_current_version)
    if [ "$current_version" = "未安装" ]; then echo -e "${RED_COLOR}OpenList 未安装。${RES}"; return; fi
    local latest_version=$(get_latest_version)
    if [ "$latest_version" = "无法获取" ]; then echo -e "${RED_COLOR}无法获取最新版本。${RES}"; return; fi
    
    echo "当前版本: $current_version, 最新版本: $latest_version"
    if ! version_gt "$latest_version" "$current_version"; then echo -e "${GREEN_COLOR}当前已是最新版本。${RES}"; return; fi

    echo -e "${YELLOW_COLOR}检测到新版本 ${latest_version}，是否更新?${RES}"
    read -p "请输入 'y' 确认: " confirm
    [ "$confirm" != "y" ] && { echo "更新已取消。"; return; }

    echo "正在停止服务..."; _sudo supervisorctl stop openlist
    local download_url="https://github.com/OpenListTeam/OpenList/releases/download/${latest_version}/$OPENLIST_FILE"
    local temp_path="/tmp/$OPENLIST_FILE"
    echo -e "${GREEN_COLOR}正在下载: $download_url ${RES}"
    if ! curl -L --fail -o "$temp_path" "$download_url"; then echo -e "${RED_COLOR}下载失败。${RES}"; _sudo supervisorctl start openlist; return 1; fi

    _sudo rm -f "$OPENLIST_BINARY"
    echo "正在解压..."; _sudo tar zxf "$temp_path" -C "$DOWNLOAD_DIR/"
    _sudo rm -f "$temp_path"; _sudo chmod +x "$OPENLIST_BINARY"
    
    echo "正在重启服务..."; _sudo supervisorctl start openlist
    sleep 2; local new_version=$(get_current_version)
    echo -e "${GREEN_COLOR}更新成功！当前版本: $new_version${RES}"
}

do_uninstall_openlist() {
    echo -e "${RED_COLOR}警告：此操作将删除所有 OpenList 文件和配置，是否继续?${RES}"
    read -p "请输入 'y' 确认: " confirm
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && { echo "卸载已取消。"; return; }
    
    echo "1. 正在强制停止所有 OpenList 进程..."
    force_cleanup
    echo "2. 正在删除程序文件和数据目录..."
    _sudo rm -rf "$DOWNLOAD_DIR"
    echo "3. 正在移除自动更新任务..."
    (crontab -l 2>/dev/null | grep -vF "$CRON_JOB_COMMAND") | crontab -
    echo "4. 正在清理日志文件..."
    _sudo rm -f /var/log/openlist_*.log
    [ -L "$SYMLINK_PATH" ] && { echo "5. 正在删除符号链接..."; _sudo rm -f "$SYMLINK_PATH"; }
    echo -e "\n${GREEN_COLOR}OpenList 卸载完成。${RES}"
}

do_check_status() {
    echo "--- OpenList 服务状态 ---"
    if ! command -v supervisorctl >/dev/null 2>&1; then echo -e "${RED_COLOR}错误: supervisorctl 命令未找到。${RES}"; return; fi
    
    if _sudo supervisorctl status openlist 2>&1 | grep -q "RUNNING"; then
        echo -e "服务状态: ${GREEN_COLOR}运行中${RES}"
    else
        echo -e "服务状态: ${RED_COLOR}已停止${RES}"
    fi

    echo "--- 自动更新任务 ---"
    if crontab -l 2>/dev/null | grep -qF "$CRON_JOB_COMMAND"; then
        local job_line=$(crontab -l | grep "$CRON_JOB_COMMAND")
        echo -e "任务状态: ${GREEN_COLOR}已开启${RES} (每日执行时间: ${job_line%%$CRON_JOB_COMMAND*})"
    else
        echo -e "任务状态: ${RED_COLOR}未开启${RES}"
    fi
}

do_reset_password() {
    if [ ! -f "$OPENLIST_BINARY" ]; then echo -e "${RED_COLOR}OpenList 未安装。${RES}"; return; fi
    
    echo -e "\n请选择密码重置方式:\n  1. 生成随机密码\n  2. 设置新密码"
    read -p "请输入选项 [1-2]: " choice

    case "$choice" in
        1)
            echo "正在生成随机密码..."
            local output=$(_sudo "$OPENLIST_BINARY" admin random --data "$DATA_DIR" 2>&1)
            local user=$(echo "$output" | grep "username:" | awk '{print $NF}')
            local pass=$(echo "$output" | grep "password:" | awk '{print $NF}')
            echo -e "${GREEN_COLOR}账号：${RES}${user}\n${GREEN_COLOR}密码：${RES}${pass}"
            ;;
        2)
            read -p "请输入新密码: " new_pass
            if [ -z "$new_pass" ]; then echo -e "${RED_COLOR}密码不能为空。${RES}"; return; fi
            echo "正在为 'admin' 用户设置新密码..."
            _sudo "$OPENLIST_BINARY" admin set "$new_pass" --data "$DATA_DIR" >/dev/null 2>&1
            echo -e "${GREEN_COLOR}账号：${RES}admin\n${GREEN_COLOR}密码：${RES}${new_pass}"
            ;;
        *) echo -e "${RED_COLOR}无效的选项。${RES}";;
    esac
}

control_service() {
    local action="$1"; local action_cn
    case "$action" in
        start) action_cn="启动" ;; stop) action_cn="停止" ;; restart) action_cn="重启" ;;
    esac
    
    local output=$(_sudo supervisorctl "$action" openlist 2>&1)
    if echo "$output" | grep -q "ERROR (already started)"; then echo -e "${YELLOW_COLOR}提示: 服务已在运行，无需启动。${RES}"
    elif echo "$output" | grep -q "ERROR (not running)"; then echo -e "${YELLOW_COLOR}提示: 服务未在运行。${RES}"; if [ "$action" = "restart" ]; then echo -e "${GREEN_COLOR}操作成功: 服务已启动。${RES}"; fi
    elif echo "$output" | grep -q "started"; then echo -e "${GREEN_COLOR}操作成功: 服务已${action_cn}。${RES}"
    elif echo "$output" | grep -q "stopped"; then echo -e "${GREEN_COLOR}操作成功: 服务已停止。${RES}"
    else echo -e "${RED_COLOR}操作失败。${RES}"; fi
}

do_start_service() { control_service "start"; }
do_stop_service() { control_service "stop"; }
do_restart_service() { control_service "restart"; }

do_check_version_info() {
    echo -e "${GREEN_COLOR}当前版本: $(get_current_version)${RES}"
    echo -e "${YELLOW_COLOR}最新版本: $(get_latest_version)${RES}"
}

do_set_auto_update() {
    echo "--- 设置自动更新 ---"
    if crontab -l 2>/dev/null | grep -qF "$CRON_JOB_COMMAND"; then
        echo -e "${YELLOW_COLOR}自动更新已开启，是否要关闭?${RES}"
        read -p "请输入 'y' 确认: " confirm
        if [ "$confirm" = "y" ]; then
            (crontab -l | grep -vF "$CRON_JOB_COMMAND") | crontab -
            echo -e "${GREEN_COLOR}自动更新已关闭。${RES}"
        fi
    else
        echo -e "${YELLOW_COLOR}是否要开启自动更新?${RES}"
        read -p "请输入 'y' 确认: " confirm
        if [ "$confirm" = "y" ]; then
            echo "请输入每日检查更新的时间 (24小时制)，留空则使用默认(凌晨4点)。"
            read -p "小时 (0-23，默认 4): " hour
            read -p "分钟 (0-59，默认 0): " min
            local cron_schedule="${min:-0} ${hour:-4} * * *"
            (crontab -l 2>/dev/null; echo "$cron_schedule $CRON_JOB_COMMAND") | crontab -
            echo -e "${GREEN_COLOR}自动更新已开启，每日将在 ${hour:-4}:${min:-0} 执行。${RES}"
            
            if [ "$(cat /etc/timezone 2>/dev/null)" != "Asia/Shanghai" ]; then
                echo -e "${YELLOW_COLOR}检测到时区不是上海时间，是否设置?${RES}"
                read -p "请输入 'y' 确认: " confirm_tz
                if [ "$confirm_tz" = "y" ]; then
                    if ! command -v setup-timezone >/dev/null 2>&1; then _sudo apk add --no-cache tzdata; fi
                    _sudo setup-timezone -z Asia/Shanghai; echo "时区已设置为 Asia/Shanghai。"
                fi
            fi
        fi
    fi
}

# --- Main Menu & Script Execution ---
main_menu() {
    while true; do
        clear
        echo -e "\n${GREEN_COLOR}OpenList 管理脚本 (v10.0 - Alpine)${RES}"
        echo "=========================================="
        echo " 1. 安装 OpenList           2. 更新 OpenList"
        echo " 3. 卸载 OpenList           4. 查看状态"
        echo " 5. 重置密码                6. 启动服务"
        echo " 7. 停止服务                8. 重启服务"
        echo " 9. 版本信息               10. 设置自动更新"
        echo " 0. 退出脚本"
        echo "=========================================="
        echo "当前版本: $(get_current_version) | 系统架构: ${ARCH}"
        read -p "请输入你的选择 [0-10]: " choice

        case "$choice" in
            1) do_install_openlist ;;  2) do_update_openlist ;;
            3) do_uninstall_openlist ;; 4) do_check_status ;;
            5) do_reset_password ;;     6) do_start_service ;;
            7) do_stop_service ;;       8) do_restart_service ;;
            9) do_check_version_info ;; 10) do_set_auto_update ;;
            0) echo "退出脚本。"; exit 0 ;;
            *) echo -e "${RED_COLOR}无效的选择。${RES}" ;;
        esac
        read -p $'\n按回车键返回主菜单...' _
    done
}

# --- Script Entry Point ---
if [ "$1" = "auto-update" ]; then
    LOG_FILE="/var/log/openlist_autoupdate.log"
    echo "--- Auto-Update Starting: $(date) ---" >> "$LOG_FILE"
    do_update_openlist >> "$LOG_FILE" 2>&1
    exit 0
fi

clear
main_menu