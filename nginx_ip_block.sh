#!/bin/bash
set -euo pipefail

# Nginx IP 拦截脚本

# 基础检查（root权限 + Nginx存在）
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请用 root 权限运行" >&2
    exit 1
fi
if ! command -v nginx &> /dev/null; then
    echo "错误：未找到 Nginx" >&2
    exit 1
fi

# 菜单选择
echo "1. 开启ip拦截"
echo "2. 关闭ip拦截"
read -p "请输入 [1/2]：" -r choice

# 生成自签证书函数
generate_cert() {
    local ssl_dir="/etc/nginx/ssl"
    mkdir -p "$ssl_dir"
    chmod 700 "$ssl_dir"
    if [ ! -f "$ssl_dir/empty.crt" ]; then
        echo "生成自签证书..."
        # 无openssl则自动安装
        if ! command -v openssl &> /dev/null; then
             apt-get update && apt-get install -y openssl
        fi
        openssl genrsa -out "$ssl_dir/empty.key" 2048 > /dev/null 2>&1
        openssl req -new -x509 -key "$ssl_dir/empty.key" -out "$ssl_dir/empty.crt" -days 3650 -subj "/CN=localhost" > /dev/null 2>&1
        chmod 600 "$ssl_dir/empty.key" "$ssl_dir/empty.crt"
    fi
}

# 核心逻辑
if [ "$choice" = "1" ]; then
    echo "正在配置拦截..."
    # 清理旧配置
    rm -f /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-available/default
    # 生成证书
    generate_cert
    # 写入拦截配置
    cat > "/etc/nginx/sites-available/default" << 'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;

    ssl_certificate /etc/nginx/ssl/empty.crt;
    ssl_certificate_key /etc/nginx/ssl/empty.key;

    server_name _;
    access_log off;
    log_not_found off;
    return 444;
}
EOF
    # 启用配置
    ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    echo "配置已写入并启用。"

elif [ "$choice" = "2" ]; then
    echo "正在移除拦截..."
    deleted=0
    # 删除软链接
    if [ -L "/etc/nginx/sites-enabled/default" ]; then
        rm -f /etc/nginx/sites-enabled/default
        deleted=1
    fi
    # 仅删除拦截相关源文件
    if [ -f "/etc/nginx/sites-available/default" ]; then
        if grep -q "return 444" "/etc/nginx/sites-available/default"; then
            rm -f /etc/nginx/sites-available/default
            echo "已删除 default 拦截文件。"
            deleted=1
        else
            echo "跳过：非拦截配置，未删除。"
        fi
    fi
    if [ "$deleted" -eq 0 ]; then
        echo "无拦截配置可删。"
    fi

else
    echo "无效选项" >&2
    exit 1
fi

# 验证并重启Nginx
if nginx -t > /dev/null 2>&1; then
    systemctl reload nginx
    echo "✅ Nginx 重载成功，操作生效。"
else
    echo "❌ Nginx 配置有误！"
    nginx -t
    exit 1
fi