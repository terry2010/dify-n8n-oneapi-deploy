#!/bin/bash

# =========================================================
# Dify系统安装模块
# =========================================================

# 安装Dify系统
install_dify() {
    log "开始安装Dify系统..."

    # 生成Dify配置
    generate_dify_compose

    # 启动Dify服务
    start_dify_services

    success "Dify系统安装完成"
}

# 生成Dify Docker Compose配置
generate_dify_compose() {
    log "生成Dify配置..."

    # 获取PostgreSQL和Redis容器IP地址
    local POSTGRES_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${CONTAINER_PREFIX}_postgres 2>/dev/null || echo "172.21.0.2")
    local REDIS_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${CONTAINER_PREFIX}_redis 2>/dev/null || echo "172.21.0.3")
    log "PostgreSQL IP地址: $POSTGRES_IP"
    log "Redis IP地址: $REDIS_IP"

    cat > "$INSTALL_PATH/docker-compose-dify.yml" << EOF
version: '3.8'

networks:
  aiserver_network:
    external: true

services:
  # Dify Sandbox
  dify_sandbox:
    image: langgenius/dify-sandbox:0.2.12
    container_name: ${CONTAINER_PREFIX}_dify_sandbox
    restart: always
    environment:
      API_KEY: dify-sandbox
      GIN_MODE: release
      WORKER_TIMEOUT: "30"
      ENABLE_NETWORK: "true"
      SANDBOX_PORT: "8194"
    volumes:
      - ./volumes/sandbox/dependencies:/dependencies
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8194/health"]
      interval: 30s
      timeout: 30s
      retries: 10
      start_period: 60s
    networks:
      - aiserver_network

  # Dify API服务
  dify_api:
    image: langgenius/dify-api:1.7.1
    container_name: ${CONTAINER_PREFIX}_dify_api
    restart: always
    environment:
      MODE: api
      LOG_LEVEL: DEBUG
      SECRET_KEY: dify-secret-key-random123456
      # 使用IP地址而非容器名
      DB_USERNAME: postgres
      DB_PASSWORD: "${DB_PASSWORD}"
      DB_HOST: $POSTGRES_IP
      DB_PORT: "5432"
      DB_DATABASE: dify
      # Redis配置使用IP地址
      REDIS_HOST: $REDIS_IP
      REDIS_PORT: "6379"
      REDIS_DB: "0"
      REDIS_PASSWORD: "${REDIS_PASSWORD}"
      CELERY_BROKER_URL: "redis://$REDIS_IP:6379/1"
      # 增加数据库连接重试配置
      DB_POOL_RECYCLE: "3600"
      DB_POOL_SIZE: "20"
      DB_MAX_OVERFLOW: "10"
      DB_POOL_TIMEOUT: "60"
      DB_POOL_PRE_PING: "true"
      # 其他配置
      WEB_API_CORS_ALLOW_ORIGINS: "*"
      CONSOLE_CORS_ALLOW_ORIGINS: "*"
      STORAGE_TYPE: local
      CODE_EXECUTION_ENDPOINT: "http://${CONTAINER_PREFIX}_dify_sandbox:8194"
      CODE_EXECUTION_API_KEY: dify-sandbox
      CONSOLE_API_URL: "${DIFY_URL}"
      CONSOLE_WEB_URL: "${DIFY_URL}"
      SERVICE_API_URL: "${DIFY_URL}"
      APP_API_URL: "${DIFY_URL}"
      APP_WEB_URL: "${DIFY_URL}"
      FILES_URL: "/files"
      MIGRATION_ENABLED: "true"
      DEPLOY_ENV: PRODUCTION
      WEB_API_CORS_ALLOW_CREDENTIALS: "true"
      CONSOLE_CORS_ALLOW_CREDENTIALS: "true"
    ports:
      - "${DIFY_API_PORT}:5001"
    volumes:
      - ./volumes/app/storage:/app/api/storage
    depends_on:
      - dify_sandbox
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5001/health"]
      interval: 30s
      timeout: 30s
      retries: 10
      start_period: 180s
    networks:
      - aiserver_network

  # Dify Worker服务
  dify_worker:
    image: langgenius/dify-api:1.7.1
    container_name: ${CONTAINER_PREFIX}_dify_worker
    restart: always
    environment:
      MODE: worker
      LOG_LEVEL: DEBUG
      SECRET_KEY: dify-secret-key-random123456
      # 使用IP地址而非容器名
      DB_USERNAME: postgres
      DB_PASSWORD: "${DB_PASSWORD}"
      DB_HOST: $POSTGRES_IP
      DB_PORT: "5432"
      DB_DATABASE: dify
      # Redis配置使用IP地址
      REDIS_HOST: $REDIS_IP
      REDIS_PORT: "6379"
      REDIS_DB: "0"
      REDIS_PASSWORD: "${REDIS_PASSWORD}"
      CELERY_BROKER_URL: "redis://$REDIS_IP:6379/1"
      # 增加数据库连接重试配置
      DB_POOL_RECYCLE: "3600"
      DB_POOL_SIZE: "20"
      DB_MAX_OVERFLOW: "10"
      DB_POOL_TIMEOUT: "60"
      DB_POOL_PRE_PING: "true"
      # 其他配置
      STORAGE_TYPE: local
      CODE_EXECUTION_ENDPOINT: "http://${CONTAINER_PREFIX}_dify_sandbox:8194"
      CODE_EXECUTION_API_KEY: dify-sandbox
    volumes:
      - ./volumes/app/storage:/app/api/storage
    depends_on:
      - dify_sandbox
    networks:
      - aiserver_network

  # Dify Web服务
  dify_web:
    image: langgenius/dify-web:1.7.1
    container_name: ${CONTAINER_PREFIX}_dify_web
    restart: always
    environment:
      CONSOLE_API_URL: "${DIFY_URL}"
      APP_API_URL: "${DIFY_URL}"
      NEXT_TELEMETRY_DISABLED: "1"
      NEXT_PUBLIC_API_PREFIX: "/console/api"
      NEXT_PUBLIC_PUBLIC_API_PREFIX: "/v1"$([ "$USE_DOMAIN" = false ] && echo "
    ports:
      - \"${DIFY_WEB_PORT}:3000\"")
    depends_on:
      - dify_api
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000"]
      interval: 30s
      timeout: 30s
      retries: 10
      start_period: 120s
    networks:
      - aiserver_network
