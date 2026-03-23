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
  # grep 无匹配时退出码为 1；在 set -o pipefail 下会导致整条管道失败并静默退出，故对 grep 使用 || true
  { grep -E "^[[:space:]]*${key}:" "$CONFIG" || true; } | head -1 | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//" | sed -E 's/^["'\'']|["'\'']$//g' | sed -E 's/[[:space:]]*#.*$//'
}

domain="$(get_yaml domain)"
acme_email="$(get_yaml acme_email)"
image="$(get_yaml image)"
tag="$(get_yaml tag)"
enable_ssl="$(get_yaml enable_ssl)"
http_port="$(get_yaml http_port)"
http_port="${http_port:-7860}"
caddy_http_port="$(get_yaml caddy_http_port)"
caddy_https_port="$(get_yaml caddy_https_port)"
caddy_http_port="${caddy_http_port:-80}"
caddy_https_port="${caddy_https_port:-443}"

bind_host="$(get_yaml bind_host)"
bind_host="${bind_host// /}"
# 已有 Nginx/Traefik/Caddy 等占用 80/443 并负责 Let's Encrypt 时：enable_ssl 设 false，由反代把域名转到本机 http_port
if [[ -n "$bind_host" ]]; then
  port_mapping="${bind_host}:${http_port}:7860"
else
  port_mapping="${http_port}:7860"
fi

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
CADDY_HTTP_PORT=$caddy_http_port
CADDY_HTTPS_PORT=$caddy_https_port
PORT_MAPPING=$port_mapping
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
  echo "      宿主机端口: HTTP ${caddy_http_port}->80, HTTPS ${caddy_https_port}->443"
  docker compose "${COMPOSE_BASE[@]}" -f compose.ssl.yaml pull
  docker compose "${COMPOSE_BASE[@]}" -f compose.ssl.yaml up -d
  if [[ "$caddy_https_port" == "443" ]]; then
    echo "部署完成。请访问: https://$domain/"
  else
    echo "部署完成。HTTPS 非标准端口，请访问: https://$domain:${caddy_https_port}/"
  fi
else
  echo "模式: 仅 HTTP（无内置 Caddy），映射: $port_mapping -> 容器 7860"
  docker compose "${COMPOSE_BASE[@]}" -f compose.local.yaml pull
  docker compose "${COMPOSE_BASE[@]}" -f compose.local.yaml up -d
  echo "部署完成。"
  echo "  若本机另有反代并已配置 Let's Encrypt：在反代里把该域名 proxy_pass 到 http://127.0.0.1:$http_port（同机建议 config 里 bind_host: 127.0.0.1）"
  echo "  直连（无反代）时可访问: http://<本机IP>:$http_port/"
fi
