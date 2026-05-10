#!/bin/bash
set -Eeuo pipefail

ACR="crpi-sw0t0esja4aokp42.cn-guangzhou.personal.cr.aliyuncs.com"
IMG="${ACR}/fuyaox/fuyao-map-web:${BUILD_NUMBER}"

TILES_SHARED_DIR="/www/docker/fuyaomap/tiles"
MAP_RESOURCES_SHARED_DIR="/www/docker/fuyaomap/map-resources"
RUNTIME_DIR="/www/docker/fuyaomapweb/runtime"

retry() {
  local attempt=1
  local max_attempts=3
  local delay_seconds=5
  while true; do
    if "$@"; then
      return 0
    fi
    local exit_code=$?
    if [ "${attempt}" -ge "${max_attempts}" ]; then
      echo "命令失败: $*"
      return "${exit_code}"
    fi
    echo "命令失败，${delay_seconds}s 后重试 (${attempt}/${max_attempts})"
    sleep "${delay_seconds}"
    attempt=$((attempt + 1))
  done
}

wait_for_http() {
  local url="$1"
  local max_checks=30
  local delay_seconds=3
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

bootstrap_map_resources_if_needed() {
  if [ -f "${MAP_RESOURCES_SHARED_DIR}/styles/amap-like.json" ] && [ -f "${MAP_RESOURCES_SHARED_DIR}/manifest.json" ]; then
    echo "map-resources 已存在，跳过初始化"
    return 0
  fi

  echo "初始化共享 map-resources"
  local tmp_container="fuyao-map-web-bootstrap-$$"
  docker rm -f "${tmp_container}" >/dev/null 2>&1 || true
  docker create --name "${tmp_container}" "${IMG}" >/dev/null
  mkdir -p "${MAP_RESOURCES_SHARED_DIR}"
  docker cp "${tmp_container}:/usr/share/nginx/html/map-resources/." "${MAP_RESOURCES_SHARED_DIR}/"
  docker rm -f "${tmp_container}" >/dev/null 2>&1 || true
}

echo "==> 部署地图 Web"
echo "镜像: ${IMG}"

mkdir -p "${TILES_SHARED_DIR}" "${MAP_RESOURCES_SHARED_DIR}" "${RUNTIME_DIR}"

if [ ! -f "${TILES_SHARED_DIR}/city.pmtiles" ]; then
  echo "缺少默认底图文件: ${TILES_SHARED_DIR}/city.pmtiles"
  exit 1
fi

echo "${DOCKER_PASSWORD}" | docker login -u "${DOCKER_USERNAME}" --password-stdin "${ACR}"
retry docker pull "${IMG}"

bootstrap_map_resources_if_needed

if [ ! -f "${MAP_RESOURCES_SHARED_DIR}/styles/amap-like.json" ]; then
  echo "缺少默认样式文件: ${MAP_RESOURCES_SHARED_DIR}/styles/amap-like.json"
  exit 1
fi

if [ ! -f "${MAP_RESOURCES_SHARED_DIR}/manifest.json" ]; then
  echo "缺少 manifest 文件: ${MAP_RESOURCES_SHARED_DIR}/manifest.json"
  exit 1
fi

docker rm -f fuyao-map-web >/dev/null 2>&1 || true

docker run -d \
  --name fuyao-map-web \
  --restart unless-stopped \
  -p 8002:8002 \
  -v "${TILES_SHARED_DIR}:/data/tiles" \
  -v "${MAP_RESOURCES_SHARED_DIR}:/usr/share/nginx/html/map-resources" \
  -v "${RUNTIME_DIR}:/usr/share/nginx/html/runtime" \
  "${IMG}"

if wait_for_http "http://127.0.0.1:8002"; then
  echo "✅ Web 健康检查通过"
else
  echo "❌ Web 健康检查失败"
  docker logs fuyao-map-web --tail 150
  exit 1
fi

curl -I http://127.0.0.1:8002/tiles/city.pmtiles || true
curl -I http://127.0.0.1:8002/map-resources/styles/amap-like.json || true
curl -I http://127.0.0.1:8002/map-resources/manifest.json || true

docker image prune -f --filter "until=24h" || true