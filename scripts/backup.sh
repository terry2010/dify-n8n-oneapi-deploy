#!/bin/bash

# =========================================================
# 数据备份脚本
# =========================================================

# 获取脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# 加载配置
if [ -f "modules/config.sh" ]; then
    source modules/config.sh
    source modules/utils.sh
    init_config
else
    echo "错误: 找不到配置文件"
    exit 1
fi

# 配置
BACKUP_BASE_DIR="$INSTALL_PATH/backup"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 显示帮助信息
show_help() {
    echo "数据备份脚本"
    echo ""
    echo "用法: $0 [选项] [系统名称]"
    echo ""
    echo "选项:"
    echo "  -h, --help       显示此帮助信息"
    echo "  -l, --list       列出可备份的系统"
    echo "  -a, --all        备份所有系统数据（默认）"
    echo "  -c, --compress   压缩备份文件"
    echo "  --exclude <path> 排除指定路径（可多次使用）"
    echo ""
    echo "系统名称:"
    echo "  mysql           备份MySQL数据库"
    echo "  postgres        备份PostgreSQL数据库"
    echo "  redis           备份Redis数据"
    echo "  dify            备份Dify系统数据"
    echo "  n8n             备份n8n系统数据"
    echo "  oneapi          备份OneAPI系统数据"
    echo "  ragflow         备份RAGFlow系统数据"
    echo "  config          备份配置文件"
    echo ""
    echo "示例:"
    echo "  $0                    # 备份所有系统"
    echo "  $0 mysql              # 只备份MySQL数据库"
    echo "  $0 dify n8n           # 备份Dify和n8n系统"
    echo "  $0 -c mysql           # 备份MySQL并压缩"
    echo "  $0 ragflow            # 备份RAGFlow系统"
    echo "  $0 --exclude logs     # 备份时排除日志目录"
}

