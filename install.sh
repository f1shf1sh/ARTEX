#!/usr/bin/env bash
# ARTEX 安装脚本：① 全部 Docker（本地构建镜像）② 本地编译运行
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd)"

info(){ printf '\033[36m[*]\033[0m %s\n' "$*"; }
ok(){   printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn(){ printf '\033[33m[!]\033[0m %s\n' "$*"; }
die(){  printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
ask(){  local p="$1" d="${2:-}" a; read -rp "$p${d:+ [$d]}: " a; echo "${a:-$d}"; }
rand(){ head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24; }

# ── docker 环境检测 / 自动安装 ───────────────────
ensure_docker(){
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "已检测到 docker 与 docker compose"; return
  fi
  warn "未检测到 docker / docker compose"
  case "$(uname -s)" in
    Linux)
      if [ "$(ask '自动安装 Docker? (y/n)' y)" = y ]; then
        curl -fsSL https://get.docker.com | sh
        sudo usermod -aG docker "$USER" || true
        ok "Docker 安装完成（用户组变更需重新登录后免 sudo）"
      else
        die "请自行安装 docker 后重试"
      fi ;;
    Darwin) die "macOS 请安装 Docker Desktop：https://www.docker.com/products/docker-desktop/" ;;
    *)      die "请自行安装 docker 后重试" ;;
  esac
}

# ── ① 全部 Docker（本地构建镜像）────────────────
# 检测 Docker daemon 的架构，映射成 Go / 镜像用的 GOARCH。
detect_linux_arch(){
  local a
  a="$(docker info --format '{{.Architecture}}' 2>/dev/null || true)"
  [ -n "$a" ] || a="$(uname -m)"
  case "$a" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "不支持的宿主机架构：$a（仅支持 amd64 / arm64）" ;;
  esac
}

# 在宿主机上构建前端 + Linux 单二进制，再交给 Dockerfile 打成运行镜像。
# Dockerfile 不负责编译，只 COPY dist/<TARGETARCH>/artex，所以这里必须先生成它。
build_image(){
  command -v go >/dev/null 2>&1 || die "本地构建镜像需要 Go（>=1.26）：https://go.dev/dl/"
  command -v npm >/dev/null 2>&1 || die "本地构建镜像需要 Node.js/npm（构建内嵌前端）"
  local arch ver
  arch="$(detect_linux_arch)"
  ver="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"; ver="${ver#v}"

  info "构建前端静态产物（npm ci + build:static）…"
  ( cd web && npm ci && npm run build:static )
  mkdir -p server/webui
  rm -rf server/webui/dist
  cp -R web/out server/webui/dist

  info "交叉编译 Linux/${arch} 单二进制（版本 ${ver}）…"
  mkdir -p "dist/${arch}"
  CGO_ENABLED=0 GOOS=linux GOARCH="${arch}" \
    go build -tags embedui -trimpath \
    -ldflags "-s -w -buildid= -X main.version=${ver}" \
    -o "dist/${arch}/artex" ./cmd/artex

  info "构建本地镜像 autumn27/artex:local（首次会拉取基础镜像，需要联网）…"
  docker build -t autumn27/artex:local .
  ok "本地镜像已构建：autumn27/artex:local"
}

# 写入/更新 .env 中的单个键，避免重复行。
set_env(){
  local k="$1" v="$2"
  if grep -q "^${k}=" .env; then
    sed -i.bak "s|^${k}=.*|${k}=${v}|" .env
    rm -f .env.bak
  else
    printf '%s=%s\n' "$k" "$v" >> .env
  fi
}

install_docker(){
  ensure_docker
  if [ ! -f .env ]; then
    cp .env.example .env 2>/dev/null || true
    local pw key
    pw="$(ask 'Postgres 密码（回车随机生成）' "$(rand)")"
    key="$(ask 'ANTHROPIC_API_KEY（可留空，后续在 UI 配）' '')"
    sed -i.bak "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${pw}|" .env
    sed -i.bak "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${key}|" .env
    rm -f .env.bak
    ok "已生成 .env（POSTGRES_PASSWORD 已设置）"
  else
    info "沿用已存在的 .env"
  fi

  build_image
  # 固定使用本地构建的 tag，compose 就不会去 Docker Hub 拉 autumn27/artex:latest。
  set_env ARTEX_TAG local

  info "启动容器…"
  docker compose up -d
  ok "启动完成 → http://localhost:8787"
  info "镜像由本地源码构建（artex:local）；代码更新后重跑本脚本即可重建"
  info "查看日志：docker compose logs -f artex"
}

# ── ② 本地编译运行 ──────────────────────────────
install_local(){
  echo "数据库安装方式："
  echo "  1) 连接已有 PostgreSQL"
  echo "  2) 用 Docker 起一个 PostgreSQL（需要 docker）"
  case "$(ask '选择' 1)" in
    2)
      ensure_docker
      local pw; pw="$(ask 'Postgres 密码（回车随机）' "$(rand)")"
      docker run -d --name artex-pg -p 5432:5432 \
        -e POSTGRES_USER=artex -e POSTGRES_PASSWORD="$pw" -e POSTGRES_DB=artex \
        -v artex-pg:/var/lib/postgresql/data postgres:16-alpine
      DB_HOST=127.0.0.1 DB_PORT=5432 DB_USER=artex DB_PASS="$pw" DB_NAME=artex DB_SSL=disable ;;
    *)
      DB_HOST="$(ask '数据库地址' 127.0.0.1)"
      DB_PORT="$(ask '端口' 5432)"
      DB_USER="$(ask '账号' artex)"
      DB_PASS="$(ask '密码' '')"
      DB_NAME="$(ask '数据库名' artex)"
      DB_SSL="$(ask 'sslmode (disable/require)' disable)" ;;
  esac

  # 生成 config.json
  cat > config.json <<JSON
{
  "database": {
    "host": "${DB_HOST}",
    "port": ${DB_PORT},
    "user": "${DB_USER}",
    "password": "${DB_PASS}",
    "dbname": "${DB_NAME}",
    "sslmode": "${DB_SSL}"
  }
}
JSON
  ok "已生成 config.json"

  # go 环境检查
  command -v go >/dev/null 2>&1 || die "未检测到 Go，请先安装 Go（>=1.26）：https://go.dev/dl/"
  ok "Go: $(go version)"

  # 内嵌前端需要 node 出静态产物
  if command -v npm >/dev/null 2>&1; then
    info "构建前端静态产物…"
    ( cd web && npm ci && npm run build:static )
    mkdir -p server/webui
    rm -rf server/webui/dist && cp -r web/out server/webui/dist
    info "编译内嵌单二进制…"
    CGO_ENABLED=0 go build -tags embedui -trimpath -o artex ./cmd/artex
  else
    warn "未检测到 npm：将编译**不内嵌前端**的后端（前端需另跑 npm run dev）"
    CGO_ENABLED=0 go build -o artex ./cmd/artex
  fi
  ok "编译完成 → ./artex"

  info "启动…（Ctrl-C 退出）"
  ./artex
}

echo "=============================="
echo "  ARTEX 安装"
echo "  1) 全部 Docker 安装（从源码本地构建镜像）"
echo "  2) 本地运行（go 编译）"
echo "=============================="
case "$(ask '选择' 1)" in
  1) install_docker ;;
  2) install_local ;;
  *) die "无效选择" ;;
esac
