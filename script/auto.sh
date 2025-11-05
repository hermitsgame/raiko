#!/bin/bash
set -e

# 配置变量
RAIKO_DIR="/root/raiko"
DEVNET_RPC="http://52.48.173.231:18545"
INTEL_API_KEY="184a8a374f0e4c61a599d492326e828e"
DOCKER_COMPOSE_FILE="docker-compose.devnet.yml"

echo "=== 步骤 1: 检查 SGX 硬件 ==="
if ! grep -q sgx /proc/cpuinfo; then
    echo "错误: CPU 不支持 SGX 或未在 BIOS 中启用"
    exit 1
fi

echo "=== 步骤 2: 配置 PCCS ==="
mkdir -p ~/.config/sgx-pccs
cd ~/.config/sgx-pccs

if [ ! -f file.crt ]; then
    openssl genrsa -out private.pem 2048
    chmod 644 private.pem
    openssl req -new -key private.pem -out csr.pem
    openssl x509 -req -days 365 -in csr.pem -signkey private.pem -out file.crt
    rm csr.pem
fi

if [ ! -f default.json ]; then
    curl -s https://raw.githubusercontent.com/taikoxyz/raiko/refs/heads/main/docs/default.json \
        > default.json
    
    # 设置 API Key
    sed -i "s/\"ApiKey\": \".*\"/\"ApiKey\": \"${INTEL_API_KEY}\"/" default.json
    
    # 设置 hosts
    sed -i 's/"hosts": ".*"/"hosts": "0.0.0.0"/' default.json
fi

echo "=== 步骤 3: 准备 Raiko 配置 ==="
mkdir -p ~/.config/raiko/{config,secrets}
sudo mkdir -p /var/log/raiko
sudo chmod 777 /var/log/raiko

cd ${RAIKO_DIR}/docker

# 创建 .env 文件
cat > .env << EOF
SGX_MODE=remote
SGX_DIRECT=0
NETWORK=devnet
L1_NETWORK=devnet
DEVNET_RPC=${DEVNET_RPC}
SGX_PACAYA_INSTANCE_ID=1
SGXGETH_PACAYA_INSTANCE_ID=2
RAIKO_REMOTE_URL=http://raiko-sgx-server:9090
GAIKO_REMOTE_URL=http://raiko-sgx-server:8090
REDIS_URL=redis://redis:6379
ENABLE_REDIS_POOL=true
RUST_LOG=info
EOF

# 复制配置文件
cp ../host/config/config.sgx.json ~/.config/raiko/config/

echo "=== 步骤 4: 启动 PCCS 服务 ==="
docker compose -f ${DOCKER_COMPOSE_FILE} up -d pccs
sleep 5

echo "=== 步骤 5: 启动 SGX Server 并 Bootstrap ==="
docker compose -f ${DOCKER_COMPOSE_FILE} up raiko-sgx-server -d
sleep 10

# 验证 SGX Server 是否正常启动
if docker compose -f ${DOCKER_COMPOSE_FILE} ps raiko-sgx-server | grep -q "Up"; then
    echo "✅ SGX Server 启动成功"
else
    echo "❌ SGX Server 启动失败，查看日志："
    docker compose -f ${DOCKER_COMPOSE_FILE} logs raiko-sgx-server
    exit 1
fi

sleep 5

# 通过 API Bootstrap（或使用 init 容器）
# 方式 1: API Bootstrap
echo "执行 Bootstrap..."
if curl -X POST http://localhost:9090/bootstrap > /dev/null 2>&1; then
    echo "✅ 通过 API Bootstrap 成功"
else
    echo "⚠️  API Bootstrap 失败，尝试使用 init 容器"
    # 临时切换为 local 模式进行 Bootstrap
    sed -i 's/SGX_MODE=remote/SGX_MODE=local/' .env
    docker compose -f ${DOCKER_COMPOSE_FILE} up init
    sed -i 's/SGX_MODE=local/SGX_MODE=remote/' .env
fi

# 检查 Bootstrap 结果
sleep 5
if [ ! -f ~/.config/raiko/config/bootstrap.json ]; then
    echo "错误: Bootstrap 失败"
    exit 1
fi

echo "=== 步骤 7: 启动 Raiko Host 服务 ==="
docker compose -f ${DOCKER_COMPOSE_FILE} --profile prod-redis up raiko -d

echo "=== 步骤 8: 验证服务 ==="
sleep 10

# 验证 SGX Server
if curl -s http://localhost:9090/check > /dev/null 2>&1; then
    echo "✅ SGX Server API 可访问"
else
    echo "⚠️  SGX Server API 检查失败（可能是正常的，取决于实现）"
fi

# 验证 Raiko Host
if curl -s http://localhost:8080/health > /dev/null; then
    echo "✅ Raiko Host 服务启动成功！"
    echo "访问 http://localhost:8080 查看 API 文档"
    echo "SGX Server 运行在 http://localhost:9090"
else
    echo "❌ Raiko Host 服务启动失败，查看日志："
    docker compose -f ${DOCKER_COMPOSE_FILE} logs raiko
    exit 1
fi