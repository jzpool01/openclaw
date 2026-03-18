#!/usr/bin/env bash
set -euo pipefail

# ======================== 核心配置（可根据实际环境调整） ========================
# 统一镜像名称（提前构建好的本地镜像）
UNIFIED_IMAGE="openclaw:unified"
# 数据根目录
DATA_BASE_DIR="$(pwd "${0}")/../data"
  
#DATA_BASE_DIR="/home/ecs-user/data"
# Gateway 基础端口（避免冲突：18789 + 用户名哈希值）
BASE_PORT=18789
# ==============================================================================

# 检查参数
if [[ $# -ne 3 ]]; then
  echo $DATA_BASE_DIR
  echo "用法: $0 <用户名> 例如: $0 user1 ding-clientId ding-clientSecret" >&2
  exit 1
fi
USER_NAME="$1"
CLIENTID="$2"
CLIENTSECRET="$3"

# 检查 OPENAI_API_KEY 环境变量是否存在
if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "错误：未检测到环境变量 OPENAI_API_KEY，请先设置该变量！"
    echo "设置示例：export OPENAI_API_KEY='你的api密钥'"
    exit 1
fi

# 检查 OPENAI_BASE_URL 环境变量是否存在
if [ -z "${OPENAI_BASE_URL:-}" ]; then
    echo "错误：未检测到环境变量 OPENAI_BASE_URL"
    echo "设置示例：export OPENAI_BASE_URL='https://dashscope.aliyuncs.com/compatible-mode/v1'"
    exit 1
fi
# 检查 OPENAI_BASE_URL 环境变量是否存在
if [ -z "${OPENAI_MODEL:-}" ]; then
    echo "错误：未检测到环境变量 OPENAI_MODEL"
    echo "设置示例：export OPENAI_MODEL='qwen-plus'"
    exit 1
fi

# 验证通过后的业务逻辑（示例）
echo "环境变量检查通过！"
echo "OPENAI_API_KEY: ${OPENAI_API_KEY:0:6}****"  # 仅展示前6位，保护密钥
echo "OPENAI_BASE_URL: $OPENAI_BASE_URL"
echo "OPENAI_MODEL: $OPENAI_MODEL"


# 1. 定义用户专属变量（核心隔离逻辑）
CONTAINER_PREFIX="openclaw-gateway-${USER_NAME}"
USER_DATA_DIR="${DATA_BASE_DIR}/${USER_NAME}/.openclaw"
USER_WORKSPACE_DIR="${USER_DATA_DIR}/workspace"
# 自动分配唯一端口（避免多用户端口冲突）
USER_PORT=$((BASE_PORT + $(echo -n "$USER_NAME" | od -An -tu1 | head -n1 | awk '{print $1}') % 100))

# 2. 导出环境变量（供 docker compose 使用）
export COMPOSE_PROJECT_NAME="${CONTAINER_PREFIX}"  # 关键：指定Compose项目名
export OPENCLAW_CONFIG_DIR="${USER_DATA_DIR}"
export OPENCLAW_WORKSPACE_DIR="${USER_WORKSPACE_DIR}"
export OPENCLAW_GATEWAY_PORT="${USER_PORT}"
export OPENCLAW_GATEWAY_BIND="lan"
export OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"  # 生成唯一Token
export OPENCLAW_IMAGE="${UNIFIED_IMAGE}"
export OPENCLAW_SANDBOX="0"
export OPENCLAW_DOCKER_SOCKET="/var/run/docker.sock"

# 3. 工具函数
fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "缺少依赖: $1，请先安装"
  fi
}

validate_path() {
  local label="$1"
  local path="$2"
  if [[ -z "$path" ]]; then
    fail "${label} 路径不能为空"
  fi
  if [[ "$path" =~ [[:space:]] || "$path" == *$'\n'* || "$path" == *$'\t'* ]]; then
    fail "${label} 路径包含非法字符（空格/换行/制表符）"
  fi
}

# 4. 前置检查
require_cmd docker
require_cmd openssl
if ! docker compose version >/dev/null 2>&1; then
  fail "Docker Compose 不可用（需 Docker 20.10+）"
fi

# 检查本地统一镜像是否存在
if ! docker images -q "${UNIFIED_IMAGE}" >/dev/null 2>&1; then
  fail "本地未找到统一镜像 ${UNIFIED_IMAGE}，请先执行：docker build -t ${UNIFIED_IMAGE} -f Dockerfile ."
fi

# 5. 验证并创建用户目录
validate_path "用户数据目录" "${USER_DATA_DIR}"
validate_path "用户工作目录" "${USER_WORKSPACE_DIR}"
mkdir -p "${USER_DATA_DIR}/identity"
mkdir -p "${USER_DATA_DIR}/agents/main/agent"
mkdir -p "${USER_DATA_DIR}/agents/main/sessions"
mkdir -p "${USER_WORKSPACE_DIR}"

# 6. 修复目录权限（关键：不依赖Compose服务，直接用docker run）
echo "==> 修复 ${USER_NAME} 数据目录权限..."
docker run --rm \
  --user root \
  -v "${USER_DATA_DIR}:/home/node/.openclaw" \
  -v "${USER_WORKSPACE_DIR}:/home/node/.openclaw/workspace" \
  "${UNIFIED_IMAGE}" \
  sh -c '
    # 仅修复挂载目录内的权限（避免跨目录）
    find /home/node/.openclaw -xdev -exec chown 1000:1000 {} +;
    # 修复workspace下的子目录
    [ -d /home/node/.openclaw/workspace/.openclaw ] && chown -R 1000:1000 /home/node/.openclaw/workspace/.openclaw || true
  '
TARGET_FILE="${USER_DATA_DIR}/openclaw.json"
if [ ! -f "${TARGET_FILE}" ]; then
    
    echo "==> 安装 ${USER_NAME} 钉钉插件..."
    docker run --rm \
    --user node \
    -v "${USER_DATA_DIR}:/home/node/.openclaw" \
    -v "${USER_WORKSPACE_DIR}:/home/node/.openclaw/workspace" \
    "${UNIFIED_IMAGE}" \
    sh -c '
        openclaw plugins install @dingtalk-real-ai/dingtalk-connector
    '
    echo "⚠️  未检测到文件: ${TARGET_FILE}，正在自动创建..."
    cat > ${TARGET_FILE} << EOF
{
    "models": {
        "providers": {
        "custom-1": {
            "baseUrl": "${OPENAI_BASE_URL}",
            "apiKey": "${OPENAI_API_KEY}",
            "auth": "token",
            "api": "openai-completions",
            "authHeader": false,
            "models": [
            {
                "id": "${OPENAI_MODEL}",
                "name": "${OPENAI_MODEL}",
                "api": "openai-completions",
                "reasoning": true,
                "input": [],
                "cost": {
                "input": 0,
                "output": 0,
                "cacheRead": 0,
                "cacheWrite": 0
                },
                "contextWindow": 200000,
                "maxTokens": 8192
            }
            ]
        }
        }
    },
    "agents": {
        "defaults": {
        "model": "custom-1/qwen3-max",
        "workspace": "/home/node/.openclaw/workspace",
        "compaction": {
            "mode": "safeguard"
        },
        "sandbox": {
            "mode": "off"
        }
        }
    },
    "channels": {
    "dingtalk-connector": {
      "clientId": "${CLIENTID}",
      "clientSecret": "${CLIENTSECRET}",
      "gatewayToken": "${OPENCLAW_GATEWAY_TOKEN}",
      "gatewayPassword": "",
      "sessionTimeout": 1800000
      }
    }
}
EOF
    docker run --rm \
    --user node \
    -v "${USER_DATA_DIR}:/home/node/.openclaw" \
    -v "${USER_WORKSPACE_DIR}:/home/node/.openclaw/workspace" \
    "${UNIFIED_IMAGE}" \
    sh -c '
        openclaw config set gateway.http.endpoints.chatCompletions.enabled true
    '
else
    echo "✅ 检测到文件已存在: ${TARGET_FILE}"
fi


# 7. 生成docker-compose.extra.yml（挂载配置，避免修改原文件）
COMPOSE_EXTRA_FILE="$(dirname "${0}")/docker-compose.extra.${USER_NAME}.yml"
cat > "${COMPOSE_EXTRA_FILE}" << EOF
services:
  openclaw-gateway:
    #env_file:
    #  - "$(pwd)/.env"  # 全局.env（兜底）
    environment:
      - OPENCLAW_GATEWAY_BIND=${OPENCLAW_GATEWAY_BIND}
      - OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}
      - OPENCLAW_CONFIG_DIR=/home/node/.openclaw
      - OPENCLAW_WORKSPACE_DIR=/home/node/.openclaw/workspace
    volumes:
      - "${USER_DATA_DIR}:/home/node/.openclaw"
      - "${USER_WORKSPACE_DIR}:/home/node/.openclaw/workspace"
      - "${OPENCLAW_DOCKER_SOCKET}:/var/run/docker.sock"
  openclaw-cli:
    environment:
      - OPENCLAW_CONFIG_DIR=/home/node/.openclaw
      - OPENCLAW_WORKSPACE_DIR=/home/node/.openclaw/workspace
    volumes:
      - "${USER_DATA_DIR}:/home/node/.openclaw"
      - "${USER_WORKSPACE_DIR}:/home/node/.openclaw/workspace"
      - "${OPENCLAW_DOCKER_SOCKET}:/var/run/docker.sock"