# 检查Docker服务状态
check_docker_services() {
    log "检查Docker服务状态..."

    local services=("mysql" "postgres" "redis" "dify_api" "n8n" "oneapi" "ragflow" "elasticsearch" "minio")
    local running_services=()
    local stopped_services=()

    for service in "${services[@]}"; do
        local container_name="${CONTAINER_PREFIX}_${service}"
        if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
            running_services+=("$service")
        else
            stopped_services+=("$service")
        fi
    done

    if [ ${#running_services[@]} -gt 0 ]; then
        success "运行中的服务: ${running_services[*]}"
    fi

    if [ ${#stopped_services[@]} -gt 0 ]; then
        warning "未运行的服务: ${stopped_services[*]}"
        warning "这些服务的备份可能会失败或不完整"
    fi
}

# 创建备份目录
create_backup_dir() {
    local backup_name="$1"
    local backup_dir="${BACKUP_BASE_DIR}/${backup_name}_${TIMESTAMP}"

    mkdir -p "$backup_dir"
    echo "$backup_dir"
}

# 备份MySQL数据库
backup_mysql() {
    log "开始备份MySQL数据库..."

    local backup_dir=$(create_backup_dir "mysql")
    local container_name="${CONTAINER_PREFIX}_mysql"

    if ! docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        error "MySQL容器未运行"
        return 1
    fi

    # 获取数据库密码
    local db_password="${DB_PASSWORD}"

    # 备份所有数据库
    docker exec "$container_name" mysqldump -u root -p"${db_password}" --all-databases --single-transaction --routines --triggers > "${backup_dir}/mysql_all_databases.sql" 2>/dev/null

    if [ $? -eq 0 ] && [ -s "${backup_dir}/mysql_all_databases.sql" ]; then
        success "MySQL数据库备份完成: ${backup_dir}/mysql_all_databases.sql"
        echo "备份时间: $(date)" > "${backup_dir}/backup_info.txt"
        echo "备份类型: MySQL数据库" >> "${backup_dir}/backup_info.txt"
        echo "备份大小: $(du -sh "${backup_dir}/mysql_all_databases.sql" | cut -f1)" >> "${backup_dir}/backup_info.txt"
        echo "数据库列表:" >> "${backup_dir}/backup_info.txt"
        docker exec "$container_name" mysql -u root -p"${db_password}" -e "SHOW DATABASES;" 2>/dev/null | grep -v "Database\|information_schema\|performance_schema\|mysql\|sys" >> "${backup_dir}/backup_info.txt" 2>/dev/null
        return 0
    else
        error "MySQL数据库备份失败"
        rm -rf "$backup_dir" 2>/dev/null
        return 1
    fi
}

# 备份PostgreSQL数据库
backup_postgres() {
    log "开始备份PostgreSQL数据库..."

    local backup_dir=$(create_backup_dir "postgres")
    local container_name="${CONTAINER_PREFIX}_postgres"

    if ! docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        error "PostgreSQL容器未运行"
        return 1
    fi

    # 获取数据库密码
    local db_password="${DB_PASSWORD}"

    # 备份所有数据库
    docker exec -e PG*="$db_password" "$container_name" pg_dumpall -U postgres > "${backup_dir}/postgres_all_databases.sql" 2>/dev/null

    if [ $? -eq 0 ] && [ -s "${backup_dir}/postgres_all_databases.sql" ]; then
        success "PostgreSQL数据库备份完成: ${backup_dir}/postgres_all_databases.sql"
        echo "备份时间: $(date)" > "${backup_dir}/backup_info.txt"
        echo "备份类型: PostgreSQL数据库" >> "${backup_dir}/backup_info.txt"
        echo "备份大小: $(du -sh "${backup_dir}/postgres_all_databases.sql" | cut -f1)" >> "${backup_dir}/backup_info.txt"
        echo "数据库列表:" >> "${backup_dir}/backup_info.txt"
        docker exec -e PG*="$db_password" "$container_name" psql -U postgres -c "\l" 2>/dev/null | grep -v "List of databases\|template\|postgres" | awk '{print $1}' | grep -v "^$\|^-\|Name" >> "${backup_dir}/backup_info.txt" 2>/dev/null
        return 0
    else
        error "PostgreSQL数据库备份失败"
        rm -rf "$backup_dir" 2>/dev/null
        return 1
    fi
}

# 备份Redis数据
backup_redis() {
    log "开始备份Redis数据..."

    local backup_dir=$(create_backup_dir "redis")
    local container_name="${CONTAINER_PREFIX}_redis"

    if ! docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        error "Redis容器未运行"
        return 1
    fi

    # 强制Redis保存当前数据
    docker exec "$container_name" redis-cli BGSAVE >/dev/null 2>&1

    # 等待后台保存完成
    local save_complete=false
    for i in {1..30}; do
        local last_save=$(docker exec "$container_name" redis-cli LASTSAVE 2>/dev/null)
        sleep 2
        local current_save=$(docker exec "$container_name" redis-cli LASTSAVE 2>/dev/null)
        if [ "$last_save" != "$current_save" ]; then
            save_complete=true
            break
        fi
    done

    if [ "$save_complete" = false ]; then
        warning "Redis后台保存可能未完成，继续备份..."
    fi

    # 复制Redis数据文件
    docker cp "${container_name}:/data/dump.rdb" "${backup_dir}/redis_dump.rdb" 2>/dev/null

    # 备份Redis配置信息
    docker exec "$container_name" redis-cli INFO all > "${backup_dir}/redis_info.txt" 2>/dev/null
    docker exec "$container_name" redis-cli CONFIG GET "*" > "${backup_dir}/redis_config.txt" 2>/dev/null

    if [ $? -eq 0 ] && [ -f "${backup_dir}/redis_dump.rdb" ]; then
        success "Redis数据备份完成: ${backup_dir}/redis_dump.rdb"
        echo "备份时间: $(date)" > "${backup_dir}/backup_info.txt"
        echo "备份类型: Redis数据" >> "${backup_dir}/backup_info.txt"
        echo "备份大小: $(du -sh "${backup_dir}/redis_dump.rdb" | cut -f1)" >> "${backup_dir}/backup_info.txt"
        echo "Redis版本: $(docker exec "$container_name" redis-cli INFO server | grep redis_version | cut -d: -f2 | tr -d '\r')" >> "${backup_dir}/backup_info.txt" 2>/dev/null
        return 0
    else
        error "Redis数据备份失败"
        rm -rf "$backup_dir" 2>/dev/null
        return 1
    fi
}

# 备份Dify系统数据
backup_dify() {
    log "开始备份Dify系统数据..."

    local backup_dir=$(create_backup_dir "dify")
    local backed_up=false

    # 备份Dify应用存储数据
    if [ -d "$INSTALL_PATH/volumes/app" ]; then
        cp -r "$INSTALL_PATH/volumes/app" "$backup_dir/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "Dify应用数据备份完成"
            backed_up=true
        fi
    fi

    # 备份Dify配置数据
    if [ -d "$INSTALL_PATH/volumes/dify" ]; then
        cp -r "$INSTALL_PATH/volumes/dify" "$backup_dir/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "Dify配置数据备份完成"
            backed_up=true
        fi
    fi

    # 备份沙箱依赖
    if [ -d "$INSTALL_PATH/volumes/sandbox" ]; then
        cp -r "$INSTALL_PATH/volumes/sandbox" "$backup_dir/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "Dify沙箱数据备份完成"
            backed_up=true
        fi
    fi

    if [ "$backed_up" = true ]; then
        echo "备份时间: $(date)" > "${backup_dir}/backup_info.txt"
        echo "备份类型: Dify系统数据" >> "${backup_dir}/backup_info.txt"
        echo "备份大小: $(du -sh "$backup_dir" | cut -f1)" >> "${backup_dir}/backup_info.txt"
        echo "备份内容:" >> "${backup_dir}/backup_info.txt"
        find "$backup_dir" -type d -name "*" | sed "s|$backup_dir/||" | grep -v "^$" >> "${backup_dir}/backup_info.txt"
        success "Dify系统数据备份完成: $backup_dir"
        return 0
    else
        error "Dify系统数据备份失败"
        rm -rf "$backup_dir" 2>/dev/null
        return 1
    fi
}

# 备份n8n系统数据
backup_n8n() {
    log "开始备份n8n系统数据..."

    local backup_dir=$(create_backup_dir "n8n")

    # 备份n8n数据目录
    if [ -d "$INSTALL_PATH/volumes/n8n" ]; then
        cp -r "$INSTALL_PATH/volumes/n8n" "$backup_dir/" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "备份时间: $(date)" > "${backup_dir}/backup_info.txt"
            echo "备份类型: n8n系统数据" >> "${backup_dir}/backup_info.txt"
            echo "备份大小: $(du -sh "$backup_dir" | cut -f1)" >> "${backup_dir}/backup_info.txt"

            # 统计工作流数量
            local workflow_count=0
            if [ -f "$backup_dir/n8n/data/database.sqlite" ]; then
                workflow_count=$(docker exec "${CONTAINER_PREFIX}_n8n" sqlite3 /home/node/.n8n/database.sqlite "SELECT COUNT(*) FROM workflow_entity;" 2>/dev/null || echo "0")
            fi
            echo "工作流数量: $workflow_count" >> "${backup_dir}/backup_info.txt"

            success "n8n系统数据备份完成: $backup_dir"
            return 0
        fi
    fi

    error "n8n系统数据备份失败"
    rm -rf "$backup_dir" 2>/dev/null
    return 1
}

# 备份OneAPI系统数据
backup_oneapi() {
    log "开始备份OneAPI系统数据..."

    local backup_dir=$(create_backup_dir "oneapi")

    # 备份OneAPI数据目录
    if [ -d "$INSTALL_PATH/volumes/oneapi" ]; then
        cp -r "$INSTALL_PATH/volumes/oneapi" "$backup_dir/" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "备份时间: $(date)" > "${backup_dir}/backup_info.txt"
            echo "备份类型: OneAPI系统数据" >> "${backup_dir}/backup_info.txt"
            echo "备份大小: $(du -sh "$backup_dir" | cut -f1)" >> "${backup_dir}/backup_info.txt"
            success "OneAPI系统数据备份完成: $backup_dir"
            return 0
        fi
    fi

    error "OneAPI系统数据备份失败"
    rm -rf "$backup_dir" 2>/dev/null
    return 1
}

# 备份RAGFlow系统数据
backup_ragflow() {
    log "开始备份RAGFlow系统数据..."

    local backup_dir=$(create_backup_dir "ragflow")
    local backed_up=false

    # 备份RAGFlow应用数据
    if [ -d "$INSTALL_PATH/volumes/ragflow/ragflow" ]; then
        log "备份RAGFlow应用数据..."
        cp -r "$INSTALL_PATH/volumes/ragflow/ragflow" "$backup_dir/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "RAGFlow应用数据备份完成"
            backed_up=true
        fi
    fi

    # 备份Elasticsearch数据
    if [ -d "$INSTALL_PATH/volumes/ragflow/elasticsearch" ]; then
        log "备份Elasticsearch数据..."
        # 先创建Elasticsearch快照（如果服务在运行）
        if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_elasticsearch"; then
            log "创建Elasticsearch快照..."
            docker exec "${CONTAINER_PREFIX}_elasticsearch" curl -X PUT "localhost:9200/_snapshot/backup_repo" -H 'Content-Type: application/json' -d'
            {
              "type": "fs",
              "settings": {
                "location": "/usr/share/elasticsearch/data/backup"
              }
            }' >/dev/null 2>&1

            docker exec "${CONTAINER_PREFIX}_elasticsearch" curl -X PUT "localhost:9200/_snapshot/backup_repo/snapshot_${TIMESTAMP}" -H 'Content-Type: application/json' -d'
            {
              "indices": "*",
              "ignore_unavailable": true,
              "include_global_state": false
            }' >/dev/null 2>&1

            # 等待快照完成
            sleep 10
        fi

        cp -r "$INSTALL_PATH/volumes/ragflow/elasticsearch" "$backup_dir/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "Elasticsearch数据备份完成"
            backed_up=true
        fi
    fi

    # 备份MinIO数据
    if [ -d "$INSTALL_PATH/volumes/ragflow/minio" ]; then
        log "备份MinIO数据..."
        cp -r "$INSTALL_PATH/volumes/ragflow/minio" "$backup_dir/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "MinIO数据备份完成"
            backed_up=true
        fi
    fi

    # 备份模型缓存
    if [ -d "$INSTALL_PATH/volumes/ragflow/huggingface" ]; then
        log "备份模型缓存（可能需要较长时间）..."
        cp -r "$INSTALL_PATH/volumes/ragflow/huggingface" "$backup_dir/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "模型缓存备份完成"
            backed_up=true
        fi
    fi

    # 备份NLTK数据
    if [ -d "$INSTALL_PATH/volumes/ragflow/nltk_data" ]; then
        log "备份NLTK数据..."
        cp -r "$INSTALL_PATH/volumes/ragflow/nltk_data" "$backup_dir/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "NLTK数据备份完成"
            backed_up=true
        fi
    fi

    if [ "$backed_up" = true ]; then
        echo "备份时间: $(date)" > "${backup_dir}/backup_info.txt"
        echo "备份类型: RAGFlow系统数据" >> "${backup_dir}/backup_info.txt"
        echo "备份大小: $(du -sh "$backup_dir" | cut -f1)" >> "${backup_dir}/backup_info.txt"
        echo "备份内容:" >> "${backup_dir}/backup_info.txt"
        echo "- RAGFlow应用数据" >> "${backup_dir}/backup_info.txt"
        echo "- Elasticsearch索引数据" >> "${backup_dir}/backup_info.txt"
        echo "- MinIO对象存储数据" >> "${backup_dir}/backup_info.txt"
        echo "- 机器学习模型缓存" >> "${backup_dir}/backup_info.txt"
        echo "- NLTK自然语言处理数据" >> "${backup_dir}/backup_info.txt"

        # 获取RAGFlow版本信息
        if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_ragflow"; then
            local ragflow_version=$(docker exec "${CONTAINER_PREFIX}_ragflow" cat /ragflow/VERSION 2>/dev/null || echo "未知")
            echo "RAGFlow版本: $ragflow_version" >> "${backup_dir}/backup_info.txt"
        fi

        success "RAGFlow系统数据备份完成: $backup_dir"
        warning "注意: RAGFlow备份文件可能较大，包含模型缓存数据"
        return 0
    else
        error "RAGFlow系统数据备份失败"
        rm -rf "$backup_dir" 2>/dev/null
        return 1
    fi
}

# 备份配置文件
backup_config() {
    log "开始备份配置文件..."

    local backup_dir=$(create_backup_dir "config")
    local backed_up=false

    # 备份配置目录
    if [ -d "$INSTALL_PATH/config" ]; then
        cp -r "$INSTALL_PATH/config" "$backup_dir/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "配置文件备份完成"
            backed_up=true
        fi
    fi

    # 备份Docker Compose文件
    for compose_file in docker-compose*.yml; do
        if [ -f "$compose_file" ]; then
            cp "$compose_file" "$backup_dir/" 2>/dev/null
            if [ $? -eq 0 ]; then
                success "Docker Compose文件备份完成: $compose_file"
                backed_up=true
            fi
        fi
    done

    # 备份脚本文件
    if [ -d "scripts" ]; then
        cp -r "scripts" "$backup_dir/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "脚本文件备份完成"
            backed_up=true
        fi
    fi

    if [ -d "modules" ]; then
        cp -r "modules" "$backup_dir/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "模块文件备份完成"
            backed_up=true
        fi
    fi

    # 备份环境变量文件
    if [ -f ".env" ]; then
        cp ".env" "$backup_dir/" 2>/dev/null
    fi

    if [ "$backed_up" = true ]; then
        echo "备份时间: $(date)" > "${backup_dir}/backup_info.txt"
        echo "备份类型: 配置文件" >> "${backup_dir}/backup_info.txt"
        echo "备份大小: $(du -sh "$backup_dir" | cut -f1)" >> "${backup_dir}/backup_info.txt"
        echo "备份内容:" >> "${backup_dir}/backup_info.txt"
        find "$backup_dir" -name "*.yml" -o -name "*.conf" -o -name "*.sh" | sed "s|$backup_dir/||" >> "${backup_dir}/backup_info.txt"
        success "配置文件备份完成: $backup_dir"
        return 0
    else
        error "配置文件备份失败"
        rm -rf "$backup_dir" 2>/dev/null
        return 1
    fi
}

# 备份所有系统
backup_all() {
    log "开始完整系统备份..."

    local backup_dir=$(create_backup_dir "full_backup")
    local success_count=0
    local total_count=8

    echo -e "\n${BLUE}=== 开始完整备份，这可能需要较长时间... ===${NC}"

    # 备份各个组件到子目录
    log "备份MySQL数据库..."
    backup_mysql_to_dir "${backup_dir}/mysql" && ((success_count++))

    log "备份PostgreSQL数据库..."
    backup_postgres_to_dir "${backup_dir}/postgres" && ((success_count++))

    log "备份Redis数据..."
    backup_redis_to_dir "${backup_dir}/redis" && ((success_count++))

    log "备份Dify系统数据..."
    backup_dify_to_dir "${backup_dir}/dify" && ((success_count++))

    log "备份n8n系统数据..."
    backup_n8n_to_dir "${backup_dir}/n8n" && ((success_count++))

    log "备份OneAPI系统数据..."
    backup_oneapi_to_dir "${backup_dir}/oneapi" && ((success_count++))

    log "备份RAGFlow系统数据..."
    backup_ragflow_to_dir "${backup_dir}/ragflow" && ((success_count++))

    log "备份配置文件..."
    backup_config_to_dir "${backup_dir}/config" && ((success_count++))

    # 生成备份摘要
    cat > "${backup_dir}/backup_summary.txt" << SUMMARY_EOF
AI服务集群完整备份报告
========================

备份时间: $(date)
备份类型: 完整系统备份
备份路径: ${backup_dir}
成功备份: ${success_count}/${total_count} 个组件

备份组件详情:
- MySQL数据库
- PostgreSQL数据库
- Redis数据
- Dify系统数据
- n8n系统数据
- OneAPI系统数据
- RAGFlow系统数据
- 配置文件和脚本

系统配置:
- 服务器IP: ${SERVER_IP}
- 安装路径: ${INSTALL_PATH}
- 容器前缀: ${CONTAINER_PREFIX}
- 使用模式: $([ "$USE_DOMAIN" = true ] && echo "域名模式" || echo "IP模式")

备份统计:
$(du -sh "${backup_dir}"/* 2>/dev/null | sort -hr)

恢复说明:
使用 scripts/restore.sh 脚本恢复备份数据

注意事项:
- RAGFlow备份包含大量模型缓存，文件较大
- 首次恢复RAGFlow可能需要重新下载部分模型
- 建议定期备份，保留多个版本
SUMMARY_EOF

    success "完整系统备份完成: $backup_dir"
    success "成功备份 ${success_count}/${total_count} 个组件"

    return 0
}

# 辅助函数：备份到指定目录
backup_mysql_to_dir() {
    local target_dir="$1"
    mkdir -p "$target_dir"

    local container_name="${CONTAINER_PREFIX}_mysql"
    local db_password="${DB_PASSWORD}"

    if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        docker exec "$container_name" mysqldump -u root -p"${db_password}" --all-databases --single-transaction --routines --triggers > "${target_dir}/mysql_all_databases.sql" 2>/dev/null
        return $?
    else
        return 1
    fi
}

backup_postgres_to_dir() {
    local target_dir="$1"
    mkdir -p "$target_dir"

    local container_name="${CONTAINER_PREFIX}_postgres"
    local db_password="${DB_PASSWORD}"

    if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        docker exec -e PG*="$db_password" "$container_name" pg_dumpall -U postgres > "${target_dir}/postgres_all_databases.sql" 2>/dev/null
        return $?
    else
        return 1
    fi
}

backup_redis_to_dir() {
    local target_dir="$1"
    mkdir -p "$target_dir"

    local container_name="${CONTAINER_PREFIX}_redis"

    if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        docker exec "$container_name" redis-cli BGSAVE >/dev/null 2>&1
        sleep 5
        docker cp "${container_name}:/data/dump.rdb" "${target_dir}/redis_dump.rdb" 2>/dev/null
        return $?
    else
        return 1
    fi
}

backup_dify_to_dir() {
    local target_dir="$1"
    mkdir -p "$target_dir"

    local success=false
    [ -d "$INSTALL_PATH/volumes/app" ] && cp -r "$INSTALL_PATH/volumes/app" "$target_dir/" 2>/dev/null && success=true
    [ -d "$INSTALL_PATH/volumes/dify" ] && cp -r "$INSTALL_PATH/volumes/dify" "$target_dir/" 2>/dev/null && success=true
    [ -d "$INSTALL_PATH/volumes/sandbox" ] && cp -r "$INSTALL_PATH/volumes/sandbox" "$target_dir/" 2>/dev/null && success=true

    [ "$success" = true ] && return 0 || return 1
}

backup_n8n_to_dir() {
    local target_dir="$1"
    mkdir -p "$target_dir"

    [ -d "$INSTALL_PATH/volumes/n8n" ] && cp -r "$INSTALL_PATH/volumes/n8n" "$target_dir/" 2>/dev/null
    return $?
}

backup_oneapi_to_dir() {
    local target_dir="$1"
    mkdir -p "$target_dir"

    [ -d "$INSTALL_PATH/volumes/oneapi" ] && cp -r "$INSTALL_PATH/volumes/oneapi" "$target_dir/" 2>/dev/null
    return $?
}

backup_ragflow_to_dir() {
    local target_dir="$1"
    mkdir -p "$target_dir"

    local success=false

    # 备份RAGFlow数据（排除大型缓存文件）
    if [ -d "$INSTALL_PATH/volumes/ragflow/ragflow" ]; then
        cp -r "$INSTALL_PATH/volumes/ragflow/ragflow" "$target_dir/" 2>/dev/null && success=true
    fi

    # 备份Elasticsearch数据
    if [ -d "$INSTALL_PATH/volumes/ragflow/elasticsearch" ]; then
        cp -r "$INSTALL_PATH/volumes/ragflow/elasticsearch" "$target_dir/" 2>/dev/null && success=true
    fi

    # 备份MinIO数据
    if [ -d "$INSTALL_PATH/volumes/ragflow/minio" ]; then
        cp -r "$INSTALL_PATH/volumes/ragflow/minio" "$target_dir/" 2>/dev/null && success=true
    fi

    # 可选择性备份大型缓存（默认备份，但用户可以排除）
    if [ -d "$INSTALL_PATH/volumes/ragflow/huggingface" ] && [[ ! " ${EXCLUDE_PATHS[@]} " =~ " huggingface " ]]; then
        cp -r "$INSTALL_PATH/volumes/ragflow/huggingface" "$target_dir/" 2>/dev/null && success=true
    fi

    if [ -d "$INSTALL_PATH/volumes/ragflow/nltk_data" ]; then
        cp -r "$INSTALL_PATH/volumes/ragflow/nltk_data" "$target_dir/" 2>/dev/null && success=true
    fi

    [ "$success" = true ] && return 0 || return 1
}

backup_config_to_dir() {
    local target_dir="$1"
    mkdir -p "$target_dir"

    local success=false
    [ -d "$INSTALL_PATH/config" ] && cp -r "$INSTALL_PATH/config" "$target_dir/" 2>/dev/null && success=true

    for compose_file in docker-compose*.yml; do
        [ -f "$compose_file" ] && cp "$compose_file" "$target_dir/" 2>/dev/null && success=true
    done

    [ -d "scripts" ] && cp -r "scripts" "$target_dir/" 2>/dev/null && success=true
    [ -d "modules" ] && cp -r "modules" "$target_dir/" 2>/dev/null && success=true

    [ "$success" = true ] && return 0 || return 1
}

# 压缩备份
compress_backup() {
    local backup_dir="$1"

    if [ ! -d "$backup_dir" ]; then
        error "备份目录不存在: $backup_dir"
        return 1
    fi

    log "压缩备份文件..."
    local backup_name=$(basename "$backup_dir")
    local parent_dir=$(dirname "$backup_dir")

    cd "$parent_dir"

    # 使用更好的压缩算法
    tar -czf "${backup_name}.tar.gz" "$backup_name" 2>/dev/null

    if [ $? -eq 0 ]; then
        success "备份文件已压缩: ${parent_dir}/${backup_name}.tar.gz"
        # 删除原目录
        rm -rf "$backup_dir"
        echo "${parent_dir}/${backup_name}.tar.gz"
        return 0
    else
        error "备份文件压缩失败"
        return 1
    fi
}

# 清理旧备份
cleanup_old_backups() {
    log "清理30天前的备份文件..."

    if [ -d "$BACKUP_BASE_DIR" ]; then
        # 删除30天前的目录
        find "$BACKUP_BASE_DIR" -name "*_*" -type d -mtime +30 -exec rm -rf {} \; 2>/dev/null || true
        # 删除30天前的压缩包
        find "$BACKUP_BASE_DIR" -name "*.tar.gz" -type f -mtime +30 -exec rm -f {} \; 2>/dev/null || true
        success "旧备份清理完成"
    fi
}

# 列出可备份的系统
list_systems() {
    echo "可备份的系统组件:"
    echo "  mysql      - MySQL数据库"
    echo "  postgres   - PostgreSQL数据库"
    echo "  redis      - Redis数据"
    echo "  dify       - Dify系统数据"
    echo "  n8n        - n8n系统数据"
    echo "  oneapi     - OneAPI系统数据"
    echo "  ragflow    - RAGFlow系统数据（包含大型模型缓存）"
    echo "  config     - 配置文件"
    echo "  all        - 所有系统（默认）"
}

# 显示备份统计
show_backup_statistics() {
    if [ ! -d "$BACKUP_BASE_DIR" ]; then
        warning "备份目录不存在"
        return
    fi

    echo -e "\n${BLUE}=== 备份统计信息 ===${NC}"

    local total_backups=$(find "$BACKUP_BASE_DIR" -maxdepth 1 \( -type d -name "*_*" -o -name "*.tar.gz" \) | wc -l)
    echo "备份总数: $total_backups"

    local total_size=$(du -sh "$BACKUP_BASE_DIR" 2>/dev/null | cut -f1)
    echo "总占用空间: $total_size"

    echo -e "\n最近的备份:"
    find "$BACKUP_BASE_DIR" -maxdepth 1 \( -type d -name "*_*" -o -name "*.tar.gz" \) -exec ls -lah {} \; 2>/dev/null | head -10
}

# 主函数
main() {
    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}     AI服务集群数据备份工具${NC}"
    echo -e "${GREEN}======================================${NC}"

    local compress_flag=false
    local systems=()
    local exclude_paths=()
    EXCLUDE_PATHS=()

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -l|--list)
                list_systems
                exit 0
                ;;
            -a|--all)
                systems=("all")
                shift
                ;;
            -c|--compress)
                compress_flag=true
                shift
                ;;
            --exclude)
                exclude_paths+=("$2")
                EXCLUDE_PATHS+=("$2")
                shift 2
                ;;
            *)
                systems+=("$1")
                shift
                ;;
        esac
    done

    # 如果没有指定系统，默认备份所有
    if [ ${#systems[@]} -eq 0 ]; then
        systems=("all")
    fi

    # 检查Docker服务状态
    check_docker_services

    # 显示备份统计
    show_backup_statistics

    # 执行备份
    local backup_results=()
    local backup_paths=()

    for system in "${systems[@]}"; do
        case "$system" in
            mysql)
                if backup_mysql; then
                    backup_results+=("mysql:成功")
                else
                    backup_results+=("mysql:失败")
                fi
                ;;
            postgres)
                if backup_postgres; then
                    backup_results+=("postgres:成功")
                else
                    backup_results+=("postgres:失败")
                fi
                ;;
            redis)
                if backup_redis; then
                    backup_results+=("redis:成功")
                else
                    backup_results+=("redis:失败")
                fi
                ;;
            dify)
                if backup_dify; then
                    backup_results+=("dify:成功")
                else
                    backup_results+=("dify:失败")
                fi
                ;;
            n8n)
                if backup_n8n; then
                    backup_results+=("n8n:成功")
                else
                    backup_results+=("n8n:失败")
                fi
                ;;
            oneapi)
                if backup_oneapi; then
                    backup_results+=("oneapi:成功")
                else
                    backup_results+=("oneapi:失败")
                fi
                ;;
            ragflow)
                if backup_ragflow; then
                    backup_results+=("ragflow:成功")
                else
                    backup_results+=("ragflow:失败")
                fi
                ;;
            config)
                if backup_config; then
                    backup_results+=("config:成功")
                else
                    backup_results+=("config:失败")
                fi
                ;;
            all)
                backup_all
                backup_results+=("完整备份:完成")
                ;;
            *)
                error "未知的系统名称: $system"
                backup_results+=("$system:未知")
                ;;
        esac
    done

    # 压缩备份文件（如果需要）
    if [ "$compress_flag" = true ] && [ "$system" != "all" ]; then
        local latest_backup=$(find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -name "*_${TIMESTAMP}" 2>/dev/null | head -1)
        if [ -n "$latest_backup" ]; then
            compress_backup "$latest_backup"
        fi
    fi

    # 清理旧备份
    cleanup_old_backups

    # 显示备份结果
    echo -e "\n${BLUE}=== 备份结果 ===${NC}"
    for result in "${backup_results[@]}"; do
        local system=$(echo "$result" | cut -d':' -f1)
        local status=$(echo "$result" | cut -d':' -f2)

        case "$status" in
            成功|完成)
                echo -e "✅ $system: $status"
                ;;
            失败|未知)
                echo -e "❌ $system: $status"
                ;;
        esac
    done

    success "备份操作完成"
    echo "备份文件位置: $BACKUP_BASE_DIR"

    # 显示最终备份统计
    echo -e "\n${BLUE}=== 最新备份统计 ===${NC}"
    if [ -d "$BACKUP_BASE_DIR" ]; then
        local newest_backup=$(find "$BACKUP_BASE_DIR" -maxdepth 1 \( -type d -name "*_${TIMESTAMP}" -o -name "*_${TIMESTAMP}.tar.gz" \) | head -1)
        if [ -n "$newest_backup" ]; then
            echo "最新备份: $(basename "$newest_backup")"
            echo "备份大小: $(du -sh "$newest_backup" | cut -f1)"
            echo "备份时间: $(date)"
        fi
    fi
}

# 运行主函数
main "$@"