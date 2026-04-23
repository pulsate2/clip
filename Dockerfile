FROM eceasy/cli-proxy-api:latest

# 安装 cloudflared（alpine 基础镜像）
RUN apk add --no-cache curl ca-certificates \
    && curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
       -o /usr/local/bin/cloudflared \
    && chmod +x /usr/local/bin/cloudflared

# 创建启动脚本（同时启动 CLI Proxy API + cloudflared，并强制 HTTP/2）
COPY <<EOF /start.sh
#!/bin/sh
set -e

echo "=== 启动 CLI Proxy API ==="
/CLIProxyAPI/CLIProxyAPI &

echo "=== 等待 API 启动（5秒）==="
sleep 5

echo "=== 启动 Cloudflare Tunnel（强制 HTTP/2 协议）==="
if [ -z "\${CLOUDFLARED_TOKEN}" ]; then
  echo "错误：请设置环境变量 CLOUDFLARED_TOKEN"
  exit 1
fi

exec cloudflared tunnel run --token "\${CLOUDFLARED_TOKEN}" --protocol http2
EOF

RUN chmod +x /start.sh

# 覆盖原 CMD
CMD ["/start.sh"]

# 保留原端口（内部使用）
EXPOSE 8317
