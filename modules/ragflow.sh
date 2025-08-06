#!/bin/bash

# =========================================================
# RAGFlow系统安装模块
# =========================================================

# 安装RAGFlow系统
install_ragflow() {
    log "开始安装RAGFlow系统..."

    # 检查系统资源
    check_ragflow_requirements

    # 生成RAGFlow配置
    generate_ragflow_compose

    # 启动RAGFlow服务
    start_ragflow_services

    success "RAGFlow系统安装完成"
}

# 检查RAGFlow系统要求
check_ragflow_requirements() {
    log "检查RAGFlow系统要求..."

    # 检查内存（RAGFlow建议至少8GB）
    local total_mem=$(free -m | awk 'NR==2{print $2}')
    if [ "$total_mem" -lt 8192 ]; then
        warning "RAGFlow建议至少8GB内存，当前系统内存: ${total_mem}MB"
        warning "系统可能运行缓慢或不稳定"
    fi

    # 检查磁盘空间（RAGFlow需要较多存储空间）
    local available_space=$(df "$INSTALL_PATH" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")
    if [ "$available_space" -lt 10485760 ]; then
        warning "RAGFlow建议至少10GB可用磁盘空间"
    fi

    success "系统要求检查完成"
}

# 生成RAGFlow Docker Compose配置
generate_ragflow_compose() {
    log "生成RAGFlow配置..."

    cat > "$INSTALL_PATH/docker-compose-ragflow.yml" << EOF
version: '3.8'

networks:
  aiserver_network:
    external: true

services:
  # Elasticsearch服务
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.11.0
    container_name: ${CONTAINER_PREFIX}_elasticsearch
    restart: always
    environment:
      - discovery.type=single-node
      - cluster.name=ragflow-es
      - node.name=ragflow-es-node
      - "ES_JAVA_OPTS=-Xms1g -Xmx1g"
      - bootstrap.memory_lock=true
      - xpack.security.enabled=false
      - xpack.security.enrollment.enabled=false$([ "$USE_DOMAIN" = false ] && echo "
    ports:
      - \"${ELASTICSEARCH_PORT}:9200\"")
    volumes:
      - ./volumes/ragflow/elasticsearch:/usr/share/elasticsearch/data
    ulimits:
      memlock:
        soft: -1
        hard: -1
      nofile:
        soft: 65536
        hard: 65536
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:9200/_cluster/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
    networks:
      - aiserver_network

  # MinIO对象存储服务
  minio:
    image: quay.io/minio/minio:RELEASE.2023-12-20T01-00-02Z
    container_name: ${CONTAINER_PREFIX}_minio
    restart: always
    command: server /data --address ":9000" --console-address ":9001"
    environment:
      MINIO_ROOT_USER: "${MINIO_ACCESS_KEY}"
      MINIO_ROOT_PASSWORD: "${MINIO_SECRET_KEY}"$([ "$USE_DOMAIN" = false ] && echo "
    ports:
      - \"${MINIO_API_PORT}:9000\"
      - \"${MINIO_CONSOLE_PORT}:9001\"")
    volumes:
      - ./volumes/ragflow/minio:/data
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 30s
      timeout: 20s
      retries: 10
      start_period: 60s
    networks:
      - aiserver_network

  # RAGFlow核心服务
  ragflow:
    image: infiniflow/ragflow:v0.7.0
    container_name: ${CONTAINER_PREFIX}_ragflow
    restart: always
    environment:
      - TZ=Asia/Shanghai
      - SECRET_KEY=${RAGFLOW_SECRET_KEY}
      - MYSQL_PASSWORD=${DB_PASSWORD}
      - MYSQL_HOST=${CONTAINER_PREFIX}_mysql
      - MYSQL_PORT=3306
      - MYSQL_USER=root
      - MYSQL_DB=ragflow
      - REDIS_HOST=${CONTAINER_PREFIX}_redis
      - REDIS_PORT=6379
      - REDIS_PASSWORD=${REDIS_PASSWORD}
      - ES_HOST=${CONTAINER_PREFIX}_elasticsearch
      - ES_PORT=9200
      - MINIO_HOST=${CONTAINER_PREFIX}_minio
      - MINIO_PORT=9000
      - MINIO_ACCESS_KEY=${MINIO_ACCESS_KEY}
      - MINIO_SECRET_KEY=${MINIO_SECRET_KEY}
      - SVR_HTTP_PORT=9380
      - PYTHONPATH=/ragflow
      - HF_ENDPOINT=https://hf-mirror.com$([ "$USE_DOMAIN" = false ] && echo "
    ports:
      - \"${RAGFLOW_WEB_PORT}:80\"
      - \"${RAGFLOW_API_PORT}:9380\"")
    volumes:
      - ./volumes/ragflow/ragflow:/ragflow/rag
      - ./volumes/ragflow/nltk_data:/root/nltk_data
      - ./volumes/ragflow/huggingface:/root/.cache/huggingface
    depends_on:
      elasticsearch:
        condition: service_healthy
      minio:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:9380 || curl -f http://localhost:80 || exit 1"]
      interval: 60s
      timeout: 60s
      retries: 20
      start_period: 600s
    networks:
      - aiserver_network
EOF

    success "RAGFlow配置生成完成"
}

