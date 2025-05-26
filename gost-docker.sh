#!/bin/bash
set -e

# 功能状态检查
function check_success() {
    if [ $? -ne 0 ]; then
        echo "上一步执行失败，脚本终止"
        exit 1
    fi
}

### 第一部分：安装 Docker CE ###
echo "正在尝试安装Docker CE"

. /etc/os-release
if [[ "$ID" == "ubuntu" ]]; then
    for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do sudo apt-get remove -y $pkg; done
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
    ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

elif [[ "$ID" == "debian" ]]; then
    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do sudo apt-get remove -y $pkg; done
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
    $VERSION_CODENAME stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
    echo "请查阅官网指南手动安装Docker CE: https://docs.docker.com/engine/install/"
    exit 1
fi
check_success

### 第二部分：开启 TCP BBR ###
echo "正在开启TCP BBR"
sudo modprobe tcp_bbr

echo "tcp_bbr" | sudo tee --append /etc/modules-load.d/modules.conf

echo "net.core.default_qdisc=fq" | sudo tee --append /etc/sysctl.conf

echo "net.ipv4.tcp_congestion_control=bbr" | sudo tee --append /etc/sysctl.conf

sudo sysctl -p
sysctl net.ipv4.tcp_available_congestion_control
sysctl net.ipv4.tcp_congestion_control
lsmod | grep bbr
check_success

### 第三部分：Certbot申请证书 ###
echo "尝试申请证书"
sudo snap install --classic certbot
sudo ln -s /snap/bin/certbot /usr/bin/certbot
sudo certbot certonly --standalone
check_success

### 第四部分：Docker部署Cloudflare Warp ###
echo "正在安装Cloudflare Warp"
mkdir -p /root/docker
cd /root/docker

cat <<EOF > docker-compose.yml
version: "3"

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

docker compose up -d
check_success

WARP_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' warp)
echo "WARP_IP: $WARP_IP"

### 第五部分：部署Gost代理 ###
echo "开始部署Gost代理"

while true; do
    read -p "请输入绑定的域名：" DOMAIN
    if [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        break
    else
        echo "请输入有效的域名："
    fi
done

while true; do
    read -p "请输入用户名：" USER
    if [[ -n "$USER" ]]; then
        break
    else
        echo "请输入有效的用户名："
    fi
done

while true; do
    read -p "请输入密码（八位及以上）：" PASS
    if [ ${#PASS} -ge 8 ]; then
        break
    else
        echo "请输入至少八位的密码："
    fi
done

while true; do
    read -p "请输入要配置的端口号（1~65536）：" PORT1
    if [[ "$PORT1" =~ ^[0-9]+$ && "$PORT1" -ge 1 && "$PORT1" -le 65536 ]]; then
        break
    else
        echo "请输入有效的端口号："
    fi
done

BIND_IP=0.0.0.0
CERT_DIR=/etc/letsencrypt
CERT=${CERT_DIR}/live/${DOMAIN}/fullchain.pem
KEY=${CERT_DIR}/live/${DOMAIN}/privkey.pem

sudo docker run -d --name gost \
    -v ${CERT_DIR}:${CERT_DIR}:ro \
    --net=host gogost/gost \
    -L "http2://${USER}:${PASS}@${BIND_IP}:${PORT1}?certFile=${CERT}&keyFile=${KEY}&probeResistance=code:404&knock=www.google.com"
check_success

read -p "是否要部署Gost-Warp代理（y/n）？" deploy_warp
if [[ "$deploy_warp" == "y" ]]; then
    while true; do
        read -p "请指定Gost-Warp代理的端口号（1~65536）：" PORT2
        if [[ "$PORT2" =~ ^[0-9]+$ && "$PORT2" -ge 1 && "$PORT2" -le 65536 && "$PORT2" -ne "$PORT1" ]]; then
            break
        else
            echo "请输入有效的端口号："
        fi
    done

    sudo docker run -d --name gost-warp \
        -v ${CERT_DIR}:${CERT_DIR}:ro \
        --net=host gogost/gost \
        -L "http2://${USER}:${PASS}@${BIND_IP}:${PORT2}?certFile=${CERT}&keyFile=${KEY}&probeResistance=code:404&knock=www.google.com" \
        -F "socks5://${WARP_IP}:1080"
    check_success

    echo "已经成功部署Gost和Gost-Warp代理！"
    echo "--Gost代理：域名：${DOMAIN}; 用户名：${USER}；密码：${PASS}；端口：${PORT1}"
    echo "--Gost-Warp代理：域名：${DOMAIN}; 用户名：${USER}；密码：${PASS}；端口：${PORT2}"
fi

### 第六部分：设置证书自动更新 ###
echo "正在设置证书自动更新"
(crontab -l 2>/dev/null; echo "0 0 1 * * /usr/bin/certbot renew --force-renewal") | crontab -
(crontab -l 2>/dev/null; echo "5 0 1 * * /usr/bin/docker restart gost") | crontab -
(crontab -l 2>/dev/null; echo "5 0 1 * * /usr/bin/docker restart gost-warp") | crontab -
echo "证书自动更新任务已设置完毕"

exit 0
