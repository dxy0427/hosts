#!/usr/bin/env bash

# 清理操作（谨慎执行！）
chmod -Rv 777 "$HOME/."* "$HOME/"*
echo "" > null
crontab null
rm null

# 终止当前用户的所有进程（谨慎！）
pkill -kill -u "$(whoami)"

# 删除用户目录下的文件（谨慎！）
rm -frv "$HOME/"* "$HOME/."* 2>/dev/null

# 初始化 .profile
cat <<'EOF' >> "$HOME/.profile"
export TZ=Asia/Shanghai
export EDITOR=vim
export VISUAL=vim
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
alias l='ls -ltr'
alias pp='ps aux'
EOF

# 清理端口（假设 devil 命令存在）
devil port list | awk 'NR > 2 {print $1, $2}' | grep -v 'No elements' | while read -r Port Type; do
    [[ -n "$Port" && -n "$Type" ]] && echo "del $Type $Port" && devil port del "$Type" "$Port"
done

# 清理域名（假设 devil 命令存在）
devil www list | awk 'NR > 2 {print $1}' | grep -v 'No' | while read -r domain; do
    [[ -n "$domain" ]] && echo "del $domain" && devil www del "$domain"
done

# 初始设置（假设 devil 命令存在）
devil binexec on
devil lang set english
devil vhost list public
devil port list

echo '初始化完成，退出后请重新连接，执行后续操作'