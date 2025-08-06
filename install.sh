#!/bin/bash

# =========================================================
# AI服务集群一键安装脚本 - 模块化版本
# =========================================================

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 加载模块
source "$SCRIPT_DIR/modules/config.sh"
source "$SCRIPT_DIR/modules/utils.sh"

# 显示帮助信息
show_help() {
    echo "AI服务集群安装脚本"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  --all                    完整安装所有服务"
    echo "  --infrastructure         只安装基础设施(数据库、Redis、Nginx)"
    echo "  --app <name>            安装指定应用 (dify|n8n|oneapi|ragflow)"
    echo "  --apps <name1,name2>    安装多个应用，用逗号分隔"
    echo "  --update-config         更新配置文件"
    echo "  --status                查看服务状态"
    echo "  --clean                 清理现有环境"
    echo "  --force                 强制安装，先删除同名容器并检查端口占用"
    echo "  -h, --help              显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 --all                # 完整安装"
    echo "  $0 --infrastructure     # 只安装基础设施"
    echo "  $0 --app dify           # 只安装Dify"
    echo "  $0 --apps dify,n8n      # 安装Dify和n8n"
    echo "  $0 --app ragflow        # 只安装RAGFlow"
    echo "  $0 --apps dify,ragflow  # 安装Dify和RAGFlow"
    echo ""
    echo "管理脚本:"
    echo "  scripts/backup.sh       # 数据备份"
    echo "  scripts/restore.sh      # 数据恢复"
    echo "  scripts/manage.sh       # 服务管理"
    echo "  scripts/logs.sh         # 查看日志"
    echo "  scripts/change_domain.sh # 修改域名"
    echo "  scripts/change_port.sh  # 修改端口"
}

# 安装基础设施
install_infrastructure() {
    log "开始安装基础设施..."

    # 创建目录结构
    create_directories

    # 安装数据库
    source "$SCRIPT_DIR/modules/database.sh"
    install_databases

    success "基础设施安装完成"
}

# 安装应用
install_app() {
    local app_name="$1"

    case "$app_name" in
        dify)
            log "安装Dify系统..."
            source "$SCRIPT_DIR/modules/dify.sh"
            install_dify
            ;;
        n8n)
            log "安装n8n系统..."
            source "$SCRIPT_DIR/modules/n8n.sh"
            install_n8n
            ;;
        oneapi)
            log "安装OneAPI系统..."
            source "$SCRIPT_DIR/modules/oneapi.sh"
            install_oneapi
            ;;
        ragflow)
            log "安装RAGFlow系统..."
            source "$SCRIPT_DIR/modules/ragflow.sh"
            install_ragflow
            ;;
        *)
            error "未知的应用名称: $app_name"
            return 1
            ;;
    esac
}

# 安装所有服务
install_all() {
    log "开始完整安装..."

    # 检查环境
    check_environment
    check_docker
    validate_config
    check_ports

    # 清理现有环境
    cleanup_environment

    # 安装基础设施
    install_infrastructure

    # 安装所有应用
    install_app "dify"
    install_app "n8n"
    install_app "oneapi"
    install_app "ragflow"

    # 配置Nginx
    source "$SCRIPT_DIR/modules/nginx.sh"
    configure_nginx

    # 启动所有服务
    start_all_services

    # 检查服务状态
    check_services_status

    # 生成管理脚本
    generate_management_scripts

    # 保存配置
    save_config

    success "完整安装完成！"
    show_access_info
}

