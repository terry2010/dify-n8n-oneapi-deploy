# dify-n8n-oneapi-deploy
一键安装部署 dify-n8n-oneapi-deploy
> 代码使用 claude-sonnet-4-20250514 生成 , 除去写prompt的耗时， AI 生成最多花了20分钟， 测试花了大约2小时。 要让我自己写的话至少得15天才能做完。  AI的效率实在太离谱了


# 使用方法

修改 install.sh 开头 的端口， 安装目录等参数后， 执行
```
sh install.sh
```
---------------------------------------------

安装目录: /volume1/homes/terry/aiserver

访问地址:
  - Dify Web界面: http://192.168.50.100:8602
  - n8n Web界面: http://192.168.50.100:8601
  - OneAPI Web界面: http://192.168.50.100:8603

管理命令:
  - 启动服务: cd /volume1/homes/terry/aiserver && ./start.sh
  - 停止服务: cd /volume1/homes/terry/aiserver && ./stop.sh
  - 重启服务: cd /volume1/homes/terry/aiserver && ./restart.sh
  - 查看日志: cd /volume1/homes/terry/aiserver && ./logs.sh

数据库信息:
  - MySQL: 192.168.50.100:3306 (root/654321)
  - PostgreSQL: 192.168.50.100:5433 (postgres/654321)
  - Redis: 192.168.50.100:6379


# 运行效果：

<img width="1309" height="975" alt="image" src="https://github.com/user-attachments/assets/bf654954-4709-45a0-b322-879431b00b91" />


<img width="946" height="2244" alt="image" src="https://github.com/user-attachments/assets/0627a150-2f68-4969-8bdb-70643040b6c5" />
