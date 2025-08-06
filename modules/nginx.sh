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

# 检查服务是否运行
check_service_running() {
    local service_name="$1"
    docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_${service_name}" 2>/dev/null
}

# 检查服务是否存在（包括未运行的容器）
check_service_exists() {
    local service_name="$1"
    docker ps -a --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_${service_name}" 2>/dev/null
}

# 生成动态upstream配置
generate_upstream_config() {
    local config=""
    
    # 检查并生成每个服务的upstream
    if check_service_running "dify_api"; then
        config="$config
    upstream dify_api_upstream {
        server ${CONTAINER_PREFIX}_dify_api:5001;
    }"
    fi
    
    if check_service_running "dify_web"; then
        config="$config
    upstream dify_web_upstream {
        server ${CONTAINER_PREFIX}_dify_web:3000;
    }"
    fi
    
    if check_service_running "n8n"; then
        config="$config
    upstream n8n_upstream {
        server ${CONTAINER_PREFIX}_n8n:5678;
    }"
    fi
    
    if check_service_running "oneapi"; then
        config="$config
    upstream oneapi_upstream {
        server ${CONTAINER_PREFIX}_oneapi:3000;
    }"
    fi
    
    if check_service_running "ragflow"; then
        config="$config
    upstream ragflow_upstream {
        server ${CONTAINER_PREFIX}_ragflow:80;
    }
    
    upstream ragflow_api_upstream {
        server ${CONTAINER_PREFIX}_ragflow:9380;
    }"
    fi
    
    echo "$config"
}

# 生成安全的域名模式的Nginx配置
generate_safe_domain_nginx_config() {
    log "生成安全的Nginx配置..."
    
    # 检查哪些服务正在运行
    local running_services=()
    local existing_services=()
    
    for service in "dify_api" "dify_web" "n8n" "oneapi" "ragflow"; do
        if check_service_running "$service"; then
            running_services+=("$service")
            existing_services+=("$service")
            log "检测到运行中的服务: $service"
        elif check_service_exists "$service"; then
            existing_services+=("$service")
            log "检测到存在但未运行的服务: $service"
        else
            log "服务未运行，将跳过: $service"
        fi
    done
    
    # 生成配置文件
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
EOF

    # 添加动态upstream配置
    for service in "${existing_services[@]}"; do
        case "$service" in
            "dify_api")
                cat >> "$INSTALL_PATH/config/nginx.conf" << EOF

    # Dify API upstream
    upstream dify_api_upstream {
        server ${CONTAINER_PREFIX}_dify_api:5001;
    }
EOF
                ;;
            "dify_web")
                cat >> "$INSTALL_PATH/config/nginx.conf" << EOF

    # Dify Web upstream
    upstream dify_web_upstream {
        server ${CONTAINER_PREFIX}_dify_web:3000;
    }
EOF
                ;;
            "n8n")
                cat >> "$INSTALL_PATH/config/nginx.conf" << EOF

    # n8n upstream
    upstream n8n_upstream {
        server ${CONTAINER_PREFIX}_n8n:5678;
    }
EOF
                ;;
            "oneapi")
                cat >> "$INSTALL_PATH/config/nginx.conf" << EOF

    # OneAPI upstream
    upstream oneapi_upstream {
        server ${CONTAINER_PREFIX}_oneapi:3000;
    }
EOF
                ;;
            "ragflow")
                cat >> "$INSTALL_PATH/config/nginx.conf" << EOF

    # RAGFlow upstream
    upstream ragflow_upstream {
        server ${CONTAINER_PREFIX}_ragflow:80;
    }
    
    upstream ragflow_api_upstream {
        server ${CONTAINER_PREFIX}_ragflow:9380;
    }
EOF
                ;;
        esac
    done
    
    # 添加服务器配置
    generate_server_configs "${existing_services[@]}"
    
    # 结束配置文件
    echo "}" >> "$INSTALL_PATH/config/nginx.conf"
    
    success "安全的Nginx配置生成完成"
}

