#!/bin/bash

# =========================================================
# AI服务集群一键安装脚本 (群晖NAS版本) - 修复域名访问问题
# 包含 Dify、n8n、OneAPI、MySQL、PostgreSQL、Redis
# =========================================================

# 配置区域 - 在这里修改所有关键配置
SERVER_IP=""  # 留空自动获取，或手动设置IP
DOMAIN_NAME=""  # 可选：设置域名，如 "your-domain.com"，留空则使用IP
INSTALL_PATH="/volume1/homes/terry/aiserver"  # 安装路径
CONTAINER_PREFIX="aiserver"  # 容器名前缀

# 服务端口配置
N8N_WEB_PORT=8601
DIFY_WEB_PORT=8602
ONEAPI_WEB_PORT=8603
MYSQL_PORT=3306
POSTGRES_PORT=5433
REDIS_PORT=6379
NGINX_PORT=8604  # 修改为8604避免冲突
DIFY_API_PORT=5002  # 改为5002避免冲突

# 数据库密码配置
DB_PASSWORD="654321"  # MySQL和PostgreSQL的root/postgres密码
REDIS_PASSWORD=""  # Redis密码（留空表示无密码）

# =========================================================
# 脚本开始
# =========================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 获取服务器IP和域名配置
get_server_config() {
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}' 2>/dev/null)
        if [ -z "$SERVER_IP" ]; then
            SERVER_IP=$(hostname -I | awk '{print $1}')
        fi
    fi
    
    # 设置访问地址（优先使用域名）
    if [ -n "$DOMAIN_NAME" ]; then
        ACCESS_HOST="$DOMAIN_NAME"
        log "使用域名: $DOMAIN_NAME"
    else
        ACCESS_HOST="$SERVER_IP"
        log "使用IP地址: $SERVER_IP"
    fi
    
    log "检测到服务器IP: $SERVER_IP"
    log "访问地址将使用: $ACCESS_HOST"
}

# 检查Docker是否安装
check_docker() {
    if ! command -v docker &> /dev/null; then
        error "Docker未安装，请先安装Docker"
        exit 1
    fi
    
    if ! command -v docker-compose &> /dev/null; then
        error "Docker Compose未安装，请先安装Docker Compose"
        exit 1
    fi
    
    success "Docker环境检查通过"
}

# 清理现有环境
cleanup_environment() {
    log "开始清理现有环境..."
    
    # 停止并删除所有相关容器
    containers=$(docker ps -a --format "table {{.Names}}" | grep -E "^${CONTAINER_PREFIX}" | tail -n +2 2>/dev/null || true)
    if [ ! -z "$containers" ]; then
        log "停止并删除现有容器..."
        echo "$containers" | while read container; do
            if [ ! -z "$container" ]; then
                docker stop "$container" 2>/dev/null || true
                docker rm "$container" 2>/dev/null || true
            fi
        done
    fi
    
    # 删除相关网络
    networks=$(docker network ls --format "{{.Name}}" | grep -E "^${CONTAINER_PREFIX}" 2>/dev/null || true)
    if [ ! -z "$networks" ]; then
        log "删除现有网络..."
        echo "$networks" | while read network; do
            if [ ! -z "$network" ]; then
                docker network rm "$network" 2>/dev/null || true
            fi
        done
    fi
    
    # 清理数据目录（保留备份）
    if [ -d "$INSTALL_PATH" ]; then
        log "备份现有数据目录..."
        backup_dir="${INSTALL_PATH}_backup_$(date +%Y%m%d_%H%M%S)"
        mv "$INSTALL_PATH" "$backup_dir" 2>/dev/null || true
        warning "原数据已备份至: $backup_dir"
    fi
    
    success "环境清理完成"
}

# 检查端口占用
check_ports() {
    log "检查端口占用情况..."
    
    ports_to_check=($N8N_WEB_PORT $DIFY_WEB_PORT $ONEAPI_WEB_PORT $MYSQL_PORT $POSTGRES_PORT $REDIS_PORT $NGINX_PORT $DIFY_API_PORT)
    
    for port in "${ports_to_check[@]}"; do
        if netstat -ln 2>/dev/null | grep ":$port " > /dev/null 2>&1; then
            warning "端口 $port 已被占用"
            # 如果是5001端口被占用，自动改为5002
            if [ "$port" = "5001" ]; then
                DIFY_API_PORT=5002
                log "自动将Dify API端口改为 $DIFY_API_PORT"
            fi
        fi
    done
}

