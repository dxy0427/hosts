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
    # Check write permission for /usr/local/bin
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

    if [ $? -ne 0 ] && [ ! -L "$SYMLINK_PATH" ]; then # Check again if link exists after trying
        echo "创建符号链接失败。脚本仍可直接运行，但 'openlist' 命令可能无效。"
    elif [ -L "$SYMLINK_PATH" ]; then
        echo "符号链接 $SYMLINK_PATH 创建成功。"
    fi
fi

# --- Variables ---
# Simplified architecture detection for amd64 and arm64 only
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

# Corrected filename format for OpenList
OPENLIST_FILE="openlist_linux_${ARCH}.tar.gz" 
DOWNLOAD_DIR="/opt/openlist"
OPENLIST_BINARY="$DOWNLOAD_DIR/openlist"
DATA_DIR="$DOWNLOAD_DIR/data"

# Alpine default Supervisor config path
SUPERVISOR_CONF_DIR="/etc/supervisor.d"
OPENLIST_SUPERVISOR_CONF_FILE="$SUPERVISOR_CONF_DIR/openlist.ini"

GREEN_COLOR="\033[32m"
YELLOW_COLOR="\033[33m"
RED_COLOR="\033[31m"
RES="\033[0m" # Reset color

CRON_JOB_COMMAND="$SCRIPT_DIR/$SCRIPT_NAME auto-update"
CRON_JOB_SCHEDULE="0 4 * * *" # 每天凌晨4点
CRON_JOB="$CRON_JOB_SCHEDULE $CRON_JOB_COMMAND"

ADMIN_USER=""
ADMIN_PASS=""

# --- Helper Functions ---

_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@" # Already root, execute directly
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo -e "${RED_COLOR}错误: 此操作需要 root 权限，并且 sudo 命令未找到。请使用 root 用户运行或安装 sudo。${RES}"
        return 1
    fi
    return $?
}

check_dependencies() {
    local missing_deps=""
    local dependencies="wget tar curl supervisor"

    echo "正在检查依赖: $dependencies..."
    for dep in $dependencies; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            if [ "$dep" = "supervisor" ]; then
                echo -e "${YELLOW_COLOR}警告: 依赖 supervisor 未找到。将在安装 OpenList 时尝试安装。${RES}"
            else
                missing_deps="$missing_deps $dep"
            fi
        fi
    done

    if [ -n "$missing_deps" ]; then
        echo -e "${RED_COLOR}错误: 缺少核心依赖 $missing_deps，正在尝试安装...${RES}"
        if ! _sudo apk add --no-cache $missing_deps; then
            echo -e "${RED_COLOR}错误: 安装依赖 $missing_deps 失败，请手动安装。${RES}"
            return 1
        fi
        echo -e "${GREEN_COLOR}依赖 $missing_deps 安装成功。${RES}"
    fi
    echo "依赖检查完成。"
    return 0
}

cleanup_residuals() {
    echo "正在清理残留进程和配置..."
    openlist_pids=$(pgrep -f "$DOWNLOAD_DIR/openlist server")

    if [ -n "$openlist_pids" ]; then
        for pid in $openlist_pids; do
            if echo "$pid" | grep -qE '^[0-9]+$'; then
                echo "正在终止残留的 OpenList 进程 PID: $pid"
                _sudo kill -9 "$pid"
            fi
        done
    else
        echo "未找到正在运行的 OpenList 进程。"
    fi

    if [ -f "$OPENLIST_SUPERVISOR_CONF_FILE" ]; then
        echo "正在删除 Supervisor OpenList 配置文件: $OPENLIST_SUPERVISOR_CONF_FILE"
        _sudo rm -f "$OPENLIST_SUPERVISOR_CONF_FILE"
    fi
    echo "残留进程和配置文件清理完成。"
}

