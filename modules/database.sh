#!/bin/bash

# =========================================================
# 数据库模块
# =========================================================

# 安装所有数据库
install_databases() {
    log "开始安装数据库服务..."

    # 生成数据库配置
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
      - ./volumes/mysql/conf:/etc/mysql/conf.d
    command: --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --default-authentication-plugin=mysql_native_password --sql_mode=STRICT_TRANS_TABLES,NO_ZERO_DATE,NO_ZERO_IN_DATE,ERROR_FOR_DIVISION_BY_ZERO
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p${DB_PASSWORD}"]
      timeout: 20s
      retries: 10
      interval: 10s
      start_period: 60s
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
      postgres -c 'max_connections=200'
               -c 'shared_buffers=256MB'
               -c 'work_mem=8MB'
               -c 'maintenance_work_mem=128MB'
               -c 'effective_cache_size=1GB'
               -c 'checkpoint_completion_target=0.9'
               -c 'wal_buffers=16MB'
               -c 'default_statistics_target=100'
               -c 'random_page_cost=1.1'
               -c 'effective_io_concurrency=200'
               -c 'logging_collector=on'
               -c 'log_directory=/var/log/postgresql'
               -c 'log_filename=postgresql-%Y-%m-%d_%H%M%S.log'
               -c 'log_statement=error'
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
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
      - ./volumes/redis/logs:/var/log/redis
    command: >
      redis-server
      --appendonly yes
      --appendfsync everysec
      --save 900 1
      --save 300 10
      --save 60 10000
      --maxmemory 1gb
      --maxmemory-policy allkeys-lru
      --tcp-keepalive 300
      --timeout 0
      --logfile /var/log/redis/redis.log
      --loglevel notice
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 5
      start_period: 10s
    networks:
      - aiserver_network
EOF

    success "数据库配置生成完成"
}

# 启动数据库服务
start_database_services() {
    log "启动数据库服务..."

    cd "$INSTALL_PATH"

    # 确保数据目录权限正确
    setup_database_permissions_pre

    # 创建网络
    docker network create aiserver_network 2>/dev/null || true

    # 启动数据库服务
    docker-compose -f docker-compose-db.yml up -d

    # 等待数据库服务启动
    wait_for_service "mysql" "mysqladmin ping -h localhost -u root -p${DB_PASSWORD} --silent" 90
    wait_for_service "postgres" "pg_isready -U postgres" 90
    wait_for_service "redis" "redis-cli ping" 60

    success "数据库服务启动完成"
}

# 初始化数据库
initialize_databases() {
    log "初始化数据库..."

    # 等待数据库完全启动
    sleep 30

    # 创建应用数据库
    create_application_databases

    # 设置数据库权限
    setup_database_permissions

    # 初始化数据库表结构
    initialize_database_schemas

    # 创建数据库索引
    create_database_indexes

    success "数据库初始化完成"
}

# 设置数据库目录权限（启动前）
setup_database_permissions_pre() {
    log "设置数据库目录权限..."

    # MySQL权限设置
    ensure_directory "$INSTALL_PATH/volumes/mysql/data" "999:999" "755"
    ensure_directory "$INSTALL_PATH/volumes/mysql/logs" "999:999" "755"
    ensure_directory "$INSTALL_PATH/volumes/mysql/conf" "999:999" "755"

    # PostgreSQL权限设置
    ensure_directory "$INSTALL_PATH/volumes/postgres/data" "70:70" "755"
    ensure_directory "$INSTALL_PATH/volumes/postgres/logs" "70:70" "755"

    # Redis权限设置
    ensure_directory "$INSTALL_PATH/volumes/redis/data" "999:999" "755"
    ensure_directory "$INSTALL_PATH/volumes/redis/logs" "999:999" "755"

    success "数据库目录权限设置完成"
}

# 创建应用数据库
create_application_databases() {
    log "创建应用数据库..."

    # 创建PostgreSQL应用数据库
    log "创建PostgreSQL数据库..."

    # 创建n8n数据库
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "SELECT 1 FROM pg_database WHERE datname = 'n8n';" 2>/dev/null | grep -q 1 || \
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "CREATE DATABASE n8n WITH ENCODING 'UTF8' LC_COLLATE='en_US.utf8' LC_CTYPE='en_US.utf8';" 2>/dev/null

    # 创建oneapi数据库
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "SELECT 1 FROM pg_database WHERE datname = 'oneapi';" 2>/dev/null | grep -q 1 || \
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "CREATE DATABASE oneapi WITH ENCODING 'UTF8' LC_COLLATE='en_US.utf8' LC_CTYPE='en_US.utf8';" 2>/dev/null

    # 创建dify数据库（PostgreSQL）
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "SELECT 1 FROM pg_database WHERE datname = 'dify';" 2>/dev/null | grep -q 1 || \
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "CREATE DATABASE dify WITH ENCODING 'UTF8' LC_COLLATE='en_US.utf8' LC_CTYPE='en_US.utf8';" 2>/dev/null

    # 创建RAGFlow数据库（MySQL）
    log "创建MySQL数据库..."
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS ragflow CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null

    # 创建备用数据库
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS oneapi_mysql CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS n8n_mysql CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS dify_mysql CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null

    success "应用数据库创建完成"
}