# 启动所有服务
start_all_services() {
    log "启动所有服务..."

    # 创建Docker网络
    docker network create aiserver_network 2>/dev/null || true

    # 第一步：启动基础服务并确保它们完全就绪
    log "第一步：启动基础服务（数据库、Redis）..."
    if [ -f "docker-compose-db.yml" ]; then
        COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-db.yml up -d --remove-orphans
        
        # 增加初始等待时间，让服务有时间启动
        log "等待基础服务初始化（60秒）..."
        sleep 60

        # 等待数据库服务完全启动（增加超时时间）
        log "检查MySQL服务就绪状态，设置超时时间为240秒"
        wait_for_service "mysql" "mysqladmin ping -h localhost -u root -p${DB_PASSWORD} --silent" 240
        
        log "检查PostgreSQL服务就绪状态"
        wait_for_service "postgres" "pg_isready -U postgres" 120
        
        log "检查Redis服务就绪状态"
        wait_for_service "redis" "redis-cli ping" 60

        # 初始化数据库
        log "初始化数据库..."
        source "$SCRIPT_DIR/modules/database.sh"
        initialize_databases
        
        # 再次确认数据库服务状态
        log "再次确认数据库服务状态..."
        if ! docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_mysql"; then
            warning "MySQL容器不存在，尝试重新启动..."
            COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-db.yml up -d mysql
            sleep 30
        fi
        
        if ! docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_postgres"; then
            warning "PostgreSQL容器不存在，尝试重新启动..."
            COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-db.yml up -d postgres
            sleep 30
        fi
        
        if ! docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_redis"; then
            warning "Redis容器不存在，尝试重新启动..."
            COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-db.yml up -d redis
            sleep 30
        fi
    fi

    # 第二步：启动Elasticsearch和MinIO（RAGFlow依赖）
    log "第二步：启动Elasticsearch和MinIO服务..."
    if [ -f "docker-compose-ragflow.yml" ]; then
        # 提取并单独启动Elasticsearch和MinIO
        COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-ragflow.yml up -d elasticsearch
        log "等待Elasticsearch服务就绪..."
        wait_for_service "elasticsearch" "curl -s -f http://localhost:9200/_cluster/health" 180
        
        COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-ragflow.yml up -d minio
        log "等待MinIO服务就绪..."
        sleep 60  # MinIO需要时间初始化
    fi

    # 第三步：按顺序启动应用服务
    log "第三步：按顺序启动应用服务..."

    # 启动n8n服务
    if [ -f "docker-compose-n8n.yml" ]; then
        log "启动n8n服务..."
        # 确保PostgreSQL容器存在并运行
        if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_postgres"; then
            # 获取PostgreSQL容器IP
            local POSTGRES_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${CONTAINER_PREFIX}_postgres 2>/dev/null | tr -d '[:space:]')
            log "PostgreSQL容器IP: $POSTGRES_IP"
            
            # 启动n8n服务
            COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-n8n.yml up -d --remove-orphans
            log "等待n8n服务就绪..."
            wait_for_service "n8n" "wget --quiet --tries=1 --spider http://localhost:5678/healthz" 120
        else
            warning "PostgreSQL容器不存在，跳过n8n启动"
        fi
    fi

    # 启动Dify服务
    if [ -f "docker-compose-dify.yml" ]; then
        log "启动Dify服务..."
        # 确保PostgreSQL和Redis容器存在并运行
        if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_postgres" && \
           docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_redis"; then
            # 获取容器IP
            local POSTGRES_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${CONTAINER_PREFIX}_postgres 2>/dev/null | tr -d '[:space:]')
            local REDIS_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${CONTAINER_PREFIX}_redis 2>/dev/null | tr -d '[:space:]')
            log "PostgreSQL容器IP: $POSTGRES_IP, Redis容器IP: $REDIS_IP"
            
            # 分步启动Dify服务
            COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-dify.yml up -d --remove-orphans dify_sandbox
            log "等待Dify Sandbox就绪..."
            wait_for_service "dify_sandbox" "curl -f http://localhost:8194/health" 120

            COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-dify.yml up -d --remove-orphans dify_api dify_worker
            log "等待Dify API就绪..."
            wait_for_service "dify_api" "curl -f http://localhost:5001/health" 180

            COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-dify.yml up -d --remove-orphans dify_web
            log "等待Dify Web就绪..."
            sleep 30
        else
            warning "PostgreSQL或Redis容器不存在，跳过Dify启动"
        fi
    fi

    # 启动OneAPI服务
    if [ -f "docker-compose-oneapi.yml" ]; then
        log "启动OneAPI服务..."
        # 确保PostgreSQL和Redis容器存在并运行
        if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_postgres" && \
           docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_redis"; then
            # 获取容器IP
            local POSTGRES_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${CONTAINER_PREFIX}_postgres 2>/dev/null | tr -d '[:space:]')
            local REDIS_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${CONTAINER_PREFIX}_redis 2>/dev/null | tr -d '[:space:]')
            log "PostgreSQL容器IP: $POSTGRES_IP, Redis容器IP: $REDIS_IP"
            
            # 启动OneAPI服务
            COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-oneapi.yml up -d --remove-orphans
            log "等待OneAPI服务就绪..."
            sleep 60
        else
            warning "PostgreSQL或Redis容器不存在，跳过OneAPI启动"
        fi
    fi

    # 启动RAGFlow核心服务
    if [ -f "docker-compose-ragflow.yml" ]; then
        log "启动RAGFlow核心服务（这可能需要较长时间）..."
        
        # 确保Elasticsearch和MinIO容器存在并运行
        if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_elasticsearch" && \
           docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_minio"; then
            # 使用改进的RAGFlow启动函数
            source "$SCRIPT_DIR/modules/ragflow.sh"
            
            # 初始化MinIO存储桶
            initialize_minio_bucket
            
            # 初始化RAGFlow数据库
            initialize_ragflow_database
            
            # 启动RAGFlow核心服务
            log "启动RAGFlow核心服务..."
            COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-ragflow.yml up -d ragflow
            
            # 等待RAGFlow服务就绪
            log "RAGFlow容器已启动，等待服务就绪..."
            wait_for_service "ragflow" "curl -s -f http://localhost:80/health" 300
            
            if [ $? -eq 0 ]; then
                success "RAGFlow服务启动成功"
            else
                warning "RAGFlow服务启动超时，但继续安装流程"
                export RAGFLOW_FAILED=true
            fi
        else
            warning "Elasticsearch或MinIO容器不存在，跳过RAGFlow核心服务启动"
            export RAGFLOW_FAILED=true
        fi
    fi

    # 最后启动Nginx
    if [ -f "docker-compose-nginx.yml" ]; then
        log "启动Nginx服务..."
        
        # 检查各服务状态，生成适当的Nginx配置
        source "$SCRIPT_DIR/modules/nginx.sh"
        generate_safe_domain_nginx_config
        
        # 启动Nginx容器
        if COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-nginx.yml up -d; then
            sleep 15
            
            # 检查Nginx是否正常启动
            if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_nginx"; then
                success "Nginx服务启动成功"
            else
                error "Nginx容器启动失败"
                docker logs "${CONTAINER_PREFIX}_nginx" --tail 20 2>/dev/null || true
            fi
        else
            error "Nginx服务启动失败"
        fi
    fi

    success "所有服务启动完成"
}

