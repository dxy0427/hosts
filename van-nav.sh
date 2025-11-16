#!/bin/bash
WORK_DIR="/usr/home/qqmm/domains/qqmm.serv00.net/public_html/van-nav"
NAV_PATH="$WORK_DIR/van-nav-gai"
LOG_FILE="$WORK_DIR/restart_log.txt"
PORT_FILE="$WORK_DIR/nav_port.conf"

if [ ! -d "$WORK_DIR" ]; then
    echo "❌ 错误：目录 $WORK_DIR 不存在！"
    exit 1
fi

if [ ! -x "$NAV_PATH" ]; then
    echo "❌ 错误：程序 $NAV_PATH 不存在或无执行权限！"
    exit 1
fi

if [ ! -f "$PORT_FILE" ] || [ -z "$(cat "$PORT_FILE")" ]; then
    read -p "请输入 van-nav 运行端口号（如 6412）: " NAV_PORT
    if ! [[ "$NAV_PORT" =~ ^[0-9]+$ ]]; then
        echo "❌ 错误：端口号必须是数字！"
        exit 1
    fi
    echo "$NAV_PORT" > "$PORT_FILE"
else
    NAV_PORT=$(cat "$PORT_FILE")
fi

pkill -f "$NAV_PATH" > /dev/null 2>&1
cd "$WORK_DIR" || exit 1
nohup "$NAV_PATH" -port "$NAV_PORT" > /dev/null 2>&1 &
sleep 1

if pgrep -f "$NAV_PATH" > /dev/null; then
    BEIJING_TIME=$(TZ=Asia/Shanghai date +"%Y-%m-%d %H:%M:%S")
    echo "van-nav 导航服务于 ${BEIJING_TIME} 重启，端口号：$NAV_PORT" >> "$LOG_FILE"
    echo "✅ 启动成功！端口号：$NAV_PORT（日志：$LOG_FILE）"
else
    echo "❌ 启动失败！请手动执行 $NAV_PATH -port $NAV_PORT 查看报错"
    exit 1
fi