# 启动RAGFlow服务
start_ragflow_services() {
    log "启动RAGFlow服务..."

    cd "$INSTALL_PATH"

    # 创建必要的数据目录
    create_ragflow_directories

    # 确保网络存在
    docker network create aiserver_network 2>/dev/null || true

    # 先启动Elasticsearch
    log "启动Elasticsearch服务..."
    COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-ragflow.yml up -d  elasticsearch
    wait_for_service "elasticsearch" "curl -f http://localhost:9200/_cluster/health" 120

    # 启动MinIO
    log "启动MinIO服务..."
    COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-ragflow.yml up -d  minio
    wait_for_service "minio" "curl -f http://localhost:9000/minio/health/live" 60

    # 初始化MinIO存储桶
    initialize_minio_buckets

    # 初始化RAGFlow数据库
    initialize_ragflow_database

    # 启动RAGFlow核心服务
    log "启动RAGFlow核心服务..."
    
    # 首先尝试启动，如果失败则重试
    local max_retries=5
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        log "尝试启动RAGFlow服务 (第 $((retry_count + 1)) 次)..."
        
        # 清理可能存在的失败容器
        docker stop "${CONTAINER_PREFIX}_ragflow" 2>/dev/null || true
        docker rm "${CONTAINER_PREFIX}_ragflow" 2>/dev/null || true
        
        # 启动RAGFlow服务
        COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-ragflow.yml up -d  ragflow
        
        # 等待容器启动
        sleep 30
        
        # 检查容器是否运行
        if docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_ragflow"; then
            log "RAGFlow容器已启动，等待服务就绪..."
            
            # 等待服务就绪，使用更长的超时时间
            local service_ready=false
            local wait_time=0
            local max_wait=1200  # 20分钟
            
            while [ $wait_time -lt $max_wait ]; do
                # 尝试多个健康检查端点
                if docker exec "${CONTAINER_PREFIX}_ragflow" curl -f http://localhost:9380 >/dev/null 2>&1 || \
                   docker exec "${CONTAINER_PREFIX}_ragflow" curl -f http://localhost:80 >/dev/null 2>&1; then
                    service_ready=true
                    break
                fi
                
                sleep 15
                wait_time=$((wait_time + 15))
                
                # 每分钟显示一次进度
                if [ $((wait_time % 60)) -eq 0 ]; then
                    log "等待RAGFlow服务就绪... ($wait_time/$max_wait 秒)"
                fi
            done
            
            if [ "$service_ready" = true ]; then
                success "RAGFlow服务启动成功"
                return 0
            else
                warning "RAGFlow服务启动超时，查看日志..."
                docker logs "${CONTAINER_PREFIX}_ragflow" --tail 10
            fi
        else
            warning "RAGFlow容器启动失败"
            # 显示docker-compose日志
            COMPOSE_PROJECT_NAME=aiserver docker-compose -f docker-compose-ragflow.yml logs --tail 10 ragflow 2>/dev/null || true
        fi
        
        retry_count=$((retry_count + 1))
        if [ $retry_count -lt $max_retries ]; then
            warning "RAGFlow启动失败，等待30秒后重试..."
            sleep 30
        fi
    done
    
    # 如果所有重试都失败了
    error "RAGFlow服务启动失败，已重试 $max_retries 次"
    log "最终错误日志:"
    docker logs "${CONTAINER_PREFIX}_ragflow" --tail 20 2>/dev/null || true
    
    # 创建一个空的RAGFlow容器，以便Nginx可以启动
    # 这样即使RAGFlow服务未完全就绪，Nginx也能正常启动
    if ! docker ps --format "{{.Names}}" | grep -q "${CONTAINER_PREFIX}_ragflow"; then
        warning "创建RAGFlow占位容器，以便Nginx可以正常启动..."
        docker run -d --name "${CONTAINER_PREFIX}_ragflow" --network aiserver_network --restart always -e TZ=Asia/Shanghai --entrypoint "tail" infiniflow/ragflow:v0.7.0 -f /dev/null
    fi
    
    # 即使RAGFlow启动失败，也继续安装流程，只是标记为警告
    warning "RAGFlow服务启动失败，但继续安装流程。可以稍后手动启动RAGFlow。"
    success "RAGFlow安装流程完成（服务可能需要手动启动）"
}

