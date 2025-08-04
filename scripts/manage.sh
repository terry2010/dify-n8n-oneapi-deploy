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
    echo "用法: $0 <操作> [服务名] [选项]"
    echo ""
    echo "操作:"
    echo "  start     启动服务"
    echo "  stop      停止服务"
    echo "  restart   重启服务"
    echo "  status    查看状态"
    echo "  logs      查看日志"
    echo "  health    健康检查"
    echo "  scale     扩缩容服务"
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
    echo "选项:"
    echo "  --force   强制执行操作"
    echo "  --wait    等待服务完全启动"
    echo "  --timeout 设置超时时间（秒）"
    echo ""
    echo "示例:"
    echo "  $0 start           # 启动所有服务"
    echo "  $0 stop dify       # 停止Dify服务"
    echo "  $0 restart nginx   # 重启Nginx服务"
    echo "  $0 status          # 查看所有服务状态"
    echo "  $0 start ragflow --wait  # 启动RAGFlow并等待完全启动"
    echo "  $0 health          # 执行健康检查"
    echo "  $0 scale dify 2    # 将Dify服务扩展到2个实例"
}

# 启动服务
start_services() {
    local service="$1"
    local wait_flag="$2"
    local timeout="${3:-300}"

    case "$service" in
        all|"")
            log "启动所有服务..."
            start_database_services "$wait_flag" "$timeout"
            start_app_services "$wait_flag" "$timeout"
            start_nginx_services "$wait_flag" "$timeout"
            ;;
        db)
            start_database_services "$wait_flag" "$timeout"
            ;;
        dify)
            start_dify_services "$wait_flag" "$timeout"
            ;;
        n8n)
            start_n8n_services "$wait_flag" "$timeout"
            ;;
        oneapi)
            start_oneapi_services "$wait_flag" "$timeout"
            ;;
        ragflow)
            start_ragflow_services "$wait_flag" "$timeout"
            ;;
        nginx)
            start_nginx_services "$wait_flag" "$timeout"
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
    local force_flag="$2"

    local stop_cmd="down"
    if [ "$force_flag" = true ]; then
        stop_cmd="down --remove-orphans"
    fi

    case "$service" in
        all|"")
            log "停止所有服务..."
            docker-compose -f docker-compose-nginx.yml $stop_cmd 2>/dev/null || true
            docker-compose -f docker-compose-dify.yml $stop_cmd 2>/dev/null || true
            docker-compose -f docker-compose-n8n.yml $stop_cmd 2>/dev/null || true
            docker-compose -f docker-compose-oneapi.yml $stop_cmd 2>/dev/null || true
            docker-compose -f docker-compose-ragflow.yml $stop_cmd 2>/dev/null || true
            docker-compose -f docker-compose-db.yml $stop_cmd 2>/dev/null || true
            ;;
        db)
            docker-compose -f docker-compose-db.yml $stop_cmd
            ;;
        dify)
            docker-compose -f docker-compose-dify.yml $stop_cmd
            ;;
        n8n)
            docker-compose -f docker-compose-n8n.yml $stop_cmd
            ;;
        oneapi)
            docker-compose -f docker-compose-oneapi.yml $stop_cmd
            ;;
        ragflow)
            docker-compose -f docker-compose-ragflow.yml $stop_cmd
            ;;
        nginx)
            docker-compose -f docker-compose-nginx.yml $stop_cmd
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
    local wait_flag="$2"
    local timeout="$3"

    log "重启服务: ${service:-all}"
    stop_services "$service"
    sleep 10
    start_services "$service" "$wait_flag" "$timeout"
}

