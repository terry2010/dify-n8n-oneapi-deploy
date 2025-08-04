#!/bin/bash

# =========================================================
# 数据恢复脚本
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

# 显示帮助信息
show_help() {
    echo "数据恢复脚本"
    echo ""
    echo "用法: $0 <备份路径> [选项]"
    echo ""
    echo "参数:"
    echo "  备份路径         指定要恢复的备份目录或压缩包"
    echo ""
    echo "选项:"
    echo "  -f, --force      强制恢复，不询问确认"
    echo "  -l, --list       列出可用的备份"
    echo "  --dry-run        预览恢复操作，不实际执行"
    echo "  --selective      选择性恢复特定组件"
    echo "  --exclude <comp> 排除指定组件"
    echo "  --verify         验证备份文件完整性"
    echo "  -h, --help       显示此帮助信息"
    echo ""
    echo "组件名称:"
    echo "  mysql           MySQL数据库"
    echo "  postgres        PostgreSQL数据库"
    echo "  redis           Redis数据"
    echo "  dify            Dify系统数据"
    echo "  n8n             n8n系统数据"
    echo "  oneapi          OneAPI系统数据"
    echo "  ragflow         RAGFlow系统数据"
    echo "  config          配置文件"
    echo ""
    echo "示例:"
    echo "  $0 backup/full_backup_20241201_143022    # 从指定目录恢复"
    echo "  $0 backup/mysql_20241201_143022          # 恢复MySQL备份"
    echo "  $0 backup/ragflow_20241201_143022        # 恢复RAGFlow备份"
    echo "  $0 backup/full_backup_20241201_143022.tar.gz  # 从压缩包恢复"
    echo "  $0 --list                                # 列出所有备份"
    echo "  $0 <backup> --selective                  # 选择性恢复"
    echo "  $0 <backup> --exclude ragflow            # 排除RAGFlow组件"
    echo "  $0 <backup> --verify                     # 只验证备份完整性"
}

