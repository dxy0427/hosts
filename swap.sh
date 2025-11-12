#!/bin/bash

# --- 颜色定义 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # 无颜色

# --- 全局变量 ---
SWAP_FILE="/swapfile"

# --- 函数定义 ---

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
       echo -e "${RED}错误：此脚本需要root权限运行。请使用sudo执行。${NC}"
       exit 1
    fi
}

check_swap_status() {
    echo -e "\n${YELLOW}--- 当前Swap状态 ---${NC}"
    swapon --show
    echo -e "\n${YELLOW}--- 内存使用情况 ---${NC}"
    free -h
    echo -e "\n${YELLOW}--- 根目录磁盘空间 ---${NC}"
    df -h /
}

# 优化sysctl配置的函数
# 参数1: key (e.g., vm.swappiness)
# 参数2: value (e.g., 10)
update_sysctl() {
    local key=$1
    local value=$2
    # 如果key已存在, 则修改它; 否则, 添加它
    if grep -q "^${key}" /etc/sysctl.conf; then
        sed -i "s/^${key}.*/${key} = ${value}/" /etc/sysctl.conf
    else
        echo "${key} = ${value}" >> /etc/sysctl.conf
    fi
}

create_swap() {
    local size_gb=$1

    if [ -f "$SWAP_FILE" ]; then
        echo -e "${RED}警告：Swap文件 $SWAP_FILE 已存在！${NC}"
        read -p "是否删除现有Swap并创建新的？(y/n) " answer
        # 将输入转为小写进行比较，增强用户体验
        if [[ "${answer,,}" != "y" ]]; then
            echo "操作已取消。"
            return
        fi
        # 在创建前先执行删除操作，确保环境干净
        delete_swap
    fi

    # 使用-kP参数确保输出格式一致，便于awk解析
    local available_kb
    available_kb=$(df -kP / | tail -1 | awk '{print $4}')
    local required_kb
    required_kb=$((size_gb * 1024 * 1024))

    if [ "$available_kb" -lt "$required_kb" ]; then
        local available_gb=$((available_kb / 1024 / 1024))
        echo -e "${RED}错误：磁盘空间不足！需要 ${size_gb}GB，但根目录仅可用 ${available_gb}GB。${NC}"
        exit 1
    fi

    echo -e "${YELLOW}正在创建 ${size_gb}GB Swap文件...（这可能需要一些时间）${NC}"
    # 优先使用fallocate快速创建文件，如果失败则回退到dd，以增强兼容性
    fallocate -l "${size_gb}G" "$SWAP_FILE"
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}fallocate失败，尝试使用dd... (这会更慢)${NC}"
        dd if=/dev/zero of="$SWAP_FILE" bs=1G count="$size_gb" status=progress || {
            echo -e "${RED}使用dd创建Swap文件失败！${NC}"
            rm -f "$SWAP_FILE" # 清理失败创建的文件
            exit 1
        }
    fi

    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE" || { echo -e "${RED}格式化Swap文件失败！${NC}"; exit 1; }
    swapon "$SWAP_FILE" || { echo -e "${RED}启用Swap失败！${NC}"; exit 1; }

    # 添加到fstab以实现开机自启
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo -e "${YELLOW}正在更新 /etc/fstab...${NC}"
        echo "$SWAP_FILE none swap defaults 0 0" >> /etc/fstab
    fi

    # 使用辅助函数来安全地更新或添加配置
    echo -e "${YELLOW}正在优化系统内存参数...${NC}"
    update_sysctl "vm.swappiness" "10"
    update_sysctl "vm.vfs_cache_pressure" "50"
    sysctl -p > /dev/null

    echo -e "${GREEN}✓ ${size_gb}GB Swap设置成功！${NC}"
    check_swap_status
}

delete_swap() {
    # 仅当swap文件被激活时才执行swapoff
    if swapon --show | grep -q "$SWAP_FILE"; then
        echo -e "${YELLOW}正在禁用Swap...${NC}"
        swapoff "$SWAP_FILE" || { echo -e "${RED}禁用Swap失败！可能正在被使用。${NC}"; return 1; }
    else
         echo -e "${YELLOW}Swap文件 $SWAP_FILE 未被激活，将直接清理文件和配置。${NC}"
    fi

    # 从fstab中删除记录
    if grep -q "$SWAP_FILE" /etc/fstab; then
        echo -e "${YELLOW}正在从 /etc/fstab 中移除记录...${NC}"
        sed -i "\|$SWAP_FILE|d" /etc/fstab
    fi

    # 删除swap文件本身
    if [ -f "$SWAP_FILE" ]; then
        echo -e "${YELLOW}正在删除Swap文件...${NC}"
        rm "$SWAP_FILE" || { echo -e "${RED}删除Swap文件失败！${NC}"; return 1; }
    fi

    echo -e "${GREEN}✓ Swap已成功清理！${NC}"
    check_swap_status
}

main_menu() {
    while true; do
        clear
        echo -e "${GREEN}=========================================${NC}"
        echo -e "${GREEN}         Swap内存管理脚本 v1.2          ${NC}"
        echo -e "${GREEN}=========================================${NC}"
        check_swap_status

        echo -e "\n${YELLOW}请选择操作：${NC}"
        echo "1. 设置 1GB Swap"
        echo "2. 设置 2GB Swap"
        echo "3. 设置 4GB Swap"
        echo "4. 自定义Swap大小"
        echo "5. 删除现有Swap"
        echo "6. 退出"

        read -p "请输入选项 [1-6]: " choice

        case $choice in
            1) create_swap 1 ;;
            2) create_swap 2 ;;
            3) create_swap 4 ;;
            4)
                read -p "请输入Swap大小(GB，仅限正整数): " custom_size
                # 使用正则表达式验证输入，确保是有效的正整数
                if ! [[ "$custom_size" =~ ^[1-9][0-9]*$ ]]; then
                    echo -e "${RED}错误：请输入一个有效的正整数！${NC}"
                else
                    create_swap "$custom_size"
                fi
                ;;
            5) delete_swap ;;
            6)
                echo -e "${GREEN}退出脚本...${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项！请输入1-6之间的数字。${NC}"
                ;;
        esac

        read -p "按Enter键返回主菜单..."
    done
}

# --- 脚本执行入口 ---
check_root
main_menu