# 创建目录结构
create_directories() {
    log "创建目录结构..."
    
    # 创建基础目录
    mkdir -p "$INSTALL_PATH"/{mysql,postgres,redis,n8n,dify,oneapi,nginx}
    
    # 创建数据目录
    mkdir -p "$INSTALL_PATH"/volumes/mysql/{data,logs,conf}
    mkdir -p "$INSTALL_PATH"/volumes/postgres/{data,logs}
    mkdir -p "$INSTALL_PATH"/volumes/redis/{data,logs}
    mkdir -p "$INSTALL_PATH"/volumes/n8n/{data,logs}
    mkdir -p "$INSTALL_PATH"/volumes/dify/{api,web,worker,sandbox,storage}
    mkdir -p "$INSTALL_PATH"/volumes/oneapi/{data,logs}
    mkdir -p "$INSTALL_PATH"/volumes/nginx/{logs,conf}
    
    # 创建配置和日志目录
    mkdir -p "$INSTALL_PATH"/{logs,config}
    
    # 创建dify相关目录
    mkdir -p "$INSTALL_PATH"/volumes/app/storage
    mkdir -p "$INSTALL_PATH"/volumes/db/data
    mkdir -p "$INSTALL_PATH"/volumes/redis/data
    mkdir -p "$INSTALL_PATH"/volumes/weaviate
    mkdir -p "$INSTALL_PATH"/volumes/sandbox/dependencies
    mkdir -p "$INSTALL_PATH"/volumes/plugin_daemon
    mkdir -p "$INSTALL_PATH"/volumes/certbot/{conf,www,logs}
    
    # 设置n8n目录权限（重要：n8n需要正确的权限）
    chown -R 1000:1000 "$INSTALL_PATH"/volumes/n8n/data 2>/dev/null || true
    chmod -R 755 "$INSTALL_PATH"/volumes
    
    success "目录结构创建完成"
}