EOF

    success "Dify配置生成完成"
}

# 启动Dify服务
start_dify_services() {
    log "启动Dify服务..."

    cd "$INSTALL_PATH"
    
    # 检查数据库和Redis服务是否已启动
    log "检查PostgreSQL和Redis服务..."
    if ! docker exec ${CONTAINER_PREFIX}_postgres pg_isready -U postgres &>/dev/null; then
        warning "PostgreSQL服务未就绪，尝试重启..."
        docker restart ${CONTAINER_PREFIX}_postgres
        sleep 10
        wait_for_service "postgres" "pg_isready -U postgres" 120
    fi
    
    if ! docker exec ${CONTAINER_PREFIX}_redis redis-cli ping &>/dev/null; then
        warning "Redis服务未就绪，尝试重启..."
        docker restart ${CONTAINER_PREFIX}_redis
        sleep 10
        wait_for_service "redis" "redis-cli ping" 60
    fi
    
    # 创建Dify数据库（如果不存在）
    log "确保Dify数据库存在..."
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "SELECT 1 FROM pg_database WHERE datname = 'dify';" | grep -q 1 || \
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "CREATE DATABASE dify WITH ENCODING 'UTF8' LC_COLLATE='en_US.utf8' LC_CTYPE='en_US.utf8';" 2>/dev/null

    # 先启动Sandbox
    log "启动Dify Sandbox..."
    COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-dify.yml up -d  dify_sandbox
    wait_for_service "dify_sandbox" "curl -f http://localhost:8194/health" 90
    
    # 如果Sandbox启动失败，尝试重启
    if [ $? -ne 0 ]; then
        warning "Dify Sandbox启动超时，尝试重启..."
        docker restart ${CONTAINER_PREFIX}_dify_sandbox
        sleep 20
        wait_for_service "dify_sandbox" "curl -f http://localhost:8194/health" 60
    fi

    # 启动API和Worker
    log "启动Dify API和Worker..."
    COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-dify.yml up -d dify_api dify_worker
    wait_for_service "dify_api" "curl -f http://localhost:5001/health" 180
    
    # 如果API启动失败，尝试重启
    if [ $? -ne 0 ]; then
        warning "Dify API启动超时，尝试重启..."
        docker restart ${CONTAINER_PREFIX}_dify_api ${CONTAINER_PREFIX}_dify_worker
        sleep 30
        wait_for_service "dify_api" "curl -f http://localhost:5001/health" 120
    fi
    
    # 检查API日志
    log "检查Dify API日志..."
    docker logs ${CONTAINER_PREFIX}_dify_api --tail 20

    # 启动Web服务
    log "启动Dify Web服务..."
    COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-dify.yml up -d dify_web
    sleep 30
    
    # 检查Web服务是否启动
    if ! docker ps | grep -q ${CONTAINER_PREFIX}_dify_web; then
        warning "Dify Web服务启动失败，尝试重启..."
        docker restart ${CONTAINER_PREFIX}_dify_web
        sleep 20
    fi

    success "Dify服务启动完成"
}

