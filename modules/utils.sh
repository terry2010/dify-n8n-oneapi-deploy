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

    # 检查Docker服务是否运行
    if ! docker info &> /dev/null; then
        error "Docker服务未运行，请启动Docker服务"
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

    # 检查磁盘空间（RAGFlow需要更多空间，至少需要20GB）
    local available_space=$(df "$INSTALL_PATH" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    if [ "$available_space" -lt 20971520 ]; then
        warning "磁盘剩余空间可能不足，RAGFlow建议至少保持20GB可用空间"
    fi

    # 检查内存（RAGFlow建议至少8GB）
    local total_mem=$(free -m | awk 'NR==2{print $2}')
    if [ "$total_mem" -lt 8192 ]; then
        warning "系统内存较少(${total_mem}MB)，RAGFlow建议至少8GB内存以获得最佳性能"
    fi

    # 检查CPU核心数
    local cpu_cores=$(nproc)
    if [ "$cpu_cores" -lt 4 ]; then
        warning "CPU核心较少(${cpu_cores}核)，建议至少4核心以获得最佳性能"
    fi

    # 检查系统负载
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    if [ -n "$load_avg" ]; then
        local load_int=$(echo "$load_avg" | cut -d'.' -f1)
        if [ "$load_int" -gt "$cpu_cores" ]; then
            warning "系统负载较高($load_avg)，可能影响安装过程"
        fi
    fi

    success "系统环境检查完成"
}