# 列出可用备份
list_backups() {
    echo -e "${BLUE}=== 可用的备份文件 ===${NC}"
    echo ""

    if [ ! -d "$BACKUP_BASE_DIR" ]; then
        warning "备份目录不存在: $BACKUP_BASE_DIR"
        return 1
    fi

    local backup_found=false

    echo "📁 目录形式的备份："
    find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -name "*_*" | sort -r | while read backup_dir; do
        if [ -f "$backup_dir/backup_info.txt" ] || [ -f "$backup_dir/backup_summary.txt" ]; then
            local backup_name=$(basename "$backup_dir")
            local backup_time=""

            if [[ $backup_name =~ _([0-9]{8}_[0-9]{6})$ ]]; then
                backup_time=${BASH_REMATCH[1]}
                backup_time=$(echo $backup_time | sed 's/_/ /' | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3/')
            fi

            local size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
            echo "  $backup_name ($backup_time, $size)"

            # 显示备份内容摘要
            if [ -f "$backup_dir/backup_summary.txt" ]; then
                echo "    类型: 完整系统备份"
            elif [ -f "$backup_dir/backup_info.txt" ]; then
                local backup_type=$(grep "备份类型:" "$backup_dir/backup_info.txt" | cut -d: -f2 | xargs)
                echo "    类型: $backup_type"
            fi

            backup_found=true
        fi
    done

    echo ""
    echo "📦 压缩包形式的备份："
    find "$BACKUP_BASE_DIR" -maxdepth 1 -name "*.tar.gz" | sort -r | while read backup_file; do
        local backup_name=$(basename "$backup_file" .tar.gz)
        local backup_time=""

        if [[ $backup_name =~ _([0-9]{8}_[0-9]{6})$ ]]; then
            backup_time=${BASH_REMATCH[1]}
            backup_time=$(echo $backup_time | sed 's/_/ /' | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3/')
        fi

        local size=$(du -sh "$backup_file" 2>/dev/null | cut -f1)
        echo "  $backup_name.tar.gz ($backup_time, $size)"
        backup_found=true
    done

    if [ "$backup_found" = false ]; then
        warning "未找到任何备份文件"
        return 1
    fi

    echo ""
    echo "💡 使用 '$0 <备份路径>' 来恢复指定备份"
}

# 验证备份文件完整性
verify_backup() {
    local backup_path="$1"

    log "验证备份文件完整性..."

    if [ ! -e "$backup_path" ]; then
        error "备份路径不存在: $backup_path"
        return 1
    fi

    local temp_dir=""
    local verify_dir="$backup_path"

    # 如果是压缩包，先解压到临时目录
    if [[ "$backup_path" == *.tar.gz ]]; then
        temp_dir="/tmp/verify_$(date +%s)"
        extract_backup "$backup_path" "$temp_dir" || return 1
        verify_dir="$temp_dir"
    fi

    local verification_passed=true
    local issues=()

    # 检查备份摘要文件
    if [ -f "$verify_dir/backup_summary.txt" ]; then
        success "找到备份摘要文件"
    elif [ -f "$verify_dir/backup_info.txt" ]; then
        success "找到备份信息文件"
    else
        issues+=("缺少备份信息文件")
        verification_passed=false
    fi

    # 检查各组件备份
    local components=("mysql" "postgres" "redis" "dify" "n8n" "oneapi" "ragflow" "config")
    for component in "${components[@]}"; do
        case "$component" in
            mysql)
                if [ -f "$verify_dir/mysql/mysql_all_databases.sql" ] || [ -f "$verify_dir/mysql_all_databases.sql" ]; then
                    local file_size=$(du -sh "$verify_dir/mysql"* 2>/dev/null | head -1 | cut -f1)
                    success "MySQL备份验证通过 ($file_size)"
                else
                    issues+=("MySQL备份文件缺失或损坏")
                fi
                ;;
            postgres)
                if [ -f "$verify_dir/postgres/postgres_all_databases.sql" ] || [ -f "$verify_dir/postgres_all_databases.sql" ]; then
                    local file_size=$(du -sh "$verify_dir/postgres"* 2>/dev/null | head -1 | cut -f1)
                    success "PostgreSQL备份验证通过 ($file_size)"
                else
                    issues+=("PostgreSQL备份文件缺失或损坏")
                fi
                ;;
            redis)
                if [ -f "$verify_dir/redis/redis_dump.rdb" ] || [ -f "$verify_dir/redis_dump.rdb" ]; then
                    success "Redis备份验证通过"
                else
                    issues+=("Redis备份文件缺失或损坏")
                fi
                ;;
            dify|n8n|oneapi|ragflow)
                if [ -d "$verify_dir/$component" ] && [ "$(ls -A "$verify_dir/$component" 2>/dev/null)" ]; then
                    local dir_size=$(du -sh "$verify_dir/$component" 2>/dev/null | cut -f1)
                    success "${component}备份验证通过 ($dir_size)"
                else
                    warning "${component}备份目录为空或不存在"
                fi
                ;;
            config)
                if [ -d "$verify_dir/config" ] || [ -f "$verify_dir/docker-compose"* ]; then
                    success "配置文件备份验证通过"
                else
                    warning "配置文件备份不存在"
                fi
                ;;
        esac
    done

    # 清理临时目录
    if [ -n "$temp_dir" ] && [ -d "$temp_dir" ]; then
        rm -rf "$temp_dir"
    fi

    # 显示验证结果
    echo -e "\n${BLUE}=== 验证结果 ===${NC}"
    if [ ${#issues[@]} -eq 0 ]; then
        success "备份文件完整性验证通过"
        return 0
    else
        warning "备份文件存在以下问题："
        for issue in "${issues[@]}"; do
            echo "  ❌ $issue"
        done
        return 1
    fi
}

# 确认恢复操作
confirm_restore() {
    local backup_path="$1"
    local force_flag="$2"

    if [ "$force_flag" = true ]; then
        return 0
    fi

    echo -e "${YELLOW}警告: 恢复操作将覆盖现有数据！${NC}"
    echo "即将从以下位置恢复数据: $backup_path"
    echo ""

    # 显示当前系统状态
    echo "当前运行的服务："
    for service in mysql postgres redis dify_api dify_web n8n oneapi ragflow elasticsearch minio nginx; do
        if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_${service}"; then
            echo "  ✅ $service"
        fi
    done

    echo ""
    read -p "确定要继续吗？(输入 'yes' 确认): " confirm

    if [ "$confirm" != "yes" ]; then
        log "恢复操作已取消"
        exit 0
    fi
}

# 停止相关服务
stop_services_for_restore() {
    local services=("$@")

    log "停止相关服务..."

    if [ ${#services[@]} -eq 0 ]; then
        # 停止所有服务
        log "停止所有服务..."
        docker-compose -f docker-compose-nginx.yml down 2>/dev/null || true
        docker-compose -f docker-compose-dify.yml down 2>/dev/null || true
        docker-compose -f docker-compose-n8n.yml down 2>/dev/null || true
        docker-compose -f docker-compose-oneapi.yml down 2>/dev/null || true
        docker-compose -f docker-compose-ragflow.yml down 2>/dev/null || true
        docker-compose -f docker-compose-db.yml down 2>/dev/null || true
    else
        # 停止指定服务
        for service in "${services[@]}"; do
            case "$service" in
                mysql|postgres|redis)
                    docker-compose -f docker-compose-db.yml stop "$service" 2>/dev/null || true
                    ;;
                dify*)
                    docker-compose -f docker-compose-dify.yml down 2>/dev/null || true
                    ;;
                n8n)
                    docker-compose -f docker-compose-n8n.yml down 2>/dev/null || true
                    ;;
                oneapi)
                    docker-compose -f docker-compose-oneapi.yml down 2>/dev/null || true
                    ;;
                ragflow|elasticsearch|minio)
                    docker-compose -f docker-compose-ragflow.yml down 2>/dev/null || true
                    ;;
                nginx)
                    docker-compose -f docker-compose-nginx.yml down 2>/dev/null || true
                    ;;
            esac
        done
    fi

    sleep 10
    success "服务已停止"
}

