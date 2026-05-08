#!/bin/bash
set -Eeuo pipefail

ACR="crpi-sw0t0esja4aokp42.cn-guangzhou.personal.cr.aliyuncs.com"
IMG="${ACR}/fuyaox/fuyao-map-web:${BUILD_NUMBER}"

TILES_SHARED_DIR="/www/docker/fuyaomap/tiles"
MAP_RESOURCES_SHARED_DIR="/www/docker/fuyaomap/map-resources"
RUNTIME_DIR="/www/docker/fuyaomapweb/runtime"

echo "==> 部署地图 Web"
echo "镜像: ${IMG}"

if [ -z "${DOCKER_USERNAME:-}" ] || [ -z "${DOCKER_PASSWORD:-}" ]; then
  echo "缺少 DOCKER_USERNAME / DOCKER_PASSWORD"
  exit 1
fi

mkdir -p "${TILES_SHARED_DIR}"
mkdir -p "${MAP_RESOURCES_SHARED_DIR}"
mkdir -p "${RUNTIME_DIR}"

if [ ! -f "${TILES_SHARED_DIR}/city.pmtiles" ]; then
  echo "缺少默认底图文件: ${TILES_SHARED_DIR}/city.pmtiles"
  exit 1
fi

if [ ! -f "${MAP_RESOURCES_SHARED_DIR}/styles/amap-like.json" ]; then
  echo "缺少默认样式文件: ${MAP_RESOURCES_SHARED_DIR}/styles/amap-like.json"
  echo "请先把 map-resources 初始化到宿主机共享目录，否则挂载后页面会空白。"
  exit 1
fi

if [ ! -f "${MAP_RESOURCES_SHARED_DIR}/manifest.json" ]; then
  echo "缺少 manifest 文件: ${MAP_RESOURCES_SHARED_DIR}/manifest.json"
  exit 1
fi

echo "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin "${ACR}"

docker pull "${IMG}"
docker rm -f fuyao-map-web >/dev/null 2>&1 || true

docker run -d \
  --name fuyao-map-web \
  --restart unless-stopped \
  -p 8002:8002 \
  -v "${TILES_SHARED_DIR}:/data/tiles" \
  -v "${MAP_RESOURCES_SHARED_DIR}:/usr/share/nginx/html/map-resources" \
  -v "${RUNTIME_DIR}:/usr/share/nginx/html/runtime" \
  "${IMG}"

sleep 6

curl -fsS http://127.0.0.1:8002 >/dev/null \
  && echo "✅ Web 健康检查通过" \
  || {
    echo "❌ Web 健康检查失败，最近日志："
    docker logs fuyao-map-web --tail 120
    exit 1
  }

echo "==> Web 静态资源检查"
curl -I http://127.0.0.1:8002/tiles/city.pmtiles || true
curl -I http://127.0.0.1:8002/map-resources/styles/amap-like.json || true
curl -I http://127.0.0.1:8002/map-resources/manifest.json || true

docker image prune -f --filter "until=24h"