# 检查端口占用
check_ports() {
    log "检查端口占用情况..."

    local ports_to_check=()
    if [ "$USE_DOMAIN" = true ]; then
        ports_to_check=($MYSQL_PORT $POSTGRES_PORT $REDIS_PORT $NGINX_PORT $DIFY_API_PORT $RAGFLOW_API_PORT $ELASTICSEARCH_PORT $MINIO_API_PORT $MINIO_CONSOLE_PORT)
    else
        ports_to_check=($N8N_WEB_PORT $DIFY_WEB_PORT $ONEAPI_WEB_PORT $RAGFLOW_WEB_PORT $MYSQL_PORT $POSTGRES_PORT $REDIS_PORT $DIFY_API_PORT $RAGFLOW_API_PORT $ELASTICSEARCH_PORT $MINIO_API_PORT $MINIO_CONSOLE_PORT)
    fi

    local occupied_ports=()
    for port in "${ports_to_check[@]}"; do
        if netstat -ln 2>/dev/null | grep ":$port " > /dev/null 2>&1 || \
           ss -ln 2>/dev/null | grep ":$port " > /dev/null 2>&1; then
            occupied_ports+=($port)
        fi
    done

    if [ ${#occupied_ports[@]} -gt 0 ]; then
        error "以下端口已被占用: ${occupied_ports[*]}"
        error "请停止占用这些端口的服务，或修改配置中的端口设置"

        # 显示占用端口的进程信息
        echo -e "\n${YELLOW}端口占用详情:${NC}"
        for port in "${occupied_ports[@]}"; do
            local process_info=$(netstat -tlnp 2>/dev/null | grep ":$port " | awk '{print $7}' || \
                               ss -tlnp 2>/dev/null | grep ":$port " | awk '{print $6}')
            if [ -n "$process_info" ]; then
                echo "端口 $port: $process_info"
            else
                echo "端口 $port: 未知进程"
            fi
        done

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

    # 清理未使用的Docker资源
    log "清理未使用的Docker资源..."
    docker system prune -f 2>/dev/null || true
    docker volume prune -f 2>/dev/null || true

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
    mkdir -p "$INSTALL_PATH"/{mysql,postgres,redis,n8n,dify,oneapi,ragflow,nginx}

    # 创建数据目录
    mkdir -p "$INSTALL_PATH"/volumes/mysql/{data,logs,conf}
    mkdir -p "$INSTALL_PATH"/volumes/postgres/{data,logs}
    mkdir -p "$INSTALL_PATH"/volumes/redis/{data,logs}
    mkdir -p "$INSTALL_PATH"/volumes/n8n/{data,logs}
    mkdir -p "$INSTALL_PATH"/volumes/dify/{api,web,worker,sandbox,storage}
    mkdir -p "$INSTALL_PATH"/volumes/oneapi/{data,logs}
    mkdir -p "$INSTALL_PATH"/volumes/nginx/{logs,conf}

    # 创建RAGFlow相关目录
    mkdir -p "$INSTALL_PATH"/volumes/ragflow/{elasticsearch,minio,ragflow,nltk_data,huggingface}
    mkdir -p "$INSTALL_PATH"/volumes/ragflow/elasticsearch/{data,backup}
    mkdir -p "$INSTALL_PATH"/volumes/ragflow/minio/{data,.minio}

    # 创建配置和日志目录
    mkdir -p "$INSTALL_PATH"/{logs,config,backup,scripts,modules,templates}

    # 创建应用特定日志目录
    mkdir -p "$INSTALL_PATH"/logs/{mysql,postgres,redis,dify,n8n,oneapi,ragflow,nginx}

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
    chown -R 1000:1000 "$INSTALL_PATH"/volumes/ragflow/elasticsearch 2>/dev/null || true
    chown -R 1001:1001 "$INSTALL_PATH"/volumes/ragflow/minio 2>/dev/null || true
    chmod -R 755 "$INSTALL_PATH"/volumes

    success "目录结构创建完成"
}

# 检查服务健康状态
check_service_health() {
    local service_name="$1"
    local health_cmd="$2"
    local container_name="${CONTAINER_PREFIX}_${service_name}"

    if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
        if docker exec "${container_name}" $health_cmd >/dev/null 2>&1; then
            echo "✅ $service_name: 运行正常"
            return 0
        else
            echo "❌ $service_name: 运行异常"
            return 1
        fi
    else
        echo "❌ $service_name: 未运行"
        return 1
    fi
}

# 等待服务启动
wait_for_service() {
    local service_name="$1"
    local health_cmd="$2"
    local timeout="${5:-60}"
    local interval="${4:-5}"
    local container_name="${CONTAINER_PREFIX}_${service_name}"
    
    # 为MySQL服务设置更长的超时时间
    if [ "$service_name" = "mysql" ]; then
        timeout=180
        log "MySQL服务可能需要更长时间初始化，设置超时时间为${timeout}秒"
    fi

    log "等待服务 $service_name 启动..."

    local count=0
    local max_count=$((timeout / interval))

    while [ $count -lt $max_count ]; do
        # 首先检查容器是否运行
        if ! docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
            echo -n "."
            sleep $interval
            count=$((count + 1))
            continue
        fi

        # 检查健康状态
        if docker exec "${container_name}" $health_cmd >/dev/null 2>&1; then
            echo ""
            success "服务 $service_name 已就绪"
            return 0
        fi

        sleep $interval
        count=$((count + 1))
        echo -n "."
    done

    echo ""
    error "服务 $service_name 启动超时"

    # 输出容器日志以便调试
    log "容器 $service_name 的最近日志:"
    docker logs --tail=20 "${container_name}" 2>&1 | head -10

    return 1
}

# 等待端口可用
wait_for_port() {
    local host="$1"
    local port="$2"
    local timeout="${3:-60}"
    local interval="${4:-2}"

    log "等待端口 $host:$port 可用..."

    local count=0
    local max_count=$((timeout / interval))

    while [ $count -lt $max_count ]; do
        if nc -z "$host" "$port" 2>/dev/null || \
           timeout 1 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
            success "端口 $host:$port 已可用"
            return 0
        fi

        sleep $interval
        count=$((count + 1))
        echo -n "."
    done

    echo ""
    error "端口 $host:$port 等待超时"
    return 1
}

# 生成随机密码
generate_random_password() {
    local length="${1:-16}"
    openssl rand -base64 $length 2>/dev/null | tr -d "=+/" | cut -c1-$length || \
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $length | head -n 1
}

# 生成随机字符串
generate_random_string() {
    local length="${1:-32}"
    local chars="${2:-a-zA-Z0-9}"
    cat /dev/urandom | tr -dc "$chars" | fold -w $length | head -n 1
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
        -e "s|\${RAGFLOW_DOMAIN}|${RAGFLOW_DOMAIN}|g" \
        -e "s|\${SERVER_IP}|${SERVER_IP}|g" \
        -e "s|\${NGINX_PORT}|${NGINX_PORT}|g" \
        -e "s|\${DIFY_WEB_PORT}|${DIFY_WEB_PORT}|g" \
        -e "s|\${N8N_WEB_PORT}|${N8N_WEB_PORT}|g" \
        -e "s|\${ONEAPI_WEB_PORT}|${ONEAPI_WEB_PORT}|g" \
        -e "s|\${RAGFLOW_WEB_PORT}|${RAGFLOW_WEB_PORT}|g" \
        -e "s|\${MYSQL_PORT}|${MYSQL_PORT}|g" \
        -e "s|\${POSTGRES_PORT}|${POSTGRES_PORT}|g" \
        -e "s|\${REDIS_PORT}|${REDIS_PORT}|g" \
        -e "s|\${DIFY_API_PORT}|${DIFY_API_PORT}|g" \
        -e "s|\${RAGFLOW_API_PORT}|${RAGFLOW_API_PORT}|g" \
        -e "s|\${ELASTICSEARCH_PORT}|${ELASTICSEARCH_PORT}|g" \
        -e "s|\${MINIO_API_PORT}|${MINIO_API_PORT}|g" \
        -e "s|\${MINIO_CONSOLE_PORT}|${MINIO_CONSOLE_PORT}|g" \
        -e "s|\${DB_PASSWORD}|${DB_PASSWORD}|g" \
        -e "s|\${REDIS_PASSWORD}|${REDIS_PASSWORD}|g" \
        -e "s|\${RAGFLOW_SECRET_KEY}|${RAGFLOW_SECRET_KEY}|g" \
        -e "s|\${MINIO_ACCESS_KEY}|${MINIO_ACCESS_KEY}|g" \
        -e "s|\${MINIO_SECRET_KEY}|${MINIO_SECRET_KEY}|g" \
        -e "s|\${CONTAINER_PREFIX}|${CONTAINER_PREFIX}|g" \
        -e "s|\${DIFY_URL}|${DIFY_URL}|g" \
        -e "s|\${N8N_URL}|${N8N_URL}|g" \
        -e "s|\${ONEAPI_URL}|${ONEAPI_URL}|g" \
        -e "s|\${RAGFLOW_URL}|${RAGFLOW_URL}|g" \
        "$template_file" > "$target_file"

    success "配置文件已生成: $target_file"
}

# 检查网络连接
check_network_connectivity() {
    log "检查网络连接..."

    local test_hosts=("8.8.8.8" "baidu.com" "github.com")
    local connected=false

    for host in "${test_hosts[@]}"; do
        if ping -c 1 -W 3 "$host" >/dev/null 2>&1; then
            connected=true
            break
        fi
    done

    if [ "$connected" = true ]; then
        success "网络连接正常"
        return 0
    else
        warning "网络连接可能存在问题"
        return 1
    fi
}

# 检查Docker镜像
check_docker_images() {
    log "检查Docker镜像..."

    local required_images=(
        "mysql:8.0"
        "postgres:15-alpine"
        "redis:7-alpine"
        "langgenius/dify-api:1.7.1"
        "langgenius/dify-web:1.7.1"
        "langgenius/dify-sandbox:0.2.12"
        "n8nio/n8n:latest"
        "justsong/one-api:latest"
        "infiniflow/ragflow:v0.7.0"
        "docker.elastic.co/elasticsearch/elasticsearch:8.11.0"
        "quay.io/minio/minio:RELEASE.2023-12-20T01-00-02Z"
        "nginx:latest"
    )

    local missing_images=()

    for image in "${required_images[@]}"; do
        if ! docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${image}$" 2>/dev/null; then
            missing_images+=("$image")
        fi
    done

    if [ ${#missing_images[@]} -gt 0 ]; then
        warning "以下Docker镜像尚未下载，安装过程中将自动下载："
        for image in "${missing_images[@]}"; do
            echo "  - $image"
        done
    else
        success "所有Docker镜像已就绪"
    fi
}

# 下载Docker镜像
pull_docker_images() {
    log "预先下载Docker镜像..."

    local images=(
        "mysql:8.0"
        "postgres:15-alpine"
        "redis:7-alpine"
        "langgenius/dify-api:1.7.1"
        "langgenius/dify-web:1.7.1"
        "langgenius/dify-sandbox:0.2.12"
        "n8nio/n8n:latest"
        "justsong/one-api:latest"
        "infiniflow/ragflow:v0.7.0"
        "docker.elastic.co/elasticsearch/elasticsearch:8.11.0"
        "quay.io/minio/minio:RELEASE.2023-12-20T01-00-02Z"
        "nginx:latest"
    )

    local success_count=0
    local total_count=${#images[@]}

    for image in "${images[@]}"; do
        log "下载镜像: $image"
        if docker pull "$image" >/dev/null 2>&1; then
            success "镜像下载完成: $image"
            ((success_count++))
        else
            warning "镜像下载失败: $image"
        fi
    done

    success "镜像下载完成: ${success_count}/${total_count}"
}

# 检查系统资源使用情况
check_system_resources() {
    log "检查系统资源使用情况..."

    # 检查CPU使用率
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' | awk -F'%' '{print $1}' 2>/dev/null)
    if [ -n "$cpu_usage" ]; then
        local cpu_int=$(echo "$cpu_usage" | cut -d'.' -f1)
        if [ "$cpu_int" -gt 80 ]; then
            warning "CPU使用率较高: ${cpu_usage}%"
        else
            log "CPU使用率: ${cpu_usage}%"
        fi
    fi

    # 检查内存使用率
    local mem_info=$(free -m | awk 'NR==2{printf "%.1f", $3*100/$2}')
    if [ -n "$mem_info" ]; then
        local mem_int=$(echo "$mem_info" | cut -d'.' -f1)
        if [ "$mem_int" -gt 80 ]; then
            warning "内存使用率较高: ${mem_info}%"
        else
            log "内存使用率: ${mem_info}%"
        fi
    fi

    # 检查磁盘使用率
    local disk_usage=$(df "$INSTALL_PATH" 2>/dev/null | awk 'NR==2{print $5}' | sed 's/%//')
    if [ -n "$disk_usage" ] && [ "$disk_usage" -gt 80 ]; then
        warning "磁盘使用率较高: ${disk_usage}%"
    else
        log "磁盘使用率: ${disk_usage}%"
    fi

    success "系统资源检查完成"
}

# 格式化文件大小
format_size() {
    local size=$1
    if [ $size -gt 1073741824 ]; then
        echo "$(($size / 1073741824))GB"
    elif [ $size -gt 1048576 ]; then
        echo "$(($size / 1048576))MB"
    elif [ $size -gt 1024 ]; then
        echo "$(($size / 1024))KB"
    else
        echo "${size}B"
    fi
}

# 显示安装进度
show_progress() {
    local current=$1
    local total=$2
    local description="${3:-安装进度}"

    local percentage=$((current * 100 / total))
    local filled=$((percentage / 2))
    local empty=$((50 - filled))

    printf "\r%s: [" "$description"
    printf "%*s" $filled | tr ' ' '='
    printf "%*s" $empty | tr ' ' '-'
    printf "] %d%% (%d/%d)" $percentage $current $total
}

# 完成进度显示
finish_progress() {
    echo ""
}

# 检查必要命令是否存在
check_required_commands() {
    log "检查必要命令..."

    local required_commands=("curl" "wget" "nc" "netstat" "ss" "awk" "sed" "grep" "tar" "gzip")
    local missing_commands=()

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done

    if [ ${#missing_commands[@]} -gt 0 ]; then
        warning "以下命令缺失，可能影响某些功能: ${missing_commands[*]}"
        warning "建议安装: apt-get install curl wget netcat net-tools iproute2 gawk sed grep tar gzip"
    else
        success "必要命令检查通过"
    fi
}

# 清理临时文件
cleanup_temp_files() {
    log "清理临时文件..."

    # 清理临时目录中的相关文件
    find /tmp -name "*${CONTAINER_PREFIX}*" -type f -mtime +1 -delete 2>/dev/null || true
    find /tmp -name "docker-compose*.tmp" -type f -mtime +1 -delete 2>/dev/null || true

    success "临时文件清理完成"
}

# 显示服务启动提示
show_startup_tips() {
    echo -e "\n${BLUE}=== 服务启动提示 ===${NC}"
    echo "1. 数据库服务通常在30-60秒内启动完成"
    echo "2. Dify服务首次启动需要2-3分钟进行数据库初始化"
    echo "3. RAGFlow服务首次启动需要5-10分钟下载模型和初始化"
    echo "4. n8n和OneAPI服务通常在1-2分钟内启动完成"
    echo "5. 如遇到启动问题，请查看日志: ./scripts/logs.sh [服务名]"
    echo ""
}

# 显示网络提示
show_network_tips() {
    echo -e "\n${BLUE}=== 网络访问提示 ===${NC}"
    if [ "$USE_DOMAIN" = true ]; then
        echo "1. 确保域名已正确解析到服务器IP: $SERVER_IP"
        echo "2. 如使用云服务器，请在安全组中开放端口: $NGINX_PORT"
        echo "3. 如使用防火墙，请开放相应端口"
    else
        echo "1. 确保以下端口在防火墙中已开放:"
        echo "   - Nginx: $NGINX_PORT"
        echo "   - Dify: $DIFY_WEB_PORT"
        echo "   - n8n: $N8N_WEB_PORT"
        echo "   - OneAPI: $ONEAPI_WEB_PORT"
        echo "   - RAGFlow: $RAGFLOW_WEB_PORT"
        echo "2. 如使用云服务器，请在安全组中开放这些端口"
    fi
    echo ""
}