# 生成Docker Compose文件
generate_docker_compose() {
    log "生成Docker Compose配置文件..."
    
    cat > "$INSTALL_PATH/docker-compose.yml" << EOF
version: '3.8'

networks:
  aiserver_network:
    driver: bridge

services:
  # MySQL数据库
  mysql:
    image: mysql:8.0
    container_name: ${CONTAINER_PREFIX}_mysql
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: "${DB_PASSWORD}"
      MYSQL_DATABASE: dify
      MYSQL_USER: dify
      MYSQL_PASSWORD: "${DB_PASSWORD}"
    ports:
      - "${MYSQL_PORT}:3306"
    volumes:
      - ./volumes/mysql/data:/var/lib/mysql
      - ./volumes/mysql/logs:/var/log/mysql
    command: --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --default-authentication-plugin=mysql_native_password
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p${DB_PASSWORD}"]
      timeout: 20s
      retries: 10
      interval: 10s
    networks:
      - aiserver_network

  # PostgreSQL数据库
  postgres:
    image: postgres:15-alpine
    container_name: ${CONTAINER_PREFIX}_postgres
    restart: always
    environment:
      POSTGRES_DB: dify
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: "${DB_PASSWORD}"
      PGDATA: /var/lib/postgresql/data/pgdata
    ports:
      - "${POSTGRES_PORT}:5432"
    volumes:
      - ./volumes/postgres/data:/var/lib/postgresql/data
      - ./volumes/postgres/logs:/var/log/postgresql
    command: >
      postgres -c 'max_connections=100'
               -c 'shared_buffers=128MB'
               -c 'work_mem=4MB'
               -c 'maintenance_work_mem=64MB'
               -c 'effective_cache_size=4096MB'
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5
    networks:
      - aiserver_network

  # Redis缓存
  redis:
    image: redis:7-alpine
    container_name: ${CONTAINER_PREFIX}_redis
    restart: always
    ports:
      - "${REDIS_PORT}:6379"
    volumes:
      - ./volumes/redis/data:/data
    command: redis-server --appendonly yes
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
    networks:
      - aiserver_network

  # OneAPI服务
  oneapi:
    image: justsong/one-api:latest
    container_name: ${CONTAINER_PREFIX}_oneapi
    restart: always
    ports:
      - "${ONEAPI_WEB_PORT}:3000"
    environment:
      SQL_DSN: "postgres://postgres:${DB_PASSWORD}@postgres:5432/oneapi?sslmode=disable"
      REDIS_CONN_STRING: "redis://redis:6379"
      SESSION_SECRET: "oneapi-session-secret-random123456"
      TZ: "Asia/Shanghai"
    volumes:
      - ./volumes/oneapi/data:/data
      - ./logs:/app/logs
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - aiserver_network

  # Dify Sandbox
  dify_sandbox:
    image: langgenius/dify-sandbox:0.2.12
    container_name: ${CONTAINER_PREFIX}_dify_sandbox
    restart: always
    environment:
      API_KEY: dify-sandbox
      GIN_MODE: release
      WORKER_TIMEOUT: "15"
      ENABLE_NETWORK: "true"
      SANDBOX_PORT: "8194"
    volumes:
      - ./volumes/sandbox/dependencies:/dependencies
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8194/health"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - aiserver_network

  # Dify API服务
  dify_api:
    image: langgenius/dify-api:1.7.1
    container_name: ${CONTAINER_PREFIX}_dify_api
    restart: always
    environment:
      MODE: api
      LOG_LEVEL: INFO
      SECRET_KEY: dify-secret-key-random123456
      DB_USERNAME: postgres
      DB_PASSWORD: "${DB_PASSWORD}"
      DB_HOST: postgres
      DB_PORT: "5432"
      DB_DATABASE: dify
      REDIS_HOST: redis
      REDIS_PORT: "6379"
      REDIS_DB: "0"
      REDIS_PASSWORD: "${REDIS_PASSWORD}"
      CELERY_BROKER_URL: "redis://redis:6379/1"
      WEB_API_CORS_ALLOW_ORIGINS: "*"
      CONSOLE_CORS_ALLOW_ORIGINS: "*"
      STORAGE_TYPE: local
      CODE_EXECUTION_ENDPOINT: "http://dify_sandbox:8194"
      CODE_EXECUTION_API_KEY: dify-sandbox
      # 修复：明确设置API URL
      CONSOLE_API_URL: "http://${ACCESS_HOST}:${DIFY_API_PORT}"
      CONSOLE_WEB_URL: "http://${ACCESS_HOST}:${DIFY_WEB_PORT}"
      SERVICE_API_URL: "http://${ACCESS_HOST}:${DIFY_API_PORT}"
      APP_API_URL: "http://${ACCESS_HOST}:${DIFY_API_PORT}"
      APP_WEB_URL: "http://${ACCESS_HOST}:${DIFY_WEB_PORT}"
      FILES_URL: "/files"
      MIGRATION_ENABLED: "true"
      DEPLOY_ENV: PRODUCTION
      # 添加CORS相关配置
      WEB_API_CORS_ALLOW_CREDENTIALS: "true"
      CONSOLE_CORS_ALLOW_CREDENTIALS: "true"
    ports:
      - "${DIFY_API_PORT}:5001"
    volumes:
      - ./volumes/app/storage:/app/api/storage
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
      dify_sandbox:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5001/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    networks:
      - aiserver_network

  # Dify Worker服务
  dify_worker:
    image: langgenius/dify-api:1.7.1
    container_name: ${CONTAINER_PREFIX}_dify_worker
    restart: always
    environment:
      MODE: worker
      LOG_LEVEL: INFO
      SECRET_KEY: dify-secret-key-random123456
      DB_USERNAME: postgres
      DB_PASSWORD: "${DB_PASSWORD}"
      DB_HOST: postgres
      DB_PORT: "5432"
      DB_DATABASE: dify
      REDIS_HOST: redis
      REDIS_PORT: "6379"
      REDIS_DB: "0"
      REDIS_PASSWORD: "${REDIS_PASSWORD}"
      CELERY_BROKER_URL: "redis://redis:6379/1"
      STORAGE_TYPE: local
      CODE_EXECUTION_ENDPOINT: "http://dify_sandbox:8194"
      CODE_EXECUTION_API_KEY: dify-sandbox
    volumes:
      - ./volumes/app/storage:/app/api/storage
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
      dify_sandbox:
        condition: service_healthy
    networks:
      - aiserver_network

  # Dify Web服务
  dify_web:
    image: langgenius/dify-web:1.7.1
    container_name: ${CONTAINER_PREFIX}_dify_web
    restart: always
    environment:
      # 修复：明确设置前端API URL
      CONSOLE_API_URL: "http://${ACCESS_HOST}:${DIFY_API_PORT}"
      APP_API_URL: "http://${ACCESS_HOST}:${DIFY_API_PORT}"
      NEXT_TELEMETRY_DISABLED: "1"
      # 添加运行时环境变量
      NEXT_PUBLIC_API_PREFIX: "/console/api"
      NEXT_PUBLIC_PUBLIC_API_PREFIX: "/v1"
    ports:
      - "${DIFY_WEB_PORT}:3000"
    depends_on:
      dify_api:
        condition: service_healthy
    networks:
      - aiserver_network

  # n8n工作流服务
  n8n:
    image: n8nio/n8n:latest
    container_name: ${CONTAINER_PREFIX}_n8n
    restart: always
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: "5432"
      DB_POSTGRESDB_USER: postgres
      DB_POSTGRESDB_SCHEMA: public
      DB_POSTGRESDB_PASSWORD: "${DB_PASSWORD}"
      N8N_HOST: "0.0.0.0"
      N8N_PORT: "5678"
      N8N_PROTOCOL: http
      N8N_SECURE_COOKIE: "false"
      WEBHOOK_URL: "http://${ACCESS_HOST}:${N8N_WEB_PORT}/"
      GENERIC_TIMEZONE: "Asia/Shanghai"
      N8N_METRICS: "true"
      EXECUTIONS_PROCESS: main
      EXECUTIONS_MODE: regular
      N8N_LOG_LEVEL: info
      N8N_PERSONALIZATION_ENABLED: "false"
      N8N_VERSION_NOTIFICATIONS_ENABLED: "false"
      N8N_DIAGNOSTICS_ENABLED: "false"
      N8N_PUBLIC_API_DISABLED: "false"
      N8N_ENCRYPTION_KEY: "n8n-encryption-key-change-this-random-string"
      EXECUTIONS_DATA_PRUNE: "true"
      EXECUTIONS_DATA_MAX_AGE: 168
      N8N_EDITOR_BASE_URL: "http://${ACCESS_HOST}:${N8N_WEB_PORT}/"
      N8N_DISABLE_UI: "false"
    ports:
      - "${N8N_WEB_PORT}:5678"
    volumes:
      - ./volumes/n8n/data:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy
    command: start
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    networks:
      - aiserver_network

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
    depends_on:
      - dify_web
      - dify_api
      - n8n
      - oneapi
    networks:
      - aiserver_network

EOF

    success "Docker Compose配置文件生成完成"
}

