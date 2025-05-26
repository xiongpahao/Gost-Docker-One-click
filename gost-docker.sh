#!/bin/bash

set -e

# 颜色和样式定义
GREEN='\033[1;92m'
BOLD='\033[1m'
RESET='\033[0m'

function echo_info() {
    echo -e "${GREEN}${BOLD}$1${RESET}"
}

function step_failed() {
    echo -e "\033[1;91m步骤失败，脚本终止。\033[0m"
    exit 1
}

function check_success() {
    if [ $? -ne 0 ]; then
        step_failed
    fi
}

# 第零部分：是否安装 Docker CE
read -rp "是否需要先安装Docker CE（y/n）？" install_docker

if [[ "$install_docker" == "y" || "$install_docker" == "Y" ]]; then
    echo_info "正在尝试安装Docker CE"
    . /etc/os-release
    if [[ "$ID" == "ubuntu" ]]; then
        echo_info "检测到系统为Ubuntu $VERSION_ID，将自动安装Docker CE"
        for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do sudo apt-get remove -y $pkg; done
        sudo apt-get update
        sudo apt-get install -y ca-certificates curl
        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc
        echo \  
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \ 
          $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
          sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        check_success
    elif [[ "$ID" == "debian" ]]; then
        echo_info "检测到系统为Debian $VERSION_ID，将自动安装Docker CE"
        for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do sudo apt-get remove -y $pkg; done
        sudo apt-get update
        sudo apt-get install -y ca-certificates curl
        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc
        echo \  
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \ 
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        check_success
    else
        echo_info "当前系统为：$PRETTY_NAME，请查阅官网指南手动安装Docker CE: https://docs.docker.com/engine/install/"
    fi
fi

# 第二部分：开启 TCP BBR

echo_info "正在开启TCP BBR"
sudo modprobe tcp_bbr

echo "tcp_bbr" | sudo tee --append /etc/modules-load.d/modules.conf

echo "net.core.default_qdisc=fq" | sudo tee --append /etc/sysctl.conf

echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee --append /etc/sysctl.conf

sudo sysctl -p

sysctl net.ipv4.tcp_available_congestion_control
sysctl net.ipv4.tcp_congestion_control

if lsmod | grep -q bbr; then
    echo_info "开启TCP BBR成功！"
else
    step_failed
fi

# 第三部分：Certbot 申请证书

echo_info "尝试申请证书"
sudo snap install --classic certbot
sudo ln -sf /snap/bin/certbot /usr/bin/certbot
sudo certbot certonly --standalone || step_failed

# 第四部分：部署 Cloudflare Warp

echo_info "正在安装Cloudflare Warp"
mkdir -p /usr/local/docker
cd /usr/local/docker || step_failed

cat <<EOF | sudo tee docker-compose.yml
services:
  warp:
    image: caomingjun/warp
    container_name: warp
    restart: always
    device_cgroup_rules:
      - 'c 10:200 rwm'
    ports:
      - "1080:1080"
    environment:
      - WARP_SLEEP=2
    cap_add:
      - MKNOD
      - AUDIT_WRITE
      - NET_ADMIN
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv4.conf.all.src_valid_mark=1
    volumes:
      - ./data:/var/lib/cloudflare-warp
EOF

sudo docker compose up -d
check_success

WARP_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' warp)
echo_info "WARP 容器 IP 地址为: $WARP_IP"

# 第五部分：部署 Gost 代理

echo_info "开始部署Gost代理"

# 获取域名
while true; do
    read -rp "请输入绑定的域名：" DOMAIN
    if [[ $DOMAIN =~ ^[a-zA-Z0-9.-]+$ ]]; then
        break
    else
        echo_info "请输入有效的域名："
    fi
done

# 获取用户名
while true; do
    read -rp "请输入用户名：" USER
    if [[ -n "$USER" ]]; then
        break
    else
        echo_info "请输入有效的用户名："
    fi
done

# 获取密码
while true; do
    read -rp "请输入密码（八位及以上）：" PASS
    if [[ ${#PASS} -ge 8 ]]; then
        break
    else
        echo_info "请输入至少八位的密码："
    fi
done

# 获取端口 PORT1
while true; do
    read -rp "请输入要配置的端口号（1~65536）：" PORT1
    if [[ $PORT1 -ge 1 && $PORT1 -le 65536 ]]; then
        break
    else
        echo_info "请输入有效的端口号："
    fi
done

CERT_DIR=/etc/letsencrypt
CERT=${CERT_DIR}/live/${DOMAIN}/fullchain.pem
KEY=${CERT_DIR}/live/${DOMAIN}/privkey.pem

sudo docker run -d --name gost \
    --restart always \
    -v ${CERT_DIR}:${CERT_DIR}:ro \
    --net=host gogost/gost \
    -L "http2://${USER}:${PASS}@0.0.0.0:${PORT1}?certFile=${CERT}&keyFile=${KEY}&probeResistance=code:404&knock=www.google.com"

# 获取端口 PORT2

echo_info "开始部署Gost-Warp代理"

while true; do
    read -rp "请指定Gost-Warp代理的端口号（1~65536）：" PORT2
    if [[ $PORT2 -ge 1 && $PORT2 -le 65536 && $PORT2 -ne $PORT1 ]]; then
        break
    else
        echo_info "请输入有效的端口号："
    fi
done

sudo docker run -d --name gost-warp \
    --restart always \
    -v ${CERT_DIR}:${CERT_DIR}:ro \
    --net=host gogost/gost \
    -L "http2://${USER}:${PASS}@0.0.0.0:${PORT2}?certFile=${CERT}&keyFile=${KEY}&probeResistance=code:404&knock=www.google.com" \
    -F "socks5://${WARP_IP}:1080"

check_success

echo_info "已经成功部署Gost和Gost-Warp代理！"
echo "--Gost代理：域名：$DOMAIN; 用户名：$USER；密码：$PASS；端口：$PORT1"
echo "--Gost-Warp代理：域名：$DOMAIN; 用户名：$USER；密码：$PASS；端口：$PORT2"

# 第六部分：设置证书自动更新

echo_info "正在设置证书自动更新"
(crontab -l 2>/dev/null; echo "0 0 1 * * /usr/bin/certbot renew --force-renewal") | crontab -
(crontab -l 2>/dev/null; echo "5 0 1 * * /usr/bin/docker restart gost") | crontab -
(crontab -l 2>/dev/null; echo "5 0 1 * * /usr/bin/docker restart gost-warp") | crontab -

echo_info "大功告成！"
