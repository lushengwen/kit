#!/bin/bash

set -e  # 如果遇到错误，立即退出

# === 配色 ===
green=$(tput setaf 2)
red=$(tput setaf 1)
reset=$(tput sgr0)

# 确保脚本以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "${red}此脚本需要 root 权限。请使用 sudo 运行。${reset}"
    exit 1
fi

# 检查是否已安装 BBR，如果没有则安装它
if ! sysctl net.ipv4.tcp_congestion_control | grep -q 'bbr'; then
  echo "${red}未安装 BBR。正在安装...${reset}"
  echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
  echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
  sysctl -p
  if lsmod | grep -q 'bbr'; then
    echo "${green}BBR 已成功安装。${reset}"
  else
    echo "${red}安装 BBR 失败。${reset}" >&2
    exit 1
  fi
else
  echo "${green}BBR 已经安装。${reset}"
fi

# 生成随机字符串的函数
generate_random_string() {
  length=$1
  char_set=$2
  < /dev/urandom tr -dc "$char_set" | head -c "$length"
}

# 生成随机的12个字符的密码 ( 允许特殊字符 )
NEW_PASSWORD=$(generate_random_string 12 'A-Za-z0-9!@#$%&*')

# 修改 root 密码
if echo "root:$NEW_PASSWORD" | chpasswd; then
  echo "${green}root 密码已更改。${reset}"
else
  echo "${red}更改 root 密码失败。${reset}" >&2
  exit 1
fi

# 生成随机的用户名（只允许小写字母和数字）
NEW_USER=$(generate_random_string 8 'a-z0-9')
USER_PASSWORD=$(generate_random_string 12 'A-Za-z0-9!@#$%&*')

# 创建用户和用户组
if id -u "$NEW_USER" >/dev/null 2>&1; then
  echo "${red}用户 $NEW_USER 已存在。由于冲突退出。${reset}"
  exit 1
else
  if groupadd "$NEW_USER" && useradd -m -g "$NEW_USER" -s /bin/bash "$NEW_USER"; then
    echo "${green}用户和用户组 $NEW_USER 已创建。${reset}"
  else
    echo "${red}创建用户或用户组 $NEW_USER 失败。${reset}" >&2
    exit 1
  fi
fi

# 设置用户密码
if echo "$NEW_USER:$USER_PASSWORD" | chpasswd; then
  echo "${green}用户 $NEW_USER 的密码已设置。${reset}"
else
  echo "${red}设置用户 $NEW_USER 的密码失败。${reset}" >&2
  exit 1
fi

# 生成随机密码短语
KEY_PASS_PHRASE=$(generate_random_string 16 'A-Za-z0-9!@#$%&*')

# 为新用户生成 SSH 密钥（私钥保存在当前用户目录中，公钥保存在 ~/.ssh/authorized_keys）
su - $NEW_USER -c "ssh-keygen -t rsa -b 8192 -f /home/$NEW_USER/RSA_8192 -N \"$KEY_PASS_PHRASE\""

# 确保 .ssh 目录存在并设置权限
SSH_DIR="/home/$NEW_USER/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown -R "$NEW_USER:$NEW_USER" "$SSH_DIR"

# 将生成的公钥添加到 authorized_keys 文件中并设置权限
AUTHORIZED_KEYS="$SSH_DIR/authorized_keys"
cat /home/$NEW_USER/RSA_8192.pub >> "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"
chown "$NEW_USER:$NEW_USER" "$AUTHORIZED_KEYS"

# 修改 sshd_config 文件
SSHD_CONFIG="/etc/ssh/sshd_config"

# 检查默认的 SSH 端口号
DEFAULT_PORT=$(grep -E "^Port " "$SSHD_CONFIG" | awk '{print $2}')
if [ -z "$DEFAULT_PORT" ]; then
  DEFAULT_PORT=22
fi