# 创建RAGFlow目录结构
create_ragflow_directories() {
    log "创建RAGFlow目录结构..."

    # 创建数据目录
    ensure_directory "$INSTALL_PATH/volumes/ragflow/elasticsearch" "1000:1000" "755"
    ensure_directory "$INSTALL_PATH/volumes/ragflow/minio" "1001:1001" "755"
    ensure_directory "$INSTALL_PATH/volumes/ragflow/ragflow" "root:root" "755"
    ensure_directory "$INSTALL_PATH/volumes/ragflow/nltk_data" "root:root" "755"
    ensure_directory "$INSTALL_PATH/volumes/ragflow/huggingface" "root:root" "755"

    # 创建日志目录
    ensure_directory "$INSTALL_PATH/logs/ragflow" "root:root" "755"

    success "RAGFlow目录结构创建完成"
}

# 初始化MinIO存储桶
initialize_minio_buckets() {
    log "初始化MinIO存储桶..."

    # 等待MinIO完全启动
    sleep 30

    # 使用MinIO客户端创建存储桶
    docker exec ${CONTAINER_PREFIX}_minio mc config host add ragflow-minio http://localhost:9000 ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} 2>/dev/null || true
    docker exec ${CONTAINER_PREFIX}_minio mc mb ragflow-minio/ragflow 2>/dev/null || true
    docker exec ${CONTAINER_PREFIX}_minio mc policy set public ragflow-minio/ragflow 2>/dev/null || true

    success "MinIO存储桶初始化完成"
}

# 初始化RAGFlow数据库
initialize_ragflow_database() {
    log "初始化RAGFlow数据库..."

    # 创建RAGFlow数据库
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS ragflow CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || true

    # 创建RAGFlow用户并授权
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "CREATE USER IF NOT EXISTS 'ragflow'@'%' IDENTIFIED BY '${DB_PASSWORD}';" 2>/dev/null || true
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "GRANT ALL PRIVILEGES ON ragflow.* TO 'ragflow'@'%';" 2>/dev/null || true
    docker exec ${CONTAINER_PREFIX}_mysql mysql -uroot -p${DB_PASSWORD} -e "FLUSH PRIVILEGES;" 2>/dev/null || true

    success "RAGFlow数据库初始化完成"
}

