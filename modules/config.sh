#!/bin/bash

# =========================================================
# 配置管理模块
# =========================================================

# ========== 域名配置区域 - 请在此处自定义每个系统的独立域名 ==========
DIFY_DOMAIN="dify.demodomain.com"        # Dify系统域名
N8N_DOMAIN="n8n.demodomain.com"          # n8n系统域名
ONEAPI_DOMAIN="oneapi.demodomain.com"    # OneAPI系统域名

# 域名模式下的端口配置（可选，留空则使用80端口）
DOMAIN_PORT=""                           # 域名模式下的端口，如8080，留空则使用80

# 如果没有域名，可以设置为空字符串使用IP+端口访问
# DIFY_DOMAIN=""
# N8N_DOMAIN=""
# ONEAPI_DOMAIN=""

# ========== 基础配置区域 ==========
SERVER_IP=""  # 留空自动获取，或手动设置IP
INSTALL_PATH="/volume1/homes/terry/aiserver"  # 安装路径
CONTAINER_PREFIX="aiserver"  # 容器名前缀

# 服务端口配置
N8N_WEB_PORT=8601
DIFY_WEB_PORT=8602
ONEAPI_WEB_PORT=8603
MYSQL_PORT=3306
POSTGRES_PORT=5433
REDIS_PORT=6379
NGINX_PORT=80  # 默认Nginx端口，域名模式下可能被DOMAIN_PORT覆盖
DIFY_API_PORT=5002  # Dify API端口

# 数据库密码配置
DB_PASSWORD="654321"  # MySQL和PostgreSQL的root/postgres密码
REDIS_PASSWORD=""  # Redis密码（留空表示无密码）

# 全局变量
USE_DOMAIN=false
DIFY_URL=""
N8N_URL=""
ONEAPI_URL=""

# 初始化配置
init_config() {
    # 获取服务器IP
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}' 2>/dev/null)
        if [ -z "$SERVER_IP" ]; then
            SERVER_IP=$(hostname -I | awk '{print $1}')
        fi
    fi

    # 检查域名配置
    if [ -n "$DIFY_DOMAIN" ] && [ -n "$N8N_DOMAIN" ] && [ -n "$ONEAPI_DOMAIN" ]; then
        USE_DOMAIN=true
        # 确定域名模式下使用的端口
        if [ -n "$DOMAIN_PORT" ]; then
            NGINX_PORT="$DOMAIN_PORT"
        else
            NGINX_PORT=80
        fi

        # 构建域名URL
        if [ -n "$DOMAIN_PORT" ] && [ "$DOMAIN_PORT" != "80" ] && [ "$DOMAIN_PORT" != "443" ]; then
            DIFY_URL="http://$DIFY_DOMAIN:$DOMAIN_PORT"
            N8N_URL="http://$N8N_DOMAIN:$DOMAIN_PORT"
            ONEAPI_URL="http://$ONEAPI_DOMAIN:$DOMAIN_PORT"
        else
            DIFY_URL="http://$DIFY_DOMAIN"
            N8N_URL="http://$N8N_DOMAIN"
            ONEAPI_URL="http://$ONEAPI_DOMAIN"
        fi
    else
        USE_DOMAIN=false
        DIFY_URL="http://$SERVER_IP:$DIFY_API_PORT"
        N8N_URL="http://$SERVER_IP:$N8N_WEB_PORT"
        ONEAPI_URL="http://$SERVER_IP:$ONEAPI_WEB_PORT"
    fi

    log "配置初始化完成"
    log "服务器IP: $SERVER_IP"
    log "使用模式: $([ "$USE_DOMAIN" = true ] && echo "域名模式" || echo "IP模式")"
}

# 验证配置
validate_config() {
    local errors=()

    # 检查必要的配置
    if [ -z "$INSTALL_PATH" ]; then
        errors+=("INSTALL_PATH未设置")
    fi

    if [ -z "$CONTAINER_PREFIX" ]; then
        errors+=("CONTAINER_PREFIX未设置")
    fi

    if [ -z "$DB_PASSWORD" ]; then
        errors+=("DB_PASSWORD未设置")
    fi

    # 检查端口冲突
    if [ "$USE_DOMAIN" = false ]; then
        local ports=($N8N_WEB_PORT $DIFY_WEB_PORT $ONEAPI_WEB_PORT $MYSQL_PORT $POSTGRES_PORT $REDIS_PORT $DIFY_API_PORT)
        local unique_ports=($(printf "%s\n" "${ports[@]}" | sort -u))

        if [ ${#ports[@]} -ne ${#unique_ports[@]} ]; then
            errors+=("端口配置存在冲突")
        fi
    fi

    # 如果有错误，显示并退出
    if [ ${#errors[@]} -gt 0 ]; then
        error "配置验证失败:"
        for err in "${errors[@]}"; do
            error "  - $err"
        done
        exit 1
    fi

    success "配置验证通过"
}

# 保存配置到文件
save_config() {
    local config_file="$INSTALL_PATH/config/app.conf"
    mkdir -p "$(dirname "$config_file")"

    cat > "$config_file" << EOF
# AI服务集群配置文件
# 生成时间: $(date)

# 域名配置
DIFY_DOMAIN="$DIFY_DOMAIN"
N8N_DOMAIN="$N8N_DOMAIN"
ONEAPI_DOMAIN="$ONEAPI_DOMAIN"
DOMAIN_PORT="$DOMAIN_PORT"

# 基础配置
SERVER_IP="$SERVER_IP"
INSTALL_PATH="$INSTALL_PATH"
CONTAINER_PREFIX="$CONTAINER_PREFIX"

# 端口配置
N8N_WEB_PORT=$N8N_WEB_PORT
DIFY_WEB_PORT=$DIFY_WEB_PORT
ONEAPI_WEB_PORT=$ONEAPI_WEB_PORT
MYSQL_PORT=$MYSQL_PORT
POSTGRES_PORT=$POSTGRES_PORT
REDIS_PORT=$REDIS_PORT
NGINX_PORT=$NGINX_PORT
DIFY_API_PORT=$DIFY_API_PORT

# 数据库配置
DB_PASSWORD="$DB_PASSWORD"
REDIS_PASSWORD="$REDIS_PASSWORD"

# 运行模式
USE_DOMAIN=$USE_DOMAIN

# URL配置
DIFY_URL="$DIFY_URL"
N8N_URL="$N8N_URL"
ONEAPI_URL="$ONEAPI_URL"
EOF

    success "配置已保存到: $config_file"
}

# 从文件加载配置
load_config() {
    local config_file="$INSTALL_PATH/config/app.conf"

    if [ -f "$config_file" ]; then
        source "$config_file"
        log "已从文件加载配置: $config_file"
        return 0
    else
        warning "配置文件不存在: $config_file"
        return 1
    fi
}

# 更新配置
update_configuration() {
    log "更新配置..."

    # 重新初始化配置
    init_config

    # 验证配置
    validate_config

    # 保存配置
    save_config

    # 更新Docker Compose配置
    if [ -f "$INSTALL_PATH/docker-compose.yml" ]; then
        log "更新Docker Compose配置..."
        generate_docker_compose
    fi

    # 更新Nginx配置
    if [ -f "$INSTALL_PATH/config/nginx.conf" ]; then
        log "更新Nginx配置..."
        source modules/nginx.sh
        configure_nginx

        # 重启Nginx
        if docker ps --format "table {{.Names}}" | grep -q "${CONTAINER_PREFIX}_nginx"; then
            docker-compose restart nginx
            log "Nginx已重启"
        fi
    fi

    success "配置更新完成"
}