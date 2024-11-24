#!/bin/bash

set -e  # 如果遇到错误，立即退出

# 确保脚本以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "${red}此脚本需要 root 权限。请使用 sudo 运行。${reset}"
    exit 1
fi

# === 配置 ===
# 默认的区域列表（根据实际需求可修改）
default_zones=("block" "dmz" "drop" "external" "home" "internal" "nm-shared" "public" "trusted" "work")
# 默认允许的服务列表（根据实际需求可修改）
default_services="ssh dhcpv6-client cockpit mdns samba-client dns dhcp"
# 默认的富规则列表（根据实际需求可修改）
default_rich_rules=(
    'rule priority="32767" reject'
    # 添加更多富规则
)
# 防火墙配置备份目录
backup_dir="/tmp/firewalld_backup_$(date +%Y%m%d_%H%M%S)"
# 设置区域名称
ALLOWED_IPS=(
    # Cloudflare IPv4
    "173.245.48.0/20"
    "103.21.244.0/22"
    "103.22.200.0/22"
    "103.31.4.0/22"
    "141.101.64.0/18"
    "108.162.192.0/18"
    "190.93.240.0/20"
    "188.114.96.0/20"
    "197.234.240.0/22"
    "198.41.128.0/17"
    "162.158.0.0/15"
    "104.16.0.0/13"
    "104.24.0.0/14"
    "172.64.0.0/13"
    "131.0.72.0/22"
    # Cloudflare IPv6
    "2400:cb00::/32"
    "2606:4700::/32"
    "2803:f800::/32"
    "2405:b500::/32"
    "2405:8100::/32"
    "2a06:98c0::/29"
    "2c0f:f248::/32"
)

# 设置公开区域的服务和端口
PUBLIC_RULES=(
    http
    https
    #80/tcp
    #443/tcp
)

# 如果脚本参数中提供了附加 IP 地址，则将其追加到 ALLOWED_IPS
if [ -n "\$1" ]; then
    IFS=',' read -r -a additional_ips <<< "\$1"
    ALLOWED_IPS+=("\${additional_ips[@]}")
fi

# 如果脚本参数中提供了附加服务规则，则将其追加到 PUBLIC_RULES
if [ -n "\$2" ]; then
    IFS=',' read -r -a additional_rules <<< "\$2"
    PUBLIC_RULES+=("\${additional_rules[@]}")
fi

# 包管理工具（自动检测 dnf 或 yum）
if command -v dnf &>/dev/null; then
    package_manager="dnf"
elif command -v yum &>/dev/null; then
    package_manager="yum"
else
    echo "${red}无法检测到支持的包管理工具 (dnf, yum)。${reset}"
    exit 1
fi

# === 配色 ===
green=$(tput setaf 2)
red=$(tput setaf 1)
reset=$(tput sgr0)

# === 检查 SELinux 状态 ===
if getenforce | grep -q "Enforcing"; then
    echo "${red}警告：SELinux 已启用，请确保防火墙配置不受限制。建议检查 SELinux 策略设置以避免干扰。${reset}"
fi

