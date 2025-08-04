#!/bin/bash

# =========================================================
# Nginx反向代理模块
# =========================================================

# 配置Nginx
configure_nginx() {
    log "开始配置Nginx反向代理..."

    # 生成Nginx配置文件
    generate_nginx_config

    # 生成Nginx Docker Compose配置
    generate_nginx_compose

    # 启动Nginx服务
    start_nginx_service

    success "Nginx配置完成"
}

# 生成Nginx配置文件
generate_nginx_config() {
    log "生成Nginx配置文件..."

    if [ "$USE_DOMAIN" = true ]; then
        generate_domain_nginx_config
    else
        generate_ip_nginx_config
    fi

    success "Nginx配置文件生成完成"
}

# 生成域名模式的Nginx配置
generate_domain_nginx_config() {
    cat > "$INSTALL_PATH/config/nginx.conf" << EOF
events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                   '\$status \$body_bytes_sent "\$http_referer" '
                   '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    client_max_body_size 100M;

    # 定义上游服务器
    upstream dify_api_upstream {
        server dify_api:5001;
    }

    upstream dify_web_upstream {
        server dify_web:3000;
    }

    upstream n8n_upstream {
        server n8n:5678;
    }

    upstream oneapi_upstream {
        server oneapi:3000;
    }

    # Dify服务器配置
    server {
        listen 80;
        server_name ${DIFY_DOMAIN};

        # API路径代理
        location /console/api/ {
            proxy_pass http://dify_api_upstream/console/api/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            add_header Access-Control-Allow-Origin * always;
            add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Content-Type, Authorization, X-Requested-With" always;

            if (\$request_method = 'OPTIONS') {
                add_header Access-Control-Allow-Origin * always;
                add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
                add_header Access-Control-Allow-Headers "Content-Type, Authorization, X-Requested-With" always;
                return 204;
            }
        }

        location /v1/ {
            proxy_pass http://dify_api_upstream/v1/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        location /files/ {
            proxy_pass http://dify_api_upstream/files/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        location /api/ {
            proxy_pass http://dify_api_upstream/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        location / {
            proxy_pass http://dify_web_upstream;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }

    # n8n服务器配置
    server {
        listen 80;
        server_name ${N8N_DOMAIN};

        location / {
            proxy_pass http://n8n_upstream;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Connection "upgrade";
            proxy_set_header Upgrade \$http_upgrade;
            proxy_read_timeout 86400;
        }
    }

    # OneAPI服务器配置
    server {
        listen 80;
        server_name ${ONEAPI_DOMAIN};

        location / {
            proxy_pass http://oneapi_upstream;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }

    # 默认服务器
    server {
        listen 80 default_server;
        server_name _;

        location / {
            return 200 '<!DOCTYPE html>
<html>
<head>
    <title>AI服务集群</title>
    <meta charset="utf-8">
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 30px; border-radius: 10px; }
        h1 { color: #333; text-align: center; }
        .service { margin: 20px 0; padding: 20px; border: 2px solid #e0e0e0; border-radius: 8px; }
        .service h3 { margin: 0 0 10px 0; color: #333; }
        .service p { color: #666; margin: 10px 0; }
        .service a { display: inline-block; margin: 5px 10px 5px 0; padding: 8px 16px; background: #007bff; color: white; text-decoration: none; border-radius: 4px; }
        .service a:hover { background: #0056b3; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 AI服务集群</h1>
        <div class="service">
            <h3>🤖 Dify AI助手平台</h3>
            <p>访问地址: <a href="${DIFY_URL}" target="_blank">${DIFY_DOMAIN}$([ -n "$DOMAIN_PORT" ] && [ "$DOMAIN_PORT" != "80" ] && echo ":$DOMAIN_PORT")</a></p>
        </div>
        <div class="service">
            <h3>🔄 n8n 工作流自动化</h3>
            <p>访问地址: <a href="${N8N_URL}" target="_blank">${N8N_DOMAIN}$([ -n "$DOMAIN_PORT" ] && [ "$DOMAIN_PORT" != "80" ] && echo ":$DOMAIN_PORT")</a></p>
        </div>
        <div class="service">
            <h3>🔑 OneAPI 接口管理</h3>
            <p>访问地址: <a href="${ONEAPI_URL}" target="_blank">${ONEAPI_DOMAIN}$([ -n "$DOMAIN_PORT" ] && [ "$DOMAIN_PORT" != "80" ] && echo ":$DOMAIN_PORT")</a></p>
        </div>
    </div>
</body>
</html>';
            add_header Content-Type text/html;
        }
    }
}
EOF
}

# 生成IP模式的Nginx配置
generate_ip_nginx_config() {
    cat > "$INSTALL_PATH/config/nginx.conf" << 'EOF'
events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                   '$status $body_bytes_sent "$http_referer" '
                   '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    client_max_body_size 100M;

    # 定义上游服务器
    upstream dify_api_upstream {
        server dify_api:5001;
    }

    upstream dify_web_upstream {
        server dify_web:3000;
    }

    upstream n8n_upstream {
        server n8n:5678;
    }

    upstream oneapi_upstream {
        server oneapi:3000;
    }

    server {
        listen 80 default_server;
        server_name _;

        location = / {
            return 200 '<!DOCTYPE html>
<html>
<head>
    <title>AI服务集群</title>
    <meta charset="utf-8">
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { max-width: 1200px; margin: 0 auto; background: white; padding: 30px; border-radius: 10px; }
        h1 { color: #333; text-align: center; margin-bottom: 30px; }
        .service { margin: 20px 0; padding: 20px; border: 2px solid #e0e0e0; border-radius: 8px; }
        .service h3 { margin: 0 0 10px 0; color: #333; }
        .service p { color: #666; margin: 10px 0; }
        .service a { display: inline-block; margin: 5px 10px 5px 0; padding: 8px 16px; background: #007bff; color: white; text-decoration: none; border-radius: 4px; }
        .service a:hover { background: #0056b3; }
        .service a.direct { background: #28a745; }
        .service a.direct:hover { background: #1e7e34; }
        .info { background: #f8f9fa; padding: 20px; margin-top: 30px; border-radius: 8px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 AI服务集群管理面板</h1>

        <div class="service">
            <h3>🤖 Dify AI助手平台</h3>
            <p>强大的AI应用开发平台，支持多种AI模型和工作流编排</p>
            <a href="/dify/">代理访问</a>
            <a href="#" onclick="openDirect(8602)" class="direct">直接访问</a>
        </div>

        <div class="service">
            <h3>🔄 n8n 工作流自动化</h3>
            <p>可视化工作流编排和自动化平台，连接各种应用和服务</p>
            <a href="/n8n/">代理访问</a>
            <a href="#" onclick="openDirect(8601)" class="direct">直接访问</a>
        </div>

        <div class="service">
            <h3>🔑 OneAPI 接口管理</h3>
            <p>统一的AI接口管理和分发平台，支持多种AI模型接口</p>
            <a href="/oneapi/">代理访问</a>
            <a href="#" onclick="openDirect(8603)" class="direct">直接访问</a>
        </div>

        <div class="info">
            <h4>📊 服务信息：</h4>
            <p>数据库连接信息：</p>
            <ul>
                <li>MySQL: <span id="host">loading...</span>:3306 (用户: root, 密码: 654321)</li>
                <li>PostgreSQL: <span id="host2">loading...</span>:5433 (用户: postgres, 密码: 654321)</li>
                <li>Redis: <span id="host3">loading...</span>:6379</li>
            </ul>
        </div>
    </div>

    <script>
        var hostname = window.location.hostname;
        document.getElementById("host").textContent = hostname;
        document.getElementById("host2").textContent = hostname;
        document.getElementById("host3").textContent = hostname;

        function openDirect(port) {
            window.open("http://" + hostname + ":" + port, "_blank");
        }
    </script>
</body>
</html>';
            add_header Content-Type text/html;
        }

        # Dify服务代理
        location /dify/ {
            rewrite ^/dify/(.*) /$1 break;
            proxy_pass http://dify_web_upstream;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        location /dify {
            return 301 /dify/;
        }

        # Dify Console API代理
        location /console/api/ {
            proxy_pass http://dify_api_upstream/console/api/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            add_header Access-Control-Allow-Origin * always;
            add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
            add_header Access-Control-Allow-Headers "Content-Type, Authorization, X-Requested-With" always;

            if ($request_method = 'OPTIONS') {
                add_header Access-Control-Allow-Origin * always;
                add_header Access-Control-Allow-Methods "GET, POST, PUT, DELETE, OPTIONS" always;
                add_header Access-Control-Allow-Headers "Content-Type, Authorization, X-Requested-With" always;
                return 204;
            }
        }

        location /api/ {
            proxy_pass http://dify_api_upstream/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        location /v1/ {
            proxy_pass http://dify_api_upstream/v1/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        location /files/ {
            proxy_pass http://dify_api_upstream/files/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        # n8n服务代理
        location /n8n/ {
            rewrite ^/n8n/(.*) /$1 break;
            proxy_pass http://n8n_upstream;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header Connection "upgrade";
            proxy_set_header Upgrade $http_upgrade;
            proxy_read_timeout 86400;
        }

        location /n8n {
            return 301 /n8n/;
        }

        # OneAPI服务代理
        location /oneapi/ {
            rewrite ^/oneapi/(.*) /$1 break;
            proxy_pass http://oneapi_upstream;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        location /oneapi {
            return 301 /oneapi/;
        }
    }
}
EOF
}

# 生成Nginx Docker Compose配置
generate_nginx_compose() {
    log "生成Nginx Docker Compose配置..."

    cat > "$INSTALL_PATH/docker-compose-nginx.yml" << EOF
version: '3.8'

networks:
  aiserver_network:
    external: true

services:
  # Nginx反向代理
  nginx:
    image: nginx:latest
    container_name: ${CONTAINER_PREFIX}_nginx
    restart: always
    ports:
      - "${NGINX_PORT}:80"
    volumes:
      - ./config/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./logs:/var/log/nginx
    networks:
      - aiserver_network
EOF

    success "Nginx Docker Compose配置生成完成"
}

# 启动Nginx服务
start_nginx_service() {
    log "启动Nginx服务..."

    cd "$INSTALL_PATH"

    # 创建Docker网络（如果不存在）
    docker network create aiserver_network 2>/dev/null || true

    # 启动Nginx
    docker-compose -f docker-compose-nginx.yml up -d nginx

    # 检查Nginx状态
    sleep 10
    if docker ps --format "table {{.Names}}" | grep -q "${CONTAINER_PREFIX}_nginx"; then
        success "Nginx服务启动完成"
    else
        warning "Nginx服务可能启动失败，请检查配置和日志"
    fi
}

# 重新加载Nginx配置
reload_nginx_config() {
    log "重新加载Nginx配置..."

    if docker ps --format "table {{.Names}}" | grep -q "${CONTAINER_PREFIX}_nginx"; then
        # 测试配置语法
        if docker exec "${CONTAINER_PREFIX}_nginx" nginx -t; then
            # 重新加载配置
            docker exec "${CONTAINER_PREFIX}_nginx" nginx -s reload
            success "Nginx配置已重新加载"
        else
            error "Nginx配置语法错误，请检查配置文件"
            return 1
        fi
    else
        warning "Nginx服务未运行"
        return 1
    fi
}