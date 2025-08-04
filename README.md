# dify-n8n-oneapi-deploy
一键安装部署 dify-n8n-oneapi-deploy
# AI服务集群一键安装脚本

这是一个模块化的Shell脚本系统，用于在群晖NAS上一键安装和管理AI服务集群，包含Dify、n8n、OneAPI、RAGFlow四个核心应用，以及MySQL、PostgreSQL、Redis、Elasticsearch、MinIO等数据库和存储服务。

## 🚀 功能特性

### 核心服务
- **Dify**: AI应用开发平台，支持多种AI模型和工作流编排
- **n8n**: 可视化工作流编排和自动化平台
- **OneAPI**: 统一的AI接口管理和分发平台
- **RAGFlow**: 基于深度文档理解的RAG引擎

### 基础设施
- **MySQL 8.0**: 关系型数据库，用于RAGFlow
- **PostgreSQL 15**: 关系型数据库，用于Dify、n8n、OneAPI
- **Redis 7**: 缓存数据库
- **Elasticsearch**: 搜索引擎，用于RAGFlow
- **MinIO**: 对象存储，用于RAGFlow
- **Nginx**: 反向代理和负载均衡

### 部署模式
- **域名模式**: 每个系统使用独立子域名访问
- **IP模式**: 使用IP+不同端口访问
- **混合模式**: 支持域名模式下的自定义端口配置

## 📋 系统要求

### 硬件要求
- **内存**: 建议至少8GB（RAGFlow需要较多内存）
- **磁盘**: 建议至少20GB可用空间
- **CPU**: 建议至少4核心
- **网络**: 稳定的互联网连接

### 软件要求
- **操作系统**: Linux（主要为群晖NAS设计）
- **Docker**: 最新版本
- **Docker Compose**: 最新版本

## 🔧 快速开始

### 1. 下载安装包
```bash
# 克隆仓库或下载压缩包
git clone <repository-url> aiserver
cd aiserver
```

### 2. 配置域名（可选）

编辑 modules/config.sh 文件，配置域名：
```bash 
# 域名配置（如果有域名的话）
DIFY_DOMAIN="dify.yourdomain.com"
N8N_DOMAIN="n8n.yourdomain.com" 
ONEAPI_DOMAIN="oneapi.yourdomain.com"
RAGFLOW_DOMAIN="ragflow.yourdomain.com"

# 域名模式下的端口（可选，默认80）
DOMAIN_PORT=""
```

如果没有域名，保持默认空值即可使用IP模式。
### 3. 一键安装
```bash 
# 完整安装所有服务
chmod +x install.sh
./install.sh --all

# 或者分步安装
./install.sh --infrastructure  # 先安装基础设施

./install.sh --app ragflow     # 然后安装RAGFlow
```

### 4. 查看服务状态
```bash 
# 查看所有服务状态
./scripts/manage.sh status

# 查看特定服务日志
./scripts/logs.sh ragflow
```

## 🌟 安装选项
### 完整安装

```shell
./install.sh --all
```
### 基础设施安装
```shell
./install.sh --infrastructure
```

### 单个应用安装
```shell
./install.sh --app dify      # 安装Dify
./install.sh --app n8n       # 安装n8n
./install.sh --app oneapi    # 安装OneAPI
./install.sh --app ragflow   # 安装RAGFlow
```

### 批量应用安装
```shell
./install.sh --apps dify,ragflow    # 安装Dify和RAGFlow
./install.sh --apps n8n,oneapi      # 安装n8n和OneAPI
```

### 📁 目录结构
```shell
aiserver/
├── install.sh                          # 主入口安装脚本
├── modules/                             # 功能模块目录
│   ├── config.sh                        # 配置管理模块
│   ├── utils.sh                         # 工具函数模块
│   ├── database.sh                      # 数据库安装模块
│   ├── nginx.sh                         # Nginx反向代理模块
│   ├── dify.sh                          # Dify系统安装模块
│   ├── n8n.sh                           # n8n系统安装模块
│   ├── oneapi.sh                        # OneAPI系统安装模块
│   └── ragflow.sh                       # RAGFlow系统安装模块
├── scripts/                             # 管理脚本目录
│   ├── manage.sh                        # 服务管理脚本
│   ├── logs.sh                          # 日志查看脚本
│   ├── backup.sh                        # 数据备份脚本
│   ├── restore.sh                       # 数据恢复脚本
│   ├── change_domain.sh                 # 域名修改脚本
│   └── change_port.sh                   # 端口修改脚本
└── README.md                            # 项目说明文档
```

## 🎮 管理命令

### 服务管理

```shell
# 启动所有服务
./scripts/manage.sh start

# 停止特定服务
./scripts/manage.sh stop ragflow

# 重启服务
./scripts/manage.sh restart nginx

# 查看服务状态
./scripts/manage.sh status

# 健康检查
./scripts/manage.sh health

```
### 日志查看
```shell
# 查看所有服务日志概览
./scripts/logs.sh

# 查看特定服务日志
./scripts/logs.sh ragflow

# 实时跟踪日志
./scripts/logs.sh nginx -f

# 查看最近50行日志
./scripts/logs.sh mysql -n 50

# 按关键词过滤日志
./scripts/logs.sh ragflow --grep error
```
### 数据备份
```shell
# 备份所有数据
./scripts/backup.sh

# 备份特定服务
./scripts/backup.sh ragflow

# 备份并压缩
./scripts/backup.sh mysql -c

# 列出可备份的系统
./scripts/backup.sh -l

```