# 启动相关服务
start_services_after_restore() {
    local services=("$@")

    log "启动服务..."

    if [ ${#services[@]} -eq 0 ]; then
        # 启动所有服务
        log "按顺序启动所有服务..."

        # 启动基础服务
        docker-compose -f docker-compose-db.yml up -d 2>/dev/null
        sleep 45

        # 等待数据库服务完全启动
        wait_for_service "mysql" "mysqladmin ping -h localhost -u root -p${DB_*} --silent" 60
        wait_for_service "postgres" "pg_isready -U postgres" 60
        wait_for_service "redis" "redis-cli ping" 30

        # 启动应用服务
        docker-compose -f docker-compose-oneapi.yml up -d 2>/dev/null || true
        sleep 15

        # 启动RAGFlow
        if [ -f "docker-compose-ragflow.yml" ]; then
            docker-compose -f docker-compose-ragflow.yml up -d elasticsearch 2>/dev/null || true
            wait_for_service "elasticsearch" "curl -f http://localhost:9200/_cluster/health" 120

            docker-compose -f docker-compose-ragflow.yml up -d minio 2>/dev/null || true
            wait_for_service "minio" "curl -f http://localhost:9000/minio/health/live" 60

            docker-compose -f docker-compose-ragflow.yml up -d ragflow 2>/dev/null || true
            sleep 30
        fi

        # 启动Dify
        if [ -f "docker-compose-dify.yml" ]; then
            docker-compose -f docker-compose-dify.yml up -d dify_sandbox 2>/dev/null || true
            sleep 20
            docker-compose -f docker-compose-dify.yml up -d dify_api dify_worker 2>/dev/null || true
            sleep 20
            docker-compose -f docker-compose-dify.yml up -d dify_web 2>/dev/null || true
            sleep 15
        fi

        # 启动n8n
        docker-compose -f docker-compose-n8n.yml up -d 2>/dev/null || true
        sleep 15

        # 最后启动Nginx
        docker-compose -f docker-compose-nginx.yml up -d 2>/dev/null || true
        sleep 10
    else
        # 启动指定服务
        for service in "${services[@]}"; do
            case "$service" in
                mysql|postgres|redis)
                    docker-compose -f docker-compose-db.yml start "$service" 2>/dev/null || true
                    ;;
                dify*)
                    docker-compose -f docker-compose-dify.yml up -d 2>/dev/null || true
                    ;;
                n8n)
                    docker-compose -f docker-compose-n8n.yml up -d 2>/dev/null || true
                    ;;
                oneapi)
                    docker-compose -f docker-compose-oneapi.yml up -d 2>/dev/null || true
                    ;;
                ragflow|elasticsearch|minio)
                    docker-compose -f docker-compose-ragflow.yml up -d 2>/dev/null || true
                    ;;
                nginx)
                    docker-compose -f docker-compose-nginx.yml up -d 2>/dev/null || true
                    ;;
            esac
        done
    fi

    success "服务已启动"
}

# 解压备份文件
extract_backup() {
    local backup_file="$1"
    local extract_dir="$2"

    log "解压备份文件: $backup_file"

    mkdir -p "$extract_dir"
    tar -xzf "$backup_file" -C "$extract_dir" --strip-components=1 2>/dev/null

    if [ $? -eq 0 ]; then
        success "备份文件解压完成"
        return 0
    else
        error "备份文件解压失败"
        return 1
    fi
}

# 恢复MySQL数据库
restore_mysql() {
    local backup_dir="$1"
    local mysql_backup=""

    # 查找MySQL备份文件
    if [ -f "$backup_dir/mysql/mysql_all_databases.sql" ]; then
        mysql_backup="$backup_dir/mysql/mysql_all_databases.sql"
    elif [ -f "$backup_dir/mysql_all_databases.sql" ]; then
        mysql_backup="$backup_dir/mysql_all_databases.sql"
    fi

    if [ -z "$mysql_backup" ] || [ ! -f "$mysql_backup" ]; then
        warning "未找到MySQL备份文件"
        return 1
    fi

    log "开始恢复MySQL数据库..."

    # 确保MySQL服务运行
    if ! docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_mysql"; then
        docker-compose -f docker-compose-db.yml start mysql
        wait_for_service "mysql" "mysqladmin ping -h localhost -u root -p${DB_*} --silent" 60
    fi

    # 恢复数据库
    docker exec -i "${CONTAINER_PREFIX}_mysql" mysql -u root -p"${DB_*}" < "$mysql_backup" 2>/dev/null

    if [ $? -eq 0 ]; then
        success "MySQL数据库恢复完成"
        return 0
    else
        error "MySQL数据库恢复失败"
        return 1
    fi
}

# 恢复PostgreSQL数据库
restore_postgres() {
    local backup_dir="$1"
    local postgres_backup=""

    # 查找PostgreSQL备份文件
    if [ -f "$backup_dir/postgres/postgres_all_databases.sql" ]; then
        postgres_backup="$backup_dir/postgres/postgres_all_databases.sql"
    elif [ -f "$backup_dir/postgres_all_databases.sql" ]; then
        postgres_backup="$backup_dir/postgres_all_databases.sql"
    fi

    if [ -z "$postgres_backup" ] || [ ! -f "$postgres_backup" ]; then
        warning "未找到PostgreSQL备份文件"
        return 1
    fi

    log "开始恢复PostgreSQL数据库..."

    # 确保PostgreSQL服务运行
    if ! docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_postgres"; then
        docker-compose -f docker-compose-db.yml start postgres
        wait_for_service "postgres" "pg_isready -U postgres" 60
    fi

    # 恢复数据库
    docker exec -i -e PG*="${DB_*}" "${CONTAINER_PREFIX}_postgres" psql -U postgres < "$postgres_backup" 2>/dev/null

    if [ $? -eq 0 ]; then
        success "PostgreSQL数据库恢复完成"
        return 0
    else
        error "PostgreSQL数据库恢复失败"
        return 1
    fi
}

