#!/bin/bash

# =========================================================
# 工具函数模块
# =========================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查Docker环境
check_docker() {
    if ! command -v docker &> /dev/null; then
        error "Docker未安装，请先安装Docker"
        exit 1
    fi

    if ! command -v docker-compose &> /dev/null; then
        error "Docker Compose未安装，请先安装Docker Compose"
        exit 1
    fi

    success "Docker环境检查通过"
}

# 检查系统环境
check_environment() {
    log "检查系统环境..."

    # 检查操作系统
    if [[ "$OSTYPE" != "linux-gnu"* ]]; then
        warning "此脚本主要为Linux系统设计，其他系统可能需要调整"
    fi

    # 检查磁盘空间（至少需要5GB）
    local available_space=$(df "$INSTALL_PATH" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    if [ "$available_space" -lt 5242880 ]; then
        warning "磁盘剩余空间可能不足，建议至少保持5GB可用空间"
    fi

    # 检查内存（建议至少4GB）
    local total_mem=$(free -m | awk 'NR==2{print $2}')
    if [ "$total_mem" -lt 4096 ]; then
        warning "系统内存较少(${total_mem}MB)，建议至少4GB内存以获得最佳性能"
    fi

    success "系统环境检查完成"
}

# 检查端口占用
check_ports() {
    log "检查端口占用情况..."

    local ports_to_check=()
    if [ "$USE_DOMAIN" = true ]; then
        ports_to_check=($MYSQL_PORT $POSTGRES_PORT $REDIS_PORT $NGINX_PORT $DIFY_API_PORT)
    else
        ports_to_check=($N8N_WEB_PORT $DIFY_WEB_PORT $ONEAPI_WEB_PORT $MYSQL_PORT $POSTGRES_PORT $REDIS_PORT $DIFY_API_PORT)
    fi

    local occupied_ports=()
    for port in "${ports_to_check[@]}"; do
        if netstat -ln 2>/dev/null | grep ":$port " > /dev/null 2>&1; then
            occupied_ports+=($port)
        fi
    done

    if [ ${#occupied_ports[@]} -gt 0 ]; then
        error "以下端口已被占用: ${occupied_ports[*]}"
        error "请停止占用这些端口的服务，或修改配置中的端口设置"
        exit 1
    fi

    success "端口检查通过"
}

# 清理现有环境
cleanup_environment() {
    log "开始清理现有环境..."

    # 停止并删除所有相关容器
    local containers=$(docker ps -a --format "table {{.Names}}" | grep -E "^${CONTAINER_PREFIX}" | tail -n +2 2>/dev/null || true)
    if [ ! -z "$containers" ]; then
        log "停止并删除现有容器..."
        echo "$containers" | while read container; do
            if [ ! -z "$container" ]; then
                docker stop "$container" 2>/dev/null || true
                docker rm "$container" 2>/dev/null || true
                log "已删除容器: $container"
            fi
        done
    fi

    # 删除相关网络
    local networks=$(docker network ls --format "{{.Name}}" | grep -E "^${CONTAINER_PREFIX}" 2>/dev/null || true)
    if [ ! -z "$networks" ]; then
        log "删除现有网络..."
        echo "$networks" | while read network; do
            if [ ! -z "$network" ]; then
                docker network rm "$network" 2>/dev/null || true
                log "已删除网络: $network"
            fi
        done
    fi

    # 清理数据目录（保留备份）
    if [ -d "$INSTALL_PATH" ]; then
        log "备份现有数据目录..."
        local backup_dir="${INSTALL_PATH}_backup_$(date +%Y%m%d_%H%M%S)"
        mv "$INSTALL_PATH" "$backup_dir" 2>/dev/null || true
        warning "原数据已备份至: $backup_dir"
    fi

    success "环境清理完成"
}

# 创建目录结构
create_directories() {
    log "创建目录结构..."

    # 创建基础目录
    mkdir -p "$INSTALL_PATH"/{mysql,postgres,redis,n8n,dify,oneapi,nginx}

    # 创建数据目录
    mkdir -p "$INSTALL_PATH"/volumes/mysql/{data,logs,conf}
    mkdir -p "$INSTALL_PATH"/volumes/postgres/{data,logs}
    mkdir -p "$INSTALL_PATH"/volumes/redis/{data,logs}
    mkdir -p "$INSTALL_PATH"/volumes/n8n/{data,logs}
    mkdir -p "$INSTALL_PATH"/volumes/dify/{api,web,worker,sandbox,storage}
    mkdir -p "$INSTALL_PATH"/volumes/oneapi/{data,logs}
    mkdir -p "$INSTALL_PATH"/volumes/nginx/{logs,conf}

    # 创建配置和日志目录
    mkdir -p "$INSTALL_PATH"/{logs,config,backup,scripts,modules,templates}

    # 创建dify相关目录
    mkdir -p "$INSTALL_PATH"/volumes/app/storage
    mkdir -p "$INSTALL_PATH"/volumes/db/data
    mkdir -p "$INSTALL_PATH"/volumes/redis/data
    mkdir -p "$INSTALL_PATH"/volumes/weaviate
    mkdir -p "$INSTALL_PATH"/volumes/sandbox/dependencies
    mkdir -p "$INSTALL_PATH"/volumes/plugin_daemon
    mkdir -p "$INSTALL_PATH"/volumes/certbot/{conf,www,logs}

    # 设置权限
    chown -R 1000:1000 "$INSTALL_PATH"/volumes/n8n/data 2>/dev/null || true
    chmod -R 755 "$INSTALL_PATH"/volumes

    success "目录结构创建完成"
}

# 检查服务健康状态
check_service_health() {
    local service_name="$1"
    local health_cmd="$2"

    if docker exec "${CONTAINER_PREFIX}_${service_name}" $health_cmd >/dev/null 2>&1; then
        echo "✅ $service_name: 运行正常"
        return 0
    else
        echo "❌ $service_name: 运行异常"
        return 1
    fi
}

# 等待服务启动
wait_for_service() {
    local service_name="$1"
    local health_cmd="$2"
    local timeout="${3:-60}"
    local interval="${4:-5}"

    log "等待服务 $service_name 启动..."

    local count=0
    local max_count=$((timeout / interval))

    while [ $count -lt $max_count ]; do
        if docker exec "${CONTAINER_PREFIX}_${service_name}" $health_cmd >/dev/null 2>&1; then
            success "服务 $service_name 已就绪"
            return 0
        fi

        sleep $interval
        count=$((count + 1))
        echo -n "."
    done

    echo ""
    error "服务 $service_name 启动超时"
    return 1
}

# 生成随机密码
generate_random_password() {
    local length="${1:-16}"
    openssl rand -base64 $length | tr -d "=+/" | cut -c1-$length 2>/dev/null || \
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $length | head -n 1
}

# 确保目录存在
ensure_directory() {
    local dir_path="$1"
    local owner="${2:-}"
    local permissions="${3:-755}"

    if [ ! -d "$dir_path" ]; then
        mkdir -p "$dir_path"
    fi

    if [ -n "$owner" ]; then
        chown -R "$owner" "$dir_path" 2>/dev/null || true
    fi

    chmod "$permissions" "$dir_path" 2>/dev/null || true
}

# 备份文件
backup_file() {
    local file_path="$1"
    local backup_suffix="${2:-$(date +%Y%m%d_%H%M%S)}"

    if [ -f "$file_path" ]; then
        cp "$file_path" "${file_path}.backup_${backup_suffix}"
        log "已备份文件: $file_path -> ${file_path}.backup_${backup_suffix}"
    fi
}

# 替换配置文件中的变量
replace_config_vars() {
    local template_file="$1"
    local target_file="$2"

    if [ ! -f "$template_file" ]; then
        error "模板文件不存在: $template_file"
        return 1
    fi

    # 创建目标目录
    mkdir -p "$(dirname "$target_file")"

    # 替换变量
    sed -e "s|\${DIFY_DOMAIN}|${DIFY_DOMAIN}|g" \
        -e "s|\${N8N_DOMAIN}|${N8N_DOMAIN}|g" \
        -e "s|\${ONEAPI_DOMAIN}|${ONEAPI_DOMAIN}|g" \
        -e "s|\${SERVER_IP}|${SERVER_IP}|g" \
        -e "s|\${NGINX_PORT}|${NGINX_PORT}|g" \
        -e "s|\${DIFY_WEB_PORT}|${DIFY_WEB_PORT}|g" \
        -e "s|\${N8N_WEB_PORT}|${N8N_WEB_PORT}|g" \
        -e "s|\${ONEAPI_WEB_PORT}|${ONEAPI_WEB_PORT}|g" \
        -e "s|\${MYSQL_PORT}|${MYSQL_PORT}|g" \
        -e "s|\${POSTGRES_PORT}|${POSTGRES_PORT}|g" \
        -e "s|\${REDIS_PORT}|${REDIS_PORT}|g" \
        -e "s|\${DIFY_API_PORT}|${DIFY_API_PORT}|g" \
        -e "s|\${DB_PASSWORD}|${DB_PASSWORD}|g" \
        -e "s|\${REDIS_PASSWORD}|${REDIS_PASSWORD}|g" \
        -e "s|\${CONTAINER_PREFIX}|${CONTAINER_PREFIX}|g" \
        -e "s|\${DIFY_URL}|${DIFY_URL}|g" \
        -e "s|\${N8N_URL}|${N8N_URL}|g" \
        -e "s|\${ONEAPI_URL}|${ONEAPI_URL}|g" \
        "$template_file" > "$target_file"

    success "配置文件已生成: $target_file"
}