# 查看服务状态
show_status() {
    echo -e "${BLUE}=== 容器运行状态 ===${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(NAMES|${CONTAINER_PREFIX})"

    echo -e "\n${BLUE}=== 服务健康检查 ===${NC}"
    check_service_health "mysql" "mysqladmin ping -h localhost -u root -p${DB_*} --silent" 2>/dev/null || echo "❌ MySQL: 未运行或连接失败"
    check_service_health "postgres" "pg_isready -U postgres" 2>/dev/null || echo "❌ PostgreSQL: 未运行或连接失败"
    check_service_health "redis" "redis-cli ping" 2>/dev/null || echo "❌ Redis: 未运行或连接失败"

    # 检查应用服务健康状态
    local services=("dify_api" "dify_web" "n8n" "oneapi" "ragflow" "elasticsearch" "minio" "nginx")
    for service in "${services[@]}"; do
        local container_name="${CONTAINER_PREFIX}_${service}"
        if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
            local health_status=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "no-health-check")
            case "$health_status" in
                healthy)
                    echo "✅ $service: 健康"
                    ;;
                unhealthy)
                    echo "❌ $service: 不健康"
                    ;;
                starting)
                    echo "🔄 $service: 启动中"
                    ;;
                *)
                    echo "ℹ️  $service: 运行中"
                    ;;
            esac
        else
            echo "❌ $service: 未运行"
        fi
    done

    echo -e "\n${BLUE}=== 资源使用情况 ===${NC}"
    docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" | grep -E "(CONTAINER|${CONTAINER_PREFIX})" | head -20

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

    echo -e "\n${BLUE}=== 磁盘使用情况 ===${NC}"
    echo "总安装目录: $(du -sh "$INSTALL_PATH" 2>/dev/null | cut -f1)"
    echo "数据目录: $(du -sh "$INSTALL_PATH/volumes" 2>/dev/null | cut -f1)"
    echo "日志目录: $(du -sh "$INSTALL_PATH/logs" 2>/dev/null | cut -f1)"
    echo "备份目录: $(du -sh "$INSTALL_PATH/backup" 2>/dev/null | cut -f1)"
}

# 健康检查
health_check() {
    echo -e "${BLUE}=== 系统健康检查 ===${NC}"

    local all_healthy=true
    local issues=()

    # 检查Docker服务
    if ! docker info >/dev/null 2>&1; then
        issues+=("Docker服务未运行")
        all_healthy=false
    else
        success "Docker服务正常"
    fi

    # 检查磁盘空间
    local available_space=$(df "$INSTALL_PATH" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    if [ "$available_space" -lt 1048576 ]; then  # 小于1GB
        issues+=("磁盘空间不足（剩余: $(($available_space / 1024))MB）")
        all_healthy=false
    else
        success "磁盘空间充足"
    fi

    # 检查内存使用
    local mem_usage=$(free | awk 'NR==2{printf "%.1f", $3*100/$2}')
    local mem_usage_int=$(echo "$mem_usage" | cut -d'.' -f1)
    if [ "$mem_usage_int" -gt 90 ]; then
        issues+=("内存使用率过高: ${mem_usage}%")
        all_healthy=false
    else
        success "内存使用正常: ${mem_usage}%"
    fi

    # 检查数据库连接
    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_mysql"; then
        if docker exec "${CONTAINER_PREFIX}_mysql" mysqladmin ping -u root -p"${DB_*}" --silent 2>/dev/null; then
            success "MySQL连接正常"
        else
            issues+=("MySQL连接失败")
            all_healthy=false
        fi
    fi

    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_postgres"; then
        if docker exec "${CONTAINER_PREFIX}_postgres" pg_isready -U postgres >/dev/null 2>&1; then
            success "PostgreSQL连接正常"
        else
            issues+=("PostgreSQL连接失败")
            all_healthy=false
        fi
    fi

    if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_redis"; then
        if docker exec "${CONTAINER_PREFIX}_redis" redis-cli ping >/dev/null 2>&1; then
            success "Redis连接正常"
        else
            issues+=("Redis连接失败")
            all_healthy=false
        fi
    fi

    # 检查应用服务
    local critical_services=("dify_api" "n8n" "oneapi" "ragflow")
    for service in "${critical_services[@]}"; do
        local container_name="${CONTAINER_PREFIX}_${service}"
        if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
            success "$service 运行正常"
        else
            issues+=("$service 未运行")
            all_healthy=false
        fi
    done

    # 网络连通性检查
    if curl -s --connect-timeout 5 --max-time 10 "http://localhost:${NGINX_PORT}/health" >/dev/null 2>&1; then
        success "Nginx代理正常"
    else
        issues+=("Nginx代理异常")
        all_healthy=false
    fi

    # 显示结果
    echo ""
    if [ "$all_healthy" = true ]; then
        success "🎉 系统健康检查通过！所有服务运行正常。"
    else
        warning "⚠️  系统健康检查发现问题:"
        for issue in "${issues[@]}"; do
            echo "  ❌ $issue"
        done
        echo ""
        echo "建议操作:"
        echo "  1. 查看服务日志: ./scripts/logs.sh [服务名]"
        echo "  2. 重启问题服务: ./scripts/manage.sh restart [服务名]"
        echo "  3. 检查系统资源: free -h && df -h"
        echo "  4. 如需帮助，请查看故障排除文档"
    fi

    return $([ "$all_healthy" = true ] && echo 0 || echo 1)
}

# 服务扩缩容
scale_service() {
    local service="$1"
    local replicas="$2"

    if [ -z "$replicas" ] || ! [[ "$replicas" =~ ^[0-9]+$ ]]; then
        error "请指定有效的副本数量"
        return 1
    fi

    case "$service" in
        dify)
            log "扩缩容Dify服务到 $replicas 个实例..."
            docker-compose -f docker-compose-dify.yml up -d --scale dify_web="$replicas" --scale dify_worker="$replicas"
            ;;
        n8n)
            warning "n8n服务不支持多实例运行（数据一致性问题）"
            return 1
            ;;
        oneapi)
            log "扩缩容OneAPI服务到 $replicas 个实例..."
            docker-compose -f docker-compose-oneapi.yml up -d --scale oneapi="$replicas"
            ;;
        ragflow)
            log "扩缩容RAGFlow服务到 $replicas 个实例..."
            docker-compose -f docker-compose-ragflow.yml up -d --scale ragflow="$replicas"
            ;;
        *)
            error "服务 $service 不支持扩缩容"
            return 1
            ;;
    esac

    success "服务扩缩容完成"
}

