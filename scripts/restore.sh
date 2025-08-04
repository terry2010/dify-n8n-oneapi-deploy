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
    echo "  -h, --help       显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 backup/full_backup_20241201_143022    # 从指定目录恢复"
    echo "  $0 backup/mysql_20241201_143022          # 恢复MySQL备份"
    echo "  $0 backup/full_backup_20241201_143022.tar.gz  # 从压缩包恢复"
    echo "  $0 --list                                # 列出所有备份"
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

    # 列出目录形式的备份
    find "$BACKUP_BASE_DIR" -maxdepth 1 -type d -name "*_*" | sort -r | while read backup_dir; do
        if [ -f "$backup_dir/backup_info.txt" ] || [ -f "$backup_dir/backup_summary.txt" ]; then
            local backup_name=$(basename "$backup_dir")
            local backup_time=""

            if [[ $backup_name =~ _([0-9]{8}_[0-9]{6})$ ]]; then
                backup_time=${BASH_REMATCH[1]}
                backup_time=$(echo $backup_time | sed 's/_/ /' | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3/')
            fi

            local size=$(du -sh "$backup_dir" 2>/dev/null | cut -f1)
            echo "📁 $backup_name ($backup_time, $size)"
            backup_found=true
        fi
    done

    # 列出压缩包形式的备份
    find "$BACKUP_BASE_DIR" -maxdepth 1 -name "*.tar.gz" | sort -r | while read backup_file; do
        local backup_name=$(basename "$backup_file" .tar.gz)
        local backup_time=""

        if [[ $backup_name =~ _([0-9]{8}_[0-9]{6})$ ]]; then
            backup_time=${BASH_REMATCH[1]}
            backup_time=$(echo $backup_time | sed 's/_/ /' | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3/')
        fi

        local size=$(du -sh "$backup_file" 2>/dev/null | cut -f1)
        echo "📦 $backup_name.tar.gz ($backup_time, $size)"
        backup_found=true
    done

    if [ "$backup_found" = false ]; then
        warning "未找到任何备份文件"
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
        docker-compose -f docker-compose-nginx.yml down 2>/dev/null || true
        docker-compose -f docker-compose-dify.yml down 2>/dev/null || true
        docker-compose -f docker-compose-n8n.yml down 2>/dev/null || true
        docker-compose -f docker-compose-oneapi.yml down 2>/dev/null || true
        docker-compose -f docker-compose-db.yml down 2>/dev/null || true
    else
        # 停止指定服务
        for service in "${services[@]}"; do
            case "$service" in
                mysql|postgres|redis)
                    docker-compose -f docker-compose-db.yml stop "$service" 2>/dev/null || true
                    ;;
                dify_*)
                    docker-compose -f docker-compose-dify.yml stop "$service" 2>/dev/null || true
                    ;;
                n8n)
                    docker-compose -f docker-compose-n8n.yml stop "$service" 2>/dev/null || true
                    ;;
                oneapi)
                    docker-compose -f docker-compose-oneapi.yml stop "$service" 2>/dev/null || true
                    ;;
                nginx)
                    docker-compose -f docker-compose-nginx.yml stop "$service" 2>/dev/null || true
                    ;;
            esac
        done
    fi

    sleep 5
    success "服务已停止"
}