# 恢复Redis数据
restore_redis() {
    local backup_dir="$1"
    local redis_backup=""

    # 查找Redis备份文件
    if [ -f "$backup_dir/redis/redis_dump.rdb" ]; then
        redis_backup="$backup_dir/redis/redis_dump.rdb"
    elif [ -f "$backup_dir/redis_dump.rdb" ]; then
        redis_backup="$backup_dir/redis_dump.rdb"
    fi

    if [ -z "$redis_backup" ] || [ ! -f "$redis_backup" ]; then
        warning "未找到Redis备份文件"
        return 1
    fi

    log "开始恢复Redis数据..."

    # 停止Redis服务
    docker-compose -f docker-compose-db.yml stop redis 2>/dev/null || true
    sleep 5

    # 恢复Redis数据文件
    docker cp "$redis_backup" "${CONTAINER_PREFIX}_redis:/data/dump.rdb" 2>/dev/null

    # 启动Redis服务
    docker-compose -f docker-compose-db.yml start redis 2>/dev/null
    wait_for_service "redis" "redis-cli ping" 30

    if [ $? -eq 0 ]; then
        success "Redis数据恢复完成"
        return 0
    else
        error "Redis数据恢复失败"
        return 1
    fi
}

# 恢复Dify系统数据
restore_dify() {
    local backup_dir="$1"

    log "开始恢复Dify系统数据..."

    local restored=false

    # 停止Dify服务
    docker-compose -f docker-compose-dify.yml stop 2>/dev/null || true

    # 恢复app目录
    if [ -d "$backup_dir/dify/app" ] || [ -d "$backup_dir/app" ]; then
        local source_dir="$backup_dir/app"
        [ -d "$backup_dir/dify/app" ] && source_dir="$backup_dir/dify/app"

        rm -rf "$INSTALL_PATH/volumes/app" 2>/dev/null
        cp -r "$source_dir" "$INSTALL_PATH/volumes/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "Dify应用数据恢复完成"
            restored=true
        fi
    fi

    # 恢复dify配置目录
    if [ -d "$backup_dir/dify/dify" ] || [ -d "$backup_dir/dify" ]; then
        local source_dir="$backup_dir/dify"
        [ -d "$backup_dir/dify/dify" ] && source_dir="$backup_dir/dify/dify"

        rm -rf "$INSTALL_PATH/volumes/dify" 2>/dev/null
        cp -r "$source_dir" "$INSTALL_PATH/volumes/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "Dify配置数据恢复完成"
            restored=true
        fi
    fi

    # 恢复sandbox目录
    if [ -d "$backup_dir/dify/sandbox" ] || [ -d "$backup_dir/sandbox" ]; then
        local source_dir="$backup_dir/sandbox"
        [ -d "$backup_dir/dify/sandbox" ] && source_dir="$backup_dir/dify/sandbox"

        rm -rf "$INSTALL_PATH/volumes/sandbox" 2>/dev/null
        cp -r "$source_dir" "$INSTALL_PATH/volumes/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "Dify沙箱数据恢复完成"
            restored=true
        fi
    fi

    if [ "$restored" = true ]; then
        success "Dify系统数据恢复完成"
        return 0
    else
        warning "未找到Dify备份数据"
        return 1
    fi
}

# 恢复n8n系统数据
restore_n8n() {
    local backup_dir="$1"
    local source_dir=""

    if [ -d "$backup_dir/n8n/n8n" ]; then
        source_dir="$backup_dir/n8n/n8n"
    elif [ -d "$backup_dir/n8n" ]; then
        source_dir="$backup_dir/n8n"
    fi

    if [ -z "$source_dir" ] || [ ! -d "$source_dir" ]; then
        warning "未找到n8n备份数据"
        return 1
    fi

    log "开始恢复n8n系统数据..."

    # 停止n8n服务
    docker-compose -f docker-compose-n8n.yml stop 2>/dev/null || true

    # 恢复n8n数据
    rm -rf "$INSTALL_PATH/volumes/n8n" 2>/dev/null
    cp -r "$source_dir" "$INSTALL_PATH/volumes/" 2>/dev/null

    # 设置正确的权限
    chown -R 1000:1000 "$INSTALL_PATH/volumes/n8n/data" 2>/dev/null || true

    if [ $? -eq 0 ]; then
        success "n8n系统数据恢复完成"
        return 0
    else
        error "n8n系统数据恢复失败"
        return 1
    fi
}

