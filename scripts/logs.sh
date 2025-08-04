#!/bin/bash

# =========================================================
# 日志查看脚本
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
    echo "日志查看脚本"
    echo ""
    echo "用法: $0 [服务名] [选项]"
    echo ""
    echo "服务名:"
    echo "  mysql         MySQL数据库日志"
    echo "  postgres      PostgreSQL数据库日志"
    echo "  redis         Redis缓存日志"
    echo "  dify_api      Dify API服务日志"
    echo "  dify_web      Dify Web服务日志"
    echo "  dify_worker   Dify Worker服务日志"
    echo "  dify_sandbox  Dify Sandbox服务日志"
    echo "  n8n           n8n工作流服务日志"
    echo "  oneapi        OneAPI服务日志"
    echo "  ragflow       RAGFlow核心服务日志"
    echo "  elasticsearch Elasticsearch搜索引擎日志"
    echo "  minio         MinIO对象存储日志"
    echo "  nginx         Nginx反向代理日志"
    echo "  nginx-access  Nginx访问日志"
    echo "  nginx-error   Nginx错误日志"
    echo "  all           所有服务日志概览 (默认)"
    echo ""
    echo "选项:"
    echo "  -f, --follow  实时跟踪日志"
    echo "  -n, --lines   显示最后N行日志 (默认100)"
    echo "  -t, --tail    等同于--lines"
    echo "  --since       显示指定时间之后的日志 (如: 1h, 30m, 2023-01-01)"
    echo "  --grep        过滤日志内容 (正则表达式)"
    echo "  --level       按日志级别过滤 (ERROR, WARN, INFO, DEBUG)"
    echo "  -h, --help    显示帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                          # 查看所有服务日志概览"
    echo "  $0 dify_api                 # 查看Dify API日志"
    echo "  $0 nginx -f                 # 实时跟踪Nginx日志"
    echo "  $0 mysql -n 50              # 查看MySQL最后50行日志"
    echo "  $0 ragflow --since 1h       # 查看RAGFlow最近1小时日志"
    echo "  $0 elasticsearch --grep error # 查看Elasticsearch错误日志"
    echo "  $0 dify_api --level ERROR   # 查看Dify API错误级别日志"
}

# 查看Docker容器日志
view_docker_logs() {
    local service_name="$1"
    local container_name="${CONTAINER_PREFIX}_${service_name}"
    local follow_flag="$2"
    local lines="$3"
    local since_time="$4"
    local grep_pattern="$5"
    local log_level="$6"

    # 检查容器是否存在
    if ! docker ps -a --format "{{.Names}}" | grep -q "^${container_name}$"; then
        error "容器 ${container_name} 不存在"
        return 1
    fi

    # 检查容器是否运行
    if ! docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        warning "容器 ${container_name} 未运行，显示历史日志"
    fi

    log "查看 ${service_name} 服务日志..."

    # 构建docker logs命令
    local cmd="docker logs"

    if [ "$follow_flag" = true ]; then
        cmd="$cmd -f"
    fi

    if [ -n "$lines" ]; then
        cmd="$cmd --tail $lines"
    fi

    if [ -n "$since_time" ]; then
        cmd="$cmd --since $since_time"
    fi

    cmd="$cmd $container_name"

    # 执行命令并可选择过滤
    if [ -n "$grep_pattern" ] || [ -n "$log_level" ]; then
        local filter_cmd="cat"

        if [ -n "$log_level" ]; then
            case "$log_level" in
                ERROR)
                    filter_cmd="grep -i -E '(error|err|fatal|exception|fail)'"
                    ;;
                WARN)
                    filter_cmd="grep -i -E '(warn|warning)'"
                    ;;
                INFO)
                    filter_cmd="grep -i -E '(info|information)'"
                    ;;
                DEBUG)
                    filter_cmd="grep -i -E '(debug|trace)'"
                    ;;
            esac
        fi

        if [ -n "$grep_pattern" ]; then
            if [ "$filter_cmd" != "cat" ]; then
                filter_cmd="$filter_cmd | grep -i -E '$grep_pattern'"
            else
                filter_cmd="grep -i -E '$grep_pattern'"
            fi
        fi

        eval "$cmd 2>&1 | $filter_cmd"
    else
        eval "$cmd 2>&1"
    fi
}

