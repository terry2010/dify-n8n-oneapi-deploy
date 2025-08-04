#!/bin/bash

# =========================================================
# 端口修改脚本
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

# 显示帮助信息
show_help() {
    echo "端口修改脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --dify <端口>            设置Dify Web端口"
    echo "  --n8n <端口>             设置n8n Web端口"
    echo "  --oneapi <端口>          设置OneAPI Web端口"
    echo "  --ragflow <端口>         设置RAGFlow Web端口"
    echo "  --mysql <端口>           设置MySQL端口"
    echo "  --postgres <端口>        设置PostgreSQL端口"
    echo "  --redis <端口>           设置Redis端口"
    echo "  --nginx <端口>           设置Nginx端口"
    echo "  --elasticsearch <端口>   设置Elasticsearch端口"
    echo "  --minio <端口>           设置MinIO API端口"
    echo "  --minio-console <端口>   设置MinIO控制台端口"
    echo "  --show                   显示当前端口配置"
    echo "  --check                  检查端口占用情况"
    echo "  --apply                  应用端口更改（重启相关服务）"
    echo "  --reset                  重置为默认端口"
    echo "  -h, --help               显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 --show                          # 显示当前端口配置"
    echo "  $0 --dify 8602 --apply             # 修改Dify端口"
    echo "  $0 --ragflow 8605 --apply          # 修改RAGFlow端口"
    echo "  $0 --mysql 3307 --postgres 5434 --apply  # 同时修改多个端口"
    echo "  $0 --check                         # 检查端口占用"
    echo "  $0 --reset --apply                 # 重置所有端口为默认值"
    echo ""
    echo "注意:"
    echo "  - 修改端口后需要使用 --apply 参数来重启相关服务"
    echo "  - 在域名模式下，只有Nginx端口和数据库端口会对外暴露"
    echo "  - 修改数据库端口需要更新应用配置，建议谨慎操作"
}

# 显示当前端口配置
show_current_ports() {
    echo -e "${BLUE}=== 当前端口配置 ===${NC}"
    echo ""
    echo "Web服务端口:"
    echo "  Nginx:        $NGINX_PORT"
    echo "  Dify:         $DIFY_WEB_PORT"
    echo "  n8n:          $N8N_WEB_PORT"
    echo "  OneAPI:       $ONEAPI_WEB_PORT"
    echo "  RAGFlow:      $RAGFLOW_WEB_PORT"
    echo ""
    echo "数据库端口:"
    echo "  MySQL:        $MYSQL_PORT"
    echo "  PostgreSQL:   $POSTGRES_PORT"
    echo "  Redis:        $REDIS_PORT"
    echo ""
    echo "RAGFlow组件端口:"
    echo "  Elasticsearch: $ELASTICSEARCH_PORT"
    echo "  MinIO API:    $MINIO_API_PORT"
    echo "  MinIO Console: $MINIO_CONSOLE_PORT"
    echo ""
    echo "内部服务端口:"
    echo "  Dify API:     $DIFY_API_PORT"
    echo "  RAGFlow API:  $RAGFLOW_API_PORT"
    echo ""
    echo "使用模式: $([ "$USE_DOMAIN" = true ] && echo "域名模式" || echo "IP模式")"
    echo "服务器IP: $SERVER_IP"
}