get_current_version() {
    if [ -x "$OPENLIST_BINARY" ]; then
        local version_output
        version_output=$("$OPENLIST_BINARY" version 2>/dev/null)
        if [ $? -ne 0 ] || [ -z "$version_output" ]; then
            if [ -f "$OPENLIST_BINARY" ]; then
                version_output=$(_sudo "$OPENLIST_BINARY" version 2>/dev/null)
            fi
        fi
        local version=$(echo "$version_output" | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        echo "${version:-未安装或无法获取}"
    else
        echo "未安装"
    fi
}

get_latest_version() {
    local url="https://api.github.com/repos/OpenListTeam/OpenList/releases/latest"
    local latest_json
    latest_json=$(curl -sL --connect-timeout 10 --retry 3 --retry-delay 3 --no-keepalive "$url" 2>/dev/null)

    if [ -z "$latest_json" ] || echo "$latest_json" | grep -q "API rate limit exceeded"; then
        echo "无法获取最新版本信息"
    else
        if command -v jq >/dev/null 2>&1; then
            echo "$latest_json" | jq -r .tag_name
        else
            echo "$latest_json" | grep -o '"tag_name": *"[^"]*"' | sed 's/"tag_name": *"//; s/"$//'
        fi
    fi
}

version_gt() {
    # handles empty inputs
    [ -z "$1" ] && return 1
    [ -z "$2" ] && return 1
    v1=$(echo "$1" | sed 's/^v//')
    v2=$(echo "$2" | sed 's/^v//')
    test "$(printf '%s\n' "$v1" "$v2" | sort -V | head -n 1)" != "$v1"
}

check_install_dir() {
    if [ -f "$OPENLIST_BINARY" ]; then
        echo -e "${YELLOW_COLOR}OpenList 已安装在 $DOWNLOAD_DIR。如需重新安装，请先卸载或选择更新。${RES}"
        return 1
    fi

    local parent_dir
    parent_dir=$(dirname "$DOWNLOAD_DIR")
    if [ ! -d "$parent_dir" ]; then
        echo -e "${GREEN_COLOR}目录 $parent_dir 不存在，正在创建...${RES}"
        if ! _sudo mkdir -p "$parent_dir"; then
            echo -e "${RED_COLOR}错误：无法创建目录 $parent_dir。请检查权限。${RES}"
            return 2
        fi
    fi

    if [ -d "$DOWNLOAD_DIR" ]; then
        read -p "${YELLOW_COLOR}安装目录 $DOWNLOAD_DIR 已存在但 OpenList 未完整安装。是否清空并继续？(y/n): ${RES}" confirm_clear
        if [ "$confirm_clear" = "y" ] || [ "$confirm_clear" = "Y" ]; then
            echo -e "${GREEN_COLOR}正在清空安装目录 $DOWNLOAD_DIR...${RES}"
            _sudo rm -rf "$DOWNLOAD_DIR/*" "$DOWNLOAD_DIR/.*" 2>/dev/null
            _sudo mkdir -p "$DOWNLOAD_DIR"
        else
            echo -e "${RED_COLOR}安装取消。${RES}"
            return 3
        fi
    else
        echo -e "${GREEN_COLOR}正在创建安装目录 $DOWNLOAD_DIR...${RES}"
        if ! _sudo mkdir -p "$DOWNLOAD_DIR"; then
            echo -e "${RED_COLOR}错误：无法创建安装目录 $DOWNLOAD_DIR。请检查权限。${RES}"
            return 2
        fi
    fi
    if [ ! -d "$DATA_DIR" ]; then
        echo -e "${GREEN_COLOR}正在创建数据目录 $DATA_DIR...${RES}"
        if ! _sudo mkdir -p "$DATA_DIR"; then
            echo -e "${RED_COLOR}错误：无法创建数据目录 $DATA_DIR。请检查权限。${RES}"
            return 2
        fi
    fi
    echo -e "${GREEN_COLOR}安装目录准备就绪：$DOWNLOAD_DIR${RES}"
    return 0
}

download_with_retry() {
    local url="$1"
    local output_path="$2"
    local max_retries=3
    local attempt=0
    local wait_time=5

    echo -e "${GREEN_COLOR}正在下载: $url 到 $output_path ${RES}"
    while [ $attempt -lt $max_retries ]; do
        attempt=$((attempt + 1))
        if curl -L --connect-timeout 15 --retry 3 --retry-delay 5 "$url" -o "$output_path"; then
            if [ -s "$output_path" ]; then
                # Simple check for tar magic number to avoid invalid archives
                if ! file "$output_path" | grep -q "gzip compressed data"; then
                     echo -e "${YELLOW_COLOR}下载的文件不是有效的 gzip 压缩包 (尝试 $attempt/$max_retries)。可能是下载链接错误。${RES}"
                     _sudo rm -f "$output_path"
                else
                    echo -e "${GREEN_COLOR}下载成功。${RES}"
                    return 0
                fi
            else
                echo -e "${YELLOW_COLOR}下载成功但文件为空。 (尝试 $attempt/$max_retries)${RES}"
                _sudo rm -f "$output_path"
            fi
        else
            echo -e "${YELLOW_COLOR}下载失败 (尝试 $attempt/$max_retries)。${RES}"
        fi
        if [ $attempt -lt $max_retries ]; then
            echo -e "${YELLOW_COLOR}${wait_time} 秒后重试...${RES}"
            sleep $wait_time
            wait_time=$((wait_time + 5))
        fi
    done
    echo -e "${RED_COLOR}下载失败 $max_retries 次尝试后。${RES}"
    _sudo rm -f "$output_path"
    return 1
}

install_openlist_binary() {
    echo -e "${GREEN_COLOR}是否使用 GitHub 代理进行下载？（默认无代理）${RES}"
    echo -e "${GREEN_COLOR}代理地址示例： https://gh-proxy.com/ (必须 https 开头，斜杠 / 结尾)${RES}"
    read -p "请输入代理地址或直接按回车继续: " proxy_input

    local gh_download_url
    if [ -n "$proxy_input" ]; then
        if ! echo "$proxy_input" | grep -Eq '^https://.*/$'; then
            echo -e "${RED_COLOR}代理地址格式不正确。必须以 https:// 开头并以 / 结尾。${RES}"
            echo -e "${YELLOW_COLOR}将不使用代理进行下载。${RES}"
            proxy_input=""
        fi
    fi

    local latest_version_for_dl=$(get_latest_version "")
    if echo "$latest_version_for_dl" | grep -q "无法获取"; then
        echo -e "${RED_COLOR}无法获取最新版本信息，无法确定下载链接。安装中止。${RES}"
        return 1
    fi

    if [ -n "$proxy_input" ]; then
        gh_download_url="${proxy_input}https://github.com/OpenListTeam/OpenList/releases/download/${latest_version_for_dl}/$OPENLIST_FILE"
        echo -e "${GREEN_COLOR}使用代理地址: $proxy_input${RES}"
    else
        gh_download_url="https://github.com/OpenListTeam/OpenList/releases/download/${latest_version_for_dl}/$OPENLIST_FILE"
        echo -e "${GREEN_COLOR}使用默认 GitHub 地址进行下载${RES}"
    fi

    local temp_download_path="/tmp/$OPENLIST_FILE"
    if ! download_with_retry "$gh_download_url" "$temp_download_path"; then
        return 1
    fi

    echo -e "${GREEN_COLOR}正在解压 $temp_download_path 到 $DOWNLOAD_DIR...${RES}"
    if [ ! -d "$DOWNLOAD_DIR" ]; then _sudo mkdir -p "$DOWNLOAD_DIR"; fi
    if ! _sudo tar zxf "$temp_download_path" -C "$DOWNLOAD_DIR/"; then
        echo -e "${RED_COLOR}解压失败！请检查下载的文件或手动解压。${RES}"
        _sudo rm -f "$temp_download_path"
        return 1
    fi
    _sudo rm -f "$temp_download_path"

    if [ -f "$OPENLIST_BINARY" ]; then
        echo -e "${GREEN_COLOR}OpenList 二进制文件已解压到 $OPENLIST_BINARY${RES}"
        _sudo chmod +x "$OPENLIST_BINARY"

        echo -e "${GREEN_COLOR}正在获取初始管理员凭据...${RES}"
        local account_info_output
        account_info_output=$(_sudo "$OPENLIST_BINARY" admin random --data "$DATA_DIR" 2>&1)

        ADMIN_USER=$(echo "$account_info_output" | awk -F': ' '/username:/ {print $2; exit}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        ADMIN_PASS=$(echo "$account_info_output" | awk -F': ' '/password:/ {print $2; exit}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [ -z "$ADMIN_USER" ] || [ -z "$ADMIN_PASS" ]; then
            echo -e "${YELLOW_COLOR}警告: 未能自动从以下输出中提取管理员用户名或密码。请稍后手动重置。${RES}"
            echo "$account_info_output"
        fi
    else
        echo -e "${RED_COLOR}安装失败：OpenList 二进制文件 $OPENLIST_BINARY 未找到。${RES}"
        return 1
    fi
    return 0
}

setup_supervisor() {
    echo "正在配置 Supervisor..."
    if ! command -v supervisord >/dev/null 2>&1; then
        echo "Supervisor 未安装，正在尝试安装..."
        if ! _sudo apk add --no-cache supervisor; then
            echo -e "${RED_COLOR}错误: 安装 supervisor 失败。请手动安装 supervisor。${RES}"
            return 1
        fi
        echo "Supervisor 安装成功。"
    fi

    local main_supervisor_conf="/etc/supervisord.conf"

    if [ ! -f "$main_supervisor_conf" ]; then
        echo "Supervisor 主配置文件 $main_supervisor_conf 未找到。正在创建默认配置..."
        if ! _sudo sh -c "echo_supervisord_conf > $main_supervisor_conf"; then
             echo -e "${RED_COLOR}错误: 创建默认 Supervisor 配置文件失败。${RES}"
             return 1
        fi
        _sudo sh -c "echo \"\n[include]\nfiles = /etc/supervisor.d/*.ini\" >> \"$main_supervisor_conf\""
        echo "默认 Supervisor 配置文件已创建并配置 include 指向 /etc/supervisor.d/。"
    else
        echo "检查现有的 Supervisor 主配置文件 $main_supervisor_conf ..."
        local include_correct=false
        if _sudo grep -q "\[include\]" "$main_supervisor_conf"; then
            if _sudo grep -Eq "^\s*files\s*=\s*(/etc/supervisor.d/\*.ini|supervisor.d/\*.ini)" "$main_supervisor_conf"; then
                include_correct=true
                echo "主配置文件中的 [include] 部分已正确配置。"
            fi
        fi

        if [ "$include_correct" = false ]; then
            echo "警告: $main_supervisor_conf 中的 [include] 部分未正确配置或未找到。"
            echo "正在尝试修正/添加 [include] files = /etc/supervisor.d/*.ini ..."
            _sudo sed -i -E '/^\[include\]/,/^\s*\[/{s/(^\s*files\s*=.*)/#\1/g}' "$main_supervisor_conf"
            if _sudo grep -q "^\[include\]" "$main_supervisor_conf"; then
                 _sudo sed -i '/^\[include\]/a files = /etc/supervisor.d/*.ini' "$main_supervisor_conf"
            else
                 _sudo sh -c "echo \"\n[include]\nfiles = /etc/supervisor.d/*.ini\" >> \"$main_supervisor_conf\""
            fi
            echo "已尝试修正 $main_supervisor_conf。"
        fi
    fi

    if [ ! -d "$SUPERVISOR_CONF_DIR" ]; then
        echo "正在创建 Supervisor 配置目录: $SUPERVISOR_CONF_DIR"
        _sudo mkdir -p "$SUPERVISOR_CONF_DIR"
    fi

    echo "正在创建 OpenList Supervisor 配置文件: $OPENLIST_SUPERVISOR_CONF_FILE"
_sudo sh -c "cat > \"$OPENLIST_SUPERVISOR_CONF_FILE\"" << EOF
[program:openlist]
directory=$DOWNLOAD_DIR
command=$OPENLIST_BINARY server --data $DATA_DIR
autostart=true
autorestart=true
startsecs=5
stopsignal=QUIT
stdout_logfile=/var/log/openlist_stdout.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=3
stderr_logfile=/var/log/openlist_stderr.log
stderr_logfile_maxbytes=10MB
stderr_logfile_backups=3
environment=GIN_MODE=release
; user=nobody
EOF

    echo "正在尝试 (重新) 启动 Supervisor 服务并加载新配置..."
    if command -v rc-service >/dev/null 2>&1; then
        echo "使用 rc-service 重启 supervisord..."
        _sudo rc-service supervisord restart
        sleep 3
        if ! _sudo rc-service supervisord status | grep -q "started"; then
             echo -e "${YELLOW_COLOR}Supervisord 服务未能通过 rc-service 启动。尝试直接启动...${RES}"
             _sudo supervisord -c "$main_supervisor_conf"
             sleep 2
        fi
    else
        echo "尝试 pkill 并重启 supervisord..."
        _sudo pkill supervisord
        sleep 1
        _sudo supervisord -c "$main_supervisor_conf"
        sleep 2
    fi

    if ! pgrep -x "supervisord" > /dev/null; then
        echo -e "${RED_COLOR}Supervisord 守护进程未能启动。请检查 Supervisor 日志。${RES}"
        echo -e "${YELLOW_COLOR}主配置文件 $main_supervisor_conf 内容:${RES}"
        _sudo cat "$main_supervisor_conf"
        return 1
    fi

    echo "正在更新 Supervisor 配置 (reread, update)..."
    _sudo supervisorctl reread
    _sudo supervisorctl update

    echo "尝试启动 openlist 程序..."
    _sudo supervisorctl start openlist

    sleep 3
    if ! _sudo supervisorctl status openlist | grep -q "RUNNING"; then
        echo -e "${RED_COLOR}错误: OpenList 未能通过 Supervisor 正常启动。请检查日志。${RES}"
        _sudo supervisorctl status openlist
        echo -e "\n${YELLOW_COLOR}--- OpenList 标准输出日志 (/var/log/openlist_stdout.log) ---${RES}"
        if [ -f "/var/log/openlist_stdout.log" ]; then _sudo tail -n 30 "/var/log/openlist_stdout.log"; else echo "文件未找到。"; fi
        echo -e "\n${YELLOW_COLOR}--- OpenList 错误输出日志 (/var/log/openlist_stderr.log) ---${RES}"
        if [ -f "/var/log/openlist_stderr.log" ]; then _sudo tail -n 30 "/var/log/openlist_stderr.log"; else echo "文件未找到。"; fi
        return 1
    fi

    echo -e "${GREEN_COLOR}OpenList 已通过 Supervisor 配置并启动。${RES}"
    return 0
}

installation_summary() {
    clear
    echo -e "${GREEN_COLOR}=============================================${RES}"
    echo -e "${GREEN_COLOR}      OpenList 安装成功! 🎉 ${RES}"
    echo -e "${GREEN_COLOR}=============================================${RES}"

    local local_ip
    local_ip=$(ip addr show | grep -w inet | grep -v "127.0.0.1" | awk '{print $2}' | cut -d/ -f1 | head -n1)
    local public_ipv4
    public_ipv4=$(curl -s4 --connect-timeout 5 ip.sb || curl -s4 --connect-timeout 5 ifconfig.me || echo "获取失败")
    local public_ipv6
    public_ipv6=$(curl -s6 --connect-timeout 5 ip.sb 2>/dev/null || curl -s6 --connect-timeout 5 ifconfig.me 2>/dev/null || echo "获取失败")


    echo "  访问地址:"
    if [ -n "$local_ip" ]; then
        echo "    局域网:   http://${local_ip}:5244/"
    else
        echo "    局域网:   无法自动获取，请使用 'ip addr' 查看"
    fi
    if [ "$public_ipv4" != "获取失败" ]; then
        echo "    公网 IPv4: http://${public_ipv4}:5244/"
    fi
    if [ "$public_ipv6" != "获取失败" ] && [ -n "$public_ipv6" ]; then
        echo "    公网 IPv6: http://[${public_ipv6}]:5244/"
    fi
    echo "  配置文件: $DATA_DIR/config.json"
    echo "  OpenList 日志: /var/log/openlist_stdout.log (及 stderr.log)"
    echo "  Supervisor 配置: $OPENLIST_SUPERVISOR_CONF_FILE"


    if [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASS" ]; then
        echo -e "\n  ${YELLOW_COLOR}重要: 初始管理员凭据:${RES}"
        echo -e "    用户名: ${GREEN_COLOR}$ADMIN_USER${RES}"
        echo -e "    密  码: ${GREEN_COLOR}$ADMIN_PASS${RES}"
        echo -e "  ${YELLOW_COLOR}请登录后立即修改密码！${RES}"
    else
        echo -e "\n  ${YELLOW_COLOR}警告: 未能获取初始管理员密码。请使用 '$OPENLIST_BINARY admin' 或 '$SYMLINK_PATH admin' 手动设置或查看日志。${RES}"
    fi

    if command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1; then
        if ! rc-update show default | grep -q 'supervisord'; then
            echo -e "\n  ${GREEN_COLOR}将 Supervisor 添加到开机启动项...${RES}"
            _sudo rc-update add supervisord default
        else
            echo -e "\n  Supervisor 已在开机启动项中。"
        fi
    else
        echo -e "\n  ${YELLOW_COLOR}警告: rc-update 或 rc-service 命令未找到。请手动将 Supervisor 添加到开机启动。${RES}"
    fi

    echo -e "\n  管理命令: 在任意目录输入 ${GREEN_COLOR}openlist${RES} (如果符号链接成功) 或 ${GREEN_COLOR}\"$SCRIPT_DIR/$SCRIPT_NAME\"${RES} 打开管理菜单。"
    echo -e "\n  ${YELLOW_COLOR}温馨提示：如果端口无法访问，请检查服务器安全组、防火墙 (例如 ufw, firewalld) 和 OpenList 服务状态。${RES}"
}

# --- Main Operations ---

do_install_openlist() {
    # ... function implementation ... (same as before)
}

# ... all other `do_` functions and `main_menu` ...

# --- Main Operations ---

do_install_openlist() {
    local current_version
    current_version=$(get_current_version)
    if [ "$current_version" != "未安装" ] && [ "$current_version" != "未安装或无法获取" ]; then
        echo "OpenList 已安装，当前版本为 $current_version。"
        echo "如需重新安装，请先卸载。"
        return
    fi

    read -p "即将开始安装 OpenList。是否继续？(y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "安装操作已取消。"
        return
    fi

    echo "步骤 1: 检查依赖..."
    if ! check_dependencies; then return 1; fi

    echo "步骤 2: 清理可能存在的残留..."
    cleanup_residuals

    echo "步骤 3: 检查并准备安装目录..."
    if ! check_install_dir; then return 1; fi

    echo "步骤 4: 下载并安装 OpenList 二进制文件..."
    if ! install_openlist_binary; then return 1; fi

    echo "步骤 5: 配置 Supervisor..."
    if ! setup_supervisor; then return 1; fi

    installation_summary
}

do_update_openlist() {
    local current_version
    current_version=$(get_current_version)
    if [ "$current_version" = "未安装" ] || [ "$current_version" = "未安装或无法获取" ]; then
        echo "OpenList 未安装，无法进行更新。请先安装。"
        return
    fi

    echo -e "${GREEN_COLOR}正在检查最新版本...${RES}"
    local latest_version
    latest_version=$(get_latest_version "")

    if echo "$latest_version" | grep -q "无法获取"; then
        echo -e "${RED_COLOR}无法获取最新版本信息。更新操作取消。${RES}"
        return
    fi

    echo "当前版本: $current_version, 最新版本: $latest_version"
    if ! version_gt "$latest_version" "$current_version"; then
        echo -e "${GREEN_COLOR}当前已是最新版本 ($current_version)，无需更新。${RES}"
        return
    fi

    read -p "${YELLOW_COLOR}检测到新版本 $latest_version。是否进行更新？(y/n): ${RES}" confirm_update
    if [ "$confirm_update" != "y" ] && [ "$confirm_update" != "Y" ]; then
        echo "更新操作已取消。"
        return
    fi

    echo -e "${GREEN_COLOR}开始更新 OpenList 至版本 $latest_version ...${RES}"

    echo -e "${GREEN_COLOR}更新时是否使用 GitHub 代理进行下载？（默认无代理）${RES}"
    read -p "请输入代理地址或直接按回车继续: " proxy_for_update_dl
    local download_proxy_url=""
    if [ -n "$proxy_for_update_dl" ]; then
        if echo "$proxy_for_update_dl" | grep -Eq '^https://.*/$'; then
            download_proxy_url="$proxy_for_update_dl"
            echo -e "${GREEN_COLOR}将使用代理 $download_proxy_url 下载。${RES}"
        else
            echo -e "${RED_COLOR}代理地址格式不正确。将不使用代理下载。${RES}"
        fi
    fi

    echo "停止 OpenList 服务..."
    _sudo supervisorctl stop openlist

    local backup_path="/tmp/openlist_backup_$(date +%s)"
    echo "备份当前 OpenList 二进制文件到 $backup_path..."
    if [ -f "$OPENLIST_BINARY" ]; then
        _sudo cp "$OPENLIST_BINARY" "$backup_path"
    fi

    local gh_download_url_versioned_openlist_file="openlist_linux_${ARCH}.tar.gz"
    local gh_download_url
    if [ -n "$download_proxy_url" ]; then
        gh_download_url="${download_proxy_url}https://github.com/OpenListTeam/OpenList/releases/download/${latest_version}/$gh_download_url_versioned_openlist_file"
    else
        gh_download_url="https://github.com/OpenListTeam/OpenList/releases/download/${latest_version}/$gh_download_url_versioned_openlist_file"
    fi

    local temp_download_path="/tmp/$gh_download_url_versioned_openlist_file"
    if ! download_with_retry "$gh_download_url" "$temp_download_path"; then
        echo -e "${RED_COLOR}下载新版本失败。${RES}"
        if [ -f "$backup_path" ]; then
            echo "正在尝试恢复备份..."
            _sudo cp "$backup_path" "$OPENLIST_BINARY"
            _sudo rm "$backup_path"
        fi
        _sudo supervisorctl start openlist
        return 1
    fi

    echo "解压新版本..."
    _sudo rm -f "$OPENLIST_BINARY"
    if ! _sudo tar zxf "$temp_download_path" -C "$DOWNLOAD_DIR/"; then
        echo -e "${RED_COLOR}解压新版本失败。${RES}"
        if [ -f "$backup_path" ]; then
            echo "正在尝试恢复备份..."
            _sudo cp "$backup_path" "$OPENLIST_BINARY"
            _sudo rm "$backup_path"
        fi
        _sudo rm -f "$temp_download_path"
        _sudo supervisorctl start openlist
        return 1
    fi
    _sudo rm -f "$temp_download_path"
    _sudo chmod +x "$OPENLIST_BINARY"

    if [ -f "$backup_path" ]; then _sudo rm -f "$backup_path"; fi

    echo "重启 OpenList 服务..."
    _sudo supervisorctl restart openlist

    sleep 2
    local new_current_version
    new_current_version=$(get_current_version)
    if [ "$new_current_version" = "$latest_version" ]; then
        echo -e "${GREEN_COLOR}OpenList 更新成功！当前版本: $new_current_version${RES}"
    else
        echo -e "${YELLOW_COLOR}OpenList 更新可能未完全成功。预期版本: $latest_version, 获取到版本: $new_current_version${RES}"
    fi
}

do_auto_update_openlist() {
    # ... function implementation ...
}

do_uninstall_openlist() {
    # ... function implementation ...
}

do_check_status() {
    # ... function implementation ...
}

do_reset_password() {
    # ... function implementation ...
}

control_service() {
    # ... function implementation ...
}

do_start_service() { control_service "start"; }
do_stop_service() { control_service "stop"; }
do_restart_service() { control_service "restart"; }

do_check_version_info() {
    # ... function implementation ...
}

do_set_auto_update() {
    # ... function implementation ...
}

# --- Main Menu & Script Execution ---
confirm_uninstall=""

main_menu() {
    while true; do
        echo -e "\n${GREEN_COLOR}OpenList 管理脚本 (v2.4 - Alpine)${RES}"
        echo "------------------------------------------"
        echo " 安装与更新:"
        echo "   1. 安装 OpenList"
        echo "   2. 更新 OpenList"
        echo "   3. 卸载 OpenList"
        echo "------------------------------------------"
        echo " 服务与状态:"
        echo "   4. 查看 OpenList 状态"
        echo "   5. 重置管理员密码"
        echo "   6. 启动 OpenList 服务"
        echo "   7. 停止 OpenList 服务"
        echo "   8. 重启 OpenList 服务"
        echo "------------------------------------------"
        echo " 其他:"
        echo "   9. 检测版本信息"
        echo "  10. 设置自动更新"
        echo "------------------------------------------"
        echo "   0. 退出脚本"
        echo "------------------------------------------"
        current_version_display=$(get_current_version)
        echo "当前版本: $current_version_display | 系统架构: $ARCH"
        read -p "请输入你的选择 [0-10]: " choice_menu

        case "$choice_menu" in
            1) do_install_openlist ;;
            2) do_update_openlist ;;
            3)
                do_uninstall_openlist
                if [ "$confirm_uninstall" = "y" ]; then
                   echo "卸载完成，脚本将退出。"
                   clear; exit 0
                fi
                ;;
            4) do_check_status ;;
            5) do_reset_password ;;
            6) do_start_service ;;
            7) do_stop_service ;;
            8) do_restart_service ;;
            9) do_check_version_info ;;
            10) do_set_auto_update ;;
            0) echo "退出脚本。"; clear; exit 0 ;;
            *) echo -e "${RED_COLOR}无效的选择，请重新输入。${RES}" ;;
        esac

        if [ "$choice_menu" != "0" ]; then
             read -p $'\n按回车键返回主菜单...' _unused_input
             clear
        fi
    done
}

# --- Script Entry Point ---
if [ "$1" = "auto-update" ]; then
    LOG_FILE="/var/log/openlist_autoupdate.log"
    {
        echo "--- OpenList Auto Update ---"
        echo "执行脚本: $SCRIPT_DIR/$SCRIPT_NAME auto-update"
        echo "开始时间: $(date)"
        do_auto_update_openlist
        echo "--- 整体更新任务完成于: $(date) ---"
    } 2>&1 | tee -a "$LOG_FILE"
    exit 0
fi

clear
main_menu