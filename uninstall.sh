#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# 显示横幅
show_banner() {
    echo -e "${RED}"
    echo "============================================================"
    echo "                AI服务集群一键卸载工具                      "
    echo "============================================================"
    echo -e "${NC}"
}

# 确认卸载
confirm_uninstall() {
    echo -e "${RED}警告: 此操作将删除所有AI服务集群相关的容器和数据！${NC}"
    echo -e "${RED}数据删除后将无法恢复！${NC}"
    echo ""
    read -p "确认要继续卸载吗? (y/n): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log "卸载操作已取消"
        exit 0
    fi
}

# 获取安装路径
get_install_path() {
    # 默认安装路径
    INSTALL_PATH=$(pwd)
    
    # 如果存在配置文件，从配置文件读取
    if [ -f "$INSTALL_PATH/.env" ]; then
        source "$INSTALL_PATH/.env"
    fi
    
    log "安装路径: $INSTALL_PATH"
}

# 停止并删除所有容器
remove_containers() {
    log "停止并删除所有容器..."
    
    # 停止所有相关容器
    docker ps -a | grep "aiserver_" | awk '{print $1}' | xargs -r docker stop
    
    # 删除所有相关容器
    docker ps -a | grep "aiserver_" | awk '{print $1}' | xargs -r docker rm -f
    
    success "所有容器已删除"
}

# 删除所有镜像
remove_images() {
     log "不自动删除镜像， 想删的话手工 docker rmi -f 镜像名"

#    log "删除所有相关镜像..."
#
#    # 列出所有相关镜像
#    local images=$(docker images | grep -E "dify|n8n|oneapi|ragflow" | awk '{print $3}')
#
#    # 删除镜像
#    if [ -n "$images" ]; then
#        echo "$images" | xargs -r docker rmi -f
#        success "所有相关镜像已删除"
#    else
#        log "未找到相关镜像"
#    fi
#}

# 删除数据卷
remove_volumes() {
    log "删除数据卷..."
    
    # 删除命名卷
    docker volume ls | grep "aiserver_" | awk '{print $2}' | xargs -r docker volume rm
    
    # 删除本地数据目录
    if [ -d "$INSTALL_PATH/volumes" ]; then
        log "删除本地数据目录: $INSTALL_PATH/volumes"
        rm -rf "$INSTALL_PATH/volumes"
    fi
    
    success "所有数据卷已删除"
}

# 删除网络
remove_networks() {
    log "删除Docker网络..."
    
    # 删除项目网络
    docker network ls | grep "aiserver_" | awk '{print $1}' | xargs -r docker network rm
    
    success "所有相关网络已删除"
}

# 删除配置文件
remove_config_files() {
    log "删除配置文件..."
    
    # 删除所有docker-compose文件
    find "$INSTALL_PATH" -name "docker-compose*.yml" -delete
    
    # 删除环境配置文件
    rm -f "$INSTALL_PATH/.env"
    
    success "所有配置文件已删除"
}

# 清理日志文件
clean_logs() {
    log "清理日志文件..."
    
    # 删除日志文件
    find "$INSTALL_PATH" -name "*.log" -delete
    
    success "所有日志文件已清理"
}

# 主函数
main() {
    show_banner
    confirm_uninstall
    get_install_path
    
    # 执行卸载步骤
    remove_containers
    remove_volumes
    remove_networks
    remove_config_files
    clean_logs
    
    # 是否删除镜像（可选）
    read -p "是否同时删除所有相关Docker镜像? (y/n): " remove_img
    if [[ "$remove_img" == "y" || "$remove_img" == "Y" ]]; then
        remove_images
    fi
    
    echo ""
    success "AI服务集群卸载完成！"
    echo ""
    log "如需重新安装，请运行: ./install.sh --all"
}

# 执行主函数
main

}