# 生成Dify前端环境配置文件 - 修复版本
generate_dify_env() {
    log "生成Dify前端环境配置..."
    
    cat > "$INSTALL_PATH/config/dify-env.js" << EOF
// Dify 动态环境配置 - 修复版本
(function() {
    // 获取当前页面的协议和主机
    var protocol = window.location.protocol;
    var hostname = window.location.hostname;
    var port = window.location.port;
    
    // 构建API基础URL
    var apiBaseUrl;
    if (port && port !== '80' && port !== '443') {
        if (port === '${NGINX_PORT}') {
            // 通过nginx代理访问
            apiBaseUrl = protocol + '//' + hostname + ':' + port;
        } else if (port === '${DIFY_WEB_PORT}') {
            // 直接访问dify web端口，API使用${DIFY_API_PORT}端口
            apiBaseUrl = protocol + '//' + hostname + ':${DIFY_API_PORT}';
        } else {
            // 其他情况
            apiBaseUrl = protocol + '//' + hostname + ':${DIFY_API_PORT}';
        }
    } else {
        // 标准端口，使用当前域名
        apiBaseUrl = protocol + '//' + hostname;
    }
    
    // 设置全局环境变量
    window.NEXT_PUBLIC_API_PREFIX = '/console/api';
    window.NEXT_PUBLIC_PUBLIC_API_PREFIX = '/v1';
    window.CONSOLE_API_URL = apiBaseUrl;
    window.APP_API_URL = apiBaseUrl;
    
    console.log('Dify 环境配置已加载:', {
        baseUrl: apiBaseUrl,
        apiPrefix: window.NEXT_PUBLIC_API_PREFIX,
        publicApiPrefix: window.NEXT_PUBLIC_PUBLIC_API_PREFIX,
        currentPort: port
    });
})();
EOF
    
    success "Dify前端环境配置生成完成"
}