backup_firewalld_config() {
    echo "${green}备份现有防火墙配置到 $backup_dir${reset}"
    sudo mkdir -p "$backup_dir"
    sudo cp -r /etc/firewalld/* "$backup_dir"
    echo "${green}备份完成，备份目录：$backup_dir${reset}"
}

# 用户交互，是否创建和配置公开区域
read -p "是否创建和配置公开区域 (public_zone)? (y/n)[默认 y]: " CREATE_PUBLIC_ZONE
CREATE_PUBLIC_ZONE=${CREATE_PUBLIC_ZONE:-y}  # 如果没有输入，默认为 "y"

# === 检查是否安装 firewalld ===
if ! rpm -q firewalld &>/dev/null ; then
    echo "${red}firewalld 未安装。正在安装...${reset}"
    sudo $package_manager install -y firewalld || { echo "${red}安装 firewalld 失败，请检查网络或系统配置。${reset}"; exit 1; }
    sudo systemctl enable firewalld
    sudo systemctl start firewalld
    echo "${green}firewalld 安装成功。规则为默认状态，无需检查。${reset}"
fi

# === 检查 firewalld 是否运行 ===
if ! systemctl is-active --quiet firewalld; then
    echo "${red}firewalld 未运行，正在启动...${reset}"
    sudo systemctl start firewalld || { echo "${red}无法启动 firewalld，请检查配置。${reset}"; exit 1; }
    echo "${green}firewalld 已启动。${reset}"
fi

# === 备份配置 ===
backup_firewalld_config

# === 一次性列出所有区域规则 ===
zones=$(firewall-cmd --get-zones)

# === 分析规则 ===
has_custom_rules=0
IFS=' ' read -r -a default_services_arr <<< "$default_services"
for zone in $zones; do
    echo "${green}检查区域：$zone${reset}"

    # 检查是否为自定义区域
    if [[ ! " ${default_zones[@]} " =~ " $zone " ]]; then
        echo "${red}发现自定义区域：$zone${reset}"
        has_custom_rules=1
    fi

    # 获取该区域的服务
    services=$(firewall-cmd --zone=$zone --list-services --permanent)
    for service in $services; do
        if [[ ! " ${default_services_arr[@]} " =~ " $service " ]]; then
            echo "${red}发现自定义服务 '$service' 在区域：$zone${reset}"
            has_custom_rules=1
            echo "${green}区域 $zone 的服务列表: $services${reset}"
        fi
    done

    # 检查自定义端口或规则
    ports=$(firewall-cmd --zone=$zone --list-ports --permanent)
    rich_rules=$(firewall-cmd --zone=$zone --list-rich-rules --permanent)
    sources=$(firewall-cmd --zone=$zone --list-sources --permanent)
    if [[ -n "$ports" ]] || [[ -n "$rich_rules" ]] || [[ -n "$sources" ]]; then
        # 检查富规则是否为默认规则
        custom_rich_rules="$rich_rules"
        for rule in "${default_rich_rules[@]}"; do
            # 使用 grep -F 来进行字面匹配（不进行正则表达式匹配），并在未找到匹配时继续执行
            custom_rich_rules=$(echo "$custom_rich_rules" | grep -v -F "$rule" || true)
        done
        if [[ -n "$ports" ]] || [[ -n "$custom_rich_rules" ]] || [[ -n "$sources" ]]; then
            echo "${red}发现自定义规则在区域：$zone${reset}"
            has_custom_rules=1
            [[ -n "$ports" ]] && echo "${green}区域 $zone 的端口列表: $ports${reset}"
            [[ -n "$custom_rich_rules" ]] && echo "${green}区域 $zone 的富规则列表: $custom_rich_rules${reset}"
            [[ -n "$sources" ]] && echo "${green}区域 $zone 的来源列表: $sources${reset}"
        fi
    fi

done

# === 根据检查结果决定是否重装 firewalld ===
if [ $has_custom_rules -eq 1 ]; then
    echo "${red}检测到自定义永久规则，准备重置 firewalld规则...${reset}"
    sudo systemctl stop firewalld
    sudo rm -rf /etc/firewalld
    sudo systemctl start firewalld
    echo "${green}firewalld 已重置完成，规则恢复为默认状态。${reset}"
else
    echo "${green}未检测到自定义永久规则，无需重置 firewalld。${reset}"
fi

# 2. 创建和配置信任区域 (trusted_zone)
echo "${green}创建和配置信任区域 (trusted_zone)...${reset}"
if ! firewall-cmd --get-zones | grep -q "trusted_zone"; then
  firewall-cmd --permanent --new-zone=trusted_zone
fi
firewall-cmd --permanent --zone=trusted_zone --set-target=ACCEPT
for IP in "${ALLOWED_IPS[@]}"; do
  firewall-cmd --permanent --zone=trusted_zone --add-source=$IP
done
# 添加 1-65535 的端口到 trusted_zone
firewall-cmd --permanent --zone=trusted_zone --add-port=1-65535/tcp
firewall-cmd --permanent --zone=trusted_zone --add-port=1-65535/udp


# 1. 创建和配置公开区域 (public_zone)
if [ "$CREATE_PUBLIC_ZONE" == "y" ] || [ "$CREATE_PUBLIC_ZONE" == "Y" ]; then
    echo "${green}创建和配置公开区域 (public_zone)...${reset}"
    if ! firewall-cmd --get-zones | grep -q "public_zone"; then
        firewall-cmd --permanent --new-zone=public_zone
    fi
    firewall-cmd --permanent --zone=public_zone --set-target=ACCEPT
    for RULE in "${PUBLIC_RULES[@]}"; do
        if [[ $RULE == */tcp || $RULE == */udp ]]; then
            firewall-cmd --permanent --zone=public_zone --add-port=$RULE
        else
            firewall-cmd --permanent --zone=public_zone --add-service=$RULE
        fi
    done
    # 添加所有 IPv4 地址
    firewall-cmd --zone=public_zone --add-source=0.0.0.0/0 --permanent
    # 添加所有 IPv6 地址
    firewall-cmd --zone=public_zone --add-source=::/0 --permanent
else
    echo "${red}跳过创建公开端口，服务器将进入白名单模式！${reset}"
fi

# 3. 设置默认区域为 DROP
echo "${green}设置默认区域为 drop...${reset}"
firewall-cmd --set-default-zone=drop

# 5. 重载防火墙配置
echo "${green}重载防火墙配置...${reset}"
firewall-cmd --reload

# 6. 验证配置
if [ "$CREATE_PUBLIC_ZONE" == "y" ] || [ "$CREATE_PUBLIC_ZONE" == "Y" ]; then
    echo "${green}公开区域：${reset}"
    firewall-cmd --list-all --zone=public_zone
fi
echo "${green}信任区域：${reset}"
firewall-cmd --list-all --zone=trusted_zone
echo "${green}默认区域：${reset}"
firewall-cmd --get-default-zone
echo "${green}活动区域及其分配的网络接口：${reset}"
firewall-cmd --get-active-zones
echo "${green}防火墙规则配置完成。${reset}"
echo "${green}如果需要还原之前的备份，请使用以下命令：${reset}"
echo "  sudo cp -r $backup_dir/* /etc/firewalld/"
echo "  sudo firewall-cmd --reload"
echo "${green}这样可以将防火墙配置还原到之前的状态。${reset}"