# 恢复OneAPI系统数据
restore_oneapi() {
    local backup_dir="$1"
    local source_dir=""

    if [ -d "$backup_dir/oneapi/oneapi" ]; then
        source_dir="$backup_dir/oneapi/oneapi"
    elif [ -d "$backup_dir/oneapi" ]; then
        source_dir="$backup_dir/oneapi"
    fi

    if [ -z "$source_dir" ] || [ ! -d "$source_dir" ]; then
        warning "未找到OneAPI备份数据"
        return 1
    fi

    log "开始恢复OneAPI系统数据..."

    # 停止OneAPI服务
    docker-compose -f docker-compose-oneapi.yml stop 2>/dev/null || true

    # 恢复OneAPI数据
    rm -rf "$INSTALL_PATH/volumes/oneapi" 2>/dev/null
    cp -r "$source_dir" "$INSTALL_PATH/volumes/" 2>/dev/null

    if [ $? -eq 0 ]; then
        success "OneAPI系统数据恢复完成"
        return 0
    else
        error "OneAPI系统数据恢复失败"
        return 1
    fi
}

# 恢复RAGFlow系统数据
restore_ragflow() {
    local backup_dir="$1"

    log "开始恢复RAGFlow系统数据..."

    local restored=false

    # 停止RAGFlow服务
    docker-compose -f docker-compose-ragflow.yml stop 2>/dev/null || true

    # 恢复RAGFlow应用数据
    if [ -d "$backup_dir/ragflow/ragflow" ] || [ -d "$backup_dir/ragflow" ]; then
        local source_dir="$backup_dir/ragflow"
        [ -d "$backup_dir/ragflow/ragflow" ] && source_dir="$backup_dir/ragflow/ragflow"

        rm -rf "$INSTALL_PATH/volumes/ragflow/ragflow" 2>/dev/null
        cp -r "$source_dir" "$INSTALL_PATH/volumes/ragflow/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "RAGFlow应用数据恢复完成"
            restored=true
        fi
    fi

    # 恢复Elasticsearch数据
    if [ -d "$backup_dir/ragflow/elasticsearch" ] || [ -d "$backup_dir/elasticsearch" ]; then
        local source_dir="$backup_dir/elasticsearch"
        [ -d "$backup_dir/ragflow/elasticsearch" ] && source_dir="$backup_dir/ragflow/elasticsearch"

        rm -rf "$INSTALL_PATH/volumes/ragflow/elasticsearch" 2>/dev/null
        cp -r "$source_dir" "$INSTALL_PATH/volumes/ragflow/" 2>/dev/null
        chown -R 1000:1000 "$INSTALL_PATH/volumes/ragflow/elasticsearch" 2>/dev/null || true
        if [ $? -eq 0 ]; then
            success "Elasticsearch数据恢复完成"
            restored=true
        fi
    fi

    # 恢复MinIO数据
    if [ -d "$backup_dir/ragflow/minio" ] || [ -d "$backup_dir/minio" ]; then
        local source_dir="$backup_dir/minio"
        [ -d "$backup_dir/ragflow/minio" ] && source_dir="$backup_dir/ragflow/minio"

        rm -rf "$INSTALL_PATH/volumes/ragflow/minio" 2>/dev/null
        cp -r "$source_dir" "$INSTALL_PATH/volumes/ragflow/" 2>/dev/null
        chown -R 1001:1001 "$INSTALL_PATH/volumes/ragflow/minio" 2>/dev/null || true
        if [ $? -eq 0 ]; then
            success "MinIO数据恢复完成"
            restored=true
        fi
    fi

    # 恢复模型缓存
    if [ -d "$backup_dir/ragflow/huggingface" ] || [ -d "$backup_dir/huggingface" ]; then
        local source_dir="$backup_dir/huggingface"
        [ -d "$backup_dir/ragflow/huggingface" ] && source_dir="$backup_dir/ragflow/huggingface"

        log "恢复模型缓存（可能需要较长时间）..."
        rm -rf "$INSTALL_PATH/volumes/ragflow/huggingface" 2>/dev/null
        cp -r "$source_dir" "$INSTALL_PATH/volumes/ragflow/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "模型缓存恢复完成"
            restored=true
        fi
    fi

    # 恢复NLTK数据
    if [ -d "$backup_dir/ragflow/nltk_data" ] || [ -d "$backup_dir/nltk_data" ]; then
        local source_dir="$backup_dir/nltk_data"
        [ -d "$backup_dir/ragflow/nltk_data" ] && source_dir="$backup_dir/ragflow/nltk_data"

        rm -rf "$INSTALL_PATH/volumes/ragflow/nltk_data" 2>/dev/null
        cp -r "$source_dir" "$INSTALL_PATH/volumes/ragflow/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "NLTK数据恢复完成"
            restored=true
        fi
    fi

    if [ "$restored" = true ]; then
        success "RAGFlow系统数据恢复完成"
        return 0
    else
        warning "未找到RAGFlow备份数据"
        return 1
    fi
}