# 生成Nginx配置 - 修复版本
generate_nginx_config() {
    log "生成Nginx配置文件..."
    
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
    
    # 默认服务器
    server {
        listen 80 default_server;
        server_name _;
        
        # 根路径显示服务导航
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
        
        # Dify Console API代理 - 关键修复
        location /console/api/ {
            proxy_pass http://dify_api_upstream/console/api/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            # 添加CORS头
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
        
        # Dify API代理
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

    success "Nginx配置文件生成完成"
}

# 初始化数据库
init_databases() {
    log "等待数据库启动..."
    sleep 30
    
    log "初始化数据库..."
    
    # 等待PostgreSQL完全启动
    for i in {1..30}; do
        if docker exec ${CONTAINER_PREFIX}_postgres pg_isready -U postgres >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done
    
    # 创建数据库
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "CREATE DATABASE IF NOT EXISTS n8n;" 2>/dev/null || \
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "CREATE DATABASE n8n;" 2>/dev/null || true
    
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "CREATE DATABASE IF NOT EXISTS oneapi;" 2>/dev/null || \
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "CREATE DATABASE oneapi;" 2>/dev/null || true
    
    # 等待MySQL完全启动
    for i in {1..30}; do
        if docker exec ${CONTAINER_PREFIX}_mysql mysqladmin ping -h localhost -u root -p${DB_PASSWORD} --silent >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done
    
    # 创建MySQL数据库
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS oneapi_mysql CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || true
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS n8n_mysql CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || true
    
    success "数据库初始化完成"
}

# 启动服务
start_services() {
    log "启动所有服务..."
    
    cd "$INSTALL_PATH"
    
    # 启动基础服务
    log "启动基础服务（数据库和缓存）..."
    docker-compose up -d mysql postgres redis
    
    # 等待基础服务启动
    log "等待基础服务完全启动..."
    sleep 45
    
    # 初始化数据库
    init_databases
    
    # 启动应用服务
    log "启动应用服务..."
    docker-compose up -d oneapi dify_sandbox
    
    # 等待sandbox启动
    log "等待Sandbox服务启动..."
    sleep 20
    
    # 启动dify服务
    log "启动Dify服务..."
    docker-compose up -d dify_api dify_worker
    
    # 等待API服务启动
    log "等待API服务启动..."
    sleep 30
    
    # 启动前端服务
    log "启动前端和代理服务..."
    docker-compose up -d dify_web n8n nginx
    
    # 最终等待
    log "等待所有服务完全启动..."
    sleep 30
    
    success "所有服务启动完成"
}

# 检查服务状态
check_services() {
    log "检查服务状态..."
    
    cd "$INSTALL_PATH"
    
    echo -e "\n${BLUE}=== 服务状态 ===${NC}"
    docker-compose ps
    
    echo -e "\n${BLUE}=== 服务健康检查 ===${NC}"
    # 检查各服务是否响应
    services_status=""
    
    # 检查MySQL
    if docker exec ${CONTAINER_PREFIX}_mysql mysqladmin ping -h localhost -u root -p${DB_PASSWORD} --silent >/dev/null 2>&1; then
        services_status+="✅ MySQL: 运行正常\n"
    else
        services_status+="❌ MySQL: 运行异常\n"
    fi
    
    # 检查PostgreSQL
    if docker exec ${CONTAINER_PREFIX}_postgres pg_isready -U postgres >/dev/null 2>&1; then
        services_status+="✅ PostgreSQL: 运行正常\n"
    else
        services_status+="❌ PostgreSQL: 运行异常\n"
    fi
    
    # 检查Redis
    if docker exec ${CONTAINER_PREFIX}_redis redis-cli ping >/dev/null 2>&1; then
        services_status+="✅ Redis: 运行正常\n"
    else
        services_status+="❌ Redis: 运行异常\n"
    fi
    
    echo -e "$services_status"
    
    echo -e "\n${BLUE}=== 服务访问地址 ===${NC}"
    success "统一入口: http://${ACCESS_HOST}:${NGINX_PORT}"
    success "Dify (直接): http://${ACCESS_HOST}:${DIFY_WEB_PORT}"
    success "Dify (代理): http://${ACCESS_HOST}:${NGINX_PORT}/dify"
    success "n8n (直接): http://${ACCESS_HOST}:${N8N_WEB_PORT}"
    success "n8n (代理): http://${ACCESS_HOST}:${NGINX_PORT}/n8n"
    success "OneAPI (直接): http://${ACCESS_HOST}:${ONEAPI_WEB_PORT}"
    success "OneAPI (代理): http://${ACCESS_HOST}:${NGINX_PORT}/oneapi"
    
    echo -e "\n${BLUE}=== 数据库连接信息 ===${NC}"
    success "MySQL: ${ACCESS_HOST}:${MYSQL_PORT} (用户:root, 密码:${DB_PASSWORD})"
    success "PostgreSQL: ${ACCESS_HOST}:${POSTGRES_PORT} (用户:postgres, 密码:${DB_PASSWORD})"
    success "Redis: ${ACCESS_HOST}:${REDIS_PORT}"
}

# 生成启动脚本
generate_control_scripts() {
    log "生成控制脚本..."
    
    # 启动脚本
    cat > "$INSTALL_PATH/start.sh" << EOF
#!/bin/bash
cd "\$(dirname "\$0")"
echo "正在启动AI服务集群..."
docker-compose up -d
echo ""
echo "服务启动完成，访问地址："
echo "统一入口: http://${ACCESS_HOST}:${NGINX_PORT}"
echo "Dify: http://${ACCESS_HOST}:${DIFY_WEB_PORT} (推荐通过代理访问)"
echo "n8n: http://${ACCESS_HOST}:${N8N_WEB_PORT}"
echo "OneAPI: http://${ACCESS_HOST}:${ONEAPI_WEB_PORT}"
echo ""
echo "等待约2分钟服务完全启动后再访问"
EOF

    # 停止脚本
    cat > "$INSTALL_PATH/stop.sh" << EOF
#!/bin/bash
cd "\$(dirname "\$0")"
echo "正在停止AI服务集群..."
docker-compose down
echo "所有服务已停止"
EOF

    # 重启脚本
    cat > "$INSTALL_PATH/restart.sh" << EOF
#!/bin/bash
cd "\$(dirname "\$0")"
echo "正在重启AI服务集群..."
docker-compose down
sleep 5
docker-compose up -d
echo "所有服务已重启"
echo ""
echo "等待约2分钟服务完全启动后再访问"
EOF

    # 查看日志脚本
    cat > "$INSTALL_PATH/logs.sh" << EOF
#!/bin/bash
cd "\$(dirname "\$0")"
if [ -z "\$1" ]; then
    echo "查看所有服务日志..."
    docker-compose logs -f --tail=100
else
    echo "查看服务 \$1 的日志..."
    docker-compose logs -f --tail=100 "\$1"
fi
EOF

    # 服务状态检查脚本
    cat > "$INSTALL_PATH/status.sh" << EOF
#!/bin/bash
cd "\$(dirname "\$0")"
echo "=== 容器状态 ==="
docker-compose ps
echo ""
echo "=== 服务访问地址 ==="
echo "统一入口: http://${ACCESS_HOST}:${NGINX_PORT}"
echo "Dify: http://${ACCESS_HOST}:${DIFY_WEB_PORT}"
echo "n8n: http://${ACCESS_HOST}:${N8N_WEB_PORT}"
echo "OneAPI: http://${ACCESS_HOST}:${ONEAPI_WEB_PORT}"
EOF

    # 数据库管理脚本
    cat > "$INSTALL_PATH/db.sh" << EOF
#!/bin/bash
cd "\$(dirname "\$0")"

case "\$1" in
    mysql)
        docker exec -it ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD}
        ;;
    postgres)
        docker exec -it ${CONTAINER_PREFIX}_postgres psql -U postgres
        ;;
    redis)
        docker exec -it ${CONTAINER_PREFIX}_redis redis-cli
        ;;
    *)
        echo "用法: \$0 {mysql|postgres|redis}"
        echo "mysql    - 连接到MySQL数据库"
        echo "postgres - 连接到PostgreSQL数据库"
        echo "redis    - 连接到Redis数据库"
        ;;
