# Google Cloud Traffic Limit

Google Cloud 服务器流量限制工具，防止超出免费额度产生费用。

## 功能特性

- 自动监控服务器流量使用情况
- 超过设定阈值时自动断网（保留 SSH 连接用于维护）
- 每月计费周期自动重置
- Telegram 通知（警告、超限、每日报告）
- 支持多服务器管理（通过服务器名称区分）
- 支持 GB/MB 两种流量限制单位
- 系统服务自动运行，无需人工干预
- 紧急恢复脚本，防止被锁在服务器外

## 快速安装

### 方式一：一键安装（推荐）

```bash
# 克隆仓库
git clone https://github.com/47alan/google-traffic-limit
cd google-traffic-limit

# 运行安装脚本
sudo bash install.sh
```

### 方式二：手动安装

```bash
# 1. 安装依赖
sudo apt-get update
sudo apt-get install -y jq bc iptables iptables-persistent curl util-linux

# 2. 创建目录
sudo mkdir -p /opt/traffic-limit
sudo mkdir -p /var/lib/traffic-limit

# 3. 复制文件
sudo cp traffic-limit.sh monthly-reset.sh emergency-recovery.sh config.conf /opt/traffic-limit/
sudo chmod +x /opt/traffic-limit/*.sh
sudo chmod 600 /opt/traffic-limit/config.conf

# 4. 安装 systemd 服务
sudo cp systemd/*.service systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now traffic-limit.timer
sudo systemctl enable --now traffic-reset.timer

# 5. 创建命令别名
sudo ln -sf /opt/traffic-limit/traffic-limit.sh /usr/local/bin/traffic-limit
```

## 使用方法

```bash
# 查看当前流量状态
sudo traffic-limit status

# 手动检查流量（通常由定时任务自动执行）
sudo traffic-limit check

# 手动阻断流量
sudo traffic-limit block

# 解除阻断
sudo traffic-limit unblock

# 修改配置后重载（使 CHECK_INTERVAL/RESET_DAY 生效）
sudo traffic-limit reload

# 测试 Telegram 通知
sudo traffic-limit test

# 查看帮助
sudo traffic-limit help
```

## 配置说明

配置文件位于 `/opt/traffic-limit/config.conf`：

```bash
# 服务器名称（用于多服务器识别）
SERVER_NAME=GCP-Server-1

# 流量限制（二选一）
TRAFFIC_LIMIT_GB=190     # 生产环境用 GB
TRAFFIC_LIMIT_MB=        # 测试用 MB（优先级更高）

# 流量统计模式
# egress  - 只统计出站流量（Google Cloud 计费方式，推荐）
# ingress - 只统计入站流量
# both    - 统计双向流量总和
TRAFFIC_COUNT_MODE=egress

# 网络接口 (通常是 ens4 或 eth0)
NETWORK_INTERFACE=ens4

# SSH 端口 (保留 SSH 连接)
SSH_PORT=22

# 计费周期重置日 (每月几号，1-28)
RESET_DAY=1

# 检查间隔（分钟，1-60）
CHECK_INTERVAL=5

# 流量警告阈值 (百分比)
WARNING_THRESHOLD=80

# Telegram 通知
ENABLE_TELEGRAM=true
TELEGRAM_BOT_TOKEN=你的Bot_Token
TELEGRAM_CHAT_ID=你的Chat_ID

# 每日报告
ENABLE_DAILY_REPORT=true
DAILY_REPORT_HOUR=9
```

## Telegram 通知配置

1. 在 Telegram 搜索 `@BotFather`，创建 Bot 获取 Token
2. 搜索 `@userinfobot` 获取你的 Chat ID
3. 编辑配置文件填入 Token 和 Chat ID
4. 运行 `sudo traffic-limit test` 测试

### 通知类型

- **每日报告**：每天固定时间发送流量使用情况
- **警告通知**：流量达到 80%、90% 时发送
- **超限通知**：流量超限并阻断时发送
- **月度重置**：每月重置日（可配置）重置时发送

## 工作原理

1. **流量监控**：定期检查服务器流量使用情况（间隔可配置，默认 5 分钟）
2. **阈值检测**：当流量超过设定阈值时触发阻断
3. **流量阻断**：使用 iptables/ip6tables 阻断所有流量，仅保留 SSH 连接
4. **自动重置**：每月重置日（可配置，默认 1 号）自动解除阻断并重置流量计数

## 文件说明

```
/opt/traffic-limit/
├── traffic-limit.sh        # 主程序
├── monthly-reset.sh        # 月度重置脚本
├── emergency-recovery.sh   # 紧急恢复脚本
└── config.conf             # 配置文件

/var/lib/traffic-limit/
├── traffic_data.json       # 流量统计数据
└── blocked                 # 阻断标记文件

/var/log/
└── traffic-limit.log       # 日志文件
```

## 查看日志

```bash
# 查看最近的日志
sudo tail -f /var/log/traffic-limit.log

# 查看定时器状态
systemctl list-timers traffic-limit.timer traffic-reset.timer
```

## 卸载

```bash
sudo bash install.sh uninstall
```

## 紧急恢复

如果因为配置错误被锁在服务器外：

1. 登录 Google Cloud Console
2. 进入 Compute Engine -> VM 实例
3. 点击实例名称 -> 连接到串口控制台
4. 运行: `sudo /opt/traffic-limit/emergency-recovery.sh`

## 注意事项

1. **首次安装后请确认网络接口名称正确**
   ```bash
   ip link show
   ```

2. **Google Cloud 计费周期通常是每月 1 号**，可通过 `RESET_DAY` 配置修改

3. **阻断后 SSH 仍然可用**，可随时登录服务器管理

4. **流量统计会在系统重启后继续累加**，不会因重启丢失

5. **建议设置阈值低于实际限制 10GB 左右**，留出安全余量

6. **测试时建议先用 200MB 测试阻断功能**，确认无误后再设置正式阈值

## 常见问题

### Q: 如何确认程序正在运行？
```bash
systemctl status traffic-limit.timer
```

### Q: 如何修改检查间隔？
修改 `/opt/traffic-limit/config.conf` 中的 `CHECK_INTERVAL`，然后运行：
```bash
sudo traffic-limit reload
```

### Q: 阻断后如何恢复？
```bash
sudo traffic-limit unblock
```

### Q: 如何手动重置流量计数？
```bash
sudo traffic-limit reset
```

### Q: 多台服务器如何区分通知？
配置不同的 `SERVER_NAME`，通知消息会显示服务器名称

## License

MIT License