# 启动数据库服务
start_database_services() {
    local wait_flag="$1"
    local timeout="${2:-300}"

    log "启动数据库服务..."
    if [ -f "docker-compose-db.yml" ]; then
        docker network create aiserver_network 2>/dev/null || true
        docker-compose -f docker-compose-db.yml up -d

        if [ "$wait_flag" = true ]; then
            log "等待数据库服务完全启动..."
            wait_for_service "mysql" "mysqladmin ping -h localhost -u root -p${DB_*} --silent" "$timeout"
            wait_for_service "postgres" "pg_isready -U postgres" "$timeout"
            wait_for_service "redis" "redis-cli ping" "$timeout"
        else
            sleep 30
        fi

        success "数据库服务启动完成"
    else
        warning "数据库配置文件不存在"
    fi
}

# 启动应用服务
start_app_services() {
    local wait_flag="$1"
    local timeout="${2:-300}"

    log "启动应用服务..."

    # 启动OneAPI
    if [ -f "docker-compose-oneapi.yml" ]; then
        docker-compose -f docker-compose-oneapi.yml up -d
        sleep 10
    fi

    # 启动Dify
    if [ -f "docker-compose-dify.yml" ]; then
        log "启动Dify服务（分步启动）..."
        docker-compose -f docker-compose-dify.yml up -d dify_sandbox

        if [ "$wait_flag" = true ]; then
            wait_for_service "dify_sandbox" "curl -f http://localhost:8194/health" "$timeout"
        else
            sleep 20
        fi

        docker-compose -f docker-compose-dify.yml up -d dify_api dify_worker

        if [ "$wait_flag" = true ]; then
            wait_for_service "dify_api" "curl -f http://localhost:5001/health" "$timeout"
        else
            sleep 20
        fi

        docker-compose -f docker-compose-dify.yml up -d dify_web
        sleep 10
    fi

    # 启动n8n
    if [ -f "docker-compose-n8n.yml" ]; then
        docker-compose -f docker-compose-n8n.yml up -d

        if [ "$wait_flag" = true ]; then
            wait_for_service "n8n" "wget --quiet --tries=1 --spider http://localhost:5678/healthz" "$timeout"
        else
            sleep 10
        fi
    fi

    # 启动RAGFlow
    if [ -f "docker-compose-ragflow.yml" ]; then
        log "启动RAGFlow服务（需要较长时间）..."
        start_ragflow_services "$wait_flag" "$timeout"
    fi

    success "应用服务启动完成"
}

# 启动Nginx服务
start_nginx_services() {
    local wait_flag="$1"
    local timeout="${2:-60}"

    log "启动Nginx服务..."
    if [ -f "docker-compose-nginx.yml" ]; then
        docker-compose -f docker-compose-nginx.yml up -d

        if [ "$wait_flag" = true ]; then
            wait_for_service "nginx" "curl -f http://localhost:80/health" "$timeout"
        else
            sleep 5
        fi

        success "Nginx服务启动完成"
    else
        warning "Nginx配置文件不存在"
    fi
}

# 启动特定服务
start_dify_services() {
    local wait_flag="$1"
    local timeout="${2:-300}"

    log "启动Dify服务..."
    if [ -f "docker-compose-dify.yml" ]; then
        docker-compose -f docker-compose-dify.yml up -d

        if [ "$wait_flag" = true ]; then
            wait_for_service "dify_api" "curl -f http://localhost:5001/health" "$timeout"
        fi

        success "Dify服务启动完成"
    fi
}