# 查看Nginx访问日志
view_nginx_access_logs() {
    local follow_flag="$1"
    local lines="$2"
    local since_time="$3"
    local grep_pattern="$4"

    local log_file="$INSTALL_PATH/logs/access.log"

    if [ ! -f "$log_file" ]; then
        warning "Nginx访问日志文件不存在: $log_file"
        return 1
    fi

    log "查看Nginx访问日志..."

    local cmd=""
    if [ "$follow_flag" = true ]; then
        cmd="tail -f"
    else
        if [ -n "$lines" ]; then
            cmd="tail -n $lines"
        else
            cmd="tail -n 100"
        fi
    fi

    # 处理时间过滤（简化版本）
    if [ -n "$since_time" ] && [ "$follow_flag" != true ]; then
        warning "文件日志暂不支持时间过滤，显示最新日志"
    fi

    # 执行命令并可选择过滤
    if [ -n "$grep_pattern" ]; then
        eval "$cmd '$log_file' | grep -i -E '$grep_pattern'"
    else
        eval "$cmd '$log_file'"
    fi
}

# 查看Nginx错误日志
view_nginx_error_logs() {
    local follow_flag="$1"
    local lines="$2"
    local since_time="$3"
    local grep_pattern="$4"

    local log_file="$INSTALL_PATH/logs/error.log"

    if [ ! -f "$log_file" ]; then
        warning "Nginx错误日志文件不存在: $log_file"
        return 1
    fi

    log "查看Nginx错误日志..."

    local cmd=""
    if [ "$follow_flag" = true ]; then
        cmd="tail -f"
    else
        if [ -n "$lines" ]; then
            cmd="tail -n $lines"
        else
            cmd="tail -n 100"
        fi
    fi

    # 处理时间过滤（简化版本）
    if [ -n "$since_time" ] && [ "$follow_flag" != true ]; then
        warning "文件日志暂不支持时间过滤，显示最新日志"
    fi

    # 执行命令并可选择过滤
    if [ -n "$grep_pattern" ]; then
        eval "$cmd '$log_file' | grep -i -E '$grep_pattern'"
    else
        eval "$cmd '$log_file'"
    fi
}

# 查看所有服务日志概览
view_all_logs_summary() {
    echo -e "${BLUE}=== 服务运行状态 ===${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.CreatedAt}}" | grep -E "(NAMES|${CONTAINER_PREFIX})"

    echo -e "\n${BLUE}=== 服务健康检查 ===${NC}"

    # 基础服务检查
    for service in mysql postgres redis; do
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

    # 应用服务检查
    for service in dify_api dify_web n8n oneapi ragflow elasticsearch minio nginx; do
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

    echo -e "\n${BLUE}=== 最近错误日志摘要 ===${NC}"

    # 检查各服务的错误日志
    for service in mysql postgres redis dify_api dify_web n8n oneapi ragflow elasticsearch minio nginx; do
        local container_name="${CONTAINER_PREFIX}_${service}"
        if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
            local error_logs=$(docker logs --tail 50 "$container_name" 2>&1 | grep -i -E "(error|err|fatal|exception|fail)" | head -3)
            if [ -n "$error_logs" ]; then
                echo -e "\n${YELLOW}--- $service 最近错误 ---${NC}"
                echo "$error_logs"
            fi
        fi
    done

    echo -e "\n${BLUE}=== 资源使用情况 ===${NC}"
    docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" | grep -E "(CONTAINER|${CONTAINER_PREFIX})"

    echo -e "\n${BLUE}=== 磁盘使用情况 ===${NC}"
    echo "安装目录: $(du -sh "$INSTALL_PATH" 2>/dev/null | cut -f1)"
    echo "日志目录: $(du -sh "$INSTALL_PATH/logs" 2>/dev/null | cut -f1)"
    echo "数据目录: $(du -sh "$INSTALL_PATH/volumes" 2>/dev/null | cut -f1)"
    echo "备份目录: $(du -sh "$INSTALL_PATH/backup" 2>/dev/null | cut -f1)"
}

# 查看特定服务的详细日志分析
analyze_service_logs() {
    local service_name="$1"
    local container_name="${CONTAINER_PREFIX}_${service_name}"

    if ! docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        error "服务 $service_name 未运行"
        return 1
    fi

    echo -e "${BLUE}=== $service_name 详细日志分析 ===${NC}"

    # 获取容器信息
    echo "容器信息:"
    docker inspect --format='创建时间: {{.Created}}' "$container_name"
    docker inspect --format='启动时间: {{.State.StartedAt}}' "$container_name"
    docker inspect --format='运行状态: {{.State.Status}}' "$container_name"

    # 统计日志级别
    echo -e "\n日志级别统计:"
    local total_logs=$(docker logs --tail 1000 "$container_name" 2>&1 | wc -l)
    local error_logs=$(docker logs --tail 1000 "$container_name" 2>&1 | grep -i -c -E "(error|err|fatal|exception)" || echo "0")
    local warn_logs=$(docker logs --tail 1000 "$container_name" 2>&1 | grep -i -c -E "(warn|warning)" || echo "0")
    local info_logs=$(docker logs --tail 1000 "$container_name" 2>&1 | grep -i -c -E "(info|information)" || echo "0")

    echo "总日志数: $total_logs"
    echo "错误日志: $error_logs"
    echo "警告日志: $warn_logs"
    echo "信息日志: $info_logs"

    # 最近错误
    echo -e "\n最近错误 (最多10条):"
    docker logs --tail 500 "$container_name" 2>&1 | grep -i -E "(error|err|fatal|exception|fail)" | head -10

    # 最近警告
    echo -e "\n最近警告 (最多5条):"
    docker logs --tail 500 "$container_name" 2>&1 | grep -i -E "(warn|warning)" | head -5
}