# 生成服务器配置
generate_server_configs() {
    local running_services=("$@")
    
    # Dify服务器配置
    if [[ " ${running_services[*]} " =~ " dify_api " ]] && [[ " ${running_services[*]} " =~ " dify_web " ]]; then
        cat >> "$INSTALL_PATH/config/nginx.conf" << 'EOF'

    # Dify服务器配置
    server {
        listen 80;
        server_name ${DIFY_DOMAIN};

        # API路径代理
        location /console/api/ {
            proxy_pass http://dify_api_upstream/console/api/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }

        location /api/ {
            proxy_pass http://dify_api_upstream/api/;
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

        # 默认路径代理到Web服务
        location / {
            proxy_pass http://dify_web_upstream/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
EOF
    fi
    
    # n8n服务器配置
    if [[ " ${running_services[*]} " =~ " n8n " ]]; then
        cat >> "$INSTALL_PATH/config/nginx.conf" << 'EOF'

    # n8n服务器配置
    server {
        listen 80;
        server_name ${N8N_DOMAIN};

        location / {
            proxy_pass http://n8n_upstream/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            
            # WebSocket支持
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
        }
    }
EOF
    fi
    
    # OneAPI服务器配置
    if [[ " ${running_services[*]} " =~ " oneapi " ]]; then
        cat >> "$INSTALL_PATH/config/nginx.conf" << 'EOF'

    # OneAPI服务器配置
    server {
        listen 80;
        server_name ${ONEAPI_DOMAIN};

        location / {
            proxy_pass http://oneapi_upstream/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
EOF
    fi
    
    # RAGFlow服务器配置
    if check_service_exists "ragflow"; then
        cat >> "$INSTALL_PATH/config/nginx.conf" << 'EOF'

    # RAGFlow服务器配置
    server {
        listen 80;
        server_name ${RAGFLOW_DOMAIN};

        # API路径代理
        location /api/ {
            proxy_pass http://ragflow_api_upstream/api/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_connect_timeout 300s;
            proxy_read_timeout 300s;
            proxy_send_timeout 300s;
            
            # 错误处理
            proxy_intercept_errors on;
            error_page 502 503 504 = @ragflow_error;
        }

        # 默认路径代理到Web服务
        location / {
            proxy_pass http://ragflow_upstream/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_connect_timeout 300s;
            proxy_read_timeout 300s;
            proxy_send_timeout 300s;
            
            # 错误处理
            proxy_intercept_errors on;
            error_page 502 503 504 = @ragflow_error;
        }
        
        # RAGFlow错误处理
        location @ragflow_error {
            return 503 '<!DOCTYPE html><html><head><title>RAGFlow服务正在启动中</title><meta http-equiv="refresh" content="30"><style>body{font-family:Arial,sans-serif;line-height:1.6;max-width:800px;margin:0 auto;padding:20px}h1{color:#3498db}p{margin-bottom:15px}</style></head><body><h1>RAGFlow服务正在启动中</h1><p>RAGFlow服务需要较长时间启动，请耐心等待（通常需要5-10分钟）。</p><p>此页面将每30秒自动刷新一次。</p><p>如果长时间未启动，请检查服务器资源是否充足（建议至少8GB内存）。</p></body></html>';
        }
    }
EOF
    fi
}

# 生成域名模式的Nginx配置
generate_domain_nginx_config() {
    # 使用安全的配置生成函数
    generate_safe_domain_nginx_config
    return $?
}

# 保留原有的函数作为备用
generate_domain_nginx_config_original() {
    # 定义服务名变量，使用容器前缀
    local dify_api="${CONTAINER_PREFIX}_dify_api"
    local dify_web="${CONTAINER_PREFIX}_dify_web"
    local n8n="${CONTAINER_PREFIX}_n8n"
    local oneapi="${CONTAINER_PREFIX}_oneapi"
    local ragflow="${CONTAINER_PREFIX}_ragflow"
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
        server ${CONTAINER_PREFIX}_dify_api:5001;
    }

    upstream dify_web_upstream {
        server ${CONTAINER_PREFIX}_dify_web:3000;
    }

    upstream n8n_upstream {
        server ${CONTAINER_PREFIX}_n8n:5678;
    }

    upstream oneapi_upstream {
        server ${CONTAINER_PREFIX}_oneapi:3000;
    }

    upstream ragflow_upstream {
        server ${CONTAINER_PREFIX}_ragflow:80;
    }

    upstream ragflow_api_upstream {
        server ${CONTAINER_PREFIX}_ragflow:9380;
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

    # RAGFlow服务器配置
    server {
        listen 80;
        server_name ${RAGFLOW_DOMAIN};

        # API路径代理
        location /api/ {
            proxy_pass http://ragflow_api_upstream/api/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_read_timeout 300;
            proxy_connect_timeout 300;
            proxy_send_timeout 300;
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

        # 健康检查
        location /health {
            proxy_pass http://ragflow_upstream/health;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }

        # WebSocket支持
        location /ws/ {
            proxy_pass http://ragflow_upstream/ws/;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_read_timeout 86400;
        }

        # 静态资源和主页面
        location / {
            proxy_pass http://ragflow_upstream;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_read_timeout 300;
            proxy_connect_timeout 300;
            proxy_send_timeout 300;
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
        .new { border-color: #28a745; background: #f8fff9; }
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
        <div class="service new">
            <h3>📚 RAGFlow 文档理解RAG引擎</h3>
            <p>访问地址: <a href="${RAGFLOW_URL}" target="_blank">${RAGFLOW_DOMAIN}$([ -n "$DOMAIN_PORT" ] && [ "$DOMAIN_PORT" != "80" ] && echo ":$DOMAIN_PORT")</a></p>
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
    # 定义服务名变量，使用容器前缀
    local dify_api="${CONTAINER_PREFIX}_dify_api"
    local dify_web="${CONTAINER_PREFIX}_dify_web"
    local n8n="${CONTAINER_PREFIX}_n8n"
    local oneapi="${CONTAINER_PREFIX}_oneapi"
    local ragflow="${CONTAINER_PREFIX}_ragflow"
    cat > "$INSTALL_PATH/config/nginx.conf" << EOF
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
        server ${CONTAINER_PREFIX}_dify_api:5001;
    }

    upstream dify_web_upstream {
        server ${CONTAINER_PREFIX}_dify_web:3000;
    }

    upstream n8n_upstream {
        server ${CONTAINER_PREFIX}_n8n:5678;
    }

    upstream oneapi_upstream {
        server ${CONTAINER_PREFIX}_oneapi:3000;
    }

    upstream ragflow_upstream {
        server ${CONTAINER_PREFIX}_ragflow:80;
    }

    upstream ragflow_api_upstream {
        server ${CONTAINER_PREFIX}_ragflow:9380;
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
        .new { border-color: #28a745; background: #f8fff9; }
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

        <div class="service new">
            <h3>📚 RAGFlow 文档理解RAG引擎</h3>
            <p>基于深度文档理解的RAG引擎，支持PDF、Word等多种文档格式</p>
            <a href="/ragflow/">代理访问</a>
            <a href="#" onclick="openDirect(8605)" class="direct">直接访问</a>
        </div>

        <div class="info">
            <h4>📊 服务信息：</h4>
            <p>数据库连接信息：</p>
            <ul>
                <li>MySQL: <span id="host">loading...</span>:3306 (用户: root, 密码: 654321)</li>
                <li>PostgreSQL: <span id="host2">loading...</span>:5433 (用户: postgres, 密码: 654321)</li>
                <li>Redis: <span id="host3">loading...</span>:6379</li>
                <li>Elasticsearch: <span id="host4">loading...</span>:9200</li>
                <li>MinIO: <span id="host5">loading...</span>:9002 (控制台)</li>
            </ul>
        </div>
    </div>

    <script>
        var hostname = window.location.hostname;
        document.getElementById("host").textContent = hostname;
        document.getElementById("host2").textContent = hostname;
        document.getElementById("host3").textContent = hostname;
        document.getElementById("host4").textContent = hostname;
        document.getElementById("host5").textContent = hostname;

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
            # 优先匹配RAGFlow API
            if ($request_uri ~* "^/api/v1/dataset|^/api/v1/chat|^/api/v1/retrieval") {
                proxy_pass http://ragflow_api_upstream;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
                proxy_read_timeout 300;
                proxy_connect_timeout 300;
                proxy_send_timeout 300;
                break;
            }

            # 默认路由到Dify API
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

        # RAGFlow服务代理
        location /ragflow/ {
            rewrite ^/ragflow/(.*) /$1 break;
            proxy_pass http://ragflow_upstream;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_read_timeout 300;
            proxy_connect_timeout 300;
            proxy_send_timeout 300;
        }

        location /ragflow {
            return 301 /ragflow/;
        }

        # RAGFlow API代理 (专用路径)
        location /ragflow/api/ {
            rewrite ^/ragflow/api/(.*) /api/$1 break;
            proxy_pass http://ragflow_api_upstream;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_read_timeout 300;
            proxy_connect_timeout 300;
            proxy_send_timeout 300;
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

        # RAGFlow WebSocket支持
        location /ragflow/ws/ {
            rewrite ^/ragflow/ws/(.*) /ws/$1 break;
            proxy_pass http://ragflow_upstream;
            proxy_http_version 1.1;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_read_timeout 86400;
        }

        # 健康检查端点
        location /health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
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
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:80/health"]
      interval: 30s
      timeout: 10s
      retries: 3
EOF

    success "Nginx Docker Compose配置生成完成"
}

# 启动Nginx服务
start_nginx_service() {
    log "启动Nginx服务..."

    cd "$INSTALL_PATH"

    # 确保网络存在
    docker network create aiserver_network 2>/dev/null || true

    # 启动Nginx服务
    COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-nginx.yml up -d --remove-orphans
    
    # 等待Nginx启动
    local max_retries=5
    local retry_count=0
    local nginx_started=false
    
    while [ $retry_count -lt $max_retries ]; do
        if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_nginx"; then
            nginx_started=true
            break
        fi
        
        log "等待Nginx启动，重试 $((retry_count + 1))/$max_retries..."
        sleep 10
        retry_count=$((retry_count + 1))
        
        # 如果Nginx启动失败，检查日志
        if [ $retry_count -eq 3 ]; then
            log "Nginx启动可能遇到问题，检查日志..."
            docker logs "${CONTAINER_PREFIX}_nginx" --tail 10 2>/dev/null || true
        fi
        
        # 如果Nginx仍未启动，尝试重新启动
        if [ $retry_count -eq $max_retries ]; then
            log "尝试重新启动Nginx..."
            docker stop "${CONTAINER_PREFIX}_nginx" 2>/dev/null || true
            docker rm "${CONTAINER_PREFIX}_nginx" 2>/dev/null || true
            COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-nginx.yml up -d --remove-orphans
            sleep 10
            
            if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_nginx"; then
                nginx_started=true
                break
            fi
        fi
    done
    
    if [ "$nginx_started" = true ]; then
        success "Nginx服务启动完成"
    else
        warning "Nginx服务启动可能存在问题，请检查日志"
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

# 测试Nginx配置
test_nginx_config() {
    log "测试Nginx配置..."

    if [ -f "$INSTALL_PATH/config/nginx.conf" ]; then
        # 使用临时容器测试配置
        docker run --rm -v "$INSTALL_PATH/config/nginx.conf:/etc/nginx/nginx.conf:ro" nginx:latest nginx -t
        if [ $? -eq 0 ]; then
            success "Nginx配置测试通过"
            return 0
        else
            error "Nginx配置测试失败"
            return 1
        fi
    else
        error "Nginx配置文件不存在"
        return 1
    fi
}

# 生成SSL证书配置（预留功能）
generate_ssl_config() {
    log "生成SSL证书配置..."

    # 这是一个预留功能，用于将来支持HTTPS
    warning "SSL证书配置功能正在开发中"

    # 创建证书目录
    ensure_directory "$INSTALL_PATH/volumes/nginx/ssl" "root:root" "755"

    success "SSL配置目录已创建"
}

# 备份Nginx配置
backup_nginx_config() {
    local backup_dir="$1"

    log "备份Nginx配置..."

    mkdir -p "$backup_dir"

    # 备份配置文件
    if [ -f "$INSTALL_PATH/config/nginx.conf" ]; then
        cp "$INSTALL_PATH/config/nginx.conf" "$backup_dir/" 2>/dev/null
        success "Nginx配置文件备份完成"
    fi

    # 备份日志文件
    if [ -d "$INSTALL_PATH/logs" ]; then
        cp -r "$INSTALL_PATH/logs" "$backup_dir/" 2>/dev/null
        success "Nginx日志备份完成"
    fi
}

# 恢复Nginx配置
restore_nginx_config() {
    local backup_dir="$1"

    log "恢复Nginx配置..."

    # 恢复配置文件
    if [ -f "$backup_dir/nginx.conf" ]; then
        backup_file "$INSTALL_PATH/config/nginx.conf"
        cp "$backup_dir/nginx.conf" "$INSTALL_PATH/config/" 2>/dev/null
        success "Nginx配置文件恢复完成"
    fi

    # 重新加载配置
    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_nginx"; then
        reload_nginx_config
    fi
}

# 显示Nginx状态
show_nginx_status() {
    log "显示Nginx状态..."

    echo -e "\n${BLUE}=== Nginx服务状态 ===${NC}"

    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_nginx"; then
        local health_status=$(docker inspect --format='{{.State.Health.Status}}' "${CONTAINER_PREFIX}_nginx" 2>/dev/null || echo "no-health-check")
        case "$health_status" in
            healthy)
                echo "✅ Nginx: 运行正常"
                ;;
            unhealthy)
                echo "❌ Nginx: 运行异常"
                ;;
            starting)
                echo "🔄 Nginx: 正在启动"
                ;;
            *)
                echo "ℹ️  Nginx: 运行中（无健康检查）"
                ;;
        esac

        # 显示端口信息
        local port_info=$(docker port "${CONTAINER_PREFIX}_nginx" 80 2>/dev/null)
        if [ -n "$port_info" ]; then
            echo "🌐 监听端口: $port_info"
        fi

        # 显示配置文件路径
        echo "📁 配置文件: $INSTALL_PATH/config/nginx.conf"
        echo "📁 日志目录: $INSTALL_PATH/logs"

    else
        echo "❌ Nginx: 未运行"
    fi

    echo -e "\n${BLUE}=== 反向代理配置 ===${NC}"
    if [ "$USE_DOMAIN" = true ]; then
        echo "模式: 域名模式"
        echo "Dify: ${DIFY_DOMAIN} -> dify_web:3000"
        echo "n8n: ${N8N_DOMAIN} -> n8n:5678"
        echo "OneAPI: ${ONEAPI_DOMAIN} -> oneapi:3000"
        echo "RAGFlow: ${RAGFLOW_DOMAIN} -> ragflow:80"
    else
        echo "模式: IP模式"
        echo "统一入口: http://${SERVER_IP}:${NGINX_PORT}"
        echo "/dify/ -> dify_web:3000"
        echo "/n8n/ -> n8n:5678"
        echo "/oneapi/ -> oneapi:3000"
        echo "/ragflow/ -> ragflow:80"
    fi
}