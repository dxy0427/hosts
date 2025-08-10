#!/bin/bash
if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 权限运行：sudo ./setup_ip_block.sh"
    exit 1
fi

# 选项菜单
echo "请选择操作："
echo "1. 配置默认拦截（IP访问返回444，不影响域名）"
echo "2. 仅删除原有默认配置（手动配置用）"
read -p "输入选项（1/2）：" choice

# 生成自签证书函数（有效期10年）
generate_cert() {
    mkdir -p /etc/nginx/ssl
    if [ ! -f "/etc/nginx/ssl/empty.key" ] || [ ! -f "/etc/nginx/ssl/empty.crt" ]; then
        echo "生成自签证书（有效期10年）..."
        openssl genrsa -out /etc/nginx/ssl/empty.key 2048 > /dev/null 2>&1
        # 有效期改为3650天（10年）
        openssl req -new -x509 -key /etc/nginx/ssl/empty.key -out /etc/nginx/ssl/empty.crt -days 3650 -subj "/CN=localhost" > /dev/null 2>&1
        echo "证书生成路径：/etc/nginx/ssl/"
    fi
}

# 选项1：配置拦截
if [ "$choice" = "1" ]; then
    # 删除原有默认配置（避免冲突）
    if [ -f "/etc/nginx/sites-enabled/default" ]; then
        rm /etc/nginx/sites-enabled/default
        echo "已删除原有 default 配置"
    fi
    if [ -f "/etc/nginx/sites-available/default" ]; then
        rm -f /etc/nginx/sites-available/default
    fi

    # 生成证书
    generate_cert

    # 创建新的 default 配置
    DEFAULT_CONF="/etc/nginx/sites-available/default"
    cat > "$DEFAULT_CONF" << 'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;

    # 自签证书（10年有效期）
    ssl_certificate /etc/nginx/ssl/empty.crt;
    ssl_certificate_key /etc/nginx/ssl/empty.key;

    # 匹配所有未绑定域名的请求（即IP访问）
    server_name _;

    # IP访问返回444，不影响已绑定的域名
    return 444;
}
EOF

    # 启用配置
    ln -s "$DEFAULT_CONF" /etc/nginx/sites-enabled/default
    echo "已创建 default 拦截配置"

# 选项2：仅删除默认配置
elif [ "$choice" = "2" ]; then
    if [ -f "/etc/nginx/sites-enabled/default" ]; then
        rm /etc/nginx/sites-enabled/default
        echo "已删除 sites-enabled/default"
    fi
    if [ -f "/etc/nginx/sites-available/default" ]; then
        rm -f /etc/nginx/sites-available/default
        echo "已删除 sites-available/default"
    else
        echo "没有默认配置可删除"
    fi
else
    echo "无效选项"
    exit 1
fi

# 验证并重启
echo "验证配置..."
if nginx -t > /dev/null 2>&1; then
    systemctl restart nginx
    echo "Nginx 重启成功"
    echo "效果：公网IP访问返回444，绑定的域名可正常访问"
else
    echo "配置有误，请检查后重试"
    exit 1
fi
