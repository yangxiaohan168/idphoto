#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

usage() {
  echo "用法: $0           # 部署"
  echo "       $0 --down   # 停止并移除容器"
  exit 0
}

DOWN=0
[[ "${1:-}" == "--down" ]] && DOWN=1
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

if ! docker version >/dev/null 2>&1; then
  echo "错误: 未检测到可用的 Docker，请先安装并启动 Docker。" >&2
  exit 1
fi

CONFIG="$ROOT/config.yml"
EXAMPLE="$ROOT/config.example.yml"

if [[ ! -f "$CONFIG" ]]; then
  if [[ ! -f "$EXAMPLE" ]]; then
    echo "错误: 缺少 config.example.yml" >&2
    exit 1
  fi
  cp "$EXAMPLE" "$CONFIG"
  echo "已创建 config.yml，请编辑后重新运行本脚本。"
  exit 0
fi

# 读取简单 key: value YAML（扁平 key: value，与 config.example.yml 约定一致）
get_yaml() {
  local key="$1"
  grep -E "^[[:space:]]*${key}:" "$CONFIG" | head -1 | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//" | sed -E 's/^["'\'']|["'\'']$//g' | sed -E 's/[[:space:]]*#.*$//'
}

domain="$(get_yaml domain)"
acme_email="$(get_yaml acme_email)"
image="$(get_yaml image)"
tag="$(get_yaml tag)"
enable_ssl="$(get_yaml enable_ssl)"
http_port="$(get_yaml http_port)"
http_port="${http_port:-7860}"

if [[ -z "$image" || -z "$tag" ]]; then
  echo "错误: config.yml 中 image / tag 不能为空" >&2
  exit 1
fi

cat > "$ROOT/.env" <<EOF
IMAGE=$image
TAG=$tag
DOMAIN=$domain
ACME_EMAIL=$acme_email
HTTP_PORT=$http_port
EOF

COMPOSE_BASE=( -f compose.yaml )

if [[ "$DOWN" -eq 1 ]]; then
  if [[ "$enable_ssl" == "true" ]]; then
    docker compose "${COMPOSE_BASE[@]}" -f compose.ssl.yaml down
  else
    docker compose "${COMPOSE_BASE[@]}" -f compose.local.yaml down
  fi
  echo "已执行 docker compose down。"
  exit 0
fi

if [[ "$enable_ssl" == "true" ]]; then
  if [[ -z "$domain" || "$domain" == "idphoto.example.com" ]]; then
    echo "错误: 开启 SSL 时请将 domain 改为真实域名（DNS A 记录指向本机）" >&2
    exit 1
  fi
  if [[ -z "$acme_email" || "$acme_email" == "you@example.com" ]]; then
    echo "错误: 开启 SSL 时请将 acme_email 改为真实邮箱" >&2
    exit 1
  fi
  echo "模式: HTTPS (Caddy + Let's Encrypt)，域名: $domain"
  docker compose "${COMPOSE_BASE[@]}" -f compose.ssl.yaml pull
  docker compose "${COMPOSE_BASE[@]}" -f compose.ssl.yaml up -d
  echo "部署完成。请访问: https://$domain/"
else
  echo "模式: 仅 HTTP，端口: $http_port -> 容器 7860"
  docker compose "${COMPOSE_BASE[@]}" -f compose.local.yaml pull
  docker compose "${COMPOSE_BASE[@]}" -f compose.local.yaml up -d
  echo "部署完成。请访问: http://<本机IP>:$http_port/"
fi
