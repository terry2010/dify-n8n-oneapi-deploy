#!/bin/bash

# =========================================================
# 域名修改脚本
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
    echo "域名修改脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --dify <域名>        设置Dify域名"
    echo "  --n8n <域名>         设置n8n域名"
    echo "  --oneapi <域名>      设置OneAPI域名"
    echo "  --port <端口>        设置域名模式下的端口（可选，默认80）"
    echo "  --disable-domain     禁用域名模式，使用IP+端口"
    echo "  --show               显示当前域名配置"
    echo "  --apply              应用配置更改（重启相关服务）"
    echo "  -h, --help           显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 --show                                    # 显示当前配置"
    echo "  $0 --dify app.example.com --apply           # 只修改Dify域名"
    echo "  $0 --dify dify.example.com --n8n n8n.example.com --oneapi api.example.com --apply"
    echo "  $0 --dify dify.example.com --port 8080 --apply    # 使用自定义端口"
    echo "  $0 --disable-domain --apply                       # 禁用域名模式"
}

# 显示当前域名配置
show_current_config() {
    echo -e "${BLUE}=== 当前域名配置 ===${NC}"
    echo "Dify域名: ${DIFY_DOMAIN:-未设置}"
    echo "n8n域名: ${N8N_DOMAIN:-未设置}"
    echo "OneAPI域名: ${ONEAPI_DOMAIN:-未设置}"
    echo "端口: ${DOMAIN_PORT:-80 (默认)}"
    echo "使用模式: $([ "$USE_DOMAIN" = true ] && echo "域名模式" || echo "IP模式")"
    echo "服务器IP: $SERVER_IP"

    if [ "$USE_DOMAIN" = true ]; then
        echo ""
        echo -e "${BLUE}=== 当前访问地址 ===${NC}"
        echo "Dify: $DIFY_URL"
        echo "n8n: $N8N_URL"
        echo "OneAPI: $ONEAPI_URL"
    else
        echo ""
        echo -e "${BLUE}=== 当前访问地址 ===${NC}"
        echo "统一入口: http://${SERVER_IP}:8604"
        echo "Dify: http://${SERVER_IP}:${DIFY_WEB_PORT}"
        echo "n8n: http://${SERVER_IP}:${N8N_WEB_PORT}"
        echo "OneAPI: http://${SERVER_IP}:${ONEAPI_WEB_PORT}"
    fi
}

# 验证域名格式
validate_domain() {
    local domain="$1"

    if [ -z "$domain" ]; then
        return 1
    fi

    # 基本域名格式检查
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 1
    fi

    return 0
}

# 验证端口
validate_port() {
    local port="$1"

    if [ -z "$port" ]; then
        return 0  # 空端口是允许的，使用默认值
    fi

    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi

    return 0
}

# 更新配置文件
update_config_file() {
    local new_dify_domain="$1"
    local new_n8n_domain="$2"
    local new_oneapi_domain="$3"
    local new_domain_port="$4"
    local disable_domain="$5"

    log "更新配置文件..."

    # 备份原配置
    backup_file "modules/config.sh"

    # 读取当前配置文件
    local config_content=$(cat "modules/config.sh")

    if [ "$disable_domain" = true ]; then
        # 禁用域名模式
        config_content=$(echo "$config_content" | sed 's/^DIFY_DOMAIN=.*/DIFY_DOMAIN=""/')
        config_content=$(echo "$config_content" | sed 's/^N8N_DOMAIN=.*/N8N_DOMAIN=""/')
        config_content=$(echo "$config_content" | sed 's/^ONEAPI_DOMAIN=.*/ONEAPI_DOMAIN=""/')
        config_content=$(echo "$config_content" | sed 's/^DOMAIN_PORT=.*/DOMAIN_PORT=""/')
        success "已禁用域名模式"
    else
        # 更新域名配置
        if [ -n "$new_dify_domain" ]; then
            config_content=$(echo "$config_content" | sed "s/^DIFY_DOMAIN=.*/DIFY_DOMAIN=\"$new_dify_domain\"/")
            success "Dify域名已更新: $new_dify_domain"
        fi

        if [ -n "$new_n8n_domain" ]; then
            config_content=$(echo "$config_content" | sed "s/^N8N_DOMAIN=.*/N8N_DOMAIN=\"$new_n8n_domain\"/")
            success "n8n域名已更新: $new_n8n_domain"
        fi

        if [ -n "$new_oneapi_domain" ]; then
            config_content=$(echo "$config_content" | sed "s/^ONEAPI_DOMAIN=.*/ONEAPI_DOMAIN=\"$new_oneapi_domain\"/")
            success "OneAPI域名已更新: $new_oneapi_domain"
        fi

        if [ -n "$new_domain_port" ]; then
            config_content=$(echo "$config_content" | sed "s/^DOMAIN_PORT=.*/DOMAIN_PORT=\"$new_domain_port\"/")
            success "域名端口已更新: $new_domain_port"
        fi
    fi

    # 写入新配置
    echo "$config_content" > "modules/config.sh"

    success "配置文件更新完成"
}