# 启动相关服务
start_services_after_restore() {
    local services=("$@")

    log "启动服务..."

    if [ ${#services[@]} -eq 0 ]; then
        # 启动所有服务
        ./scripts/manage.sh start
    else
        # 启动指定服务
        for service in "${services[@]}"; do
            case "$service" in
                mysql|postgres|redis)
                    docker-compose -f docker-compose-db.yml start "$service" 2>/dev/null || true
                    ;;
                dify_*)
                    docker-compose -f docker-compose-dify.yml start "$service" 2>/dev/null || true
                    ;;
                n8n)
                    docker-compose -f docker-compose-n8n.yml start "$service" 2>/dev/null || true
                    ;;
                oneapi)
                    docker-compose -f docker-compose-oneapi.yml start "$service" 2>/dev/null || true
                    ;;
                nginx)
                    docker-compose -f docker-compose-nginx.yml start "$service" 2>/dev/null || true
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
    local mysql_backup="$backup_dir/mysql_all_databases.sql"

    if [ ! -f "$mysql_backup" ]; then
        warning "未找到MySQL备份文件: $mysql_backup"
        return 1
    fi

    log "开始恢复MySQL数据库..."

    # 确保MySQL服务运行
    if ! docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_mysql"; then
        docker-compose -f docker-compose-db.yml start mysql
        wait_for_service "mysql" "mysqladmin ping -h localhost -u root -p${DB_PASSWORD} --silent" 60
    fi

    # 恢复数据库
    docker exec -i "${CONTAINER_PREFIX}_mysql" mysql -u root -p"${DB_PASSWORD}" < "$mysql_backup" 2>/dev/null

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
    local postgres_backup="$backup_dir/postgres_all_databases.sql"

    if [ ! -f "$postgres_backup" ]; then
        warning "未找到PostgreSQL备份文件: $postgres_backup"
        return 1
    fi

    log "开始恢复PostgreSQL数据库..."

    # 确保PostgreSQL服务运行
    if ! docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_postgres"; then
        docker-compose -f docker-compose-db.yml start postgres
        wait_for_service "postgres" "pg_isready -U postgres" 60
    fi

    # 恢复数据库
    docker exec -i -e PGPASSWORD="${DB_PASSWORD}" "${CONTAINER_PREFIX}_postgres" psql -U postgres < "$postgres_backup" 2>/dev/null

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
    local redis_backup="$backup_dir/redis_dump.rdb"

    if [ ! -f "$redis_backup" ]; then
        warning "未找到Redis备份文件: $redis_backup"
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
    if [ -d "$backup_dir/app" ]; then
        rm -rf "$INSTALL_PATH/volumes/app" 2>/dev/null
        cp -r "$backup_dir/app" "$INSTALL_PATH/volumes/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "Dify应用数据恢复完成"
            restored=true
        fi
    fi

    # 恢复dify配置目录
    if [ -d "$backup_dir/dify" ]; then
        rm -rf "$INSTALL_PATH/volumes/dify" 2>/dev/null
        cp -r "$backup_dir/dify" "$INSTALL_PATH/volumes/" 2>/dev/null
        if [ $? -eq 0 ]; then
            success "Dify配置数据恢复完成"
            restored=true
        fi
    fi

    # 恢复sandbox目录
    if [ -d "$backup_dir/sandbox" ]; then
        rm -rf "$INSTALL_PATH/volumes/sandbox" 2>/dev/null
        cp -r "$backup_dir/sandbox" "$INSTALL_PATH/volumes/" 2>/dev/null
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

    if [ ! -d "$backup_dir/n8n" ]; then
        warning "未找到n8n备份数据: $backup_dir/n8n"
        return 1
    fi

    log "开始恢复n8n系统数据..."

    # 停止n8n服务
    docker-compose -f docker-compose-n8n.yml stop 2>/dev/null || true

    # 恢复n8n数据
    rm -rf "$INSTALL_PATH/volumes/n8n" 2>/dev/null
    cp -r "$backup_dir/n8n" "$INSTALL_PATH/volumes/" 2>/dev/null

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

    if [ ! -d "$backup_dir/oneapi" ]; then
        warning "未找到OneAPI备份数据: $backup_dir/oneapi"
        return 1
    fi

    log "开始恢复OneAPI系统数据..."

    # 停止OneAPI服务
    docker-compose -f docker-compose-oneapi.yml stop 2>/dev/null || true

    # 恢复OneAPI数据
    rm -rf "$INSTALL_PATH/volumes/oneapi" 2>/dev/null
    cp -r "$backup_dir/oneapi" "$INSTALL_PATH/volumes/" 2>/dev/null

    if [ $? -eq 0 ]; then
        success "OneAPI系统数据恢复完成"
        return 0
    else
        error "OneAPI系统数据恢复失败"
        return 1
    fi
}

