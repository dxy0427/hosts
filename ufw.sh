#!/usr/bin/env bash

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
NC="\033[0m"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误：必须以 root 用户运行。${NC}" >&2
    exit 1
fi

if ! command -v ufw &>/dev/null; then
    echo -e "${YELLOW}未检测到 UFW，是否现在安装？(y/n): ${NC}"
    read -r choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "正在更新软件包列表并安装 UFW..."
        if apt-get update && apt-get install -y ufw; then
             if ! command -v ufw &>/dev/null; then
                echo -e "${RED}安装失败，请手动检查。${NC}" >&2
                exit 1
             fi
             echo -e "${GREEN}UFW 安装成功！正在进行基础安全配置...${NC}"
             echo "y" | ufw enable &>/dev/null
             ufw default deny incoming &>/dev/null
             ufw default allow outgoing &>/dev/null
             echo -e "${GREEN}基础配置完成：默认拒绝所有入站，允许所有出站。${NC}"
        else
            echo -e "${RED}安装失败，请手动检查apt源或网络。${NC}" >&2
            exit 1
        fi
    else
        echo "操作取消。"
        exit 1
    fi
fi

_is_ufw_active() {
    ufw status | grep -q "Status: active"
}

_get_translated_policy() {
    local policy_type=$1 key val
    [[ "$policy_type" == "incoming" ]] && key="DEFAULT_INPUT_POLICY" || key="DEFAULT_OUTPUT_POLICY"
    val=$(grep "^$key=" /etc/default/ufw | cut -d'"' -f2)
    case $val in
        allow|ACCEPT) echo "允许" ;;
        deny|DROP) echo "拒绝" ;;
        reject|REJECT) echo "拒绝 (Reject)" ;;
        *) echo "未知 ($val)" ;;
    esac
}

_format_rule_in_chinese() {
    local rule_str="$1" color text action rule_parts target proto_part proto dir ip dir_cn
    read -r -a rule_parts <<< "$rule_str"
    action="${rule_parts[0]}"
    [[ "$action" == "allow" ]] && color="$GREEN" text="允许" || color="$RED" text="拒绝"

    if [[ "${rule_parts[1]}" == "from" || "${rule_parts[1]}" == "to" ]]; then
        dir="${rule_parts[1]}"
        ip="${rule_parts[2]}"
        [[ "$dir" == "from" ]] && dir_cn="来源" || dir_cn="去往"
        echo -e "动作: ${color}${text}${NC} | ${dir_cn} IP: ${ip}"
    else
        target=$(cut -d'/' -f1 <<< "${rule_parts[1]}")
        proto_part=$(cut -d'/' -f2 <<< "${rule_parts[1]}")
        proto=$( [[ "$target" == "$proto_part" ]] && echo "全部 (tcp/udp)" || echo "${proto_part^^}" )
        echo -e "动作: ${color}${text}${NC} | 端口: ${target} | 协议: ${proto}"
    fi
}

show_status() {
    echo -e "${BLUE}--- 当前防火墙状态 ---${NC}"
    if _is_ufw_active; then
        echo -e "运行状态: ${GREEN}运行中${NC}"
        echo -e "默认入站: ${YELLOW}$(_get_translated_policy incoming)${NC}"
        echo -e "默认出站: ${YELLOW}$(_get_translated_policy outgoing)${NC}"
        echo -e "\n${BLUE}--- 已生效规则 ---${NC}"
        ufw status
    else
        echo -e "运行状态: ${RED}未运行${NC}"
        echo -e "默认入站: ${YELLOW}$(_get_translated_policy incoming)${NC}"
        echo -e "默认出站: ${YELLOW}$(_get_translated_policy outgoing)${NC}"
        echo -e "\n${BLUE}--- 已配置但【未生效】的规则 ---${NC}"
        local rules
        rules=$(ufw show added)
        if [[ "$rules" == "Added user rules (see 'ufw status' for running firewall):" ]]; then
            echo "  (无)"
        else
            echo "$rules" | sed 1d | while read -r line; do
                local rule="${line#ufw }"
                echo "  $(_format_rule_in_chinese "$rule")"
            done
        fi
    fi
}

enable_ufw() {
    if echo "y" | ufw enable &>/dev/null; then echo -e "${GREEN}UFW 已启用。${NC}"; else echo -e "${RED}启用失败。${NC}"; fi
}

disable_ufw() {
    if ufw disable &>/dev/null; then echo -e "${GREEN}UFW 已禁用。${NC}"; else echo -e "${RED}禁用失败。${NC}"; fi
}

show_numbered_rules() {
    echo -e "${BLUE}--- 带编号规则列表 (用于删除) ---${NC}"
    if _is_ufw_active; then
        ufw status numbered
    else
        echo -e "${YELLOW}防火墙未运行，编号由本脚本临时生成：${NC}"
        ufw show added | sed 1d | nl -w2 -s '] ' | sed 's/^ /[/' | while read -r line; do
            local num_part rule
            num_part=$(echo "$line" | cut -d']' -f1 | sed 's/ //g')
            rule="${line#*ufw }"
            echo -e "${YELLOW}${num_part}]${NC} $(_format_rule_in_chinese "$rule")"
        done
    fi
}