# 检查端口占用
check_port_usage() {
    echo -e "${BLUE}=== 端口占用检查 ===${NC}"
    echo ""

    local ports_to_check=()
    if [ "$USE_DOMAIN" = true ]; then
        ports_to_check=($NGINX_PORT $MYSQL_PORT $POSTGRES_PORT $REDIS_PORT $ELASTICSEARCH_PORT $MINIO_API_PORT $MINIO_CONSOLE_PORT)
    else
        ports_to_check=($NGINX_PORT $DIFY_WEB_PORT $N8N_WEB_PORT $ONEAPI_WEB_PORT $RAGFLOW_WEB_PORT $MYSQL_PORT $POSTGRES_PORT $REDIS_PORT $ELASTICSEARCH_PORT $MINIO_API_PORT $MINIO_CONSOLE_PORT)
    fi

    local occupied_ports=()
    local free_ports=()

    for port in "${ports_to_check[@]}"; do
        if netstat -ln 2>/dev/null | grep ":$port " > /dev/null 2>&1 || \
           ss -ln 2>/dev/null | grep ":$port " > /dev/null 2>&1; then
            occupied_ports+=($port)
        else
            free_ports+=($port)
        fi
    done

    echo "可用端口:"
    for port in "${free_ports[@]}"; do
        echo "  ✅ $port"
    done

    if [ ${#occupied_ports[@]} -gt 0 ]; then
        echo ""
        echo "占用端口:"
        for port in "${occupied_ports[@]}"; do
            local process_info=$(netstat -tlnp 2>/dev/null | grep ":$port " | awk '{print $7}' || \
                               ss -tlnp 2>/dev/null | grep ":$port " | awk '{print $6}' || echo "未知进程")
            local our_service=$(docker ps --format "{{.Names}}" | grep "${CONTAINER_PREFIX}" | while read container; do
                local container_ports=$(docker port "$container" 2>/dev/null | grep ":$port" | head -1)
                if [ -n "$container_ports" ]; then
                    echo "$container"
                    break
                fi
            done)

            if [ -n "$our_service" ]; then
                echo "  🔵 $port (我们的服务: $our_service)"
            else
                echo "  ❌ $port ($process_info)"
            fi
        done
    fi
}

# 验证端口号
validate_port() {
    local port="$1"
    local service_name="$2"

    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        error "无效的端口号: $port (服务: $service_name)"
        return 1
    fi

    # 检查是否为系统保留端口
    if [ "$port" -lt 1024 ] && [ "$port" != "80" ] && [ "$port" != "443" ]; then
        warning "端口 $port 是系统保留端口，可能需要root权限"
    fi

    return 0
}

# 检查端口冲突
check_port_conflicts() {
    local new_ports=()

    # 收集所有新端口
    [ -n "$NEW_DIFY_WEB_PORT" ] && new_ports+=($NEW_DIFY_WEB_PORT)
    [ -n "$NEW_N8N_WEB_PORT" ] && new_ports+=($NEW_N8N_WEB_PORT)
    [ -n "$NEW_ONEAPI_WEB_PORT" ] && new_ports+=($NEW_ONEAPI_WEB_PORT)
    [ -n "$NEW_RAGFLOW_WEB_PORT" ] && new_ports+=($NEW_RAGFLOW_WEB_PORT)
    [ -n "$NEW_MYSQL_PORT" ] && new_ports+=($NEW_MYSQL_PORT)
    [ -n "$NEW_POSTGRES_PORT" ] && new_ports+=($NEW_POSTGRES_PORT)
    [ -n "$NEW_REDIS_PORT" ] && new_ports+=($NEW_REDIS_PORT)
    [ -n "$NEW_NGINX_PORT" ] && new_ports+=($NEW_NGINX_PORT)
    [ -n "$NEW_ELASTICSEARCH_PORT" ] && new_ports+=($NEW_ELASTICSEARCH_PORT)
    [ -n "$NEW_MINIO_API_PORT" ] && new_ports+=($NEW_MINIO_API_PORT)
    [ -n "$NEW_MINIO_CONSOLE_PORT" ] && new_ports+=($NEW_MINIO_CONSOLE_PORT)

    # 检查内部冲突
    local unique_ports=($(printf "%s\n" "${new_ports[@]}" | sort -u))
    if [ ${#new_ports[@]} -ne ${#unique_ports[@]} ]; then
        error "新端口配置中存在冲突"
        return 1
    fi

    # 检查与现有端口的冲突
    for port in "${new_ports[@]}"; do
        # 跳过我们自己的服务占用的端口
        local our_service_port=false
        for container in $(docker ps --format "{{.Names}}" | grep "${CONTAINER_PREFIX}"); do
            if docker port "$container" 2>/dev/null | grep -q ":$port"; then
                our_service_port=true
                break
            fi
        done

        if [ "$our_service_port" = false ]; then
            if netstat -ln 2>/dev/null | grep ":$port " > /dev/null 2>&1 || \
               ss -ln 2>/dev/null | grep ":$port " > /dev/null 2>&1; then
                error "端口 $port 已被其他进程占用"
                return 1
            fi
        fi
    done

    return 0
}

# 更新配置文件
update_port_config() {
    log "更新端口配置..."

    # 备份原配置
    backup_file "modules/config.sh"

    # 读取当前配置文件
    local config_content=$(cat "modules/config.sh")

    # 更新端口配置
    if [ -n "$NEW_DIFY_WEB_PORT" ]; then
        config_content=$(echo "$config_content" | sed "s/^DIFY_WEB_PORT=.*/DIFY_WEB_PORT=$NEW_DIFY_WEB_PORT/")
        success "Dify Web端口已更新: $NEW_DIFY_WEB_PORT"
    fi

    if [ -n "$NEW_N8N_WEB_PORT" ]; then
        config_content=$(echo "$config_content" | sed "s/^N8N_WEB_PORT=.*/N8N_WEB_PORT=$NEW_N8N_WEB_PORT/")
        success "n8n Web端口已更新: $NEW_N8N_WEB_PORT"
    fi

    if [ -n "$NEW_ONEAPI_WEB_PORT" ]; then
        config_content=$(echo "$config_content" | sed "s/^ONEAPI_WEB_PORT=.*/ONEAPI_WEB_PORT=$NEW_ONEAPI_WEB_PORT/")
        success "OneAPI Web端口已更新: $NEW_ONEAPI_WEB_PORT"
    fi

    if [ -n "$NEW_RAGFLOW_WEB_PORT" ]; then
        config_content=$(echo "$config_content" | sed "s/^RAGFLOW_WEB_PORT=.*/RAGFLOW_WEB_PORT=$NEW_RAGFLOW_WEB_PORT/")
        success "RAGFlow Web端口已更新: $NEW_RAGFLOW_WEB_PORT"
    fi

    if [ -n "$NEW_MYSQL_PORT" ]; then
        config_content=$(echo "$config_content" | sed "s/^MYSQL_PORT=.*/MYSQL_PORT=$NEW_MYSQL_PORT/")
        success "MySQL端口已更新: $NEW_MYSQL_PORT"
    fi

    if [ -n "$NEW_POSTGRES_PORT" ]; then
        config_content=$(echo "$config_content" | sed "s/^POSTGRES_PORT=.*/POSTGRES_PORT=$NEW_POSTGRES_PORT/")
        success "PostgreSQL端口已更新: $NEW_POSTGRES_PORT"
    fi

    if [ -n "$NEW_REDIS_PORT" ]; then
        config_content=$(echo "$config_content" | sed "s/^REDIS_PORT=.*/REDIS_PORT=$NEW_REDIS_PORT/")
        success "Redis端口已更新: $NEW_REDIS_PORT"
    fi

    if [ -n "$NEW_NGINX_PORT" ]; then
        config_content=$(echo "$config_content" | sed "s/^NGINX_PORT=.*/NGINX_PORT=$NEW_NGINX_PORT/")
        success "Nginx端口已更新: $NEW_NGINX_PORT"
    fi

    if [ -n "$NEW_ELASTICSEARCH_PORT" ]; then
        config_content=$(echo "$config_content" | sed "s/^ELASTICSEARCH_PORT=.*/ELASTICSEARCH_PORT=$NEW_ELASTICSEARCH_PORT/")
        success "Elasticsearch端口已更新: $NEW_ELASTICSEARCH_PORT"
    fi

    if [ -n "$NEW_MINIO_API_PORT" ]; then
        config_content=$(echo "$config_content" | sed "s/^MINIO_API_PORT=.*/MINIO_API_PORT=$NEW_MINIO_API_PORT/")
        success "MinIO API端口已更新: $NEW_MINIO_API_PORT"
    fi

    if [ -n "$NEW_MINIO_CONSOLE_PORT" ]; then
        config_content=$(echo "$config_content" | sed "s/^MINIO_CONSOLE_PORT=.*/MINIO_CONSOLE_PORT=$NEW_MINIO_CONSOLE_PORT/")
        success "MinIO控制台端口已更新: $NEW_MINIO_CONSOLE_PORT"
    fi

    # 写入新配置
    echo "$config_content" > "modules/config.sh"

    success "端口配置文件更新完成"
}

# 重新生成配置文件
regenerate_configs() {
    log "重新生成配置文件..."

    # 重新加载配置
    source modules/config.sh
    init_config

    # 重新生成Docker Compose文件
    local updated_services=()

    if [ -n "$NEW_MYSQL_PORT" ] || [ -n "$NEW_POSTGRES_PORT" ] || [ -n "$NEW_REDIS_PORT" ]; then
        if [ -f "modules/database.sh" ]; then
            source modules/database.sh
            generate_database_compose
            updated_services+=("database")
        fi
    fi

    if [ -n "$NEW_DIFY_WEB_PORT" ]; then
        if [ -f "modules/dify.sh" ]; then
            source modules/dify.sh
            generate_dify_compose
            updated_services+=("dify")
        fi
    fi

    if [ -n "$NEW_N8N_WEB_PORT" ]; then
        if [ -f "modules/n8n.sh" ]; then
            source modules/n8n.sh
            generate_n8n_compose
            updated_services+=("n8n")
        fi
    fi

    if [ -n "$NEW_ONEAPI_WEB_PORT" ]; then
        if [ -f "modules/oneapi.sh" ]; then
            source modules/oneapi.sh
            generate_oneapi_compose
            updated_services+=("oneapi")
        fi
    fi

    if [ -n "$NEW_RAGFLOW_WEB_PORT" ] || [ -n "$NEW_ELASTICSEARCH_PORT" ] || [ -n "$NEW_MINIO_API_PORT" ] || [ -n "$NEW_MINIO_CONSOLE_PORT" ]; then
        if [ -f "modules/ragflow.sh" ]; then
            source modules/ragflow.sh
            generate_ragflow_compose
            updated_services+=("ragflow")
        fi
    fi

    if [ -n "$NEW_NGINX_PORT" ]; then
        if [ -f "modules/nginx.sh" ]; then
            source modules/nginx.sh
            generate_nginx_config
            generate_nginx_compose
            updated_services+=("nginx")
        fi
    fi

    if [ ${#updated_services[@]} -gt 0 ]; then
        success "已更新服务配置: ${updated_services[*]}"
    fi

    success "所有配置文件已重新生成"
}

# 应用端口更改
apply_port_changes() {
    log "应用端口更改..."

    # 检查是否有运行的服务
    local running_services=()
    for service in mysql postgres redis dify_api dify_web dify_worker n8n oneapi ragflow elasticsearch minio nginx; do
        if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_${service}"; then
            running_services+=("$service")
        fi
    done

    if [ ${#running_services[@]} -eq 0 ]; then
        warning "没有运行的服务，端口更改将在下次启动时生效"
        return 0
    fi

    log "需要重启的服务: ${running_services[*]}"

    # 确认操作
    echo -e "\n${YELLOW}注意: 应用端口更改将重启相关服务，可能导致短暂的服务中断。${NC}"
    read -p "确定要继续吗？(输入 'yes' 确认): " confirm

    if [ "$confirm" != "yes" ]; then
        log "端口更改已取消"
        return 0
    fi

    # 重启相关服务
    local services_to_restart=()

    # 确定需要重启的服务
    if [ -n "$NEW_MYSQL_PORT" ] || [ -n "$NEW_POSTGRES_PORT" ] || [ -n "$NEW_REDIS_PORT" ]; then
        services_to_restart+=("database")
    fi

    if [ -n "$NEW_DIFY_WEB_PORT" ]; then
        services_to_restart+=("dify")
    fi

    if [ -n "$NEW_N8N_WEB_PORT" ]; then
        services_to_restart+=("n8n")
    fi

    if [ -n "$NEW_ONEAPI_WEB_PORT" ]; then
        services_to_restart+=("oneapi")
    fi

    if [ -n "$NEW_RAGFLOW_WEB_PORT" ] || [ -n "$NEW_ELASTICSEARCH_PORT" ] || [ -n "$NEW_MINIO_API_PORT" ] || [ -n "$NEW_MINIO_CONSOLE_PORT" ]; then
        services_to_restart+=("ragflow")
    fi

    if [ -n "$NEW_NGINX_PORT" ]; then
        services_to_restart+=("nginx")
    fi

    # 按顺序重启服务
    for service in "${services_to_restart[@]}"; do
        log "重启 $service 服务..."
        case "$service" in
            database)
                docker-compose -f docker-compose-db.yml down
                sleep 5
                docker-compose -f docker-compose-db.yml up -d
                sleep 30
                ;;
            dify)
                docker-compose -f docker-compose-dify.yml restart
                sleep 20
                ;;
            n8n)
                docker-compose -f docker-compose-n8n.yml restart
                sleep 15
                ;;
            oneapi)
                docker-compose -f docker-compose-oneapi.yml restart
                sleep 10
                ;;
            ragflow)
                docker-compose -f docker-compose-ragflow.yml restart
                sleep 30
                ;;
            nginx)
                docker-compose -f docker-compose-nginx.yml restart
                sleep 10
                ;;
        esac
        success "$service 服务重启完成"
    done

    success "端口更改已应用"

    # 显示新的访问地址
    echo -e "\n${BLUE}=== 更新后的访问地址 ===${NC}"
    source modules/config.sh
    init_config

    if [ "$USE_DOMAIN" = true ]; then
        echo "Dify: $DIFY_URL"
        echo "n8n: $N8N_URL"
        echo "OneAPI: $ONEAPI_URL"
        echo "RAGFlow: $RAGFLOW_URL"
    else
        echo "统一入口: http://${SERVER_IP}:${NGINX_PORT}"
        echo "Dify: http://${SERVER_IP}:${DIFY_WEB_PORT}"
        echo "n8n: http://${SERVER_IP}:${N8N_WEB_PORT}"
        echo "OneAPI: http://${SERVER_IP}:${ONEAPI_WEB_PORT}"
        echo "RAGFlow: http://${SERVER_IP}:${RAGFLOW_WEB_PORT}"
    fi
}

# 重置为默认端口
reset_to_default_ports() {
    log "重置端口为默认值..."

    # 设置默认端口
    NEW_N8N_WEB_PORT=8601
    NEW_DIFY_WEB_PORT=8602
    NEW_ONEAPI_WEB_PORT=8603
    NEW_RAGFLOW_WEB_PORT=8605
    NEW_MYSQL_PORT=3306
    NEW_POSTGRES_PORT=5433
    NEW_REDIS_PORT=6379
    NEW_NGINX_PORT=80
    NEW_ELASTICSEARCH_PORT=9200
    NEW_MINIO_API_PORT=9001
    NEW_MINIO_CONSOLE_PORT=9002

    success "端口配置已重置为默认值"
}

# 备份端口配置
backup_port_config() {
    local backup_file="$INSTALL_PATH/backup/port_config_backup_$(date +%Y%m%d_%H%M%S).txt"

    mkdir -p "$(dirname "$backup_file")"

    cat > "$backup_file" << EOF
# 端口配置备份
# 备份时间: $(date)
# 服务器IP: $SERVER_IP

# 原端口配置
N8N_WEB_PORT_OLD=$N8N_WEB_PORT
DIFY_WEB_PORT_OLD=$DIFY_WEB_PORT
ONEAPI_WEB_PORT_OLD=$ONEAPI_WEB_PORT
RAGFLOW_WEB_PORT_OLD=$RAGFLOW_WEB_PORT
MYSQL_PORT_OLD=$MYSQL_PORT
POSTGRES_PORT_OLD=$POSTGRES_PORT
REDIS_PORT_OLD=$REDIS_PORT
NGINX_PORT_OLD=$NGINX_PORT
ELASTICSEARCH_PORT_OLD=$ELASTICSEARCH_PORT
MINIO_API_PORT_OLD=$MINIO_API_PORT
MINIO_CONSOLE_PORT_OLD=$MINIO_CONSOLE_PORT

# 使用模式
USE_DOMAIN_OLD=$USE_DOMAIN
EOF

    log "端口配置已备份至: $backup_file"
}

# 主函数
main() {
    local NEW_DIFY_WEB_PORT=""
    local NEW_N8N_WEB_PORT=""
    local NEW_ONEAPI_WEB_PORT=""
    local NEW_RAGFLOW_WEB_PORT=""
    local NEW_MYSQL_PORT=""
    local NEW_POSTGRES_PORT=""
    local NEW_REDIS_PORT=""
    local NEW_NGINX_PORT=""
    local NEW_ELASTICSEARCH_PORT=""
    local NEW_MINIO_API_PORT=""
    local NEW_MINIO_CONSOLE_PORT=""
    local show_ports=false
    local check_ports=false
    local apply_changes_flag=false
    local reset_flag=false

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dify)
                NEW_DIFY_WEB_PORT="$2"
                if ! validate_port "$NEW_DIFY_WEB_PORT" "Dify Web"; then
                    exit 1
                fi
                shift 2
                ;;
            --n8n)
                NEW_N8N_WEB_PORT="$2"
                if ! validate_port "$NEW_N8N_WEB_PORT" "n8n Web"; then
                    exit 1
                fi
                shift 2
                ;;
            --oneapi)
                NEW_ONEAPI_WEB_PORT="$2"
                if ! validate_port "$NEW_ONEAPI_WEB_PORT" "OneAPI Web"; then
                    exit 1
                fi
                shift 2
                ;;
            --ragflow)
                NEW_RAGFLOW_WEB_PORT="$2"
                if ! validate_port "$NEW_RAGFLOW_WEB_PORT" "RAGFlow Web"; then
                    exit 1
                fi
                shift 2
                ;;
            --mysql)
                NEW_MYSQL_PORT="$2"
                if ! validate_port "$NEW_MYSQL_PORT" "MySQL"; then
                    exit 1
                fi
                shift 2
                ;;
            --postgres)
                NEW_POSTGRES_PORT="$2"
                if ! validate_port "$NEW_POSTGRES_PORT" "PostgreSQL"; then
                    exit 1
                fi
                shift 2
                ;;
            --redis)
                NEW_REDIS_PORT="$2"
                if ! validate_port "$NEW_REDIS_PORT" "Redis"; then
                    exit 1
                fi
                shift 2
                ;;
            --nginx)
                NEW_NGINX_PORT="$2"
                if ! validate_port "$NEW_NGINX_PORT" "Nginx"; then
                    exit 1
                fi
                shift 2
                ;;
            --elasticsearch)
                NEW_ELASTICSEARCH_PORT="$2"
                if ! validate_port "$NEW_ELASTICSEARCH_PORT" "Elasticsearch"; then
                    exit 1
                fi
                shift 2
                ;;
            --minio)
                NEW_MINIO_API_PORT="$2"
                if ! validate_port "$NEW_MINIO_API_PORT" "MinIO API"; then
                    exit 1
                fi
                shift 2
                ;;
            --minio-console)
                NEW_MINIO_CONSOLE_PORT="$2"
                if ! validate_port "$NEW_MINIO_CONSOLE_PORT" "MinIO Console"; then
                    exit 1
                fi
                shift 2
                ;;
            --show)
                show_ports=true
                shift
                ;;
            --check)
                check_ports=true
                shift
                ;;
            --apply)
                apply_changes_flag=true
                shift
                ;;
            --reset)
                reset_flag=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # 如果只是显示端口
    if [ "$show_ports" = true ]; then
        show_current_ports
        exit 0
    fi

    # 如果只是检查端口
    if [ "$check_ports" = true ]; then
        check_port_usage
        exit 0
    fi

    # 如果是重置端口
    if [ "$reset_flag" = true ]; then
        reset_to_default_ports
    fi

    # 检查是否有端口更改
    local has_changes=false
    if [ -n "$NEW_DIFY_WEB_PORT" ] || [ -n "$NEW_N8N_WEB_PORT" ] || [ -n "$NEW_ONEAPI_WEB_PORT" ] || [ -n "$NEW_RAGFLOW_WEB_PORT" ] || \
       [ -n "$NEW_MYSQL_PORT" ] || [ -n "$NEW_POSTGRES_PORT" ] || [ -n "$NEW_REDIS_PORT" ] || [ -n "$NEW_NGINX_PORT" ] || \
       [ -n "$NEW_ELASTICSEARCH_PORT" ] || [ -n "$NEW_MINIO_API_PORT" ] || [ -n "$NEW_MINIO_CONSOLE_PORT" ] || [ "$reset_flag" = true ]; then
        has_changes=true
    fi

    if [ "$has_changes" = false ]; then
        warning "没有指定任何端口更改"
        show_help
        exit 1
    fi

    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}       端口配置修改工具${NC}"
    echo -e "${GREEN}======================================${NC}"

    # 显示当前配置
    show_current_ports

    # 显示准备进行的更改
    echo -e "\n${YELLOW}=== 准备进行的更改 ===${NC}"
    [ -n "$NEW_DIFY_WEB_PORT" ] && echo "- Dify Web端口: ${DIFY_WEB_PORT} → $NEW_DIFY_WEB_PORT"
    [ -n "$NEW_N8N_WEB_PORT" ] && echo "- n8n Web端口: ${N8N_WEB_PORT} → $NEW_N8N_WEB_PORT"
    [ -n "$NEW_ONEAPI_WEB_PORT" ] && echo "- OneAPI Web端口: ${ONEAPI_WEB_PORT} → $NEW_ONEAPI_WEB_PORT"
    [ -n "$NEW_RAGFLOW_WEB_PORT" ] && echo "- RAGFlow Web端口: ${RAGFLOW_WEB_PORT} → $NEW_RAGFLOW_WEB_PORT"
    [ -n "$NEW_MYSQL_PORT" ] && echo "- MySQL端口: ${MYSQL_PORT} → $NEW_MYSQL_PORT"
    [ -n "$NEW_POSTGRES_PORT" ] && echo "- PostgreSQL端口: ${POSTGRES_PORT} → $NEW_POSTGRES_PORT"
    [ -n "$NEW_REDIS_PORT" ] && echo "- Redis端口: ${REDIS_PORT} → $NEW_REDIS_PORT"
    [ -n "$NEW_NGINX_PORT" ] && echo "- Nginx端口: ${NGINX_PORT} → $NEW_NGINX_PORT"
    [ -n "$NEW_ELASTICSEARCH_PORT" ] && echo "- Elasticsearch端口: ${ELASTICSEARCH_PORT} → $NEW_ELASTICSEARCH_PORT"
    [ -n "$NEW_MINIO_API_PORT" ] && echo "- MinIO API端口: ${MINIO_API_PORT} → $NEW_MINIO_API_PORT"
    [ -n "$NEW_MINIO_CONSOLE_PORT" ] && echo "- MinIO控制台端口: ${MINIO_CONSOLE_PORT} → $NEW_MINIO_CONSOLE_PORT"

    # 检查端口冲突
    if ! check_port_conflicts; then
        exit 1
    fi

    # 确认更改
    if [ "$apply_changes_flag" = false ]; then
        echo -e "\n${YELLOW}端口配置已准备，使用 --apply 参数应用更改${NC}"
        exit 0
    fi

    # 备份当前配置
    backup_port_config

    # 应用端口更改
    update_port_config
    regenerate_configs
    apply_port_changes

    success "端口配置修改完成！"

    # 显示最终端口信息
    echo -e "\n${GREEN}=== 端口修改完成 ===${NC}"
    source modules/config.sh
    init_config

    if [ "$USE_DOMAIN" = true ]; then
        echo "域名访问地址（端口已更新）："
        echo "- Dify: $DIFY_URL"
        echo "- n8n: $N8N_URL"
        echo "- OneAPI: $ONEAPI_URL"
        echo "- RAGFlow: $RAGFLOW_URL"
    else
        echo "IP访问地址（端口已更新）："
        echo "- 统一入口: http://${SERVER_IP}:${NGINX_PORT}"
        echo "- Dify: http://${SERVER_IP}:${DIFY_WEB_PORT}"
        echo "- n8n: http://${SERVER_IP}:${N8N_WEB_PORT}"
        echo "- OneAPI: http://${SERVER_IP}:${ONEAPI_WEB_PORT}"
        echo "- RAGFlow: http://${SERVER_IP}:${RAGFLOW_WEB_PORT}"
    fi

    echo ""
    echo "提示："
    echo "- 端口修改后请更新防火墙规则"
    echo "- 使用 ./scripts/manage.sh status 检查服务状态"
    echo "- 如有问题，可从备份恢复配置"
}

# 运行主函数
main "$@"