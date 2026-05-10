#!/bin/bash
set -Eeuo pipefail

ACR="crpi-sw0t0esja4aokp42.cn-guangzhou.personal.cr.aliyuncs.com"
IMG="${ACR}/fuyaox/fuyao-web-api:${BUILD_NUMBER}"

TILES_SHARED_DIR="/www/docker/fuyaomap/tiles"
MAP_RESOURCES_SHARED_DIR="/www/docker/fuyaomap/map-resources"
IMPORTS_DIR="/data/fuyaomap/imports"

retry() {
  local max_attempts="${RETRY_MAX_ATTEMPTS:-3}"
  local delay_seconds="${RETRY_DELAY_SECONDS:-5}"
  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi
    local exit_code=$?
    if [ "${attempt}" -ge "${max_attempts}" ]; then
      echo "命令执行失败，已达到最大重试次数: $*"
      return "${exit_code}"
    fi
    echo "命令执行失败，${delay_seconds}s 后重试 (${attempt}/${max_attempts}): $*"
    sleep "${delay_seconds}"
    attempt=$((attempt + 1))
  done
}

docker_login() {
  echo "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin "${ACR}"
}

wait_for_http() {
  local url="$1"
  local max_checks="${2:-20}"
  local delay_seconds="${3:-3}"

  for i in $(seq 1 "${max_checks}"); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      echo "健康检查通过: ${url}"
      return 0
    fi
    echo "等待服务启动 (${i}/${max_checks}): ${url}"
    sleep "${delay_seconds}"
  done

  return 1
}

echo "==> 部署地图 API"
echo "镜像: ${IMG}"

if [ -z "${DOCKER_USERNAME:-}" ] || [ -z "${DOCKER_PASSWORD:-}" ]; then
  echo "缺少 DOCKER_USERNAME / DOCKER_PASSWORD"
  exit 1
fi

if [ -z "${CONN_POSTGRES:-}" ]; then
  echo "缺少 CONN_POSTGRES"
  exit 1
fi

mkdir -p "${TILES_SHARED_DIR}"
mkdir -p "${MAP_RESOURCES_SHARED_DIR}"
mkdir -p "${IMPORTS_DIR}"

if [ ! -f "${TILES_SHARED_DIR}/city.pmtiles" ]; then
  echo "缺少默认底图文件: ${TILES_SHARED_DIR}/city.pmtiles"
  exit 1
fi

if [ ! -f "${MAP_RESOURCES_SHARED_DIR}/styles/amap-like.json" ]; then
  echo "缺少默认样式文件: ${MAP_RESOURCES_SHARED_DIR}/styles/amap-like.json"
  echo "请先成功部署 Web，确保 map-resources 已初始化到共享目录。"
  exit 1
fi

retry docker_login
retry docker pull "${IMG}"

docker rm -f fuyao-map-api >/dev/null 2>&1 || true

docker run -d \
  --name fuyao-map-api \
  --restart unless-stopped \
  -p 7165:7165 \
  -e ASPNETCORE_ENVIRONMENT=Production \
  -e ConnectionStrings__Postgres="${CONN_POSTGRES}" \
  -e FUYAO_MAP_RUNTIME_PROBE_BASE_URLS="http://fuyao-map-web:8002;http://159.75.54.99:8002" \
  -e FUYAO_MAP_SHARED_TILES_ROOT="/shared/tiles" \
  -e FUYAO_MAP_SHARED_MAP_RESOURCES_ROOT="/shared/map-resources" \
  -v "${IMPORTS_DIR}:${IMPORTS_DIR}" \
  -v "${TILES_SHARED_DIR}:/shared/tiles" \
  -v "${MAP_RESOURCES_SHARED_DIR}:/shared/map-resources" \
  "${IMG}"

if wait_for_http "http://127.0.0.1:7165/health" 30 3; then
  echo "✅ API 健康检查通过"
else
  echo "❌ API 健康检查失败，最近日志："
  docker logs fuyao-map-api --tail 150
  exit 1
fi

echo "==> API 环境变量检查"
docker exec fuyao-map-api sh -lc 'printenv | grep FUYAO_MAP || true'

docker image prune -f --filter "until=24h" || true