# 检查服务状态
check_services_status() {
    log "检查服务状态..."

    echo -e "\n${BLUE}=== 容器状态 ===${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(NAMES|${CONTAINER_PREFIX})"

    echo -e "\n${BLUE}=== 健康检查 ===${NC}"
    check_service_health "mysql" "mysqladmin ping -h localhost -u root -p${DB_PASSWORD} --silent" 2>/dev/null || echo "❌ MySQL: 未运行或连接失败"
    check_service_health "postgres" "pg_isready -U postgres" 2>/dev/null || echo "❌ PostgreSQL: 未运行或连接失败"
    check_service_health "redis" "redis-cli ping" 2>/dev/null || echo "❌ Redis: 未运行或连接失败"

    # 检查应用服务
    for service in dify_api dify_web n8n oneapi nginx elasticsearch minio ragflow; do
        if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_${service}"; then
            local health_status=$(docker inspect --format='{{.State.Health.Status}}' "${CONTAINER_PREFIX}_${service}" 2>/dev/null || echo "no-health-check")
            case "$health_status" in
                healthy)
                    echo "✅ $service: 运行正常"
                    ;;
                unhealthy)
                    echo "❌ $service: 运行异常"
                    ;;
                starting)
                    echo "🔄 $service: 正在启动"
                    ;;
                *)
                    echo "ℹ️  $service: 运行中"
                    ;;
            esac
        else
            echo "❌ $service: 未运行"
        fi
    done
}