# 设置数据库权限
setup_database_permissions() {
    log "设置数据库权限..."

    # MySQL权限设置
    log "设置MySQL权限..."

    # 为dify创建用户
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "CREATE USER IF NOT EXISTS 'dify'@'%' IDENTIFIED BY '${DB_PASSWORD}';" 2>/dev/null
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "GRANT ALL PRIVILEGES ON dify_mysql.* TO 'dify'@'%';" 2>/dev/null

    # 为ragflow创建用户
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "CREATE USER IF NOT EXISTS 'ragflow'@'%' IDENTIFIED BY '${DB_PASSWORD}';" 2>/dev/null
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "GRANT ALL PRIVILEGES ON ragflow.* TO 'ragflow'@'%';" 2>/dev/null

    # 为oneapi创建用户
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "CREATE USER IF NOT EXISTS 'oneapi'@'%' IDENTIFIED BY '${DB_PASSWORD}';" 2>/dev/null
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "GRANT ALL PRIVILEGES ON oneapi_mysql.* TO 'oneapi'@'%';" 2>/dev/null

    # 刷新权限
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "FLUSH PRIVILEGES;" 2>/dev/null

    # PostgreSQL权限设置
    log "设置PostgreSQL权限..."

    # 为应用创建专用用户
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "DO \$\$ BEGIN CREATE USER dify_user WITH *='${DB_PASSWORD}'; EXCEPTION WHEN duplicate_object THEN RAISE NOTICE 'User already exists'; END \$\$;" 2>/dev/null
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "DO \$\$ BEGIN CREATE USER n8n_user WITH *='${DB_PASSWORD}'; EXCEPTION WHEN duplicate_object THEN RAISE NOTICE 'User already exists'; END \$\$;" 2>/dev/null
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "DO \$\$ BEGIN CREATE USER oneapi_user WITH *='${DB_PASSWORD}'; EXCEPTION WHEN duplicate_object THEN RAISE NOTICE 'User already exists'; END \$\$;" 2>/dev/null

    # 授权
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE dify TO dify_user;" 2>/dev/null
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE n8n TO n8n_user;" 2>/dev/null
    docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE oneapi TO oneapi_user;" 2>/dev/null

    success "数据库权限设置完成"
}

# 初始化数据库表结构
initialize_database_schemas() {
    log "初始化数据库表结构..."

    # 初始化RAGFlow数据库表结构
    initialize_ragflow_schema

    # 检查其他应用的表结构（这些通常由应用自动创建）
    check_application_schemas

    success "数据库表结构初始化完成"
}