start_n8n_services() {
    local wait_flag="$1"
    local timeout="${2:-120}"

    log "启动n8n服务..."
    if [ -f "docker-compose-n8n.yml" ]; then
        docker-compose -f docker-compose-n8n.yml up -d

        if [ "$wait_flag" = true ]; then
            wait_for_service "n8n" "wget --quiet --tries=1 --spider http://localhost:5678/healthz" "$timeout"
        fi

        success "n8n服务启动完成"
    fi
}

start_oneapi_services() {
    local wait_flag="$1"
    local timeout="${2:-120}"

    log "启动OneAPI服务..."
    if [ -f "docker-compose-oneapi.yml" ]; then
        docker-compose -f docker-compose-oneapi.yml up -d

        if [ "$wait_flag" = true ]; then
            sleep 30  # OneAPI没有健康检查端点，等待固定时间
        fi

        success "OneAPI服务启动完成"
    fi
}

start_ragflow_services() {
    local wait_flag="$1"
    local timeout="${2:-600}"

    log "启动RAGFlow服务..."
    if [ -f "docker-compose-ragflow.yml" ]; then
        # 先启动Elasticsearch
        log "启动Elasticsearch..."
        docker-compose -f docker-compose-ragflow.yml up -d elasticsearch

        if [ "$wait_flag" = true ]; then
            wait_for_service "elasticsearch" "curl -f http://localhost:9200/_cluster/health" 120
        else
            sleep 60
        fi

        # 启动MinIO
        log "启动MinIO..."
        docker-compose -f docker-compose-ragflow.yml up -d minio

        if [ "$wait_flag" = true ]; then
            wait_for_service "minio" "curl -f http://localhost:9000/minio/health/live" 60
        else
            sleep 30
        fi

        # 启动RAGFlow核心服务
        log "启动RAGFlow核心服务..."
        docker-compose -f docker-compose-ragflow.yml up -d ragflow

        if [ "$wait_flag" = true ]; then
            wait_for_service "ragflow" "curl -f http://localhost:80/health" "$timeout"
        else
            sleep 60
        fi

        success "RAGFlow服务启动完成"
    fi
}

# 显示服务详细信息
show_service_details() {
    local service="$1"

    case "$service" in
        all|"")
            show_all_services_details
            ;;
        db)
            show_database_details
            ;;
        dify)
            show_dify_details
            ;;
        n8n)
            show_n8n_details
            ;;
        oneapi)
            show_oneapi_details
            ;;
        ragflow)
            show_ragflow_details
            ;;
        nginx)
            show_nginx_details
            ;;
        *)
            error "未知的服务名: $service"
            return 1
            ;;
    esac
}

show_all_services_details() {
    echo -e "${BLUE}=== 所有服务详细信息 ===${NC}"

    for service in db dify n8n oneapi ragflow nginx; do
        echo ""
        show_service_details "$service"
    done
}

show_database_details() {
    echo -e "${YELLOW}--- 数据库服务详情 ---${NC}"

    for db_service in mysql postgres redis; do
        local container_name="${CONTAINER_PREFIX}_${db_service}"
        if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
            echo "✅ $db_service:"
            echo "   状态: 运行中"
            echo "   镜像: $(docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null)"
            echo "   端口: $(docker port "$container_name" 2>/dev/null | head -1)"
            echo "   启动时间: $(docker inspect --format='{{.State.StartedAt}}' "$container_name" 2>/dev/null | cut -d'T' -f1)"
        else
            echo "❌ $db_service: 未运行"
        fi
    done
}

show_dify_details() {
    echo -e "${YELLOW}--- Dify服务详情 ---${NC}"

    for dify_service in dify_api dify_web dify_worker dify_sandbox; do
        local container_name="${CONTAINER_PREFIX}_${dify_service}"
        if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
            echo "✅ $dify_service:"
            echo "   状态: 运行中"
            echo "   镜像: $(docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null)"
            local port_info=$(docker port "$container_name" 2>/dev/null | head -1)
            [ -n "$port_info" ] && echo "   端口: $port_info"
        else
            echo "❌ $dify_service: 未运行"
        fi
    done
}

show_n8n_details() {
    echo -e "${YELLOW}--- n8n服务详情 ---${NC}"

    local container_name="${CONTAINER_PREFIX}_n8n"
    if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        echo "✅ n8n:"
        echo "   状态: 运行中"
        echo "   镜像: $(docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null)"
        echo "   端口: $(docker port "$container_name" 2>/dev/null | head -1)"
        echo "   数据库: PostgreSQL (n8n库)"

        # 检查工作流数量
        local workflow_count=$(docker exec "$container_name" sqlite3 /home/node/.n8n/database.sqlite "SELECT COUNT(*) FROM workflow_entity;" 2>/dev/null || echo "N/A")
        echo "   工作流数量: $workflow_count"
    else
        echo "❌ n8n: 未运行"
    fi
}

