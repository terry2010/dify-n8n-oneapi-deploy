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
    echo "  nginx     Nginx服务"
    echo ""
    echo "示例:"
    echo "  $0 start           # 启动所有服务"
    echo "  $0 stop dify       # 停止Dify服务"
    echo "  $0 restart nginx   # 重启Nginx服务"
    echo "  $0 status          # 查看所有服务状态"
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
    check_service_health "mysql" "mysqladmin ping -h localhost -u root -p${DB_*} --silent" 2>/dev/null || echo "❌ MySQL: 未运行或连接失败"
    check_service_health "postgres" "pg_isready -U postgres" 2>/dev/null || echo "❌ PostgreSQL: 未运行或连接失败"
    check_service_health "redis" "redis-cli ping" 2>/dev/null || echo "❌ Redis: 未运行或连接失败"

    echo -e "\n${BLUE}=== 访问地址 ===${NC}"
    if [ "$USE_DOMAIN" = true ]; then
        echo "Dify: ${DIFY_URL}"
        echo "n8n: ${N8N_URL}"
        echo "OneAPI: ${ONEAPI_URL}"
    else
        echo "统一入口: http://${SERVER_IP}:8604"
        echo "Dify: http://${SERVER_IP}:${DIFY_WEB_PORT}"
        echo "n8n: http://${SERVER_IP}:${N8N_WEB_PORT}"
        echo "OneAPI: http://${SERVER_IP}:${ONEAPI_WEB_PORT}"
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