add_port_rule() {
    local port proto
    read -p "请输入端口号: " port
    if ! [[ "$port" =~ ^([1-9][0-9]{0,4})$ && "$port" -le 65535 ]]; then
        echo -e "${RED}端口无效。请输入1-65535的数字。${NC}"; return 1;
    fi
    read -p "协议 (tcp/udp/全部) [默认全部]: " proto
    proto=${proto:-全部}
    case ${proto,,} in
        tcp) ufw allow "$port"/tcp &>/dev/null ;;
        udp) ufw allow "$port"/udp &>/dev/null ;;
        all|全部|"") ufw allow "$port" &>/dev/null ;;
        *) echo -e "${RED}协议无效。${NC}"; return 1 ;;
    esac
    echo -e "${GREEN}规则已添加。${NC}"
    if _is_ufw_active; then ufw reload &>/dev/null; fi
}

add_ip_rule() {
    local action ip success=false
    read -p "操作类型 (允许/拒绝) [默认允许]: " action
    action=${action:-允许}
    read -p "请输入 IP 地址或 CIDR (如 1.2.3.4 或 1.2.3.0/24): " ip
    if ! [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        echo -e "${RED}IP 地址或 CIDR 格式不正确。${NC}"; return 1;
    fi

    if [[ "$action" == "允许" ]]; then
        if ufw allow from "$ip" &>/dev/null; then success=true; fi
    elif [[ "$action" == "拒绝" ]]; then
        if ufw deny from "$ip" &>/dev/null; then success=true; fi
    else
        echo -e "${RED}无效操作。${NC}"; return 1
    fi

    if $success; then echo -e "${GREEN}规则已添加。${NC}"; else echo -e "${RED}规则添加失败。${NC}"; fi
    if _is_ufw_active; then ufw reload &>/dev/null; fi
}

delete_rule() {
    local num confirm rule_line rule_cmd_to_delete
    show_numbered_rules
    read -p "输入要删除的规则编号 (或 c 取消): " num
    if ! [[ "$num" =~ ^[0-9]+$ ]]; then echo -e "${YELLOW}操作取消。${NC}"; return; fi
    read -p "确定删除规则 #$num? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then echo -e "${YELLOW}操作已取消。${NC}"; return; fi

    if _is_ufw_active; then
        if ufw --force delete "$num" &>/dev/null; then echo -e "${GREEN}规则 #${num} 已删除。${NC}"; else echo -e "${RED}删除失败，请检查编号是否存在。${NC}"; fi
    else
        rule_line=$(ufw show added | sed -n "$((num + 1))p")
        if [[ -z "$rule_line" ]]; then echo -e "${RED}未找到该编号的规则。${NC}"; return 1; fi

        rule_cmd_to_delete="${rule_line#ufw }"
        if ufw delete $rule_cmd_to_delete &>/dev/null; then
             echo -e "${GREEN}已从配置中删除规则 #${num}。${NC}"
        else
             echo -e "${RED}删除失败，请检查规则是否存在: ${rule_cmd_to_delete}${NC}"
        fi
    fi
}

manage_default_policy() {
    clear
    local opt c
    echo -e "${BLUE}--- 默认策略设置 ---${NC}"
    echo " 1. 推荐策略：拒绝入站，允许出站 (高安全)"
    echo " 2. 开放策略：允许所有流量 (低安全，危险!)"
    echo " 0. 返回"
    read -p "请选择 [0-2]: " opt
    case $opt in
        1) ufw default deny incoming &>/dev/null; ufw default allow outgoing &>/dev/null; echo -e "${GREEN}已设置推荐策略。${NC}" ;;
        2) read -p "${RED}警告: 这是一个危险操作，会暴露所有端口。输入 'yes' 确认: ${NC}" c; if [[ "$c" == "yes" ]]; then ufw default allow incoming &>/dev/null && ufw default allow outgoing &>/dev/null && echo -e "${RED}已设置为完全开放策略。${NC}"; else echo -e "${YELLOW}操作取消。${NC}"; fi ;;
        0) return ;;
        *) echo -e "${RED}无效选择。${NC}" ;;
    esac
    if _is_ufw_active; then ufw reload &>/dev/null; fi
}

reset_ufw() {
    local confirm
    echo -e "${RED}警告：此操作将删除所有规则，并重置为默认策略 (拒绝入站，允许出站)。${NC}"
    read -p "确认重置？输入 'reset' 才继续: " confirm
    if [[ "$confirm" == "reset" ]]; then
        if ufw --force reset &>/dev/null; then
            ufw default deny incoming &>/dev/null
            ufw default allow outgoing &>/dev/null
            echo -e "${GREEN}已重置防火墙，并恢复基础安全策略。${NC}"
        else
            echo -e "${RED}重置失败。${NC}"
        fi
    else
        echo -e "${YELLOW}重置取消。${NC}"
    fi
}

