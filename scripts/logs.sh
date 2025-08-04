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
    echo "  nginx         Nginx反向代理日志"
    echo "  all           所有服务日志 (默认)"
    echo ""
    echo "选项:"
    echo "  -f, --follow  实时跟踪日志"
    echo "  -n, --lines   显示最后N行日志 (默认100)"
    echo "  -h, --help    显示帮助信息"
    echo ""
    echo "示例:"
    echo "  $0                    # 查看所有服务日志"
    echo "  $0 dify_api           # 查看Dify API日志"
    echo "  $0 nginx -f           # 实时跟踪Nginx日志"
    echo "  $0 mysql -n 50        # 查看MySQL最后50行日志"
}

# 查看Docker容器日志
view_docker_logs() {
    local service_name="$1"
    local container_name="${CONTAINER_PREFIX}_${service_name}"
    local follow_flag="$2"
    local lines="$3"

    # 检查容器是否存在
    if ! docker ps -a --format "{{.Names}}" | grep -q "^${container_name}$"; then
        error "容器 ${container_name} 不存在"
        return 1
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
    cmd="$cmd $container_name"

    # 执行命令
    eval $cmd
}

# 查看Nginx访问日志
view_nginx_access_logs() {
    local follow_flag="$1"
    local lines="$2"

    local log_file="$INSTALL_PATH/logs/access.log"

    if [ ! -f "$log_file" ]; then
        warning "Nginx访问日志文件不存在: $log_file"
        return 1
    fi

    log "查看Nginx访问日志..."

    if [ "$follow_flag" = true ]; then
        tail -f "$log_file"
    else
        if [ -n "$lines" ]; then
            tail -n "$lines" "$log_file"
        else
            tail -n 100 "$log_file"
        fi
    fi
}

# 查看Nginx错误日志
view_nginx_error_logs() {
    local follow_flag="$1"
    local lines="$2"

    local log_file="$INSTALL_PATH/logs/error.log"

    if [ ! -f "$log_file" ]; then
        warning "Nginx错误日志文件不存在: $log_file"
        return 1
    fi

    log "查看Nginx错误日志..."

    if [ "$follow_flag" = true ]; then
        tail -f "$log_file"
    else
        if [ -n "$lines" ]; then
            tail -n "$lines" "$log_file"
        else
            tail -n 100 "$log_file"
        fi
    fi
}

# 查看所有服务日志概览
view_all_logs_summary() {
    echo -e "${BLUE}=== 服务运行状态 ===${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "(NAMES|${CONTAINER_PREFIX})"

    echo -e "\n${BLUE}=== 最近日志摘要 ===${NC}"

    # 检查各服务的最后几行日志
    for service in mysql postgres redis dify_api dify_web n8n oneapi nginx; do
        local container_name="${CONTAINER_PREFIX}_${service}"
        if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
            echo -e "\n${YELLOW}--- $service 服务最后5行日志 ---${NC}"
            docker logs --tail 5 "$container_name" 2>&1 | head -5
        fi
    done
}

# 主函数
main() {
    local service=""
    local follow_flag=false
    local lines=""

    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--follow)
                follow_flag=true
                shift
                ;;
            -n|--lines)
                lines="$2"
                shift 2
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

    case "$service" in
        all)
            if [ "$follow_flag" = true ]; then
                warning "无法实时跟踪所有服务日志，显示概览信息"
            fi
            view_all_logs_summary
            ;;
        mysql|postgres|redis|dify_api|dify_web|dify_worker|dify_sandbox|n8n|oneapi)
            view_docker_logs "$service" "$follow_flag" "$lines"
            ;;
        nginx)
            view_docker_logs "nginx" "$follow_flag" "$lines"
            ;;
        nginx-access)
            view_nginx_access_logs "$follow_flag" "$lines"
            ;;
        nginx-error)
            view_nginx_error_logs "$follow_flag" "$lines"
            ;;
        *)
            error "未知的服务名: $service"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# 运行主函数
main "$@"