# 检查是否安装了 firewall-cmd，如果没有则安装它
if ! command -v firewall-cmd &> /dev/null; then
  echo "${red}未安装 firewall-cmd。正在安装...${reset}"
  if ! yum install -y firewalld; then
    echo "${red}安装 firewalld 失败。${reset}" >&2
    exit 1
  fi
  systemctl start firewalld
  systemctl enable firewalld
fi

# 生成随机的新端口号（10000-65535 之间）
NEW_PORT=$(shuf -i 10000-65535 -n 1)

# 在防火墙中添加新端口
if ! firewall-cmd --add-port=${NEW_PORT}/tcp --permanent; then
  echo "${red}将新 SSH 端口 $NEW_PORT 添加到防火墙失败。${reset}" >&2
  exit 1
fi

if ! firewall-cmd --reload; then
  echo "${red}重新加载防火墙失败。${reset}" >&2
  exit 1
fi

# 如果启用了 SELinux，则为新的 SSH 端口添加 SELinux 端口规则
if command -v getenforce &>/dev/null; then
  SELINUX_MODE=$(getenforce)
  if [ "$SELINUX_MODE" != "Disabled" ]; then
    # 确保 semanage 可用
    if ! command -v semanage &>/dev/null; then
      echo "${red}未找到 semanage，正在安装 SELinux 管理工具...${reset}"
      yum install -y policycoreutils-python-utils 2>/dev/null || \
      yum install -y policycoreutils-python 2>/dev/null || true
    fi

    if command -v semanage &>/dev/null; then
      echo "${green}为 SELinux 放行 SSH 端口 $NEW_PORT...${reset}"
      semanage port -a -t ssh_port_t -p tcp "$NEW_PORT" 2>/dev/null || \
      semanage port -m -t ssh_port_t -p tcp "$NEW_PORT"
    else
      echo "${red}警告: 未能安装 semanage，SELinux 可能会阻止 SSH 使用端口 $NEW_PORT。${reset}"
    fi
  fi
fi

update_sshd_config() {
    local key=$1
    local value=$2
    if grep -q "^$key " "$SSHD_CONFIG"; then
        sed -i "s/^$key .*/$key $value/" "$SSHD_CONFIG"
    else
        # 确保新配置不被添加到注释行后面
        if ! grep -q "^# $key" "$SSHD_CONFIG"; then
            echo "$key $value" >> "$SSHD_CONFIG"
        fi
    fi
}

update_sshd_config "Port" "$NEW_PORT"
update_sshd_config "PermitRootLogin" "no"
update_sshd_config "PasswordAuthentication" "no"
update_sshd_config "ChallengeResponseAuthentication" "no"

# 显示所有密码信息给用户
echo "${green}新 root 密码: $NEW_PASSWORD${reset}"
echo "${green}用户名: $NEW_USER${reset}"
echo "${green}密码: $USER_PASSWORD${reset}"
echo "${green}SSH 密钥密码短语: $KEY_PASS_PHRASE${reset}"
echo "${green}新 SSH 端口: $NEW_PORT${reset}"
echo "${red}请下载您的密钥并在重新启动 ssh 服务之前删除目录中的公钥${reset}"

# 询问用户是否重启 sshd 服务
read -p "是否要重启 SSHD 服务？ (y/n) [默认 y]: " RESTART_SSHD
RESTART_SSHD=${RESTART_SSHD:-y}  # 如果没有输入，默认为 "y"
# 1. 创建和配置公开区域 (public_zone)
if [ "$RESTART_SSHD" == "y" ] || [ "$RESTART_SSHD" == "Y" ]; then
  if systemctl restart sshd; then
    echo "${green}SSHD 服务已重启。${reset}"
  else
    echo "${red}已取消重启 SSHD 服务。${reset}" >&2
    exit 1
  fi
else
  echo "${green}SSHD 服务未重启。更改将在服务重启后生效。${reset}"
fi