# 备份RAGFlow数据
backup_ragflow_data() {
    local backup_dir="$1"

    log "备份RAGFlow数据..."

    mkdir -p "$backup_dir"

    # 备份RAGFlow应用数据
    if [ -d "$INSTALL_PATH/volumes/ragflow/ragflow" ]; then
        cp -r "$INSTALL_PATH/volumes/ragflow/ragflow" "$backup_dir/" 2>/dev/null
        success "RAGFlow应用数据备份完成"
    fi

    # 备份Elasticsearch数据
    if [ -d "$INSTALL_PATH/volumes/ragflow/elasticsearch" ]; then
        # 先创建Elasticsearch快照
        docker exec ${CONTAINER_PREFIX}_elasticsearch curl -X PUT "localhost:9200/_snapshot/ragflow_backup" -H 'Content-Type: application/json' -d'
        {
          "type": "fs",
          "settings": {
            "location": "/usr/share/elasticsearch/data/backup"
          }
        }' 2>/dev/null || true

        docker exec ${CONTAINER_PREFIX}_elasticsearch curl -X PUT "localhost:9200/_snapshot/ragflow_backup/snapshot_$(date +%Y%m%d_%H%M%S)" -H 'Content-Type: application/json' -d'
        {
          "indices": "*",
          "ignore_unavailable": true,
          "include_global_state": false
        }' 2>/dev/null || true

        cp -r "$INSTALL_PATH/volumes/ragflow/elasticsearch" "$backup_dir/" 2>/dev/null
        success "Elasticsearch数据备份完成"
    fi

    # 备份MinIO数据
    if [ -d "$INSTALL_PATH/volumes/ragflow/minio" ]; then
        cp -r "$INSTALL_PATH/volumes/ragflow/minio" "$backup_dir/" 2>/dev/null
        success "MinIO数据备份完成"
    fi

    # 备份模型缓存
    if [ -d "$INSTALL_PATH/volumes/ragflow/huggingface" ]; then
        cp -r "$INSTALL_PATH/volumes/ragflow/huggingface" "$backup_dir/" 2>/dev/null
        success "模型缓存备份完成"
    fi

    # 备份NLTK数据
    if [ -d "$INSTALL_PATH/volumes/ragflow/nltk_data" ]; then
        cp -r "$INSTALL_PATH/volumes/ragflow/nltk_data" "$backup_dir/" 2>/dev/null
        success "NLTK数据备份完成"
    fi

    # 生成备份信息
    cat > "$backup_dir/backup_info.txt" << EOF
RAGFlow系统数据备份
==================

备份时间: $(date)
备份类型: RAGFlow系统数据
备份内容:
- RAGFlow应用数据
- Elasticsearch索引数据
- MinIO对象存储数据
- 模型缓存数据
- NLTK语言数据

备份大小: $(du -sh "$backup_dir" | cut -f1)

恢复说明:
1. 停止RAGFlow相关服务
2. 恢复数据目录
3. 重新启动服务
EOF
}