### 数据恢复
```shell
# 列出所有备份
./scripts/restore.sh -l

# 恢复指定备份
./scripts/restore.sh backup/full_backup_20241201_143022

# 验证备份完整性
./scripts/restore.sh backup/ragflow_20241201_143022 --verify

# 选择性恢复
./scripts/restore.sh backup/full_backup_20241201_143022 --selective
```

### 域名管理
```shell
# 显示当前域名配置
./scripts/change_domain.sh --show

# 修改RAGFlow域名
./scripts/change_domain.sh --ragflow rag.newdomain.com --apply

# 修改多个域名
./scripts/change_domain.sh --dify dify.newdomain.com --ragflow rag.newdomain.com --apply

# 禁用域名模式
./scripts/change_domain.sh --disable-domain --apply

# 测试域名连通性
./scripts/change_domain.sh --test
```

### 端口管理
```shell

# 显示当前端口配置
./scripts/change_port.sh --show

# 修改RAGFlow端口
./scripts/change_port.sh --ragflow 8605 --apply

# 修改多个端口
./scripts/change_port.sh --dify 8602 --ragflow 8605 --apply

# 重置为默认端口
./scripts/change_port.sh --reset --apply
```

## 🌐 访问地址
安装完成后，根据配置模式访问相应地址：
域名模式

    Dify: http://dify.yourdomain.com
    n8n: http://n8n.yourdomain.com
    OneAPI: http://oneapi.yourdomain.com
    RAGFlow: http://ragflow.yourdomain.com

IP模式

    统一入口: http://your-server-ip:8604
    Dify: http://your-server-ip:8602
    n8n: http://your-server-ip:8601
    OneAPI: http://your-server-ip:8603
    RAGFlow: http://your-server-ip:8605

管理端口

    MySQL: your-server-ip:3306
    PostgreSQL: your-server-ip:5433
    Redis: your-server-ip:6379
    Elasticsearch: your-server-ip:9200
    MinIO控制台: your-server-ip:9002

🔐 默认账户信息
RAGFlow

    管理员邮箱: admin@ragflow.io
    默认密码: ragflow123456

数据库

    MySQL root密码: 654321
    PostgreSQL postgres密码: 654321
    Redis密码: 无密码

⚠️ 重要提示: 请在首次登录后立即修改所有默认密码！
📊 端口配置
服务 	默认端口 	说明
Nginx 	80 	反向代理端口
Dify Web 	8602 	Dify前端服务
n8n 	8601 	n8n工作流服务
OneAPI 	8603 	OneAPI管理界面
RAGFlow 	8605 	RAGFlow前端服务
MySQL 	3306 	MySQL数据库
PostgreSQL 	5433 	PostgreSQL数据库
Redis 	6379 	Redis缓存
Elasticsearch 	9200 	Elasticsearch搜索
MinIO API 	9001 	MinIO对象存储API
MinIO Console 	9002 	MinIO管理控制台


## 🔧 故障排除

### 常见问题

#### 1. 端口被占用

```bash
# 检查端口占用
./scripts/change_port.sh --check

# 修改冲突端口
./scripts/change_port.sh --ragflow 8606 --apply
```

#### 2. 内存不足

```bash
# 检查系统资源
./scripts/manage.sh health

# 停止不必要的服务
./scripts/manage.sh stop ragflow
```

#### 3. 域名解析问题

```bash
# 检查域名解析
./scripts/change_domain.sh --dns-check

# 测试域名连通性
./scripts/change_domain.sh --test
```

#### 4. 服务启动失败

```bash
# 查看服务日志
./scripts/logs.sh ragflow

# 检查服务状态
./scripts/manage.sh status

# 重启服务
./scripts/manage.sh restart ragflow
```

#### 5. RAGFlow启动缓慢

RAGFlow首次启动需要下载模型和初始化，可能需要10-15分钟，请耐心等待。

```bash
# 查看RAGFlow启动日志
./scripts/logs.sh ragflow -f

# 查看Elasticsearch状态
./scripts/logs.sh elasticsearch
```

### 日志位置

- 容器日志: `./scripts/logs.sh [服务名]`
- Nginx访问日志: `logs/access.log`
- Nginx错误日志: `logs/error.log`
- 应用数据: `volumes/` 目录下

### 数据备份建议

- 定期备份: 建议每天备份一次
- 完整备份: 使用 `./scripts/backup.sh` 进行完整备份
- 重要数据: 特别注意备份RAGFlow的文档数据
- 测试恢复: 定期测试备份恢复功能

## 📈 性能优化

### 1. 系统资源优化

- 为RAGFlow分配足够内存（建议8GB+）
- 使用SSD存储提升I/O性能
- 配置合适的swap空间

### 2. 数据库优化

```bash
# 数据库性能优化
source modules/database.sh
optimize_database_performance

# 数据库维护
maintain_databases
```

### 3. 服务扩缩容

```bash
# 扩展Dify服务到2个实例
./scripts/manage.sh scale dify 2

# 扩展OneAPI服务
./scripts/manage.sh scale oneapi 2
```

## 🤝 贡献指南

欢迎提交Issue和Pull Request！

### 开发环境

- Fork本项目
- 创建功能分支
- 提交更改
- 发起Pull Request

### 代码规范

- 使用4空格缩进
- 函数和变量使用小写+下划线
- 添加适当的注释
- 遵循Shell脚本最佳实践

## 📜 许可证

本项目采用MIT许可证，详情请查看LICENSE文件。

## 📞 联系方式

如果您在使用过程中遇到问题，请：

- 查看本文档的故障排除部分
- 提交Issue描述问题
- 提供日志信息以便排查