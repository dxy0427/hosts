#!/bin/bash

WORK_DIR="/usr/home/$(whoami)/van-nav"
NAV_PATH="$WORK_DIR/van-nav-gai"
LOG_FILE="$WORK_DIR/restart_log.txt"
PORT_FILE="$WORK_DIR/nav_port.conf"

if [ ! -f "$PORT_FILE" ]; then
    read -p "请输入 van-nav 运行端口号: " NAV_PORT
    echo "$NAV_PORT" > "$PORT_FILE"
else
    NAV_PORT=$(cat "$PORT_FILE")
fi

if ! pgrep -f "$NAV_PATH" > /dev/null
then
    cd "$WORK_DIR"
    nohup ./van-nav-gai -port "$NAV_PORT" > /dev/null 2>&1 &

    BEIJING_TIME=$(TZ=Asia/Shanghai date +"%Y-%m-%d %H:%M:%S")

    echo "van-nav 导航服务于 ${BEIJING_TIME} 重启，端口号：$NAV_PORT" >> "$LOG_FILE"
fi