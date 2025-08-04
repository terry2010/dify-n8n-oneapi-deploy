#!/bin/bash

# =========================================================
# n8n系统安装模块
# =========================================================

# 安装n8n系统
install_n8n() {
    log "开始安装n8n系统..."

    # 生成n8n配置
    generate_n8n_compose

    # 启动n8n服务
    start_n8n_services

    success "n8n系统安装完成"
}

# 生成n8n Docker Compose配置
generate_n8n_compose() {
    log "生成n8n配置..."

    cat > "$INSTALL_PATH/docker-compose-n8n.yml" << EOF
version: '3.8'

networks:
  aiserver_network:
    external: true

services:
  # n8n工作流服务
  n8n:
    image: n8nio/n8n:latest
    container_name: ${CONTAINER_PREFIX}_n8n
    restart: always
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_DATABASE: n8n
      DB_POSTGRESDB_HOST: ${CONTAINER_PREFIX}_postgres
      DB_POSTGRESDB_PORT: "5432"
      DB_POSTGRESDB_USER: postgres
      DB_POSTGRESDB_SCHEMA: public
      DB_POSTGRESDB_PASSWORD: "${DB_PASSWORD}"
      N8N_HOST: "0.0.0.0"
      N8N_PORT: "5678"$(if [ "$USE_DOMAIN" = true ]; then
        if [ "$NGINX_PORT" = "443" ]; then
            echo "
      N8N_PROTOCOL: https
      N8N_SECURE_COOKIE: \"true\""
        else
            echo "
      N8N_PROTOCOL: http
      N8N_SECURE_COOKIE: \"false\""
        fi
        echo "
      WEBHOOK_URL: \"${N8N_URL}/\"
      N8N_EDITOR_BASE_URL: \"${N8N_URL}/\""
    else
        echo "
      N8N_PROTOCOL: http
      N8N_SECURE_COOKIE: \"false\"
      WEBHOOK_URL: \"http://$SERVER_IP:$N8N_WEB_PORT/\"
      N8N_EDITOR_BASE_URL: \"http://$SERVER_IP:$N8N_WEB_PORT/\""
    fi)
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
      N8N_DISABLE_UI: "false"$([ "$USE_DOMAIN" = false ] && echo "
    ports:
      - \"${N8N_WEB_PORT}:5678\"")
    volumes:
      - ./volumes/n8n/data:/home/node/.n8n
    command: start
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:5678/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    networks:
      - aiserver_network
EOF

    success "n8n配置生成完成"
}

# 启动n8n服务
start_n8n_services() {
    log "启动n8n服务..."

    cd "$INSTALL_PATH"

    # 确保n8n数据目录权限正确
    ensure_directory "$INSTALL_PATH/volumes/n8n/data" "1000:1000" "755"

    # 启动n8n服务
    COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-n8n.yml up -d n8n --remove-orphans
    wait_for_service "n8n" "wget --quiet --tries=1 --spider http://localhost:5678/healthz" 60

    success "n8n服务启动完成"
}

# 备份n8n数据
backup_n8n_data() {
    local backup_dir="$1"

    log "备份n8n数据..."

    mkdir -p "$backup_dir"

    # 备份n8n数据目录
    if [ -d "$INSTALL_PATH/volumes/n8n" ]; then
        cp -r "$INSTALL_PATH/volumes/n8n" "$backup_dir/" 2>/dev/null
        success "n8n数据备份完成"
    fi
}

# 恢复n8n数据
restore_n8n_data() {
    local backup_dir="$1"

    log "恢复n8n数据..."

    # 停止n8n服务
    docker-compose -f docker-compose-n8n.yml stop 2>/dev/null || true

    # 恢复n8n数据
    if [ -d "$backup_dir/n8n" ]; then
        rm -rf "$INSTALL_PATH/volumes/n8n" 2>/dev/null
        cp -r "$backup_dir/n8n" "$INSTALL_PATH/volumes/" 2>/dev/null
        # 重新设置权限
        chown -R 1000:1000 "$INSTALL_PATH/volumes/n8n/data" 2>/dev/null || true
        success "n8n数据恢复完成"
    fi

    # 重启n8n服务
    start_n8n_services
}

# 更新n8n配置
update_n8n_config() {
    log "更新n8n配置..."

    # 重新生成配置
    generate_n8n_compose

    # 重启服务
    docker-compose -f docker-compose-n8n.yml restart

    success "n8n配置更新完成"
}