# 重新生成配置文件
regenerate_configs() {
    log "重新生成配置文件..."

    # 重新加载配置
    source modules/config.sh
    init_config

    # 重新生成Nginx配置
    if [ -f "modules/nginx.sh" ]; then
        source modules/nginx.sh
        generate_nginx_config
        success "Nginx配置已更新"
    fi

    # 重新生成各应用配置
    for app in dify n8n oneapi; do
        local compose_file="docker-compose-${app}.yml"
        if [ -f "$compose_file" ]; then
            source "modules/${app}.sh"
            eval "generate_${app}_compose"
            success "${app}配置已更新"
        fi
    done

    success "所有配置文件已重新生成"
}

# 应用配置更改
apply_changes() {
    log "应用配置更改..."

    # 检查是否有运行的服务
    local running_services=()
    for service in nginx dify_web dify_api n8n oneapi; do
        if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_${service}"; then
            running_services+=("$service")
        fi
    done

    if [ ${#running_services[@]} -eq 0 ]; then
        warning "没有运行的服务，配置更改将在下次启动时生效"
        return 0
    fi

    log "重启相关服务以应用配置更改..."

    # 重启顺序：先重启应用，再重启Nginx
    for service in dify_web dify_api n8n oneapi; do
        if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_${service}"; then
            case "$service" in
                dify_*)
                    docker-compose -f docker-compose-dify.yml restart "$service" 2>/dev/null
                    ;;
                n8n)
                    docker-compose -f docker-compose-n8n.yml restart "$service" 2>/dev/null
                    ;;
                oneapi)
                    docker-compose -f docker-compose-oneapi.yml restart "$service" 2>/dev/null
                    ;;
            esac
            log "已重启服务: $service"
        fi
    done

    # 最后重启Nginx
    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_nginx"; then
        docker-compose -f docker-compose-nginx.yml restart nginx 2>/dev/null
        log "已重启Nginx服务"
    fi

    success "配置更改已应用"

    # 等待服务启动
    sleep 10

    # 显示新的访问地址
    echo -e "\n${BLUE}=== 更新后的访问地址 ===${NC}"
    source modules/config.sh
    init_config

    if [ "$USE_DOMAIN" = true ]; then
        echo "Dify: $DIFY_URL"
        echo "n8n: $N8N_URL"
        echo "OneAPI: $ONEAPI_URL"
    else
        echo "统一入口: http://${SERVER_IP}:8604"
        echo "Dify: http://${SERVER_IP}:${DIFY_WEB_PORT}"
        echo "n8n: http://${SERVER_IP}:${N8N_WEB_PORT}"
        echo "OneAPI: http://${SERVER_IP}:${ONEAPI_WEB_PORT}"
    fi
}

# 检查域名解析
check_domain_resolution() {
    local domains=("$@")

    log "检查域名解析..."

    for domain in "${domains[@]}"; do
        if [ -n "$domain" ]; then
            local resolved_ip=$(dig +short "$domain" 2>/dev/null | tail -1)
            if [ -n "$resolved_ip" ]; then
                if [ "$resolved_ip" = "$SERVER_IP" ]; then
                    success "域名 $domain 解析正确: $resolved_ip"
                else
                    warning "域名 $domain 解析到 $resolved_ip，但服务器IP是 $SERVER_IP"
                fi
            else
                warning "无法解析域名 $domain"
            fi
        fi
    done
}

# 测试域名连通性
test_domain_connectivity() {
    local domains=("$@")

    log "测试域名连通性..."

    for domain in "${domains[@]}"; do
        if [ -n "$domain" ]; then
            # 构建测试URL
            local test_url="http://$domain"
            if [ -n "$DOMAIN_PORT" ] && [ "$DOMAIN_PORT" != "80" ]; then
                test_url="${test_url}:${DOMAIN_PORT}"
            fi

            # 测试连通性
            if curl -s --connect-timeout 10 --max-time 20 "$test_url" >/dev/null 2>&1; then
                success "域名 $domain 连通性测试通过"
            else
                warning "域名 $domain 连通性测试失败"
            fi
        fi
    done
}