# 恢复配置文件
restore_config() {
    local backup_dir="$1"

    log "开始恢复配置文件..."

    local restored=false

    # 恢复配置目录
    if [ -d "$backup_dir/config" ]; then
        backup_file "$INSTALL_PATH/config"
        rm -rf "$INSTALL_PATH/config" 2>/dev/null
        cp -r "$backup_dir/config" "$INSTALL_PATH/" 2>/dev/null
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
    if [ -d "$backup_dir/scripts" ]; then
        backup_file "$INSTALL_PATH/scripts"
        rm -rf "$INSTALL_PATH/scripts" 2>/dev/null
        cp -r "$backup_dir/scripts" "$INSTALL_PATH/" 2>/dev/null
        chmod +x "$INSTALL_PATH/scripts"/*.sh 2>/dev/null
        if [ $? -eq 0 ]; then
            success "脚本文件恢复完成"
            restored=true
        fi
    fi

    # 恢复模块文件
    if [ -d "$backup_dir/modules" ]; then
        backup_file "$INSTALL_PATH/modules"
        rm -rf "$INSTALL_PATH/modules" 2>/dev/null
        cp -r "$backup_dir/modules" "$INSTALL_PATH/" 2>/dev/null
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

# 完整系统恢复
restore_full_system() {
    local backup_dir="$1"
    local dry_run="$2"

    log "开始完整系统恢复..."

    if [ "$dry_run" = true ]; then
        echo -e "${BLUE}=== 预览恢复操作 ===${NC}"
        [ -f "$backup_dir/mysql/mysql_all_databases.sql" ] && echo "✓ 将恢复MySQL数据库"
        [ -f "$backup_dir/postgres/postgres_all_databases.sql" ] && echo "✓ 将恢复PostgreSQL数据库"
        [ -f "$backup_dir/redis/redis_dump.rdb" ] && echo "✓ 将恢复Redis数据"
        [ -d "$backup_dir/dify" ] && echo "✓ 将恢复Dify系统数据"
        [ -d "$backup_dir/n8n" ] && echo "✓ 将恢复n8n系统数据"
        [ -d "$backup_dir/oneapi" ] && echo "✓ 将恢复OneAPI系统数据"
        [ -d "$backup_dir/config" ] && echo "✓ 将恢复配置文件"
        return 0
    fi

    local success_count=0
    local total_count=7

    # 停止所有服务
    stop_services_for_restore

    # 恢复配置文件（优先）
    restore_config "$backup_dir" && ((success_count++))

    # 启动数据库服务
    log "启动数据库服务..."
    docker-compose -f docker-compose-db.yml up -d 2>/dev/null
    sleep 30

    # 恢复数据库
    restore_mysql "$backup_dir" && ((success_count++))
    restore_postgres "$backup_dir" && ((success_count++))
    restore_redis "$backup_dir" && ((success_count++))

    # 恢复应用数据
    restore_dify "$backup_dir" && ((success_count++))
    restore_n8n "$backup_dir" && ((success_count++))
    restore_oneapi "$backup_dir" && ((success_count++))

    # 启动所有服务
    start_services_after_restore

    # 等待服务完全启动
    log "等待服务完全启动..."
    sleep 60

    success "完整系统恢复完成"
    success "成功恢复 ${success_count}/${total_count} 个组件"

    return 0
}

# 主函数
main() {
    local backup_path=""
    local force_flag=false
    local dry_run=false
    local list_flag=false

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

    # 判断备份类型并执行相应的恢复
    if [ -f "$restore_dir/backup_summary.txt" ]; then
        # 完整系统备份
        log "检测到完整系统备份"
        restore_full_system "$restore_dir" "$dry_run"
    elif [ -f "$restore_dir/mysql_all_databases.sql" ]; then
        # MySQL备份
        log "检测到MySQL备份"
        if [ "$dry_run" = false ]; then
            restore_mysql "$restore_dir"
        else
            echo "✓ 将恢复MySQL数据库"
        fi
    elif [ -f "$restore_dir/postgres_all_databases.sql" ]; then
        # PostgreSQL备份
        log "检测到PostgreSQL备份"
        if [ "$dry_run" = false ]; then
            restore_postgres "$restore_dir"
        else
            echo "✓ 将恢复PostgreSQL数据库"
        fi
    elif [ -f "$restore_dir/redis_dump.rdb" ]; then
        # Redis备份
        log "检测到Redis备份"
        if [ "$dry_run" = false ]; then
            restore_redis "$restore_dir"
        else
            echo "✓ 将恢复Redis数据"
        fi
    elif [ -d "$restore_dir/app" ] || [ -d "$restore_dir/dify" ]; then
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
    elif [ -d "$restore_dir/config" ]; then
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
        success "恢复操作完成"
        echo ""
        echo "建议等待2-3分钟让服务完全启动，然后检查服务状态："
        echo "  ./scripts/manage.sh status"
    fi
}

# 运行主函数
main "$@"