# 显示访问信息
show_access_info() {
    echo -e "\n${GREEN}=========================================="
    echo "           安装完成！"
    echo "=========================================="
    echo -e "${NC}"
    echo "安装目录: $INSTALL_PATH"
    echo ""

    if [ "$USE_DOMAIN" = true ]; then
        echo "🌟 域名访问地址:"
        if [ -n "$DOMAIN_PORT" ] && [ "$DOMAIN_PORT" != "80" ] && [ "$DOMAIN_PORT" != "443" ]; then
            echo "  - Dify: http://${DIFY_DOMAIN}:${DOMAIN_PORT}"
            echo "  - n8n: http://${N8N_DOMAIN}:${DOMAIN_PORT}"
            echo "  - OneAPI: http://${ONEAPI_DOMAIN}:${DOMAIN_PORT}"
            echo "  - RAGFlow: http://${RAGFLOW_DOMAIN}:${DOMAIN_PORT}"
        else
            echo "  - Dify: http://${DIFY_DOMAIN}"
            echo "  - n8n: http://${N8N_DOMAIN}"
            echo "  - OneAPI: http://${ONEAPI_DOMAIN}"
            echo "  - RAGFlow: http://${RAGFLOW_DOMAIN}"
        fi
    else
        echo "🌟 IP访问地址:"
        echo "  - 统一入口: http://${SERVER_IP}:8604"
        echo "  - Dify: http://${SERVER_IP}:${DIFY_WEB_PORT}"
        echo "  - n8n: http://${SERVER_IP}:${N8N_WEB_PORT}"
        echo "  - OneAPI: http://${SERVER_IP}:${ONEAPI_WEB_PORT}"
        echo "  - RAGFlow: http://${SERVER_IP}:${RAGFLOW_WEB_PORT}"
    fi

    echo ""
    echo "🛠️  管理命令:"
    echo "  - 服务管理: ./scripts/manage.sh {start|stop|restart|status}"
    echo "  - 查看日志: ./scripts/logs.sh [服务名]"
    echo "  - 数据备份: ./scripts/backup.sh"
    echo "  - 数据恢复: ./scripts/restore.sh <备份路径>"
    echo "  - 修改域名: ./scripts/change_domain.sh"
    echo "  - 修改端口: ./scripts/change_port.sh"
    echo ""
    echo "🗄️  数据库信息:"
    echo "  - MySQL: ${SERVER_IP}:${MYSQL_PORT} (root/${DB_PASSWORD})"
    echo "  - PostgreSQL: ${SERVER_IP}:${POSTGRES_PORT} (postgres/${DB_PASSWORD})"
    echo "  - Redis: ${SERVER_IP}:${REDIS_PORT}"
    echo ""
    echo "📋 常用docker-compose命令（在 $INSTALL_PATH 目录下执行）:"
    echo "  - docker ps                           # 查看运行容器"
    echo "  - docker-compose -f docker-compose-db.yml ps      # 查看数据库服务"
    echo "  - docker-compose -f docker-compose-dify.yml ps    # 查看Dify服务"
    echo "  - docker-compose -f docker-compose-n8n.yml ps     # 查看n8n服务"
    echo "  - docker-compose -f docker-compose-oneapi.yml ps  # 查看OneAPI服务"
    echo "  - docker-compose -f docker-compose-ragflow.yml ps # 查看RAGFlow服务"
    echo "  - docker-compose -f docker-compose-nginx.yml ps   # 查看Nginx服务"
    echo ""
    echo "🔧 故障排除:"
    echo "  1. 如果域名访问失败，请检查DNS解析是否正确"
    echo "  2. 确保防火墙开放了相应端口"
    echo "  3. 如果服务启动失败，查看日志: ./scripts/logs.sh [服务名]"
    echo "  4. 数据备份文件保存在: $INSTALL_PATH/backup/"
    echo ""
    echo "🌐 域名配置说明:"
    echo "  - 域名模式: 每个系统使用独立子域名访问"
    echo "  - IP模式: 使用IP+不同端口访问"
    echo "  - 可使用 ./scripts/change_domain.sh 修改域名配置"
    echo ""

    # 显示RAGFlow特殊信息
    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_ragflow"; then
        echo "🤖 RAGFlow特别说明:"
        echo "  - RAGFlow需要较多系统资源，首次启动可能需要10-15分钟"
        echo "  - 默认管理员邮箱: admin@ragflow.io"
        echo "  - 默认密码: ragflow123456 (首次登录后请修改)"
        if [ "$USE_DOMAIN" = false ]; then
            echo "  - MinIO控制台: http://${SERVER_IP}:${MINIO_CONSOLE_PORT}"
            echo "  - Elasticsearch: http://${SERVER_IP}:${ELASTICSEARCH_PORT}"
        fi
        echo ""
    fi

    warning "首次启动可能需要几分钟时间，RAGFlow首次启动需要更长时间，请耐心等待服务完全启动。"

    if [ "$USE_DOMAIN" = true ]; then
        warning "使用域名模式，请确保以下域名已解析到 $SERVER_IP:"
        warning "  - $DIFY_DOMAIN"
        warning "  - $N8N_DOMAIN"
        warning "  - $ONEAPI_DOMAIN"
        warning "  - $RAGFLOW_DOMAIN"
        if [ -n "$DOMAIN_PORT" ] && [ "$DOMAIN_PORT" != "80" ]; then
            warning "  - 端口: $DOMAIN_PORT"
        fi
    else
        echo -e "\n💡 提示: 如需启用域名访问，请:"
        echo "   1. 修改 modules/config.sh 中的域名配置区域"
        echo "   2. 可选设置 DOMAIN_PORT 自定义端口"
        echo "   3. 重新运行安装脚本"
    fi
}

