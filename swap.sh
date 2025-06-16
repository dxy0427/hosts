#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # 无颜色

# 检查是否为root用户
if [ "$(id -u)" -ne 0 ]; then
   echo -e "${RED}错误：此脚本需要root权限运行。请使用sudo执行。${NC}"
   exit 1
fi

# Swap文件路径
SWAP_FILE="/swapfile"

# 检查当前swap状态
check_swap() {
    echo -e "\n${YELLOW}当前Swap状态：${NC}"
    swapon --show
    free -h
    echo -e "\n${YELLOW}磁盘空间：${NC}"
    df -h /
}

# 创建Swap
create_swap() {
    local size=$1
    
    # 检查文件是否已存在
    if [ -f "$SWAP_FILE" ]; then
        echo -e "${RED}错误：Swap文件 $SWAP_FILE 已存在！${NC}"
        read -p "是否删除现有Swap文件并创建新的？(y/n) " answer
        if [ "$answer" != "y" ]; then
            exit 1
        fi
        delete_swap
    fi
    
    # 检查磁盘空间
    available=$(df --output=avail -BK / | tail -n 1 | tr -d 'K')
    required=$((size * 1024 * 1024 / 1024))  # 转换为KB
    
    if [ "$available" -lt "$required" ]; then
        echo -e "${RED}错误：磁盘空间不足！需要 ${size}GB，可用 $(($available/1024/1024))GB${NC}"
        exit 1
    fi
    
    # 创建Swap文件
    echo -e "${YELLOW}正在创建 ${size}GB Swap文件...${NC}"
    fallocate -l "${size}G" "$SWAP_FILE" || { echo -e "${RED}创建Swap文件失败！${NC}"; exit 1; }
    
    # 设置权限
    chmod 600 "$SWAP_FILE"
    
    # 格式化Swap
    echo -e "${YELLOW}正在格式化Swap文件...${NC}"
    mkswap "$SWAP_FILE" || { echo -e "${RED}格式化Swap文件失败！${NC}"; exit 1; }
    
    # 启用Swap
    echo -e "${YELLOW}正在启用Swap...${NC}"
    swapon "$SWAP_FILE" || { echo -e "${RED}启用Swap失败！${NC}"; exit 1; }
    
    # 添加到fstab
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo -e "${YELLOW}正在更新 /etc/fstab...${NC}"
        echo "$SWAP_FILE none swap defaults 0 0" >> /etc/fstab
    fi
    
    # 调整swappiness
    echo -e "${YELLOW}正在优化系统内存参数...${NC}"
    if ! grep -q "vm.swappiness=10" /etc/sysctl.conf; then
        echo "vm.swappiness=10" >> /etc/sysctl.conf
    fi
    if ! grep -q "vm.vfs_cache_pressure=50" /etc/sysctl.conf; then
        echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf
    fi
    sysctl -p
    
    echo -e "${GREEN}✓ ${size}GB Swap设置成功！${NC}"
    check_swap
}

# 删除Swap
delete_swap() {
    # 检查文件是否存在
    if [ ! -f "$SWAP_FILE" ]; then
        echo -e "${RED}错误：Swap文件 $SWAP_FILE 不存在！${NC}"
        exit 1
    fi
    
    # 禁用Swap
    echo -e "${YELLOW}正在禁用Swap...${NC}"
    swapoff "$SWAP_FILE" || { echo -e "${RED}禁用Swap失败！${NC}"; exit 1; }
    
    # 从fstab中删除
    echo -e "${YELLOW}正在更新 /etc/fstab...${NC}"
    sed -i "\|$SWAP_FILE|d" /etc/fstab
    
    # 删除文件
    echo -e "${YELLOW}正在删除Swap文件...${NC}"
    rm "$SWAP_FILE" || { echo -e "${RED}删除Swap文件失败！${NC}"; exit 1; }
    
    echo -e "${GREEN}✓ Swap已成功删除！${NC}"
    check_swap
}

# 主菜单
while true; do
    clear
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}         Swap内存管理脚本 v1.0          ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    check_swap
    
    echo -e "\n${YELLOW}请选择操作：${NC}"
    echo "1. 设置1GB Swap"
    echo "2. 设置2GB Swap"
    echo "3. 自定义Swap大小"
    echo "4. 删除现有Swap"
    echo "5. 退出"
    
    read -p "请输入选项 [1-5]: " choice
    
    case $choice in
        1) create_swap 1 ;;
        2) create_swap 2 ;;
        3) 
            read -p "请输入Swap大小(GB): " custom_size
            create_swap "$custom_size" 
            ;;
        4) delete_swap ;;
        5) 
            echo -e "${GREEN}退出脚本...${NC}"
            exit 0 
            ;;
        *) 
            echo -e "${RED}无效选项！请输入1-5${NC}"
            sleep 2
            ;;
    esac
    
    read -p "按Enter键返回主菜单..."
done