# 导出日志
export_logs() {
    local service_name="$1"
    local output_file="$2"
    local lines="$3"
    local since_time="$4"

    local container_name="${CONTAINER_PREFIX}_${service_name}"

    if [ -z "$output_file" ]; then
        output_file="$INSTALL_PATH/logs/${service_name}_export_$(date +%Y%m%d_%H%M%S).log"
    fi

    log "导出 $service_name 日志到 $output_file"

    local cmd="docker logs"

    if [ -n "$lines" ]; then
        cmd="$cmd --tail $lines"
    fi

    if [ -n "$since_time" ]; then
        cmd="$cmd --since $since_time"
    fi

    cmd="$cmd $container_name"

    eval "$cmd" > "$output_file" 2>&1

    if [ $? -eq 0 ]; then
        success "日志已导出到: $output_file"
        echo "文件大小: $(du -sh "$output_file" | cut -f1)"
    else
        error "日志导出失败"
    fi
}

# 主函数
main() {
    local service=""
    local follow_flag=false
    local lines=""
    local since_time=""
    local grep_pattern=""
    local log_level=""
    local analyze_flag=false
    local export_flag=false
    local output_file=""

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--follow)
                follow_flag=true
                shift
                ;;
            -n|--lines|-t|--tail)
                lines="$2"
                shift 2
                ;;
            --since)
                since_time="$2"
                shift 2
                ;;
            --grep)
                grep_pattern="$2"
                shift 2
                ;;
            --level)
                log_level="$2"
                shift 2
                ;;
            --analyze)
                analyze_flag=true
                shift
                ;;
            --export)
                export_flag=true
                if [[ $2 != -* ]] && [[ $2 != "" ]]; then
                    output_file="$2"
                    shift
                fi
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
                if [ -z "$service" ]; then
                    service="$1"
                fi
                shift
                ;;
        esac
    done

    # 默认服务为all
    if [ -z "$service" ]; then
        service="all"
    fi

    # 如果是导出模式
    if [ "$export_flag" = true ]; then
        if [ "$service" = "all" ]; then
            error "导出模式不支持all，请指定具体服务"
            exit 1
        fi
        export_logs "$service" "$output_file" "$lines" "$since_time"
        exit 0
    fi

    # 如果是分析模式
    if [ "$analyze_flag" = true ]; then
        if [ "$service" = "all" ]; then
            error "分析模式不支持all，请指定具体服务"
            exit 1
        fi
        analyze_service_logs "$service"
        exit 0
    fi

    case "$service" in
        all)
            if [ "$follow_flag" = true ]; then
                warning "无法实时跟踪所有服务日志，显示概览信息"
            fi
            view_all_logs_summary
            ;;
        mysql|postgres|redis|dify_api|dify_web|dify_worker|dify_sandbox|n8n|oneapi|ragflow|elasticsearch|minio|nginx)
            view_docker_logs "$service" "$follow_flag" "$lines" "$since_time" "$grep_pattern" "$log_level"
            ;;
        nginx-access)
            view_nginx_access_logs "$follow_flag" "$lines" "$since_time" "$grep_pattern"
            ;;
        nginx-error)
            view_nginx_error_logs "$follow_flag" "$lines" "$since_time" "$grep_pattern"
            ;;
        *)
            error "未知的服务名: $service"
            echo ""
            echo "可用的服务名:"
            echo "  mysql, postgres, redis"
            echo "  dify_api, dify_web, dify_worker, dify_sandbox"
            echo "  n8n, oneapi"
            echo "  ragflow, elasticsearch, minio"
            echo "  nginx, nginx-access, nginx-error"
            echo "  all (所有服务概览)"
            exit 1
            ;;
    esac
}

# 运行主函数
main "$@"