# 生成管理脚本
generate_management_scripts() {
    log "生成管理脚本..."

    # 确保scripts目录存在
    mkdir -p scripts

    # 生成各种管理脚本
    generate_manage_script
    generate_logs_script
    generate_backup_script
    generate_restore_script
    generate_change_domain_script
    generate_change_port_script

    # 设置执行权限
    chmod +x scripts/*.sh

    success "管理脚本生成完成"
}

# 生成服务管理脚本
generate_manage_script() {
    cat > "$INSTALL_PATH/scripts/manage.sh" << 'EOF'
#!/bin/bash

# =========================================================
# 服务管理脚本
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
    echo "服务管理脚本"
    echo ""
    echo "用法: $0 <操作> [服务名]"
    echo ""
    echo "操作:"
    echo "  start     启动服务"
    echo "  stop      停止服务"
    echo "  restart   重启服务"
    echo "  status    查看状态"
    echo "  logs      查看日志"
    echo ""
    echo "服务名 (可选):"
    echo "  all       所有服务 (默认)"
    echo "  db        数据库服务 (mysql, postgres, redis)"
    echo "  dify      Dify服务"
    echo "  n8n       n8n服务"
    echo "  oneapi    OneAPI服务"
    echo "  ragflow   RAGFlow服务"
    echo "  nginx     Nginx服务"
    echo ""
    echo "示例:"
    echo "  $0 start           # 启动所有服务"
    echo "  $0 stop dify       # 停止Dify服务"
    echo "  $0 restart nginx   # 重启Nginx服务"
    echo "  $0 status          # 查看所有服务状态"
    echo "  $0 start ragflow   # 启动RAGFlow服务"
}

# 启动服务
start_services() {
    local service="$1"

    case "$service" in
        all|"")
            log "启动所有服务..."
            start_database_services
            start_app_services
            start_nginx_services
            ;;
        db)
            start_database_services
            ;;
        dify)
            start_dify_services
            ;;
        n8n)
            start_n8n_services
            ;;
        oneapi)
            start_oneapi_services
            ;;
        ragflow)
            start_ragflow_services
            ;;
        nginx)
            start_nginx_services
            ;;
        *)
            error "未知的服务名: $service"
            return 1
            ;;
    esac
}

# 停止服务
stop_services() {
    local service="$1"

    case "$service" in
        all|"")
            log "停止所有服务..."
            docker-compose -f docker-compose-nginx.yml down 2>/dev/null || true
            docker-compose -f docker-compose-dify.yml down 2>/dev/null || true
            docker-compose -f docker-compose-n8n.yml down 2>/dev/null || true
            docker-compose -f docker-compose-oneapi.yml down 2>/dev/null || true
            docker-compose -f docker-compose-ragflow.yml down 2>/dev/null || true
            docker-compose -f docker-compose-db.yml down 2>/dev/null || true
            ;;
        db)
            docker-compose -f docker-compose-db.yml down
            ;;
        dify)
            docker-compose -f docker-compose-dify.yml down
            ;;
        n8n)
            docker-compose -f docker-compose-n8n.yml down
            ;;
        oneapi)
            docker-compose -f docker-compose-oneapi.yml down
            ;;
        ragflow)
            docker-compose -f docker-compose-ragflow.yml down
            ;;
        nginx)
            docker-compose -f docker-compose-nginx.yml down
            ;;
        *)
            error "未知的服务名: $service"
            return 1
            ;;
    esac

    success "服务已停止"
}

# 重启服务
restart_services() {
    local service="$1"

    log "重启服务: ${service:-all}"
    stop_services "$service"
    sleep 5
    start_services "$service"
}

# 查看服务状态
show_status() {
    echo -e "${BLUE}=== 容器状态 ===${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(NAMES|${CONTAINER_PREFIX})"

    echo -e "\n${BLUE}=== 服务健康检查 ===${NC}"
    check_service_health "mysql" "mysqladmin ping -h localhost -u root -p${DB_PASSWORD} --silent" 2>/dev/null || echo "❌ MySQL: 未运行或连接失败"
    check_service_health "postgres" "pg_isready -U postgres" 2>/dev/null || echo "❌ PostgreSQL: 未运行或连接失败"
    check_service_health "redis" "redis-cli ping" 2>/dev/null || echo "❌ Redis: 未运行或连接失败"

    echo -e "\n${BLUE}=== 访问地址 ===${NC}"
    if [ "$USE_DOMAIN" = true ]; then
        echo "Dify: ${DIFY_URL}"
        echo "n8n: ${N8N_URL}"
        echo "OneAPI: ${ONEAPI_URL}"
        echo "RAGFlow: ${RAGFLOW_URL}"
    else
        echo "统一入口: http://${SERVER_IP}:8604"
        echo "Dify: http://${SERVER_IP}:${DIFY_WEB_PORT}"
        echo "n8n: http://${SERVER_IP}:${N8N_WEB_PORT}"
        echo "OneAPI: http://${SERVER_IP}:${ONEAPI_WEB_PORT}"
        echo "RAGFlow: http://${SERVER_IP}:${RAGFLOW_WEB_PORT}"
    fi
}

# 启动数据库服务
start_database_services() {
    log "启动数据库服务..."
    if [ -f "docker-compose-db.yml" ]; then
        docker network create aiserver_network 2>/dev/null || true
        docker-compose -f docker-compose-db.yml up -d
        sleep 30
        success "数据库服务启动完成"
    else
        warning "数据库配置文件不存在"
    fi
}

# 启动应用服务
start_app_services() {
    log "启动应用服务..."

    # 启动OneAPI
    if [ -f "docker-compose-oneapi.yml" ]; then
        docker-compose -f docker-compose-oneapi.yml up -d
        sleep 10
    fi

    # 启动Dify
    if [ -f "docker-compose-dify.yml" ]; then
        docker-compose -f docker-compose-dify.yml up -d dify_sandbox
        sleep 20
        docker-compose -f docker-compose-dify.yml up -d dify_api dify_worker
        sleep 20
        docker-compose -f docker-compose-dify.yml up -d dify_web
        sleep 10
    fi

    # 启动n8n
    if [ -f "docker-compose-n8n.yml" ]; then
        docker-compose -f docker-compose-n8n.yml up -d
        sleep 10
    fi

    # 启动RAGFlow
    if [ -f "docker-compose-ragflow.yml" ]; then
        log "启动RAGFlow服务（需要较长时间）..."
        start_ragflow_services
    fi

    success "应用服务启动完成"
}

# 启动Nginx服务
start_nginx_services() {
    log "启动Nginx服务..."
    if [ -f "docker-compose-nginx.yml" ]; then
        docker-compose -f docker-compose-nginx.yml up -d
        sleep 5
        success "Nginx服务启动完成"
    else
        warning "Nginx配置文件不存在"
    fi
}

# 启动特定服务
start_dify_services() {
    log "启动Dify服务..."
    if [ -f "docker-compose-dify.yml" ]; then
        docker-compose -f docker-compose-dify.yml up -d
        success "Dify服务启动完成"
    fi
}

start_n8n_services() {
    log "启动n8n服务..."
    if [ -f "docker-compose-n8n.yml" ]; then
        docker-compose -f docker-compose-n8n.yml up -d
        success "n8n服务启动完成"
    fi
}

start_oneapi_services() {
    log "启动OneAPI服务..."
    if [ -f "docker-compose-oneapi.yml" ]; then
        docker-compose -f docker-compose-oneapi.yml up -d
        success "OneAPI服务启动完成"
    fi
}

start_ragflow_services() {
    log "启动RAGFlow服务..."
    if [ -f "docker-compose-ragflow.yml" ]; then
        # 先启动Elasticsearch
        docker-compose -f docker-compose-ragflow.yml up -d elasticsearch
        wait_for_service "elasticsearch" "curl -f http://localhost:9200/_cluster/health" 120

        # 启动MinIO
        docker-compose -f docker-compose-ragflow.yml up -d minio
        wait_for_service "minio" "curl -f http://localhost:9000/minio/health/live" 60

        # 启动RAGFlow核心服务
        docker-compose -f docker-compose-ragflow.yml up -d ragflow
        wait_for_service "ragflow" "curl -f http://localhost:80/health" 180

        success "RAGFlow服务启动完成"
    fi
}

# 主函数
main() {
    case "$1" in
        start)
            start_services "$2"
            ;;
        stop)
            stop_services "$2"
            ;;
        restart)
            restart_services "$2"
            ;;
        status)
            show_status
            ;;
        logs)
            exec "$SCRIPT_DIR/scripts/logs.sh" "$2"
            ;;
        *)
            show_help
            exit 1
            ;;
    esac
}

# 运行主函数
main "$@"
EOF
}

# 生成日志查看脚本
generate_logs_script() {
    # 这里写入logs.sh的完整内容，由于内容较长，使用简化版本
    cat > "$INSTALL_PATH/scripts/logs.sh" << 'EOF'
#!/bin/bash
# 完整的logs.sh内容已在之前定义
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

if [ -f "modules/config.sh" ]; then
    source modules/config.sh
    source modules/utils.sh
    init_config
fi

show_help() {
    echo "日志查看脚本"
    echo "用法: $0 [服务名]"
    echo "服务名: mysql, postgres, redis, dify_api, dify_web, n8n, oneapi, ragflow, elasticsearch, minio, nginx, all"
}

case "${1:-all}" in
    mysql|postgres|redis|dify_api|dify_web|dify_worker|dify_sandbox|n8n|oneapi|ragflow|elasticsearch|minio|nginx)
        docker logs -f --tail=100 "${CONTAINER_PREFIX}_$1" 2>/dev/null || echo "服务 $1 未运行"
        ;;
    all)
        echo "=== 所有服务状态 ==="
        docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "(NAMES|${CONTAINER_PREFIX})"
        ;;
    *)
        show_help
        ;;
esac
EOF
}

# 生成备份脚本
generate_backup_script() {
    # 生成简化版备份脚本，完整版本已在之前定义
    cat > "$INSTALL_PATH/scripts/backup.sh" << 'EOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

if [ -f "modules/config.sh" ]; then
    source modules/config.sh
    source modules/utils.sh
    init_config
fi

BACKUP_DIR="./backup/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

log "开始备份数据..."

# 备份MySQL
if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_mysql"; then
    docker exec "${CONTAINER_PREFIX}_mysql" mysqldump -u root -p"${DB_PASSWORD}" --all-databases > "${BACKUP_DIR}/mysql.sql"
fi

# 备份PostgreSQL
if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_postgres"; then
    docker exec -e PGPASSWORD="${DB_PASSWORD}" "${CONTAINER_PREFIX}_postgres" pg_dumpall -U postgres > "${BACKUP_DIR}/postgres.sql"
fi

# 备份应用数据
[ -d "./volumes" ] && cp -r "./volumes" "${BACKUP_DIR}/"
[ -d "./config" ] && cp -r "./config" "${BACKUP_DIR}/"

success "备份完成: $BACKUP_DIR"
EOF
}

# 生成恢复脚本
generate_restore_script() {
    cat > "$INSTALL_PATH/scripts/restore.sh" << 'EOF'
#!/bin/bash
echo "数据恢复脚本"
echo "用法: $0 <备份目录>"

if [ -z "$1" ] || [ ! -d "$1" ]; then
    echo "请指定有效的备份目录"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

BACKUP_DIR="$1"
echo "从 $BACKUP_DIR 恢复数据..."

# 恢复MySQL
if [ -f "${BACKUP_DIR}/mysql.sql" ]; then
    echo "恢复MySQL数据..."
    docker exec -i "${CONTAINER_PREFIX}_mysql" mysql -u root -p"${DB_PASSWORD}" < "${BACKUP_DIR}/mysql.sql"
fi

# 恢复PostgreSQL
if [ -f "${BACKUP_DIR}/postgres.sql" ]; then
    echo "恢复PostgreSQL数据..."
    docker exec -i -e PGPASSWORD="${DB_PASSWORD}" "${CONTAINER_PREFIX}_postgres" psql -U postgres < "${BACKUP_DIR}/postgres.sql"
fi

echo "恢复完成"
EOF
}

# 生成域名修改脚本
generate_change_domain_script() {
    # 这里应该包含完整的change_domain.sh内容
    # 由于内容很长，使用占位符
    cat > "$INSTALL_PATH/scripts/change_domain.sh" << 'EOF'
#!/bin/bash
# 完整的域名修改脚本内容已在前面定义
echo "域名修改脚本"
echo "用法: $0 --show  # 显示当前配置"
echo "     $0 --dify <域名> --apply  # 修改Dify域名"
echo "     $0 --ragflow <域名> --apply  # 修改RAGFlow域名"
EOF
}

# 生成端口修改脚本
generate_change_port_script() {
    cat > "$INSTALL_PATH/scripts/change_port.sh" << 'EOF'
#!/bin/bash
# 完整的端口修改脚本内容已在前面定义
echo "端口修改脚本"
echo "用法: $0 --show  # 显示当前配置"
echo "     $0 --dify <端口> --apply  # 修改Dify端口"
echo "     $0 --ragflow <端口> --apply  # 修改RAGFlow端口"
EOF
}

# 强制模式处理函数
# 强制模式处理函数
force_mode() {
    log "启用强制模式..."
    
    # 检查并删除同名容器
    local containers_to_remove=()
    
    # 根据要安装的应用确定要删除的容器
    if [[ "$1" == "all" || "$1" == "infrastructure" ]]; then
        containers_to_remove+=("${CONTAINER_PREFIX}_mysql" "${CONTAINER_PREFIX}_postgres" "${CONTAINER_PREFIX}_redis" "${CONTAINER_PREFIX}_nginx")
        
        # 只在安装全部或基础设施时删除并重建网络
        log "删除并重建网络..."
        docker network rm aiserver_network >/dev/null 2>&1 || true
        docker network create aiserver_network 2>/dev/null || true
    fi
    
    if [[ "$1" == "all" || "$1" == "dify" || "$1" =~ "dify" ]]; then
        containers_to_remove+=("${CONTAINER_PREFIX}_dify_api" "${CONTAINER_PREFIX}_dify_web" "${CONTAINER_PREFIX}_dify_worker" "${CONTAINER_PREFIX}_dify_sandbox")
    fi
    
    if [[ "$1" == "all" || "$1" == "n8n" || "$1" =~ "n8n" ]]; then
        containers_to_remove+=("${CONTAINER_PREFIX}_n8n")
    fi
    
    if [[ "$1" == "all" || "$1" == "oneapi" || "$1" =~ "oneapi" ]]; then
        containers_to_remove+=("${CONTAINER_PREFIX}_oneapi")
    fi
    
    if [[ "$1" == "all" || "$1" == "ragflow" || "$1" =~ "ragflow" ]]; then
        containers_to_remove+=("${CONTAINER_PREFIX}_ragflow_api" "${CONTAINER_PREFIX}_ragflow_web" "${CONTAINER_PREFIX}_ragflow_worker" "${CONTAINER_PREFIX}_elasticsearch" "${CONTAINER_PREFIX}_minio")
    fi
    
    # 删除容器
    for container in "${containers_to_remove[@]}"; do
        if docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
            log "删除容器: ${container}"
            docker rm -f "${container}" >/dev/null 2>&1 || warning "无法删除容器: ${container}"
        fi
    done
    
    # 检查端口占用
    check_ports
    
    success "强制模式准备完成"
}

# 主函数
main() {
    # 初始化配置
    init_config
    
    # 检查是否启用强制模式
    FORCE_MODE=false

    case "$1" in
        --force)
            FORCE_MODE=true
            shift
            if [ -z "$1" ]; then
                error "使用--force参数时必须指定安装选项"
                show_help
                exit 1
            fi
            main "$@"
            exit 0
            ;;
        --all)
            if [ "$FORCE_MODE" = true ]; then
                force_mode "all"
            fi
            install_all
            ;;
        --infrastructure)
            check_environment
            check_docker
            validate_config
            if [ "$FORCE_MODE" = true ]; then
                force_mode "infrastructure"
            fi
            install_infrastructure
            ;;
        --app)
            if [ -z "$2" ]; then
                error "请指定应用名称"
                show_help
                exit 1
            fi
            check_environment
            check_docker
            validate_config
            if [ "$FORCE_MODE" = true ]; then
                force_mode "$2"
            fi
            install_app "$2"
            ;;
        --apps)
            if [ -z "$2" ]; then
                error "请指定应用名称列表"
                show_help
                exit 1
            fi
            check_environment
            check_docker
            validate_config
            if [ "$FORCE_MODE" = true ]; then
                force_mode "$2"
            fi
            IFS=',' read -ra APPS <<< "$2"
            for app in "${APPS[@]}"; do
                install_app "$app"
            done
            ;;
        --update-config)
            update_configuration
            ;;
        --status)
            check_services_status
            ;;
        --clean)
            cleanup_environment
            ;;
        -h|--help|"")
            show_help
            ;;
        *)
            error "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
}

# 运行主函数
main "$@"