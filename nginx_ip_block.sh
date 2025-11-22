#!/bin/sh
# 使用 /bin/sh 以兼容 Alpine 的 ash 和 Debian 的 bash
set -e

# ==========================================
# Nginx IP 拦截脚本
# 自动适配: Debian/Ubuntu/Alpine
# ==========================================

# 1. 基础检查
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请用 root 权限运行" >&2
    exit 1
fi

# 2. 检测系统类型和路径
# 默认为未知
CONF_FILE=""
LINK_FILE=""
OS_TYPE=""
if [ -d "/etc/nginx/http.d" ]; then
    echo "检测到系统环境: Alpine"
    CONF_FILE="/etc/nginx/http.d/default.conf"
    OS_TYPE="alpine"
elif [ -d "/etc/nginx/sites-available" ]; then
    echo "检测到系统环境: Debian/Ubuntu"
    CONF_FILE="/etc/nginx/sites-available/default"
    LINK_FILE="/etc/nginx/sites-enabled/default"
    OS_TYPE="debian"
else
    echo "错误：未找到标准的 Nginx 配置目录 (http.d 或 sites-available)。" >&2
    echo "请确认 Nginx 已安装。" >&2
    exit 1
fi

# 3. 检查 Nginx 是否安装
if ! command -v nginx > /dev/null 2>&1; then
    echo "错误：未找到 nginx 命令。" >&2
    exit 1
fi

# 4. 菜单选择
echo "========================================"
echo "1. 开启 IP 拦截"
echo "2. 关闭 IP 拦截"
echo "========================================"
printf "请输入 [1/2]："
read choice

# 函数：安装 OpenSSL
install_openssl() {
    if [ "$OS_TYPE" = "alpine" ]; then
        apk add openssl
    else
        apt-get update && apt-get install -y openssl
    fi
}

# 函数：生成证书
generate_cert() {
    local ssl_dir="/etc/nginx/ssl"
    mkdir -p "$ssl_dir"
    chmod 700 "$ssl_dir"
    if [ ! -f "$ssl_dir/empty.crt" ]; then
        echo "正在生成自签证书..."
        if ! command -v openssl > /dev/null 2>&1; then
            install_openssl
        fi
        openssl genrsa -out "$ssl_dir/empty.key" 2048 > /dev/null 2>&1
        openssl req -new -x509 -key "$ssl_dir/empty.key" -out "$ssl_dir/empty.crt" -days 3650 -subj "/CN=localhost" > /dev/null 2>&1
        chmod 600 "$ssl_dir/empty.key" "$ssl_dir/empty.crt"
    fi
}

# ==========================================
# 核心逻辑
# ==========================================
if [ "$choice" = "1" ]; then
    echo "正在配置拦截..."
    
    # 1. 清理旧配置
    [ -n "$LINK_FILE" ] && [ -L "$LINK_FILE" ] && rm -f "$LINK_FILE"
    [ -f "$CONF_FILE" ] && rm -f "$CONF_FILE"

    # 2. 生成证书
    generate_cert

    # 3. 写入新配置
    cat > "$CONF_FILE" << 'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;

    ssl_certificate /etc/nginx/ssl/empty.crt;
    ssl_certificate_key /etc/nginx/ssl/empty.key;

    server_name _;
    
    # 关闭日志
    access_log off;
    log_not_found off;
    
    # 直接断开连接
    return 444;
}
EOF
    echo "拦截配置已写入: $CONF_FILE"

    # 4. 如果是 Debian 系，需要创建软链接
    if [ "$OS_TYPE" = "debian" ]; then
        ln -s "$CONF_FILE" "$LINK_FILE"
        echo "已创建软链接 sites-enabled。"
    fi

elif [ "$choice" = "2" ]; then
    echo "正在移除拦截..."
    deleted=0
    
    # 删除 Debian 的软链接
    if [ -n "$LINK_FILE" ] && [ -L "$LINK_FILE" ]; then
        rm -f "$LINK_FILE"
        deleted=1
    fi
    
    # 删除源文件
    if [ -f "$CONF_FILE" ]; then
        if grep -q "return 444" "$CONF_FILE"; then
            rm -f "$CONF_FILE"
            echo "已删除拦截配置文件。"
            deleted=1
        else
            echo "跳过：配置文件存在但似乎不是拦截脚本生成的，未删除。"
        fi
    fi

    if [ "$deleted" -eq 0 ]; then
        echo "没有发现拦截配置，无需操作。"
    fi

else
    echo "无效选项" >&2
    exit 1
fi

# 验证并重载
echo "正在验证并重载 Nginx..."
if nginx -t > /dev/null 2>&1; then
    nginx -s reload
    echo "✅ Nginx 重载成功，配置已生效！"
else
    echo "❌ Nginx 配置验证失败！请检查错误信息："
    nginx -t
    exit 1
fi