# 恢复配置文件
restore_config() {
    local backup_dir="$1"

    log "开始恢复配置文件..."

    local restored=false

    # 恢复配置目录
    if [ -d "$backup_dir/config/config" ] || [ -d "$backup_dir/config" ]; then
        local source_dir="$backup_dir/config"
        [ -d "$backup_dir/config/config" ] && source_dir="$backup_dir/config/config"

        backup_file "$INSTALL_PATH/config"
        rm -rf "$INSTALL_PATH/config" 2>/dev/null
        cp -r "$source_dir" "$INSTALL_PATH/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "配置文件恢复完成"
            restored=true
        fi
    fi

    # 恢复Docker Compose文件
    for compose_file in "$backup_dir"/docker-compose*.yml; do
        if [ -f "$compose_file" ]; then
            local filename=$(basename "$compose_file")
            backup_file "$INSTALL_PATH/$filename"
            cp "$compose_file" "$INSTALL_PATH/" 2>/dev/null
            if [ $? -eq 0 ]; then
                success "Docker Compose文件恢复完成: $filename"
                restored=true
            fi
        fi
    done

    # 恢复脚本文件
    if [ -d "$backup_dir/config/scripts" ] || [ -d "$backup_dir/scripts" ]; then
        local source_dir="$backup_dir/scripts"
        [ -d "$backup_dir/config/scripts" ] && source_dir="$backup_dir/config/scripts"

        backup_file "$INSTALL_PATH/scripts"
        rm -rf "$INSTALL_PATH/scripts" 2>/dev/null
        cp -r "$source_dir" "$INSTALL_PATH/" 2>/dev/null
        chmod +x "$INSTALL_PATH/scripts"/*.sh 2>/dev/null
        if [ $? -eq 0 ]; then
            success "脚本文件恢复完成"
            restored=true
        fi
    fi

    # 恢复模块文件
    if [ -d "$backup_dir/config/modules" ] || [ -d "$backup_dir/modules" ]; then
        local source_dir="$backup_dir/modules"
        [ -d "$backup_dir/config/modules" ] && source_dir="$backup_dir/config/modules"

        backup_file "$INSTALL_PATH/modules"
        rm -rf "$INSTALL_PATH/modules" 2>/dev/null
        cp -r "$source_dir" "$INSTALL_PATH/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "模块文件恢复完成"
            restored=true
        fi
    fi

    if [ "$restored" = true ]; then
        return 0
    else
        warning "未找到配置文件备份"
        return 1
    fi
}

# 选择性恢复
selective_restore() {
    local backup_dir="$1"

    echo -e "${BLUE}=== 选择性恢复 ===${NC}"
    echo "可恢复的组件："

    local components=()
    local available_components=()

    # 检查可用组件
    [ -f "$backup_dir/mysql"* ] || [ -d "$backup_dir/mysql" ] && available_components+=("mysql")
    [ -f "$backup_dir/postgres"* ] || [ -d "$backup_dir/postgres" ] && available_components+=("postgres")
    [ -f "$backup_dir/redis"* ] || [ -d "$backup_dir/redis" ] && available_components+=("redis")
    [ -d "$backup_dir/dify" ] && available_components+=("dify")
    [ -d "$backup_dir/n8n" ] && available_components+=("n8n")
    [ -d "$backup_dir/oneapi" ] && available_components+=("oneapi")
    [ -d "$backup_dir/ragflow" ] && available_components+=("ragflow")
    [ -d "$backup_dir/config" ] || [ -f "$backup_dir/docker-compose"* ] && available_components+=("config")

    if [ ${#available_components[@]} -eq 0 ]; then
        error "未找到可恢复的组件"
        return 1
    fi

    # 显示可选组件
    local i=1
    for component in "${available_components[@]}"; do
        echo "  $i) $component"
        ((i++))
    done
    echo "  0) 全部组件"

    echo ""
    read -p "请选择要恢复的组件（多个组件用空格分隔，如: 1 3 5）: " selections

    if [ -z "$selections" ]; then
        log "未选择任何组件"
        return 0
    fi

    # 处理选择
    for selection in $selections; do
        if [ "$selection" = "0" ]; then
            components=("${available_components[@]}")
            break
        elif [ "$selection" -ge 1 ] && [ "$selection" -le ${#available_components[@]} ]; then
            local idx=$((selection - 1))
            components+=("${available_components[$idx]}")
        else
            warning "无效选择: $selection"
        fi
    done

    if [ ${#components[@]} -eq 0 ]; then
        log "未选择有效组件"
        return 0
    fi

    echo ""
    echo "将恢复以下组件: ${components[*]}"
    read -p "确认继续？(y/N): " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log "操作已取消"
        return 0
    fi

    # 执行选择性恢复
    local success_count=0
    for component in "${components[@]}"; do
        case "$component" in
            mysql)
                restore_mysql "$backup_dir" && ((success_count++))
                ;;
            postgres)
                restore_postgres "$backup_dir" && ((success_count++))
                ;;
            redis)
                restore_redis "$backup_dir" && ((success_count++))
                ;;
            dify)
                restore_dify "$backup_dir" && ((success_count++))
                ;;
            n8n)
                restore_n8n "$backup_dir" && ((success_count++))
                ;;
            oneapi)
                restore_oneapi "$backup_dir" && ((success_count++))
                ;;
            ragflow)
                restore_ragflow "$backup_dir" && ((success_count++))
                ;;
            config)
                restore_config "$backup_dir" && ((success_count++))
                ;;
        esac
    done

    success "选择性恢复完成: ${success_count}/${#components[@]} 个组件成功"
}

# 完整系统恢复
restore_full_system() {
    local backup_dir="$1"
    local dry_run="$2"
    local exclude_components=("$@")

    log "开始完整系统恢复..."

    if [ "$dry_run" = true ]; then
        echo -e "${BLUE}=== 预览恢复操作 ===${NC}"
        [ -f "$backup_dir/mysql"* ] && [[ ! " ${exclude_components[@]} " =~ " mysql " ]] && echo "✓ 将恢复MySQL数据库"
        [ -f "$backup_dir/postgres"* ] && [[ ! " ${exclude_components[@]} " =~ " postgres " ]] && echo "✓ 将恢复PostgreSQL数据库"
        [ -f "$backup_dir/redis"* ] && [[ ! " ${exclude_components[@]} " =~ " redis " ]] && echo "✓ 将恢复Redis数据"
        [ -d "$backup_dir/dify" ] && [[ ! " ${exclude_components[@]} " =~ " dify " ]] && echo "✓ 将恢复Dify系统数据"
        [ -d "$backup_dir/n8n" ] && [[ ! " ${exclude_components[@]} " =~ " n8n " ]] && echo "✓ 将恢复n8n系统数据"
        [ -d "$backup_dir/oneapi" ] && [[ ! " ${exclude_components[@]} " =~ " oneapi " ]] && echo "✓ 将恢复OneAPI系统数据"
        [ -d "$backup_dir/ragflow" ] && [[ ! " ${exclude_components[@]} " =~ " ragflow " ]] && echo "✓ 将恢复RAGFlow系统数据"
        [ -d "$backup_dir/config" ] && [[ ! " ${exclude_components[@]} " =~ " config " ]] && echo "✓ 将恢复配置文件"
        return 0
    fi

    local success_count=0
    local total_count=0

    # 停止所有服务
    stop_services_for_restore

    # 恢复配置文件（优先）
    if [ -d "$backup_dir/config" ] && [[ ! " ${exclude_components[@]} " =~ " config " ]]; then
        ((total_count++))
        restore_config "$backup_dir" && ((success_count++))
    fi

    # 启动数据库服务
    log "启动数据库服务..."
    docker-compose -f docker-compose-db.yml up -d 2>/dev/null
    sleep 45

    # 等待数据库启动
    wait_for_service "mysql" "mysqladmin ping -h localhost -u root -p${DB_*} --silent" 60
    wait_for_service "postgres" "pg_isready -U postgres" 60
    wait_for_service "redis" "redis-cli ping" 30

    # 恢复数据库
    if [[ ! " ${exclude_components[@]} " =~ " mysql " ]]; then
        ((total_count++))
        restore_mysql "$backup_dir" && ((success_count++))
    fi

    if [[ ! " ${exclude_components[@]} " =~ " postgres " ]]; then
        ((total_count++))
        restore_postgres "$backup_dir" && ((success_count++))
    fi

    if [[ ! " ${exclude_components[@]} " =~ " redis " ]]; then
        ((total_count++))
        restore_redis "$backup_dir" && ((success_count++))
    fi

    # 恢复应用数据
    if [[ ! " ${exclude_components[@]} " =~ " dify " ]]; then
        ((total_count++))
        restore_dify "$backup_dir" && ((success_count++))
    fi

    if [[ ! " ${exclude_components[@]} " =~ " n8n " ]]; then
        ((total_count++))
        restore_n8n "$backup_dir" && ((success_count++))
    fi

    if [[ ! " ${exclude_components[@]} " =~ " oneapi " ]]; then
        ((total_count++))
        restore_oneapi "$backup_dir" && ((success_count++))
    fi

    if [[ ! " ${exclude_components[@]} " =~ " ragflow " ]]; then
        ((total_count++))
        restore_ragflow "$backup_dir" && ((success_count++))
    fi

    # 启动所有服务
    start_services_after_restore

    # 等待服务完全启动
    log "等待服务完全启动..."
    sleep 90

    success "完整系统恢复完成"
    success "成功恢复 ${success_count}/${total_count} 个组件"

    return 0
}

# 生成恢复报告
generate_restore_report() {
    local backup_path="$1"
    local restore_components=("$@")

    local report_file="$INSTALL_PATH/logs/restore_report_$(date +%Y%m%d_%H%M%S).txt"
    mkdir -p "$(dirname "$report_file")"

    {
        echo "数据恢复报告"
        echo "============"
        echo "恢复时间: $(date)"
        echo "备份来源: $backup_path"
        echo ""

        echo "恢复的组件:"
        for component in "${restore_components[@]}"; do
            echo "- $component"
        done
        echo ""

        echo "服务状态检查:"
        for service in mysql postgres redis dify_api dify_web n8n oneapi ragflow elasticsearch minio nginx; do
            if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_${service}"; then
                echo "✅ $service: 运行中"
            else
                echo "❌ $service: 未运行"
            fi
        done

    } > "$report_file"

    success "恢复报告已生成: $report_file"
}

# 主函数
main() {
    local backup_path=""
    local force_flag=false
    local dry_run=false
    local list_flag=false
    local selective_flag=false
    local verify_flag=false
    local exclude_components=()

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--force)
                force_flag=true
                shift
                ;;
            -l|--list)
                list_flag=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --selective)
                selective_flag=true
                shift
                ;;
            --exclude)
                exclude_components+=("$2")
                shift 2
                ;;
            --verify)
                verify_flag=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                error "未知选项: $1"
                show_help
                exit 1
                ;;
            *)
                if [ -z "$backup_path" ]; then
                    backup_path="$1"
                fi
                shift
                ;;
        esac
    done

    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}     AI服务集群数据恢复工具${NC}"
    echo -e "${GREEN}======================================${NC}"

    # 如果只是列出备份
    if [ "$list_flag" = true ]; then
        list_backups
        exit 0
    fi

    # 检查备份路径
    if [ -z "$backup_path" ]; then
        error "请指定备份路径"
        show_help
        exit 1
    fi

    # 检查备份路径是否存在
    if [ ! -e "$backup_path" ]; then
        error "备份路径不存在: $backup_path"
        exit 1
    fi

    # 如果只是验证备份
    if [ "$verify_flag" = true ]; then
        verify_backup "$backup_path"
        exit $?
    fi

    # 验证备份完整性
    if ! verify_backup "$backup_path"; then
        warning "备份文件验证失败，但仍可以尝试恢复"
        if [ "$force_flag" = false ]; then
            read -p "是否继续恢复？(y/N): " continue_restore
            if [[ ! "$continue_restore" =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    fi

    # 确认恢复操作
    confirm_restore "$backup_path" "$force_flag"

    local temp_dir=""
    local restore_dir="$backup_path"

    # 如果是压缩包，先解压
    if [[ "$backup_path" == *.tar.gz ]]; then
        temp_dir="/tmp/restore_$(date +%s)"
        extract_backup "$backup_path" "$temp_dir" || exit 1
        restore_dir="$temp_dir"
    fi

    # 选择性恢复
    if [ "$selective_flag" = true ]; then
        selective_restore "$restore_dir"
    # 判断备份类型并执行相应的恢复
    elif [ -f "$restore_dir/backup_summary.txt" ]; then
        # 完整系统备份
        log "检测到完整系统备份"
        restore_full_system "$restore_dir" "$dry_run" "${exclude_components[@]}"
    elif [ -f "$restore_dir/mysql_all_databases.sql" ] || [ -d "$restore_dir/mysql" ]; then
        # MySQL备份
        log "检测到MySQL备份"
        if [ "$dry_run" = false ]; then
            stop_services_for_restore mysql
            restore_mysql "$restore_dir"
            start_services_after_restore mysql
        else
            echo "✓ 将恢复MySQL数据库"
        fi
    elif [ -f "$restore_dir/postgres_all_databases.sql" ] || [ -d "$restore_dir/postgres" ]; then
        # PostgreSQL备份
        log "检测到PostgreSQL备份"
        if [ "$dry_run" = false ]; then
            stop_services_for_restore postgres
            restore_postgres "$restore_dir"
            start_services_after_restore postgres
        else
            echo "✓ 将恢复PostgreSQL数据库"
        fi
    elif [ -f "$restore_dir/redis_dump.rdb" ] || [ -d "$restore_dir/redis" ]; then
        # Redis备份
        log "检测到Redis备份"
        if [ "$dry_run" = false ]; then
            restore_redis "$restore_dir"
        else
            echo "✓ 将恢复Redis数据"
        fi
    elif [ -d "$restore_dir/dify" ] || [ -d "$restore_dir/app" ]; then
        # Dify备份
        log "检测到Dify系统备份"
        if [ "$dry_run" = false ]; then
            restore_dify "$restore_dir"
        else
            echo "✓ 将恢复Dify系统数据"
        fi
    elif [ -d "$restore_dir/n8n" ]; then
        # n8n备份
        log "检测到n8n系统备份"
        if [ "$dry_run" = false ]; then
            restore_n8n "$restore_dir"
        else
            echo "✓ 将恢复n8n系统数据"
        fi
    elif [ -d "$restore_dir/oneapi" ]; then
        # OneAPI备份
        log "检测到OneAPI系统备份"
        if [ "$dry_run" = false ]; then
            restore_oneapi "$restore_dir"
        else
            echo "✓ 将恢复OneAPI系统数据"
        fi
    elif [ -d "$restore_dir/ragflow" ]; then
        # RAGFlow备份
        log "检测到RAGFlow系统备份"
        if [ "$dry_run" = false ]; then
            restore_ragflow "$restore_dir"
        else
            echo "✓ 将恢复RAGFlow系统数据"
        fi
    elif [ -d "$restore_dir/config" ] || [ -f "$restore_dir/docker-compose"* ]; then
        # 配置备份
        log "检测到配置文件备份"
        if [ "$dry_run" = false ]; then
            restore_config "$restore_dir"
        else
            echo "✓ 将恢复配置文件"
        fi
    else
        error "无法识别的备份格式"
        exit 1
    fi

    # 清理临时目录
    if [ -n "$temp_dir" ] && [ -d "$temp_dir" ]; then
        rm -rf "$temp_dir"
    fi

    if [ "$dry_run" = true ]; then
        success "预览完成"
    else
        # 生成恢复报告
        generate_restore_report "$backup_path"

        success "恢复操作完成"
        echo ""
        echo "建议操作："
        echo "1. 等待2-3分钟让服务完全启动"
        echo "2. 检查服务状态: ./scripts/manage.sh status"
        echo "3. 查看服务日志: ./scripts/logs.sh [服务名]"
        echo "4. 测试服务功能是否正常"
        echo ""
        if [ ${#exclude_components[@]} -gt 0 ]; then
            warning "注意: 以下组件已被排除，未进行恢复: ${exclude_components[*]}"
        fi
    fi
}

# 运行主函数
main "$@"