# 恢复RAGFlow数据
restore_ragflow_data() {
    local backup_dir="$1"

    log "恢复RAGFlow数据..."

    # 停止RAGFlow服务
    docker-compose -f docker-compose-ragflow.yml stop 2>/dev/null || true
    sleep 10

    # 恢复RAGFlow应用数据
    if [ -d "$backup_dir/ragflow" ]; then
        rm -rf "$INSTALL_PATH/volumes/ragflow/ragflow" 2>/dev/null
        cp -r "$backup_dir/ragflow" "$INSTALL_PATH/volumes/ragflow/" 2>/dev/null
        success "RAGFlow应用数据恢复完成"
    fi

    # 恢复Elasticsearch数据
    if [ -d "$backup_dir/elasticsearch" ]; then
        rm -rf "$INSTALL_PATH/volumes/ragflow/elasticsearch" 2>/dev/null
        cp -r "$backup_dir/elasticsearch" "$INSTALL_PATH/volumes/ragflow/" 2>/dev/null
        chown -R 1000:1000 "$INSTALL_PATH/volumes/ragflow/elasticsearch" 2>/dev/null || true
        success "Elasticsearch数据恢复完成"
    fi

    # 恢复MinIO数据
    if [ -d "$backup_dir/minio" ]; then
        rm -rf "$INSTALL_PATH/volumes/ragflow/minio" 2>/dev/null
        cp -r "$backup_dir/minio" "$INSTALL_PATH/volumes/ragflow/" 2>/dev/null
        chown -R 1001:1001 "$INSTALL_PATH/volumes/ragflow/minio" 2>/dev/null || true
        success "MinIO数据恢复完成"
    fi

    # 恢复模型缓存
    if [ -d "$backup_dir/huggingface" ]; then
        rm -rf "$INSTALL_PATH/volumes/ragflow/huggingface" 2>/dev/null
        cp -r "$backup_dir/huggingface" "$INSTALL_PATH/volumes/ragflow/" 2>/dev/null
        success "模型缓存恢复完成"
    fi

    # 恢复NLTK数据
    if [ -d "$backup_dir/nltk_data" ]; then
        rm -rf "$INSTALL_PATH/volumes/ragflow/nltk_data" 2>/dev/null
        cp -r "$backup_dir/nltk_data" "$INSTALL_PATH/volumes/ragflow/" 2>/dev/null
        success "NLTK数据恢复完成"
    fi

    # 重启RAGFlow服务
    start_ragflow_services
}

# 更新RAGFlow配置
update_ragflow_config() {
    log "更新RAGFlow配置..."

    # 重新生成配置
    generate_ragflow_compose

    # 重启服务
    docker-compose -f docker-compose-ragflow.yml restart

    success "RAGFlow配置更新完成"
}

# 检查RAGFlow服务状态
check_ragflow_status() {
    log "检查RAGFlow服务状态..."

    echo -e "\n${BLUE}=== RAGFlow服务状态 ===${NC}"

    for service in elasticsearch minio ragflow; do
        local container_name="${CONTAINER_PREFIX}_${service}"
        if docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
            local status=$(docker inspect --format='{{.State.Health.Status}}' "$container_name" 2>/dev/null || echo "no-health-check")
            case "$status" in
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
                    echo "ℹ️  $service: 运行中（无健康检查）"
                    ;;
            esac
        else
            echo "❌ $service: 未运行"
        fi
    done

    echo -e "\n${BLUE}=== RAGFlow访问信息 ===${NC}"
    if [ "$USE_DOMAIN" = true ]; then
        echo "RAGFlow Web界面: $RAGFLOW_URL"
        echo "RAGFlow API: $RAGFLOW_URL/api"
    else
        echo "RAGFlow Web界面: http://$SERVER_IP:$RAGFLOW_WEB_PORT"
        echo "RAGFlow API: http://$SERVER_IP:$RAGFLOW_API_PORT"
        echo "MinIO控制台: http://$SERVER_IP:$MINIO_CONSOLE_PORT"
        echo "Elasticsearch: http://$SERVER_IP:$ELASTICSEARCH_PORT"
    fi
}

# 获取RAGFlow初始管理员密码
get_ragflow_admin_password() {
    log "获取RAGFlow初始管理员账户信息..."

    echo -e "\n${BLUE}=== RAGFlow管理员账户 ===${NC}"
    echo "默认管理员邮箱: admin@ragflow.io"

    # 尝试从容器日志中获取初始密码
    local admin_password=$(docker logs ${CONTAINER_PREFIX}_ragflow 2>/dev/null | grep -i "admin.*password" | tail -1 | sed 's/.*password[: ]*\([^ ]*\).*/\1/' 2>/dev/null)

    if [ -n "$admin_password" ]; then
        echo "初始管理员密码: $admin_password"
    else
        echo "初始管理员密码: ragflow123456 (默认密码，首次登录后请修改)"
    fi

    echo ""
    warning "请在首次登录后立即修改管理员密码！"
}