# 初始化RAGFlow数据库表结构
initialize_ragflow_schema() {
    log "初始化RAGFlow数据库表结构..."

    # RAGFlow的基础表结构
    cat > "/tmp/ragflow_schema.sql" << 'EOF'
-- RAGFlow数据库表结构

-- 用户表
CREATE TABLE IF NOT EXISTS users (
    id VARCHAR(32) PRIMARY KEY,
    email VARCHAR(128) UNIQUE NOT NULL,
    nickname VARCHAR(32) NOT NULL,
    avatar VARCHAR(256),
    password_hash VARCHAR(128) NOT NULL,
    salt VARCHAR(32) NOT NULL,
    status TINYINT DEFAULT 1,
    is_superuser BOOLEAN DEFAULT FALSE,
    create_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    update_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 知识库表
CREATE TABLE IF NOT EXISTS datasets (
    id VARCHAR(32) PRIMARY KEY,
    name VARCHAR(128) NOT NULL,
    description TEXT,
    language VARCHAR(16) DEFAULT 'English',
    embedding_model VARCHAR(128),
    parser_id VARCHAR(32),
    parser_config JSON,
    created_by VARCHAR(32),
    status TINYINT DEFAULT 1,
    create_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    update_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_created_by (created_by),
    INDEX idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 文档表
CREATE TABLE IF NOT EXISTS documents (
    id VARCHAR(32) PRIMARY KEY,
    dataset_id VARCHAR(32) NOT NULL,
    name VARCHAR(256) NOT NULL,
    type VARCHAR(16) NOT NULL,
    size BIGINT DEFAULT 0,
    location VARCHAR(512),
    parser_config JSON,
    run_id VARCHAR(32),
    progress FLOAT DEFAULT 0,
    progress_msg TEXT,
    process_begin_at TIMESTAMP NULL,
    process_duation FLOAT DEFAULT 0,
    created_by VARCHAR(32),
    status TINYINT DEFAULT 1,
    create_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    update_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_dataset_id (dataset_id),
    INDEX idx_created_by (created_by),
    INDEX idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 聊天表
CREATE TABLE IF NOT EXISTS conversations (
    id VARCHAR(32) PRIMARY KEY,
    name VARCHAR(128),
    dataset_id VARCHAR(32),
    llm_id VARCHAR(32),
    prompt_template TEXT,
    created_by VARCHAR(32),
    status TINYINT DEFAULT 1,
    create_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    update_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_dataset_id (dataset_id),
    INDEX idx_created_by (created_by),
    INDEX idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 对话消息表
CREATE TABLE IF NOT EXISTS messages (
    id VARCHAR(32) PRIMARY KEY,
    conversation_id VARCHAR(32) NOT NULL,
    role VARCHAR(16) NOT NULL,
    content TEXT NOT NULL,
    reference JSON,
    create_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_conversation_id (conversation_id),
    INDEX idx_role (role),
    INDEX idx_create_time (create_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- API Token表
CREATE TABLE IF NOT EXISTS api_tokens (
    id VARCHAR(32) PRIMARY KEY,
    token VARCHAR(128) UNIQUE NOT NULL,
    name VARCHAR(128),
    created_by VARCHAR(32),
    dataset_ids JSON,
    llm_ids JSON,
    status TINYINT DEFAULT 1,
    create_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    update_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_token (token),
    INDEX idx_created_by (created_by),
    INDEX idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- LLM配置表
CREATE TABLE IF NOT EXISTS llms (
    id VARCHAR(32) PRIMARY KEY,
    name VARCHAR(128) NOT NULL,
    type VARCHAR(32) NOT NULL,
    config JSON NOT NULL,
    created_by VARCHAR(32),
    status TINYINT DEFAULT 1,
    create_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    update_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_type (type),
    INDEX idx_created_by (created_by),
    INDEX idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 插入默认管理员用户
INSERT IGNORE INTO users (id, email, nickname, password_hash, salt, is_superuser)
VALUES (
    'admin_user_001',
    'admin@ragflow.io',
    'Administrator',
    '5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8', -- 'ragflow123456' 的SHA256值
    'ragflow_salt',
    TRUE
);

-- 插入默认LLM配置
INSERT IGNORE INTO llms (id, name, type, config, created_by)
VALUES (
    'default_llm_001',
    'Default OpenAI',
    'openai',
    '{"api_key": "", "base_url": "https://api.openai.com/v1", "model": "gpt-3.5-turbo"}',
    'admin_user_001'
);
EOF

    # 执行SQL脚本
    docker cp "/tmp/ragflow_schema.sql" "${CONTAINER_PREFIX}_mysql:/tmp/ragflow_schema.sql"
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} ragflow < /tmp/ragflow_schema.sql 2>/dev/null

    # 清理临时文件
    rm -f "/tmp/ragflow_schema.sql"
    docker exec ${CONTAINER_PREFIX}_mysql rm -f /tmp/ragflow_schema.sql

    if [ $? -eq 0 ]; then
        success "RAGFlow数据库表结构初始化完成"
    else
        warning "RAGFlow数据库表结构初始化可能存在问题"
    fi
}

# 检查应用数据库表结构
check_application_schemas() {
    log "检查应用数据库表结构..."

    # 检查PostgreSQL数据库
    local pg_dbs=("dify" "n8n" "oneapi")
    for db in "${pg_dbs[@]}"; do
        local table_count=$(docker exec ${CONTAINER_PREFIX}_postgres psql -U postgres -d "$db" -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null | tr -d ' ' || echo "0")
        log "$db 数据库表数量: $table_count"
    done

    # 检查MySQL数据库
    local mysql_dbs=("ragflow" "dify_mysql" "oneapi_mysql" "n8n_mysql")
    for db in "${mysql_dbs[@]}"; do
        local table_count=$(docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$db';" 2>/dev/null | tail -1 || echo "0")
        log "$db 数据库表数量: $table_count"
    done

    success "应用数据库表结构检查完成"
}

# 创建数据库索引
create_database_indexes() {
    log "创建数据库索引..."

    # 为RAGFlow数据库创建额外索引
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} ragflow -e "
        CREATE INDEX IF NOT EXISTS idx_documents_type_status ON documents(type, status);
        CREATE INDEX IF NOT EXISTS idx_conversations_dataset_status ON conversations(dataset_id, status);
        CREATE INDEX IF NOT EXISTS idx_messages_conversation_time ON messages(conversation_id, create_time);
    " 2>/dev/null || true

    success "数据库索引创建完成"
}

# 备份数据库
backup_databases() {
    local backup_dir="$1"

    log "备份数据库..."

    mkdir -p "$backup_dir"

    # 备份MySQL
    if docker ps --format "table {{.Names}}" | grep -q "${CONTAINER_PREFIX}_mysql"; then
        log "备份MySQL数据库..."

        # 备份所有数据库结构和数据
        docker exec "${CONTAINER_PREFIX}_mysql" mysqldump -u root -p"${DB_PASSWORD}" --all-databases --single-transaction --routines --triggers --events --comments > "${backup_dir}/mysql_all_databases.sql" 2>/dev/null

        # 单独备份重要数据库
        docker exec "${CONTAINER_PREFIX}_mysql" mysqldump -u root -p"${DB_PASSWORD}" --single-transaction --routines --triggers ragflow > "${backup_dir}/mysql_ragflow.sql" 2>/dev/null

        # 备份系统信息
        docker exec "${CONTAINER_PREFIX}_mysql" mysql -u root -p"${DB_PASSWORD}" -e "SELECT version();" > "${backup_dir}/mysql_version.txt" 2>/dev/null
        docker exec "${CONTAINER_PREFIX}_mysql" mysql -u root -p"${DB_PASSWORD}" -e "SHOW DATABASES;" > "${backup_dir}/mysql_databases.txt" 2>/dev/null

        if [ -s "${backup_dir}/mysql_all_databases.sql" ]; then
            success "MySQL数据库备份完成"
        else
            error "MySQL数据库备份失败"
        fi
    fi

    # 备份PostgreSQL
    if docker ps --format "table {{.Names}}" | grep -q "${CONTAINER_PREFIX}_postgres"; then
        log "备份PostgreSQL数据库..."

        # 备份所有数据库
        docker exec -e PG*="${DB_PASSWORD}" "${CONTAINER_PREFIX}_postgres" pg_dumpall -U postgres > "${backup_dir}/postgres_all_databases.sql" 2>/dev/null

        # 单独备份重要数据库
        for db in dify n8n oneapi; do
            docker exec -e PG*="${DB_PASSWORD}" "${CONTAINER_PREFIX}_postgres" pg_dump -U postgres "$db" > "${backup_dir}/postgres_${db}.sql" 2>/dev/null
        done

        # 备份系统信息
        docker exec -e PG*="${DB_PASSWORD}" "${CONTAINER_PREFIX}_postgres" psql -U postgres -c "SELECT version();" > "${backup_dir}/postgres_version.txt" 2>/dev/null
        docker exec -e PG*="${DB_PASSWORD}" "${CONTAINER_PREFIX}_postgres" psql -U postgres -c "\\l" > "${backup_dir}/postgres_databases.txt" 2>/dev/null

        if [ -s "${backup_dir}/postgres_all_databases.sql" ]; then
            success "PostgreSQL数据库备份完成"
        else
            error "PostgreSQL数据库备份失败"
        fi
    fi

    # 备份Redis
    if docker ps --format "table {{.Names}}" | grep -q "${CONTAINER_PREFIX}_redis"; then
        log "备份Redis数据..."

        # 强制保存
        docker exec "${CONTAINER_PREFIX}_redis" redis-cli BGSAVE >/dev/null 2>&1

        # 等待保存完成
        local save_complete=false
        for i in {1..30}; do
            local last_save=$(docker exec "${CONTAINER_PREFIX}_redis" redis-cli LASTSAVE 2>/dev/null)
            sleep 2
            local current_save=$(docker exec "${CONTAINER_PREFIX}_redis" redis-cli LASTSAVE 2>/dev/null)
            if [ "$last_save" != "$current_save" ]; then
                save_complete=true
                break
            fi
        done

        # 复制数据文件
        docker cp "${CONTAINER_PREFIX}_redis:/data/dump.rdb" "${backup_dir}/redis_dump.rdb" 2>/dev/null

        # 备份配置信息
        docker exec "${CONTAINER_PREFIX}_redis" redis-cli INFO all > "${backup_dir}/redis_info.txt" 2>/dev/null
        docker exec "${CONTAINER_PREFIX}_redis" redis-cli CONFIG GET "*" > "${backup_dir}/redis_config.txt" 2>/dev/null

        if [ -f "${backup_dir}/redis_dump.rdb" ]; then
            success "Redis数据备份完成"
        else
            error "Redis数据备份失败"
        fi
    fi

    # 生成备份摘要
    cat > "${backup_dir}/backup_summary.txt" << BACKUP_SUMMARY_EOF
数据库备份摘要
==============

备份时间: $(date)
备份类型: 数据库完整备份

MySQL备份:
- 全量备份: mysql_all_databases.sql
- RAGFlow专用备份: mysql_ragflow.sql
- 版本信息: mysql_version.txt
- 数据库列表: mysql_databases.txt

PostgreSQL备份:
- 全量备份: postgres_all_databases.sql
- Dify备份: postgres_dify.sql
- n8n备份: postgres_n8n.sql
- OneAPI备份: postgres_oneapi.sql
- 版本信息: postgres_version.txt
- 数据库列表: postgres_databases.txt

Redis备份:
- 数据文件: redis_dump.rdb
- 系统信息: redis_info.txt
- 配置信息: redis_config.txt

备份文件大小:
$(du -sh "${backup_dir}"/* 2>/dev/null | sort -hr)

恢复说明:
1. 停止数据库服务
2. 清空数据目录
3. 启动数据库服务
4. 导入备份文件
BACKUP_SUMMARY_EOF

    success "数据库备份摘要已生成"
}

# 恢复数据库
restore_databases() {
    local backup_dir="$1"

    log "恢复数据库..."

    # 确认操作
    echo -e "\n${YELLOW}警告: 数据恢复将覆盖现有数据库！${NC}"
    echo "备份目录: $backup_dir"
    read -p "确定要继续吗？(输入 'yes' 确认): " confirm

    if [ "$confirm" != "yes" ]; then
        log "数据恢复已取消"
        return 0
    fi

    # 停止相关应用服务
    log "停止相关应用服务..."
    docker-compose -f docker-compose-dify.yml stop 2>/dev/null || true
    docker-compose -f docker-compose-n8n.yml stop 2>/dev/null || true
    docker-compose -f docker-compose-oneapi.yml stop 2>/dev/null || true
    docker-compose -f docker-compose-ragflow.yml stop 2>/dev/null || true

    # 恢复MySQL
    if [ -f "${backup_dir}/mysql_all_databases.sql" ]; then
        log "恢复MySQL数据库..."
        docker exec -i "${CONTAINER_PREFIX}_mysql" mysql -u root -p"${DB_PASSWORD}" < "${backup_dir}/mysql_all_databases.sql" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "MySQL数据库恢复完成"
        else
            error "MySQL数据库恢复失败"
        fi
    fi

    # 恢复PostgreSQL
    if [ -f "${backup_dir}/postgres_all_databases.sql" ]; then
        log "恢复PostgreSQL数据库..."
        docker exec -i -e PG*="${DB_PASSWORD}" "${CONTAINER_PREFIX}_postgres" psql -U postgres < "${backup_dir}/postgres_all_databases.sql" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "PostgreSQL数据库恢复完成"
        else
            error "PostgreSQL数据库恢复失败"
        fi
    fi

    # 恢复Redis
    if [ -f "${backup_dir}/redis_dump.rdb" ]; then
        log "恢复Redis数据..."
        docker-compose -f docker-compose-db.yml stop redis 2>/dev/null
        sleep 5
        docker cp "${backup_dir}/redis_dump.rdb" "${CONTAINER_PREFIX}_redis:/data/dump.rdb" 2>/dev/null
        docker-compose -f docker-compose-db.yml start redis 2>/dev/null
        wait_for_service "redis" "redis-cli ping" 30
        if [ $? -eq 0 ]; then
            success "Redis数据恢复完成"
        else
            error "Redis数据恢复失败"
        fi
    fi

    log "重新启动应用服务..."
    sleep 10
    # 重新启动应用服务
    docker-compose -f docker-compose-dify.yml start 2>/dev/null || true
    docker-compose -f docker-compose-n8n.yml start 2>/dev/null || true
    docker-compose -f docker-compose-oneapi.yml start 2>/dev/null || true
    docker-compose -f docker-compose-ragflow.yml start 2>/dev/null || true

    success "数据库恢复操作完成"
}

# 优化数据库性能
optimize_database_performance() {
    log "优化数据库性能..."

    # 优化MySQL
    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_mysql"; then
        log "优化MySQL配置..."

        # 创建MySQL配置文件
        cat > "$INSTALL_PATH/volumes/mysql/conf/mysql_optimization.cnf" << 'EOF'
[mysqld]
# 连接和内存设置
max_connections = 200
thread_cache_size = 16
table_open_cache = 2000
table_definition_cache = 1400

# InnoDB设置
innodb_buffer_pool_size = 512M
innodb_log_file_size = 128M
innodb_log_buffer_size = 16M
innodb_flush_log_at_trx_commit = 2
innodb_file_per_table = 1

# 查询缓存
query_cache_type = 1
query_cache_size = 32M
query_cache_limit = 2M

# 日志设置
slow_query_log = 1
slow_query_log_file = /var/log/mysql/mysql-slow.log
long_query_time = 2

# 其他优化
tmp_table_size = 64M
max_heap_table_size = 64M
EOF

        success "MySQL优化配置已生成"
    fi

    # 优化PostgreSQL（通过环境变量已设置）
    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_postgres"; then
        log "PostgreSQL已通过启动参数优化"
        success "PostgreSQL优化完成"
    fi

    # 优化Redis（通过启动命令已设置）
    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_redis"; then
        log "Redis已通过启动参数优化"
        success "Redis优化完成"
    fi

    success "数据库性能优化完成"
    warning "配置更改需要重启数据库服务才能生效"
}

# 数据库健康检查
check_database_health() {
    echo -e "${BLUE}=== 数据库健康检查 ===${NC}"

    # 检查MySQL
    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_mysql"; then
        echo -n "MySQL连接测试: "
        if docker exec "${CONTAINER_PREFIX}_mysql" mysqladmin ping -u root -p"${DB_PASSWORD}" --silent 2>/dev/null; then
            echo "✅ 正常"

            # 显示详细信息
            local mysql_version=$(docker exec "${CONTAINER_PREFIX}_mysql" mysql -u root -p"${DB_PASSWORD}" -e "SELECT VERSION();" 2>/dev/null | tail -1)
            echo "  版本: $mysql_version"

            local mysql_uptime=$(docker exec "${CONTAINER_PREFIX}_mysql" mysql -u root -p"${DB_PASSWORD}" -e "SHOW STATUS LIKE 'Uptime';" 2>/dev/null | tail -1 | awk '{print $2}')
            echo "  运行时间: $((mysql_uptime / 3600))小时"

            local mysql_connections=$(docker exec "${CONTAINER_PREFIX}_mysql" mysql -u root -p"${DB_PASSWORD}" -e "SHOW STATUS LIKE 'Threads_connected';" 2>/dev/null | tail -1 | awk '{print $2}')
            echo "  当前连接数: $mysql_connections"
        else
            echo "❌ 连接失败"
        fi
    else
        echo "MySQL: ❌ 未运行"
    fi

    # 检查PostgreSQL
    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_postgres"; then
        echo -n "PostgreSQL连接测试: "
        if docker exec "${CONTAINER_PREFIX}_postgres" pg_isready -U postgres >/dev/null 2>&1; then
            echo "✅ 正常"

            # 显示详细信息
            local pg_version=$(docker exec -e PG*="${DB_PASSWORD}" "${CONTAINER_PREFIX}_postgres" psql -U postgres -t -c "SELECT version();" 2>/dev/null | head -1 | xargs)
            echo "  版本: ${pg_version:0:50}..."

            local pg_connections=$(docker exec -e PG*="${DB_PASSWORD}" "${CONTAINER_PREFIX}_postgres" psql -U postgres -t -c "SELECT count(*) FROM pg_stat_activity;" 2>/dev/null | xargs)
            echo "  当前连接数: $pg_connections"
        else
            echo "❌ 连接失败"
        fi
    else
        echo "PostgreSQL: ❌ 未运行"
    fi

    # 检查Redis
    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_redis"; then
        echo -n "Redis连接测试: "
        if docker exec "${CONTAINER_PREFIX}_redis" redis-cli ping >/dev/null 2>&1; then
            echo "✅ 正常"

            # 显示详细信息
            local redis_version=$(docker exec "${CONTAINER_PREFIX}_redis" redis-cli info server | grep redis_version | cut -d: -f2 | tr -d '\r')
            echo "  版本: $redis_version"

            local redis_memory=$(docker exec "${CONTAINER_PREFIX}_redis" redis-cli info memory | grep used_memory_human | cut -d: -f2 | tr -d '\r')
            echo "  内存使用: $redis_memory"

            local redis_keys=$(docker exec "${CONTAINER_PREFIX}_redis" redis-cli dbsize 2>/dev/null)
            echo "  键数量: $redis_keys"
        else
            echo "❌ 连接失败"
        fi
    else
        echo "Redis: ❌ 未运行"
    fi

    echo ""
}

# 显示数据库统计信息
show_database_stats() {
    echo -e "${BLUE}=== 数据库统计信息 ===${NC}"

    # MySQL统计
    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_mysql"; then
        echo "MySQL数据库:"
        docker exec "${CONTAINER_PREFIX}_mysql" mysql -u root -p"${DB_PASSWORD}" -e "
            SELECT
                table_schema as 'Database',
                count(*) as 'Tables',
                ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) as 'Size (MB)'
            FROM information_schema.tables
            WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys')
            GROUP BY table_schema;
        " 2>/dev/null | column -t
        echo ""
    fi

    # PostgreSQL统计
    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_postgres"; then
        echo "PostgreSQL数据库:"
        docker exec -e PG*="${DB_PASSWORD}" "${CONTAINER_PREFIX}_postgres" psql -U postgres -c "
            SELECT
                datname as \"Database\",
                pg_size_pretty(pg_database_size(datname)) as \"Size\"
            FROM pg_database
            WHERE datname NOT IN ('template0', 'template1', 'postgres')
            ORDER BY pg_database_size(datname) DESC;
        " 2>/dev/null
        echo ""
    fi

    # Redis统计
    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_redis"; then
        echo "Redis统计:"
        local redis_info=$(docker exec "${CONTAINER_PREFIX}_redis" redis-cli info stats 2>/dev/null)
        echo "  总连接数: $(echo "$redis_info" | grep total_connections_received | cut -d: -f2 | tr -d '\r')"
        echo "  总命令数: $(echo "$redis_info" | grep total_commands_processed | cut -d: -f2 | tr -d '\r')"
        echo "  键过期数: $(echo "$redis_info" | grep expired_keys | cut -d: -f2 | tr -d '\r')"
        echo ""
    fi
}

# 清理数据库日志
cleanup_database_logs() {
    log "清理数据库日志..."

    # 清理MySQL日志
    if [ -d "$INSTALL_PATH/volumes/mysql/logs" ]; then
        find "$INSTALL_PATH/volumes/mysql/logs" -name "*.log" -mtime +7 -delete 2>/dev/null || true
        success "MySQL日志清理完成"
    fi

    # 清理PostgreSQL日志
    if [ -d "$INSTALL_PATH/volumes/postgres/logs" ]; then
        find "$INSTALL_PATH/volumes/postgres/logs" -name "*.log" -mtime +7 -delete 2>/dev/null || true
        success "PostgreSQL日志清理完成"
    fi

    # 清理Redis日志
    if [ -d "$INSTALL_PATH/volumes/redis/logs" ]; then
        find "$INSTALL_PATH/volumes/redis/logs" -name "*.log" -mtime +7 -delete 2>/dev/null || true
        success "Redis日志清理完成"
    fi
}

# 数据库维护
maintain_databases() {
    log "执行数据库维护..."

    # MySQL维护
    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_mysql"; then
        log "执行MySQL维护..."

        # 分析表
        docker exec "${CONTAINER_PREFIX}_mysql" mysql -u root -p"${DB_PASSWORD}" -e "
            ANALYZE TABLE ragflow.users, ragflow.datasets, ragflow.documents;
        " 2>/dev/null || true

        # 优化表
        docker exec "${CONTAINER_PREFIX}_mysql" mysql -u root -p"${DB_PASSWORD}" -e "
            OPTIMIZE TABLE ragflow.conversations, ragflow.messages;
        " 2>/dev/null || true

        success "MySQL维护完成"
    fi

    # PostgreSQL维护
    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_postgres"; then
        log "执行PostgreSQL维护..."

        # 更新统计信息
        for db in dify n8n oneapi; do
            docker exec -e PG*="${DB_PASSWORD}" "${CONTAINER_PREFIX}_postgres" psql -U postgres -d "$db" -c "ANALYZE;" 2>/dev/null || true
        done

        # 清理死元组
        for db in dify n8n oneapi; do
            docker exec -e PG*="${DB_PASSWORD}" "${CONTAINER_PREFIX}_postgres" psql -U postgres -d "$db" -c "VACUUM;" 2>/dev/null || true
        done

        success "PostgreSQL维护完成"
    fi

    # Redis维护
    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_redis"; then
        log "执行Redis维护..."

        # 后台保存
        docker exec "${CONTAINER_PREFIX}_redis" redis-cli BGSAVE >/dev/null 2>&1

        # 清理过期键
        docker exec "${CONTAINER_PREFIX}_redis" redis-cli --scan --pattern "*" | head -1000 | while read key; do
            docker exec "${CONTAINER_PREFIX}_redis" redis-cli TTL "$key" >/dev/null 2>&1
        done

        success "Redis维护完成"
    fi

    # 清理日志
    cleanup_database_logs

    success "数据库维护完成"
}

# 重置数据库密码
reset_database_password() {
    local new_password="$1"

    if [ -z "$new_password" ]; then
        error "请提供新密码"
        return 1
    fi

    log "重置数据库密码..."

    # 确认操作
    echo -e "\n${YELLOW}警告: 重置数据库密码将影响所有应用连接！${NC}"
    read -p "确定要继续吗？(输入 'yes' 确认): " confirm

    if [ "$confirm" != "yes" ]; then
        log "密码重置已取消"
        return 0
    fi

    # 停止应用服务
    log "停止应用服务..."
    docker-compose -f docker-compose-dify.yml stop 2>/dev/null || true
    docker-compose -f docker-compose-n8n.yml stop 2>/dev/null || true
    docker-compose -f docker-compose-oneapi.yml stop 2>/dev/null || true
    docker-compose -f docker-compose-ragflow.yml stop 2>/dev/null || true

    # 重置MySQL密码
    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_mysql"; then
        log "重置MySQL密码..."
        docker exec "${CONTAINER_PREFIX}_mysql" mysql -u root -p"${DB_PASSWORD}" -e "
            SET PASSWORD FOR 'root'@'%' = PASSWORD('$new_password');
            SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$new_password');
            UPDATE mysql.user SET * = PASSWORD('$new_password') WHERE User = 'ragflow';
            UPDATE mysql.user SET * = PASSWORD('$new_password') WHERE User = 'dify';
            UPDATE mysql.user SET * = PASSWORD('$new_password') WHERE User = 'oneapi';
            FLUSH PRIVILEGES;
        " 2>/dev/null
        success "MySQL密码重置完成"
    fi

    # 重置PostgreSQL密码
    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_postgres"; then
        log "重置PostgreSQL密码..."
        docker exec "${CONTAINER_PREFIX}_postgres" psql -U postgres -c "
            ALTER USER postgres * '$new_password';
            ALTER USER dify_user * '$new_password';
            ALTER USER n8n_user * '$new_password';
            ALTER USER oneapi_user * '$new_password';
        " 2>/dev/null
        success "PostgreSQL密码重置完成"
    fi

    # 更新配置文件
    log "更新配置文件..."
    sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=\"$new_password\"/" "modules/config.sh"

    # 重新生成应用配置
    source modules/config.sh
    init_config

    # 重新生成Docker Compose文件
    generate_database_compose

    # 重启数据库服务
    log "重启数据库服务..."
    docker-compose -f docker-compose-db.yml restart
    sleep 30

    success "数据库密码重置完成"
    warning "请重新启动所有应用服务以使新密码生效"
}

# 导出数据库配置
export_database_config() {
    local config_file="$1"

    if [ -z "$config_file" ]; then
        config_file="$INSTALL_PATH/backup/database_config_$(date +%Y%m%d_%H%M%S).txt"
    fi

    mkdir -p "$(dirname "$config_file")"

    cat > "$config_file" << CONFIG_EOF
# 数据库配置导出
# 导出时间: $(date)

# 基础配置
DB_PASSWORD=${DB_PASSWORD}
MYSQL_PORT=${MYSQL_PORT}
POSTGRES_PORT=${POSTGRES_PORT}
REDIS_PORT=${REDIS_PORT}

# 服务器信息
SERVER_IP=${SERVER_IP}
CONTAINER_PREFIX=${CONTAINER_PREFIX}

# MySQL配置
MYSQL_DATABASES=ragflow,dify_mysql,oneapi_mysql,n8n_mysql
MYSQL_USERS=root,ragflow,dify,oneapi

# PostgreSQL配置
POSTGRES_DATABASES=dify,n8n,oneapi
POSTGRES_USERS=postgres,dify_user,n8n_user,oneapi_user

# Redis配置
REDIS_DATABASES=16
REDIS_MAXMEMORY=1gb

# 连接字符串
MYSQL_CONNECTION_STRING="mysql://root:${DB_PASSWORD}@${SERVER_IP}:${MYSQL_PORT}"
POSTGRES_CONNECTION_STRING="postgresql://postgres:${DB_PASSWORD}@${SERVER_IP}:${POSTGRES_PORT}"
REDIS_CONNECTION_STRING="redis://${SERVER_IP}:${REDIS_PORT}"
CONFIG_EOF

    success "数据库配置已导出: $config_file"
}