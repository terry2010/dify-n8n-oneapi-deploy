#!/bin/bash

# =========================================================
# 数据库模块
# =========================================================

# 安装所有数据库
install_databases() {
    log "开始安装数据库服务..."

    # 创建数据库配置
    generate_database_compose

    # 启动数据库服务
    start_database_services

    # 初始化数据库
    initialize_databases

    success "数据库服务安装完成"
}

# 生成数据库Docker Compose配置
generate_database_compose() {
    log "生成数据库配置..."

    cat > "$INSTALL_PATH/docker-compose-db.yml" << EOF
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
EOF

    success "数据库配置生成完成"
}

# 启动数据库服务
start_database_services() {
    log "启动数据库服务..."

    cd "$INSTALL_PATH"
    docker-compose -f docker-compose-db.yml up -d

    # 等待数据库服务启动
    wait_for_service "mysql" "mysqladmin ping -h localhost -u root -p${DB_PASSWORD} --silent" 60
    wait_for_service "postgres" "pg_isready -U postgres" 60
    wait_for_service "redis" "redis-cli ping" 30

    success "数据库服务启动完成"
}

# 初始化数据库
initialize_databases() {
    log "初始化数据库..."

    # 创建应用数据库
    create_application_databases

    # 设置数据库权限
    setup_database_permissions

    success "数据库初始化完成"
}

# 创建应用数据库
create_application_databases() {
    log "创建应用数据库..."

    # 创建PostgreSQL应用数据库
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "CREATE DATABASE IF NOT EXISTS n8n;" 2>/dev/null || \
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "CREATE DATABASE n8n;" 2>/dev/null || true

    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "CREATE DATABASE IF NOT EXISTS oneapi;" 2>/dev/null || \
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "CREATE DATABASE oneapi;" 2>/dev/null || true

    # 创建MySQL应用数据库（备用）
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS oneapi_mysql CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || true
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS n8n_mysql CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || true

    success "应用数据库创建完成"
}

# 设置数据库权限
setup_database_permissions() {
    log "设置数据库权限..."

    # MySQL权限设置
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "GRANT ALL PRIVILEGES ON *.* TO 'dify'@'%' WITH GRANT OPTION;" 2>/dev/null || true
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "FLUSH PRIVILEGES;" 2>/dev/null || true

    success "数据库权限设置完成"
}

# 备份数据库
backup_databases() {
    local backup_dir="$1"

    log "备份数据库..."

    mkdir -p "$backup_dir"

    # 备份MySQL
    if docker ps --format "table {{.Names}}" | grep -q "${CONTAINER_PREFIX}_mysql"; then
        docker exec ${CONTAINER_PREFIX}_mysql mysqldump -u root -p${DB_PASSWORD} --all-databases --single-transaction --routines --triggers > "${backup_dir}/mysql_all_databases.sql" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "MySQL备份完成"
        else
            error "MySQL备份失败"
        fi
    fi

    # 备份PostgreSQL
    if docker ps --format "table {{.Names}}" | grep -q "${CONTAINER_PREFIX}_postgres"; then
        docker exec -e PGPASSWORD=${DB_PASSWORD} ${CONTAINER_PREFIX}_postgres pg_dumpall -U postgres > "${backup_dir}/postgres_all_databases.sql" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "PostgreSQL备份完成"
        else
            error "PostgreSQL备份失败"
        fi
    fi

    # 备份Redis
    if docker ps --format "table {{.Names}}" | grep -q "${CONTAINER_PREFIX}_redis"; then
        docker exec ${CONTAINER_PREFIX}_redis redis-cli BGSAVE >/dev/null 2>&1
        sleep 5
        docker cp ${CONTAINER_PREFIX}_redis:/data/dump.rdb "${backup_dir}/redis_dump.rdb" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "Redis备份完成"
        else
            error "Redis备份失败"
        fi
    fi
}

# 恢复数据库
restore_databases() {
    local backup_dir="$1"

    log "恢复数据库..."

    # 恢复MySQL
    if [ -f "${backup_dir}/mysql_all_databases.sql" ]; then
        docker exec -i ${CONTAINER_PREFIX}_mysql mysql -u root -p${DB_PASSWORD} < "${backup_dir}/mysql_all_databases.sql" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "MySQL恢复完成"
        else
            error "MySQL恢复失败"
        fi
    fi

    # 恢复PostgreSQL
    if [ -f "${backup_dir}/postgres_all_databases.sql" ]; then
        docker exec -i -e PGPASSWORD=${DB_PASSWORD} ${CONTAINER_PREFIX}_postgres psql -U postgres < "${backup_dir}/postgres_all_databases.sql" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "PostgreSQL恢复完成"
        else
            error "PostgreSQL恢复失败"
        fi
    fi

    # 恢复Redis
    if [ -f "${backup_dir}/redis_dump.rdb" ]; then
        docker-compose stop redis
        docker cp "${backup_dir}/redis_dump.rdb" ${CONTAINER_PREFIX}_redis:/data/dump.rdb 2>/dev/null
        docker-compose start redis
        if [ $? -eq 0 ]; then
            success "Redis恢复完成"
        else
            error "Redis恢复失败"
        fi
    fi
}