# 生成域名配置备份
backup_domain_config() {
    local backup_file="$INSTALL_PATH/backup/domain_config_backup_$(date +%Y%m%d_%H%M%S).txt"

    mkdir -p "$(dirname "$backup_file")"

    cat > "$backup_file" << EOF
# 域名配置备份
# 备份时间: $(date)
# 服务器IP: $SERVER_IP

# 原域名配置
DIFY_DOMAIN_OLD="$DIFY_DOMAIN"
N8N_DOMAIN_OLD="$N8N_DOMAIN"
ONEAPI_DOMAIN_OLD="$ONEAPI_DOMAIN"
DOMAIN_PORT_OLD="$DOMAIN_PORT"
USE_DOMAIN_OLD="$USE_DOMAIN"

# 原访问地址
$([ "$USE_DOMAIN" = true ] && echo "# 域名模式访问地址" || echo "# IP模式访问地址")
DIFY_URL_OLD="$DIFY_URL"
N8N_URL_OLD="$N8N_URL"
ONEAPI_URL_OLD="$ONEAPI_URL"
EOF

    log "域名配置已备份至: $backup_file"
}

# 验证新域名配置
validate_domain_config() {
    local new_dify_domain="$1"
    local new_n8n_domain="$2"
    local new_oneapi_domain="$3"
    local new_domain_port="$4"
    local disable_domain="$5"

    log "验证域名配置..."

    if [ "$disable_domain" = true ]; then
        success "将切换到IP模式，无需验证域名"
        return 0
    fi

    # 检查是否至少有一个域名被设置
    local has_domain=false
    if [ -n "$new_dify_domain" ] || [ -n "$DIFY_DOMAIN" ]; then
        has_domain=true
    fi
    if [ -n "$new_n8n_domain" ] || [ -n "$N8N_DOMAIN" ]; then
        has_domain=true
    fi
    if [ -n "$new_oneapi_domain" ] || [ -n "$ONEAPI_DOMAIN" ]; then
        has_domain=true
    fi

    if [ "$has_domain" = false ]; then
        error "域名模式下至少需要设置一个域名"
        return 1
    fi

    # 验证端口
    if [ -n "$new_domain_port" ]; then
        if ! validate_port "$new_domain_port"; then
            error "无效的端口号: $new_domain_port"
            return 1
        fi

        # 检查端口占用（排除我们自己的nginx）
        if netstat -ln 2>/dev/null | grep ":$new_domain_port " > /dev/null 2>&1; then
            local nginx_port_used=$(docker port "${CONTAINER_PREFIX}_nginx" 2>/dev/null | grep ":$new_domain_port" || true)
            if [ -z "$nginx_port_used" ]; then
                warning "端口 $new_domain_port 已被其他进程占用"
                return 1
            fi
        fi
    fi

    success "域名配置验证通过"
    return 0
}