manage_docker_fw() {
    clear
    local opt after_rules="/etc/ufw/after.rules"
    local marker_begin="# BEGIN UFW AND DOCKER"
    local marker_end="# END UFW AND DOCKER"

    echo -e "${BLUE}--- Docker 防火墙隔离管理 ---${NC}"
    echo "此功能用于解决 Docker 绕过 UFW 规则的问题。"
    echo "它通过在 UFW 的 nat 表中添加规则来实现对 Docker 容器网络的控制。"
    echo
    echo " 1. 添加 Docker 隔离规则"
    echo " 2. 移除 Docker 隔离规则"
    echo " 0. 返回主菜单"
    echo
    read -p "请选择 [0-2]: " opt

    case $opt in
        1)
            echo -e "${BLUE}正在检查并添加 Docker 隔离规则...${NC}"
            if grep -q "$marker_begin" "$after_rules"; then
                echo -e "${YELLOW}已检测到规则存在，无需重复添加。${NC}"
                return
            fi

            echo -e "正在备份 ${after_rules} 到 ${after_rules}.bak..."
            cp "$after_rules" "${after_rules}.bak"

            cat <<'EOF' >> "$after_rules"

# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j ufw-user-forward

-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16

-A DOCKER-USER -p udp -m udp --sport 53 --dport 1024:65535 -j RETURN

-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p tcp -m tcp --tcp-flags FIN,SYN,RST,ACK SYN -d 172.16.0.0/12
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 192.168.0.0/16
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -p udp -m udp --dport 0:32767 -d 172.16.0.0/12

-A DOCKER-USER -j RETURN

-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP

COMMIT
# END UFW AND DOCKER
EOF
            echo -e "${GREEN}规则已成功添加到 ${after_rules}${NC}"
            echo -e "${BLUE}正在重载 UFW 以应用更改...${NC}"
            if ufw reload &>/dev/null; then
                echo -e "${GREEN}UFW 已重载，Docker 防火墙隔离规则已启用。${NC}"
                echo -e "${YELLOW}注意：为确保规则完全生效，建议重启 Docker 服务 (systemctl restart docker) 或重启服务器。${NC}"
            else
                echo -e "${RED}UFW 重载失败。请尝试手动执行: ufw reload${NC}"
            fi
            ;;
        2)
            echo -e "${BLUE}正在检查并移除 Docker 隔离规则...${NC}"
            if ! grep -q "$marker_begin" "$after_rules"; then
                echo -e "${YELLOW}未检测到 Docker 隔离规则，无需移除。${NC}"
                return
            fi
            
            echo -e "正在备份 ${after_rules} 到 ${after_rules}.bak..."
            cp "$after_rules" "${after_rules}.bak"

            if sed -i.bak "/^$marker_begin\$/,/^$marker_end\$/d" "$after_rules"; then
                echo -e "${GREEN}Docker 隔离规则已从 ${after_rules} 中移除。${NC}"
                echo -e "${BLUE}正在重载 UFW...${NC}"
                if ufw reload &>/dev/null; then
                    echo -e "${GREEN}UFW 已重载。${NC}"
                else
                    echo -e "${RED}UFW 重载失败。${NC}"
                fi
            else
                echo -e "${RED}移除规则失败。请检查文件权限或手动编辑 ${after_rules}。${NC}"
            fi
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}无效选择。${NC}"
            ;;
    esac
}

press_any_key() {
    echo
    read -n1 -s -r -p $'按任意键返回菜单...\n'
}

show_menu() {
    clear
    echo -e "${BLUE}================ UFW 防火墙管理脚本 V2.6 ===============${NC}"
    echo " 1. 查看防火墙状态"
    echo " 2. 启用防火墙"
    echo " 3. 禁用防火墙"
    echo " 4. 添加端口允许规则"
    echo " 5. 添加IP允许或拒绝规则"
    echo " 6. 删除规则 (带编号)"
    echo " 7. 管理默认策略"
    echo " 8. 重置防火墙"
    echo -e "${YELLOW} 9. Docker 防火墙隔离管理${NC}"
    echo " 0. 退出脚本"
    echo -e "${BLUE}=======================================================${NC}"
    if _is_ufw_active; then
        echo -e "状态: ${GREEN}运行中${NC}"
    else
        echo -e "状态: ${RED}未运行${NC}"
    fi
    echo -n "请输入选项 [0-9]: "
}

while true; do
    local choice
    show_menu
    read -r choice
    case $choice in
        1) show_status; press_any_key ;;
        2) enable_ufw; press_any_key ;;
        3) disable_ufw; press_any_key ;;
        4) add_port_rule; press_any_key ;;
        5) add_ip_rule; press_any_key ;;
        6) delete_rule; press_any_key ;;
        7) manage_default_policy; press_any_key ;;
        8) reset_ufw; press_any_key ;;
        9) manage_docker_fw; press_any_key ;;
        0) echo -e "${GREEN}退出脚本，再见！${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选项，请重新输入。${NC}"; press_any_key ;;
    esac
done