EOF

# 8. 启动Gateway（指定项目名+额外配置文件，避免找不到服务）
echo "==> 启动 ${USER_NAME} 的Gateway服务..."
docker compose \
  -p "${COMPOSE_PROJECT_NAME}" \
  -f "$(dirname "${0}")/docker-compose.yml" \
  -f "${COMPOSE_EXTRA_FILE}" \
  up -d openclaw-gateway


# 9. 配置Gateway（跳过CLI交互）
echo "==> 配置 ${USER_NAME} 的Gateway参数..."
docker compose \
  -p "${COMPOSE_PROJECT_NAME}" \
  -f "$(dirname "${0}")/docker-compose.yml" \
  -f "${COMPOSE_EXTRA_FILE}" \
  run --rm openclaw-cli config set gateway.mode local 
docker compose \
  -p "${COMPOSE_PROJECT_NAME}" \
  -f "$(dirname "${0}")/docker-compose.yml" \
  -f "${COMPOSE_EXTRA_FILE}" \
  run --rm openclaw-cli config set gateway.bind "${OPENCLAW_GATEWAY_BIND}" >/dev/null

# 10. 输出用户配置信息
echo -e "\n=================== ${USER_NAME} 配置完成 ==================="
echo "✅ 容器名: ${CONTAINER_PREFIX}-openclaw-gateway-1"
echo "✅ 数据目录: ${USER_DATA_DIR}"
echo "✅ Gateway端口: ${USER_PORT}"
echo "✅ Gateway Token: ${OPENCLAW_GATEWAY_TOKEN}"
echo "✅ 项目名: ${COMPOSE_PROJECT_NAME}"
echo -e "\n常用命令："
echo "  # 查看日志"
echo "  docker compose -p ${COMPOSE_PROJECT_NAME} -f $(dirname "${0}")/docker-compose.yml -f ${COMPOSE_EXTRA_FILE} logs -f openclaw-gateway"
echo "  # 配置渠道（如Telegram）"
echo "  docker compose -p ${COMPOSE_PROJECT_NAME} -f $(dirname "${0}")/docker-compose.yml -f ${COMPOSE_EXTRA_FILE} run --rm openclaw-cli channels add --channel telegram --token <你的BotToken>"
echo "  # 停止服务"
echo "  docker compose -p ${COMPOSE_PROJECT_NAME} -f $(dirname "${0}")/docker-compose.yml -f ${COMPOSE_EXTRA_FILE} stop openclaw-gateway"
echo "============================================================"