esac
EOF

    # n8n修复脚本
    cat > "$INSTALL_PATH/fix_n8n.sh" << EOF
#!/bin/bash
cd "\$(dirname "\$0")"
echo "修复n8n安全cookie问题..."
docker-compose stop n8n
docker-compose up -d n8n
echo "n8n服务已重启，请稍等片刻后访问: http://${ACCESS_HOST}:${N8N_WEB_PORT}"
EOF

    # 域名配置更新脚本
    cat > "$INSTALL_PATH/update_domain.sh" << EOF
#!/bin/bash
cd "\$(dirname "\$0")"

if [ -z "\$1" ]; then
    echo "用法: \$0 <域名>"
    echo "示例: \$0 your-domain.com"
    exit 1
fi

NEW_DOMAIN="\$1"
echo "更新域名配置为: \$NEW_DOMAIN"

# 更新docker-compose.yml中的WEBHOOK_URL
sed -i "s|WEBHOOK_URL:.*|WEBHOOK_URL: \"http://\${NEW_DOMAIN}:${N8N_WEB_PORT}/\"|" docker-compose.yml
sed -i "s|N8N_EDITOR_BASE_URL:.*|N8N_EDITOR_BASE_URL: \"http://\${NEW_DOMAIN}:${N8N_WEB_PORT}/\"|" docker-compose.yml

