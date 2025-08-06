#!/bin/bash

# =========================================================
# OneAPI系统安装模块
# =========================================================

# 安装OneAPI系统
install_oneapi() {
    log "开始安装OneAPI系统..."

    # 生成OneAPI配置
    generate_oneapi_compose

    # 启动OneAPI服务
    start_oneapi_services

    success "OneAPI系统安装完成"
}

# 生成OneAPI Docker Compose配置
generate_oneapi_compose() {
    log "生成OneAPI配置..."

    # 获取PostgreSQL和Redis容器IP地址 - 确保去除空格
    local POSTGRES_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${CONTAINER_PREFIX}_postgres 2>/dev/null | tr -d '[:space:]' || echo "172.21.0.2")
    local REDIS_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${CONTAINER_PREFIX}_redis 2>/dev/null | tr -d '[:space:]' || echo "172.21.0.3")
    log "数据库连接信息 - PostgreSQL IP: $POSTGRES_IP, Redis IP: $REDIS_IP"

    cat > "$INSTALL_PATH/docker-compose-oneapi.yml" << EOF
version: '3.8'

networks:
  aiserver_network:
    external: true

services:
  # OneAPI服务
  oneapi:
    image: justsong/one-api:latest
    container_name: ${CONTAINER_PREFIX}_oneapi
    restart: always$([ "$USE_DOMAIN" = false ] && echo "
    ports:
      - \"${ONEAPI_WEB_PORT}:3000\"")
    environment:
      # 使用IP地址而非容器名，确保无空格
      SQL_DSN: "postgres://postgres:${DB_PASSWORD}@${POSTGRES_IP}:5432/oneapi?sslmode=disable"
      REDIS_CONN_STRING: "redis://${REDIS_IP}:6379"
      SESSION_SECRET: "oneapi-session-secret-random123456"
      TZ: "Asia/Shanghai"
      # 增加调试日志
      LOG_LEVEL: "debug"
    volumes:
      - ./volumes/oneapi/data:/data
      - ./logs:/app/logs
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 30s
      timeout: 30s
      retries: 15
      start_period: 180s
    networks:
      - aiserver_network
EOF

    success "OneAPI配置生成完成"
}

# 启动OneAPI服务
start_oneapi_services() {
    log "启动OneAPI服务..."

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
    
    # 创建OneAPI数据库（如果不存在）
    log "确保OneAPI数据库存在..."
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "SELECT 1 FROM pg_database WHERE datname = 'oneapi';" | grep -q 1 || \
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "CREATE DATABASE oneapi WITH ENCODING 'UTF8' LC_COLLATE='en_US.utf8' LC_CTYPE='en_US.utf8';" 2>/dev/null

    # 启动OneAPI服务
    log "启动OneAPI服务..."
    COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-oneapi.yml up -d  oneapi
    sleep 30
    
    # 检查服务状态
    if docker ps --format "table {{.Names}}" | grep -q "${CONTAINER_PREFIX}_oneapi"; then
        log "检查OneAPI容器日志..."
        docker logs ${CONTAINER_PREFIX}_oneapi --tail 20
        
        # 检查服务是否响应
        if curl -s -o /dev/null -w "%{http_code}" http://localhost:${ONEAPI_WEB_PORT}/health 2>/dev/null | grep -q "200"; then
            success "OneAPI服务启动并响应正常"
        else
            warning "OneAPI服务已启动但可能未响应，尝试重启..."
            docker restart ${CONTAINER_PREFIX}_oneapi
            sleep 20
            if curl -s -o /dev/null -w "%{http_code}" http://localhost:${ONEAPI_WEB_PORT}/health 2>/dev/null | grep -q "200"; then
                success "OneAPI服务重启后响应正常"
            else
                warning "OneAPI服务可能仍然有问题，请检查日志"
            fi
        fi
    else
        warning "OneAPI服务启动失败，尝试重启..."
        docker-compose -f docker-compose-oneapi.yml up -d --force-recreate oneapi
        sleep 20
        if docker ps --format "table {{.Names}}" | grep -q "${CONTAINER_PREFIX}_oneapi"; then
            success "OneAPI服务重启成功"
        else
            error "OneAPI服务启动失败，请检查日志"
        fi
    fi
}

# 备份OneAPI数据
backup_oneapi_data() {
    local backup_dir="$1"

    log "备份OneAPI数据..."

    mkdir -p "$backup_dir"

    # 备份OneAPI数据目录
    if [ -d "$INSTALL_PATH/volumes/oneapi" ]; then
        cp -r "$INSTALL_PATH/volumes/oneapi" "$backup_dir/" 2>/dev/null
        success "OneAPI数据备份完成"
    fi
}

# 恢复OneAPI数据
restore_oneapi_data() {
    local backup_dir="$1"

    log "恢复OneAPI数据..."

    # 停止OneAPI服务
    docker-compose -f docker-compose-oneapi.yml stop 2>/dev/null || true

    # 恢复OneAPI数据
    if [ -d "$backup_dir/oneapi" ]; then
        rm -rf "$INSTALL_PATH/volumes/oneapi" 2>/dev/null
        cp -r "$backup_dir/oneapi" "$INSTALL_PATH/volumes/" 2>/dev/null
        success "OneAPI数据恢复完成"
    fi

    # 重启OneAPI服务
    start_oneapi_services
}

# 更新OneAPI配置
update_oneapi_config() {
    log "更新OneAPI配置..."

    # 重新生成配置
    generate_oneapi_compose

    # 重启服务
    docker-compose -f docker-compose-oneapi.yml restart

    success "OneAPI配置更新完成"
}