# 备份Dify数据
backup_dify_data() {
    local backup_dir="$1"

    log "备份Dify数据..."

    mkdir -p "$backup_dir"

    # 备份应用存储数据
    if [ -d "$INSTALL_PATH/volumes/app" ]; then
        cp -r "$INSTALL_PATH/volumes/app" "$backup_dir/" 2>/dev/null
        success "Dify应用数据备份完成"
    fi

    # 备份沙箱依赖
    if [ -d "$INSTALL_PATH/volumes/sandbox" ]; then
        cp -r "$INSTALL_PATH/volumes/sandbox" "$backup_dir/" 2>/dev/null
        success "Dify沙箱数据备份完成"
    fi

    # 备份配置文件
    if [ -d "$INSTALL_PATH/volumes/dify" ]; then
        cp -r "$INSTALL_PATH/volumes/dify" "$backup_dir/" 2>/dev/null
        success "Dify配置数据备份完成"
    fi
}

# 恢复Dify数据
restore_dify_data() {
    local backup_dir="$1"

    log "恢复Dify数据..."

    # 停止Dify服务
    docker-compose -f docker-compose-dify.yml stop 2>/dev/null || true

    # 恢复应用数据
    if [ -d "$backup_dir/app" ]; then
        rm -rf "$INSTALL_PATH/volumes/app" 2>/dev/null
        cp -r "$backup_dir/app" "$INSTALL_PATH/volumes/" 2>/dev/null
        success "Dify应用数据恢复完成"
    fi

    # 恢复沙箱数据
    if [ -d "$backup_dir/sandbox" ]; then
        rm -rf "$INSTALL_PATH/volumes/sandbox" 2>/dev/null
        cp -r "$backup_dir/sandbox" "$INSTALL_PATH/volumes/" 2>/dev/null
        success "Dify沙箱数据恢复完成"
    fi

    # 恢复配置数据
    if [ -d "$backup_dir/dify" ]; then
        rm -rf "$INSTALL_PATH/volumes/dify" 2>/dev/null
        cp -r "$backup_dir/dify" "$INSTALL_PATH/volumes/" 2>/dev/null
        success "Dify配置数据恢复完成"
    fi

    # 重启Dify服务
    start_dify_services
}

# 更新Dify配置
update_dify_config() {
    log "更新Dify配置..."

    # 重新生成配置
    generate_dify_compose

    # 重启服务
    docker-compose -f docker-compose-dify.yml restart

    success "Dify配置更新完成"
}