# CLIProxyAPI：启动时按环境变量动态安装插件（GitHub Release 预编译包）
# 无 volume、不编译、不重打镜像即可换插件列表
#
# 环境变量：
#   PLUGIN_REPOS   必填示例（逗号分隔，多个插件）
#     https://github.com/vrxiaojie/xai-autoban
#     https://github.com/vrxiaojie/xai-autoban,https://github.com/other/foo
#     vrxiaojie/xai-autoban,other/foo
#
#   PLUGIN_VERSIONS  可选，与 REPOS 一一对应；空或 latest = 最新
#     latest,1.2.0
#     1.0.4                 # 仅一个插件时
#
#   PLUGIN_ARCH    可选，默认 amd64（arm64 机器设 arm64）
#   CPA_MANAGEMENT_KEY / CLOUDFLARED_TOKEN / PGSTORE_*  按需

FROM eceasy/cli-proxy-api:latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates unzip \
    && curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
       -o /usr/local/bin/cloudflared \
    && chmod +x /usr/local/bin/cloudflared \
    && mkdir -p /CLIProxyAPI/plugins /CLIProxyAPI/data \
    && rm -rf /var/lib/apt/lists/*

COPY <<'EOF' /install-plugins.sh
#!/bin/sh
set -eu

PLUGIN_DIR="${PLUGIN_DIR:-/CLIProxyAPI/plugins}"
PLUGIN_ARCH="${PLUGIN_ARCH:-amd64}"
PLUGIN_REPOS="${PLUGIN_REPOS:-}"
PLUGIN_VERSIONS="${PLUGIN_VERSIONS:-}"

case "$PLUGIN_ARCH" in
  amd64|arm64) ;;
  x86_64) PLUGIN_ARCH=amd64 ;;
  aarch64) PLUGIN_ARCH=arm64 ;;
  *) echo "ERROR: PLUGIN_ARCH 仅支持 amd64/arm64，当前=$PLUGIN_ARCH"; exit 1 ;;
esac

mkdir -p "$PLUGIN_DIR"

if [ -z "$PLUGIN_REPOS" ]; then
  echo "=== PLUGIN_REPOS 为空，跳过插件安装 ==="
  return 0 2>/dev/null || exit 0
fi

# 按逗号拆成位置参数
old_ifs=$IFS
IFS=','
# shellcheck disable=SC2086
set -- $PLUGIN_REPOS
IFS=$old_ifs
repos="$*"

# versions 数组（用 | 拼，避免空格问题）
ver_list=""
if [ -n "$PLUGIN_VERSIONS" ]; then
  IFS=','
  # shellcheck disable=SC2086
  set -- $PLUGIN_VERSIONS
  IFS=$old_ifs
  for v in "$@"; do
    v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -n "$ver_list" ] && ver_list="${ver_list}|"
    ver_list="${ver_list}${v}"
  done
fi

idx=0
IFS=','
# shellcheck disable=SC2086
set -- $PLUGIN_REPOS
IFS=$old_ifs

for repo in "$@"; do
  repo=$(printf '%s' "$repo" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s|/$||;s|\.git$||')
  [ -n "$repo" ] || continue

  case "$repo" in
    https://github.com/*|http://github.com/*)
      owner_name=$(printf '%s' "$repo" | sed -E 's|https?://github.com/||')
      ;;
    *)
      owner_name="$repo"
      repo="https://github.com/$repo"
      ;;
  esac
  owner_name=$(printf '%s' "$owner_name" | sed 's|/$||')
  id=$(printf '%s' "$owner_name" | awk -F/ '{print $NF}')

  # 取对应 version
  ver="latest"
  if [ -n "$ver_list" ]; then
    ver=$(printf '%s' "$ver_list" | awk -F'|' -v i=$((idx + 1)) '{print $i}')
    ver=$(printf '%s' "$ver" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -n "$ver" ] || ver="latest"
  fi

  echo "=== [$id] $repo  version=$ver  arch=linux/$PLUGIN_ARCH ==="

  api="https://api.github.com/repos/${owner_name}/releases"
  if [ "$ver" = "latest" ]; then
    release_json=$(curl -fsSL "${api}/latest")
  else
    ver_num=$(printf '%s' "$ver" | sed 's/^v//')
    release_json=$(curl -fsSL "${api}/tags/v${ver_num}" 2>/dev/null \
      || curl -fsSL "${api}/tags/${ver}")
  fi

  zip_url=$(printf '%s' "$release_json" \
    | sed -n 's/.*"browser_download_url": "\([^"]*\)".*/\1/p' \
    | grep -E "linux[_-]${PLUGIN_ARCH}\\.zip$" | head -n1 || true)

  if [ -z "$zip_url" ]; then
    zip_url=$(printf '%s' "$release_json" \
      | sed -n 's/.*"browser_download_url": "\([^"]*\)".*/\1/p' \
      | grep -iE "linux.*${PLUGIN_ARCH}.*\\.zip$" | head -n1 || true)
  fi

  so_url=$(printf '%s' "$release_json" \
    | sed -n 's/.*"browser_download_url": "\([^"]*\)".*/\1/p' \
    | grep -E "linux[_-]${PLUGIN_ARCH}\\.so$" | head -n1 || true)

  tmp=$(mktemp -d)
  if [ -n "$zip_url" ]; then
    echo "  下载 $zip_url"
    curl -fsSL --retry 3 --retry-delay 2 "$zip_url" -o "$tmp/p.zip"
    unzip -qo "$tmp/p.zip" -d "$tmp/out"
    so=$(find "$tmp/out" -type f -name '*.so' | head -n1 || true)
    [ -n "$so" ] || { echo "  ERROR: zip 内无 .so"; find "$tmp/out" -type f; rm -rf "$tmp"; exit 1; }
    cp -f "$so" "${PLUGIN_DIR}/${id}.so"
  elif [ -n "$so_url" ]; then
    echo "  下载 $so_url"
    curl -fsSL --retry 3 --retry-delay 2 "$so_url" -o "${PLUGIN_DIR}/${id}.so"
  else
    echo "  ERROR: release 中没有 linux/${PLUGIN_ARCH} 的 zip/so"
    printf '%s\n' "$release_json" | sed -n 's/.*"name": "\([^"]*\)".*/  asset: \1/p' | head -30
    rm -rf "$tmp"
    exit 1
  fi

  test -s "${PLUGIN_DIR}/${id}.so"
  echo "  已安装 ${PLUGIN_DIR}/${id}.so ($(wc -c < "${PLUGIN_DIR}/${id}.so" | tr -d ' ') bytes)"
  rm -rf "$tmp"
  idx=$((idx + 1))
done

echo "=== 插件目录 ==="
ls -la "$PLUGIN_DIR"
EOF

COPY <<'EOF' /start.sh
#!/bin/sh
set -eu

# 每次启动按环境变量安装/更新插件（容器无持久化时必须）
/bin/sh /install-plugins.sh

echo "=== 启动 CLI Proxy API ==="
/CLIProxyAPI/CLIProxyAPI &
api_pid=$!

sleep 5
if ! kill -0 "$api_pid" 2>/dev/null; then
  echo "CLIProxyAPI 启动失败"
  wait "$api_pid" || true
  exit 1
fi

if [ -n "${CLOUDFLARED_TOKEN:-}" ]; then
  echo "=== Cloudflare Tunnel (http2) ==="
  trap 'kill "$api_pid" 2>/dev/null || true' EXIT INT TERM
  cloudflared tunnel run --token "${CLOUDFLARED_TOKEN}" --protocol http2
  code=$?
  kill "$api_pid" 2>/dev/null || true
  wait "$api_pid" 2>/dev/null || true
  exit "$code"
fi

echo "=== 仅运行 API ==="
wait "$api_pid"
EOF

RUN chmod +x /start.sh /install-plugins.sh

CMD ["/start.sh"]
EXPOSE 8317