show_oneapi_details() {
    echo -e "${YELLOW}--- OneAPI服务详情 ---${NC}"

    local container_name="${CONTAINER_PREFIX}_oneapi"
    if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        echo "✅ OneAPI:"
        echo "   状态: 运行中"
        echo "   镜像: $(docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null)"
        echo "   端口: $(docker port "$container_name" 2>/dev/null | head -1)"
        echo "   数据库: PostgreSQL (oneapi库)"
    else
        echo "❌ OneAPI: 未运行"
    fi
}

show_ragflow_details() {
    echo -e "${YELLOW}--- RAGFlow服务详情 ---${NC}"

    for ragflow_service in ragflow elasticsearch minio; do
        local container_name="${CONTAINER_PREFIX}_${ragflow_service}"
        if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
            echo "✅ $ragflow_service:"
            echo "   状态: 运行中"
            echo "   镜像: $(docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null)"
            local port_info=$(docker port "$container_name" 2>/dev/null | head -1)
            [ -n "$port_info" ] && echo "   端口: $port_info"

            if [ "$ragflow_service" = "ragflow" ]; then
                echo "   数据库: MySQL (ragflow库)"
            fi
        else
            echo "❌ $ragflow_service: 未运行"
        fi
    done
}

show_nginx_details() {
    echo -e "${YELLOW}--- Nginx服务详情 ---${NC}"

    local container_name="${CONTAINER_PREFIX}_nginx"
    if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        echo "✅ Nginx:"
        echo "   状态: 运行中"
        echo "   镜像: $(docker inspect --format='{{.Config.Image}}' "$container_name" 2>/dev/null)"
        echo "   端口: $(docker port "$container_name" 2>/dev/null | head -1)"
        echo "   配置模式: $([ "$USE_DOMAIN" = true ] && echo "域名模式" || echo "IP模式")"

        # 测试配置语法
        if docker exec "$container_name" nginx -t >/dev/null 2>&1; then
            echo "   配置语法: ✅ 正确"
        else
            echo "   配置语法: ❌ 错误"
        fi
    else
        echo "❌ Nginx: 未运行"
    fi
}

# 清理未使用的资源
cleanup_resources() {
    log "清理未使用的Docker资源..."

    # 清理停止的容器
    local stopped_containers=$(docker ps -a -q --filter "status=exited" --filter "name=${CONTAINER_PREFIX}_*")
    if [ -n "$stopped_containers" ]; then
        docker rm $stopped_containers
        success "已清理停止的容器"
    fi

    # 清理未使用的镜像
    docker image prune -f >/dev/null 2>&1
    success "已清理未使用的镜像"

    # 清理未使用的卷
    docker volume prune -f >/dev/null 2>&1
    success "已清理未使用的卷"

    # 清理未使用的网络
    docker network prune -f >/dev/null 2>&1
    success "已清理未使用的网络"

    success "资源清理完成"
}

# 主函数
main() {
    local operation="$1"
    local service="$2"
    local force_flag=false
    local wait_flag=false
    local timeout=300

    # 解析参数
    shift 2
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)
                force_flag=true
                shift
                ;;
            --wait)
                wait_flag=true
                shift
                ;;
            --timeout)
                timeout="$2"
                shift 2
                ;;
            *)
                # 对于scale操作，这可能是副本数
                if [ "$operation" = "scale" ] && [[ "$1" =~ ^[0-9]+$ ]]; then
                    scale_service "$service" "$1"
                    exit $?
                else
                    error "未知参数: $1"
                    show_help
                    exit 1
                fi
                ;;
        esac
    done

    case "$operation" in
        start)
            start_services "$service" "$wait_flag" "$timeout"
            ;;
        stop)
            stop_services "$service" "$force_flag"
            ;;
        restart)
            restart_services "$service" "$wait_flag" "$timeout"
            ;;
        status)
            show_status
            ;;
        health)
            health_check
            ;;
        details)
            show_service_details "$service"
            ;;
        scale)
            error "scale操作需要指定副本数: $0 scale <服务名> <副本数>"
            ;;
        cleanup)
            cleanup_resources
            ;;
        logs)
            exec "$SCRIPT_DIR/scripts/logs.sh" "$service"
            ;;
        *)
            show_help
            exit 1
            ;;
    esac
}

# 运行主函数
main "$@"