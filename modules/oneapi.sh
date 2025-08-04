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
      SQL_DSN: "postgres://postgres:${DB_PASSWORD}@postgres:5432/oneapi?sslmode=disable"
      REDIS_CONN_STRING: "redis://redis:6379"
      SESSION_SECRET: "oneapi-session-secret-random123456"
      TZ: "Asia/Shanghai"
    volumes:
      - ./volumes/oneapi/data:/data
      - ./logs:/app/logs
    networks:
      - aiserver_network
EOF

    success "OneAPI配置生成完成"
}

# 启动OneAPI服务
start_oneapi_services() {
    log "启动OneAPI服务..."

    cd "$INSTALL_PATH"

    # 启动OneAPI服务
    docker-compose -f docker-compose-oneapi.yml up -d oneapi
    sleep 20

    # 检查服务状态
    if docker ps --format "table {{.Names}}" | grep -q "${CONTAINER_PREFIX}_oneapi"; then
        success "OneAPI服务启动完成"
    else
        warning "OneAPI服务可能启动失败，请检查日志"
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