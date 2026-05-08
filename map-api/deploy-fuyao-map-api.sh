#!/bin/bash
set -Eeuo pipefail

ACR="crpi-sw0t0esja4aokp42.cn-guangzhou.personal.cr.aliyuncs.com"
IMG="${ACR}/fuyaox/fuyao-web-api:${BUILD_NUMBER}"

TILES_SHARED_DIR="/www/docker/fuyaomap/tiles"
MAP_RESOURCES_SHARED_DIR="/www/docker/fuyaomap/map-resources"
IMPORTS_DIR="/data/fuyaomap/imports"

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
  echo "请先把 map-resources 初始化到宿主机共享目录。"
  exit 1
fi

echo "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin "${ACR}"

docker pull "${IMG}"
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

sleep 6

curl -fsS http://127.0.0.1:7165/health >/dev/null \
  && echo "✅ API 健康检查通过" \
  || {
    echo "❌ API 健康检查失败，最近日志："
    docker logs fuyao-map-api --tail 120
    exit 1
  }

echo "==> API 容器环境变量检查"
docker exec fuyao-map-api sh -lc 'printenv | grep FUYAO_MAP || true'

docker image prune -f --filter "until=24h"