# 重启相关服务
docker-compose up -d n8n nginx

echo "域名配置已更新并重启相关服务"
echo "新的访问地址:"
echo "统一入口: http://\${NEW_DOMAIN}:${NGINX_PORT}"
echo "n8n: http://\${NEW_DOMAIN}:${N8N_WEB_PORT}"
EOF

    # Nginx配置修复脚本
    cat > "$INSTALL_PATH/fix_nginx.sh" << EOF
#!/bin/bash
cd "\$(dirname "\$0")"
echo "修复Nginx配置并重启服务..."

# 检查nginx配置语法
docker-compose exec nginx nginx -t
if [ \$? -ne 0 ]; then
    echo "Nginx配置有语法错误，正在重新生成..."
    # 重新生成简化的nginx配置
    cat > config/nginx.conf << 'NGINX_EOF'
events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    
    sendfile on;
    keepalive_timeout 65;
    client_max_body_size 100M;
    
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
        listen 80;
        server_name _;
        
        location = / {
            return 200 '<html><body><h1>AI服务集群</h1><p><a href="/dify/">Dify</a> | <a href="/n8n/">n8n</a> | <a href="/oneapi/">OneAPI</a></p></body></html>';
            add_header Content-Type text/html;
        }
        
        location /dify/ {
            rewrite ^/dify/(.*) /\$1 break;
            proxy_pass http://dify_web_upstream;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
        
        location /dify {
            return 301 /dify/;
        }
        
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
        
        location /api/ {
            proxy_pass http://dify_api_upstream/;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
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
        
        location /n8n/ {
            rewrite ^/n8n/(.*) /\$1 break;
            proxy_pass http://n8n_upstream;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Connection "upgrade";
            proxy_set_header Upgrade \$http_upgrade;
        }
        
        location /n8n {
            return 301 /n8n/;
        }
        
        location /oneapi/ {
            rewrite ^/oneapi/(.*) /\$1 break;
            proxy_pass http://oneapi_upstream;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
        
        location /oneapi {
            return 301 /oneapi/;
        }
    }
}
NGINX_EOF
fi

# 重启nginx服务
docker-compose up -d nginx
echo "Nginx服务已重启"
echo "访问地址: http://\$(hostname -I | awk '{print \$1}'):${NGINX_PORT}"
EOF

    # Dify修复脚本
    cat > "$INSTALL_PATH/fix_dify_api.sh" << EOF
#!/bin/bash
cd "\$(dirname "\$0")"
echo "修复Dify API连接问题..."

# 重启dify相关服务
docker-compose stop dify_web dify_api dify_worker
sleep 5

# 先启动API和Worker
docker-compose up -d dify_api dify_worker
echo "等待API服务启动..."
sleep 30

# 再启动Web
docker-compose up -d dify_web
echo "等待Web服务启动..."
sleep 15

echo "Dify服务已重启"
echo "请访问: http://${ACCESS_HOST}:${DIFY_WEB_PORT}"
echo "或代理地址: http://${ACCESS_HOST}:${NGINX_PORT}/dify"

# 测试API连接
echo ""
echo "测试API连接..."
curl -s -o /dev/null -w "HTTP状态码: %{http_code}" http://localhost:${DIFY_API_PORT}/health && echo " - API服务正常" || echo " - API服务异常"
EOF

    chmod +x "$INSTALL_PATH"/*.sh
    
    success "控制脚本生成完成"
}

# 主函数
main() {
    echo -e "${GREEN}"
    echo "=========================================="
    echo "     AI服务集群一键安装脚本"
    echo "     Dify + n8n + OneAPI"
    echo "     支持域名访问，解决跨域问题"
    echo "=========================================="
    echo -e "${NC}"
    
    get_server_config
    check_docker
    cleanup_environment
    check_ports
    create_directories
    generate_docker_compose
    generate_dify_env
    generate_nginx_config
    start_services
    check_services
    generate_control_scripts
    
    echo -e "\n${GREEN}=========================================="
    echo "           安装完成！"
    echo "=========================================="
    echo -e "${NC}"
    echo "安装目录: $INSTALL_PATH"
    echo ""
    echo "🌟 推荐访问方式（解决跨域问题）:"
    echo "  - 服务导航页: http://${ACCESS_HOST}:${NGINX_PORT}"
    echo "  - Dify (代理): http://${ACCESS_HOST}:${NGINX_PORT}/dify"
    echo "  - n8n (代理): http://${ACCESS_HOST}:${NGINX_PORT}/n8n"  
    echo "  - OneAPI (代理): http://${ACCESS_HOST}:${NGINX_PORT}/oneapi"
    echo ""
    echo "📱 直接访问地址:"
    echo "  - Dify Web界面: http://${ACCESS_HOST}:${DIFY_WEB_PORT}"
    echo "  - n8n Web界面: http://${ACCESS_HOST}:${N8N_WEB_PORT}"
    echo "  - OneAPI Web界面: http://${ACCESS_HOST}:${ONEAPI_WEB_PORT}"
    echo ""
    echo "🛠️  管理命令:"
    echo "  - 启动服务: cd $INSTALL_PATH && ./start.sh"
    echo "  - 停止服务: cd $INSTALL_PATH && ./stop.sh"
    echo "  - 重启服务: cd $INSTALL_PATH && ./restart.sh"
    echo "  - 查看日志: cd $INSTALL_PATH && ./logs.sh [服务名]"
    echo "  - 检查状态: cd $INSTALL_PATH && ./status.sh"
    echo "  - 数据库管理: cd $INSTALL_PATH && ./db.sh {mysql|postgres|redis}"
    echo "  - 修复n8n: cd $INSTALL_PATH && ./fix_n8n.sh"
    echo "  - 修复nginx: cd $INSTALL_PATH && ./fix_nginx.sh"
    echo "  - 修复Dify API: cd $INSTALL_PATH && ./fix_dify_api.sh"
    echo "  - 更新域名: cd $INSTALL_PATH && ./update_domain.sh <域名>"
    echo ""
    echo "🗄️  数据库信息:"
    echo "  - MySQL: ${ACCESS_HOST}:${MYSQL_PORT} (root/${DB_PASSWORD})"
    echo "  - PostgreSQL: ${ACCESS_HOST}:${POSTGRES_PORT} (postgres/${DB_PASSWORD})"
    echo "  - Redis: ${ACCESS_HOST}:${REDIS_PORT}"
    echo ""
    echo "📋 常用docker-compose命令（在 $INSTALL_PATH 目录下执行）:"
    echo "  - docker-compose ps                    # 查看服务状态"
    echo "  - docker-compose logs -f [服务名]       # 查看实时日志"
    echo "  - docker-compose restart [服务名]       # 重启特定服务"
    echo "  - docker-compose exec [服务名] bash     # 进入容器"
    echo ""
    echo "🔧 跨域问题解决方案:"
    echo "  1. 优先使用Nginx代理访问（http://${ACCESS_HOST}:${NGINX_PORT}/dify）"
    echo "  2. 如需要修改域名，运行: ./update_domain.sh <新域名>"
    echo "  3. Dify前端已配置自动检测当前域名，支持动态API地址"
    echo "  4. 如nginx有问题，运行: ./fix_nginx.sh 修复配置"
    echo "  5. 如Dify白屏，运行: ./fix_dify_api.sh 修复API连接"
    echo ""
    warning "首次启动可能需要几分钟时间，请耐心等待服务完全启动。"
    warning "如果遇到跨域问题，请使用Nginx代理访问地址。"
    warning "建议等待2-3分钟后再访问web界面，确保所有服务完全启动。"
    warning "如果Dify出现白屏，请运行 ./fix_dify_api.sh 修复API连接问题。"
    
    if [ -n "$DOMAIN_NAME" ]; then
        echo -e "\n🌐 域名配置已启用: $DOMAIN_NAME"
        echo "   可通过域名访问所有服务，无需记忆IP地址"
    else
        echo -e "\n💡 提示: 如有域名，可运行以下命令启用域名访问:"
        echo "   cd $INSTALL_PATH && ./update_domain.sh your-domain.com"
    fi
}

# 运行主函数
main "$@"