# 主函数
main() {
    local new_dify_domain=""
    local new_n8n_domain=""
    local new_oneapi_domain=""
    local new_domain_port=""
    local disable_domain=false
    local show_config=false
    local apply_changes_flag=false

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dify)
                new_dify_domain="$2"
                if ! validate_domain "$new_dify_domain"; then
                    error "无效的Dify域名格式: $new_dify_domain"
                    exit 1
                fi
                shift 2
                ;;
            --n8n)
                new_n8n_domain="$2"
                if ! validate_domain "$new_n8n_domain"; then
                    error "无效的n8n域名格式: $new_n8n_domain"
                    exit 1
                fi
                shift 2
                ;;
            --oneapi)
                new_oneapi_domain="$2"
                if ! validate_domain "$new_oneapi_domain"; then
                    error "无效的OneAPI域名格式: $new_oneapi_domain"
                    exit 1
                fi
                shift 2
                ;;
            --port)
                new_domain_port="$2"
                if ! validate_port "$new_domain_port"; then
                    error "无效的端口号: $new_domain_port"
                    exit 1
                fi
                shift 2
                ;;
            --disable-domain)
                disable_domain=true
                shift
                ;;
            --show)
                show_config=true
                shift
                ;;
            --apply)
                apply_changes_flag=true
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

    # 如果只是显示配置
    if [ "$show_config" = true ]; then
        show_current_config
        exit 0
    fi

    # 检查是否有配置更改
    local has_changes=false
    if [ -n "$new_dify_domain" ] || [ -n "$new_n8n_domain" ] || [ -n "$new_oneapi_domain" ] || [ -n "$new_domain_port" ] || [ "$disable_domain" = true ]; then
        has_changes=true
    fi

    if [ "$has_changes" = false ]; then
        warning "没有指定任何配置更改"
        show_help
        exit 1
    fi

    echo -e "${GREEN}======================================${NC}"
    echo -e "${GREEN}       域名配置修改工具${NC}"
    echo -e "${GREEN}======================================${NC}"

    # 显示当前配置
    show_current_config

    echo -e "\n${YELLOW}=== 准备进行的更改 ===${NC}"
    if [ "$disable_domain" = true ]; then
        echo "- 禁用域名模式，切换到IP+端口模式"
    else
        [ -n "$new_dify_domain" ] && echo "- Dify域名: ${DIFY_DOMAIN:-未设置} → $new_dify_domain"
        [ -n "$new_n8n_domain" ] && echo "- n8n域名: ${N8N_DOMAIN:-未设置} → $new_n8n_domain"
        [ -n "$new_oneapi_domain" ] && echo "- OneAPI域名: ${ONEAPI_DOMAIN:-未设置} → $new_oneapi_domain"
        [ -n "$new_domain_port" ] && echo "- 端口: ${DOMAIN_PORT:-80} → $new_domain_port"
    fi

    # 验证新配置
    if ! validate_domain_config "$new_dify_domain" "$new_n8n_domain" "$new_oneapi_domain" "$new_domain_port" "$disable_domain"; then
        error "域名配置验证失败"
        exit 1
    fi

    # 确认更改
    if [ "$apply_changes_flag" = false ]; then
        echo -e "\n${YELLOW}配置已准备，使用 --apply 参数应用更改${NC}"
        exit 0
    fi

    # 备份当前配置
    backup_domain_config

    # 域名解析检查
    if [ "$disable_domain" = false ]; then
        local domains_to_check=()
        [ -n "$new_dify_domain" ] && domains_to_check+=("$new_dify_domain")
        [ -n "$new_n8n_domain" ] && domains_to_check+=("$new_n8n_domain")
        [ -n "$new_oneapi_domain" ] && domains_to_check+=("$new_oneapi_domain")

        if [ ${#domains_to_check[@]} -gt 0 ]; then
            check_domain_resolution "${domains_to_check[@]}"
        fi
    fi

    # 应用配置更改
    update_config_file "$new_dify_domain" "$new_n8n_domain" "$new_oneapi_domain" "$new_domain_port" "$disable_domain"
    regenerate_configs
    apply_changes

    # 测试新域名连通性（如果适用）
    if [ "$disable_domain" = false ] && [ "$apply_changes_flag" = true ]; then
        echo -e "\n${BLUE}=== 测试新域名连通性 ===${NC}"
        local test_domains=()
        [ -n "$new_dify_domain" ] && test_domains+=("$new_dify_domain")
        [ -n "$new_n8n_domain" ] && test_domains+=("$new_n8n_domain")
        [ -n "$new_oneapi_domain" ] && test_domains+=("$new_oneapi_domain")

        if [ ${#test_domains[@]} -gt 0 ]; then
            sleep 15  # 等待服务完全启动
            test_domain_connectivity "${test_domains[@]}"
        fi
    fi

    success "域名配置修改完成！"

    # 显示最终访问信息
    echo -e "\n${GREEN}=== 配置修改完成 ===${NC}"
    if [ "$disable_domain" = true ]; then
        echo "已切换到IP模式，访问地址："
        echo "- 统一入口: http://${SERVER_IP}:8604"
        echo "- Dify: http://${SERVER_IP}:${DIFY_WEB_PORT}"
        echo "- n8n: http://${SERVER_IP}:${N8N_WEB_PORT}"
        echo "- OneAPI: http://${SERVER_IP}:${ONEAPI_WEB_PORT}"
    else
        echo "域名访问地址已更新："
        source modules/config.sh
        init_config
        echo "- Dify: $DIFY_URL"
        echo "- n8n: $N8N_URL"
        echo "- OneAPI: $ONEAPI_URL"
    fi

    echo ""
    echo "提示："
    echo "- 如果域名无法访问，请检查DNS解析设置"
    echo "- 使用 ./scripts/logs.sh nginx 查看Nginx日志"
    echo "- 使用 ./scripts/manage.sh status 检查服务状态"
}

# 运行主函数
main "$@"