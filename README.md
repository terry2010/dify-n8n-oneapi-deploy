# dify-n8n-oneapi-deploy
一键安装部署 dify-n8n-oneapi-deploy


在 install.sh 开头 可以自定义下面所有参数

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

<img width="1187" height="2045" alt="image" src="https://github.com/user-attachments/assets/549e4a36-679f-4cfe-82c1-a8e2a97b5095" />
