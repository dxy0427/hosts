#!/bin/bash
set -euo pipefail  # 增强错误处理：遇到未定义变量、命令失败时退出

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请用root权限运行，例如：sudo ./setup_ip_block.sh" >&2  # 错误信息输出到stderr
    exit 1
fi

# 选项菜单
echo "请选择操作："
echo "1. 配置默认拦截（IP访问返回444，不影响域名）"
echo "2. 仅删除原有默认配置（手动配置用）"
read -p "输入选项（1/2）：" -r choice  # -r 防止反斜杠转义

# 生成自签证书函数（添加权限控制和清洁输出）
generate_cert() {
    local ssl_dir="/etc/nginx/ssl"
    mkdir -p "$ssl_dir"
    # 设置证书目录权限（仅root可读写）
    chmod 700 "$ssl_dir"

    if [ ! -f "$ssl_dir/empty.key" ] || [ ! -f "$ssl_dir/empty.crt" ]; then
        echo "正在生成自签证书（有效期10年）..."
        # 静默生成但保留错误提示（若失败会显式报错）
        if ! openssl genrsa -out "$ssl_dir/empty.key" 2048 > /dev/null 2>&1; then
            echo "错误：生成私钥失败，请检查openssl是否安装" >&2
            exit 1
        fi
        if ! openssl req -new -x509 -key "$ssl_dir/empty.key" -out "$ssl_dir/empty.crt" -days 3650 -subj "/CN=localhost" > /dev/null 2>&1; then
            echo "错误：生成证书失败" >&2
            exit 1
        fi
        # 限制证书权限（防止非root读取私钥）
        chmod 600 "$ssl_dir/empty.key" "$ssl_dir/empty.crt"
        echo "证书生成成功，路径：$ssl_dir/"
    else
        echo "证书已存在，跳过生成"
    fi
}

# 选项1：配置拦截
if [ "$choice" = "1" ]; then
    # 删除原有默认配置（处理软链接和文件）
    if [ -L "/etc/nginx/sites-enabled/default" ]; then  # 先检查是否为软链接
        rm -f /etc/nginx/sites-enabled/default
        echo "已删除 sites-enabled/default 软链接"
    elif [ -f "/etc/nginx/sites-enabled/default" ]; then  # 若为普通文件也删除
        rm -f /etc/nginx/sites-enabled/default
        echo "已删除 sites-enabled/default 文件"
    fi
    if [ -f "/etc/nginx/sites-available/default" ]; then
        rm -f /etc/nginx/sites-available/default
        echo "已删除 sites-available/default"
    fi

    # 生成证书
    generate_cert

    # 创建新的default配置
    local default_conf="/etc/nginx/sites-available/default"
    cat > "$default_conf" << 'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;

    # 自签证书
    ssl_certificate /etc/nginx/ssl/empty.crt;
    ssl_certificate_key /etc/nginx/ssl/empty.key;

    # 匹配所有未绑定域名的请求（IP访问）
    server_name _;

    # 立即关闭连接（444状态码）
    return 444;
}
EOF

    # 避免重复创建软链接
    if [ ! -L "/etc/nginx/sites-enabled/default" ]; then
        ln -s "$default_conf" /etc/nginx/sites-enabled/default
        echo "已创建默认拦截配置并启用"
    else
        echo "默认配置已启用，无需重复操作"
    fi

# 选项2：仅删除默认配置
elif [ "$choice" = "2" ]; then
    local deleted=0
    if [ -e "/etc/nginx/sites-enabled/default" ]; then  # -e 同时检查文件/链接
        rm -f /etc/nginx/sites-enabled/default
        echo "已删除 sites-enabled/default"
        deleted=1
    fi
    if [ -f "/etc/nginx/sites-available/default" ]; then
        rm -f /etc/nginx/sites-available/default
        echo "已删除 sites-available/default"
        deleted=1
    fi
    if [ "$deleted" -eq 0 ]; then
        echo "没有默认配置可删除"
    fi

else
    echo "错误：无效选项，请输入1或2" >&2
    exit 1
fi

# 验证并重启Nginx
echo "正在验证Nginx配置..."
if nginx -t > /dev/null 2>&1; then
    systemctl restart nginx
    echo "✅ Nginx重启成功"
    echo "效果：公网IP直接访问将被拒绝（返回444），已绑定的域名可正常访问"
else
    echo "❌ Nginx配置验证失败，请检查错误信息后重试" >&2
    exit 1
fi
