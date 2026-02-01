#!/bin/bash
#
# monthly-reset.sh - 月度流量重置脚本
# Monthly traffic reset script
#

# 不使用 set -e，避免某些命令失败导致整个重置失败

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.conf"
LOCK_FILE="/var/lib/traffic-limit/traffic-limit.lock"

# 获取文件锁（防止与 check 并发）
acquire_lock() {
    # 确保锁目录存在
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true

    # 检查 flock 是否可用
    if ! command -v flock &> /dev/null; then
        echo "警告: flock 不可用，跳过锁检查"
        return 0
    fi

    local lock_fd=200
    eval "exec $lock_fd>$LOCK_FILE"
    # 等待锁（最多 30 秒）
    if ! flock -w 30 $lock_fd 2>/dev/null; then
        echo "无法获取锁，退出"
        exit 1
    fi
}

# 获取锁
acquire_lock

# 加载配置
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

LOG_FILE=${LOG_FILE:-/var/log/traffic-limit.log}
DATA_FILE=${DATA_FILE:-/var/lib/traffic-limit/traffic_data.json}

log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [INFO] $@" | tee -a "$LOG_FILE"
}

log "=== 月度流量重置开始 ==="

# 删除旧的数据文件，让主脚本重新初始化
if [[ -f "$DATA_FILE" ]]; then
    # 备份旧数据
    cp "$DATA_FILE" "${DATA_FILE}.$(date +%Y%m).bak" 2>/dev/null || true
    rm -f "$DATA_FILE"
    log "已备份并删除旧的流量数据"
fi

# 清理警告标记文件（确保新月份可以正常发送警告）
find /var/lib/traffic-limit -name "warning_sent_*" -delete 2>/dev/null || true
find /var/lib/traffic-limit -name "daily_report_*" -delete 2>/dev/null || true
log "已清理警告标记文件"

# 解除流量阻断（直接执行 iptables 命令，不 source 整个脚本）
log "解除流量阻断..."

# === IPv4 ===
# 从 INPUT 和 OUTPUT 移除 TRAFFIC_LIMIT 引用
iptables -D INPUT -j TRAFFIC_LIMIT 2>/dev/null || true
iptables -D OUTPUT -j TRAFFIC_LIMIT 2>/dev/null || true

# 清空并删除 TRAFFIC_LIMIT 链
iptables -F TRAFFIC_LIMIT 2>/dev/null || true
iptables -X TRAFFIC_LIMIT 2>/dev/null || true

# === IPv6 ===
if command -v ip6tables &> /dev/null; then
    ip6tables -D INPUT -j TRAFFIC_LIMIT 2>/dev/null || true
    ip6tables -D OUTPUT -j TRAFFIC_LIMIT 2>/dev/null || true
    ip6tables -F TRAFFIC_LIMIT 2>/dev/null || true
    ip6tables -X TRAFFIC_LIMIT 2>/dev/null || true
fi

# 移除阻断标记
rm -f /var/lib/traffic-limit/blocked

# 持久化 iptables 规则
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save 2>/dev/null || true
fi

log "流量限制已解除"

# 发送重置通知
if [[ "$ENABLE_TELEGRAM" == "true" && -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
    SERVER_NAME=${SERVER_NAME:-$(hostname)}
    msg="🖥️ *${SERVER_NAME}*
🔄 *月度流量重置*

新的计费周期已开始！
流量计数器已重置为 0
网络限制已解除

📅 $(date '+%Y-%m-%d %H:%M')"

    curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${msg}" \
        -d "parse_mode=Markdown" \
        > /dev/null 2>&1 || log "WARN" "Telegram 通知发送失败"
fi

log "=== 月度流量重置完成 ==="
