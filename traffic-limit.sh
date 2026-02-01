#!/bin/bash
#
# traffic-limit.sh - 主流量监控和限制脚本
# Main traffic monitoring and limiting script
#
# 功能:
# - 监控网络流量使用情况
# - 超过阈值时自动断网（保留SSH）
# - 每月自动重置
#

# 不使用 set -e，避免命令失败导致脚本退出

# 脚本目录（解析软链接，获取真实路径）
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.conf"
LOCK_FILE="/var/lib/traffic-limit/traffic-limit.lock"
LOG_FILE="/var/log/traffic-limit.log"

# 获取文件锁（防止并发执行）
acquire_lock() {
    # 确保锁目录存在
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true

    # 检查 flock 是否可用
    if ! command -v flock &> /dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] flock 不可用，跳过锁检查" | tee -a "$LOG_FILE"
        return 0
    fi

    local lock_fd=200
    eval "exec $lock_fd>$LOCK_FILE"
    if ! flock -n $lock_fd 2>/dev/null; then
        echo "另一个实例正在运行，退出"
        exit 0
    fi
}

# 释放文件锁（不删除锁文件，避免竞态）
release_lock() {
    # flock 在进程退出时自动释放，无需手动操作
    :
}

# 检查依赖
check_dependencies() {
    local missing=()

    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi
    if ! command -v bc &> /dev/null; then
        missing+=("bc")
    fi
    if ! command -v iptables &> /dev/null; then
        missing+=("iptables")
    fi
    if ! command -v curl &> /dev/null; then
        missing+=("curl")
    fi
    if ! command -v flock &> /dev/null; then
        missing+=("util-linux")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "错误: 缺少依赖: ${missing[*]}"
        echo "请运行: sudo apt-get install -y ${missing[*]}"
        exit 1
    fi
}

# 验证网络接口是否存在
validate_interface() {
    if [[ ! -d "/sys/class/net/${NETWORK_INTERFACE}" ]]; then
        log "ERROR" "网络接口 ${NETWORK_INTERFACE} 不存在！"
        log "ERROR" "可用接口: $(ls /sys/class/net/ | tr '\n' ' ')"
        return 1
    fi
    return 0
}

# 验证 SSH 端口（安全检查）
validate_ssh_port() {
    # 检查当前 SSH 连接使用的端口
    local current_ssh_port=$(ss -tnlp | grep sshd | awk '{print $4}' | grep -oE '[0-9]+$' | head -n1)

    if [[ -n "$current_ssh_port" && "$current_ssh_port" != "$SSH_PORT" ]]; then
        log "WARN" "警告: 配置的 SSH 端口($SSH_PORT) 与实际 SSH 端口($current_ssh_port) 不一致！"
        log "WARN" "这可能导致阻断后无法登录服务器！"
        return 1
    fi
    return 0
}

# 加载配置
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        echo "错误: 配置文件不存在: $CONFIG_FILE"
        exit 1
    fi

    # 默认值
    SERVER_NAME=${SERVER_NAME:-$(hostname)}
    NETWORK_INTERFACE=${NETWORK_INTERFACE:-ens4}
    SSH_PORT=${SSH_PORT:-22}
    RESET_DAY=${RESET_DAY:-1}
    LOG_FILE=${LOG_FILE:-/var/log/traffic-limit.log}
    DATA_FILE=${DATA_FILE:-/var/lib/traffic-limit/traffic_data.json}
    WARNING_THRESHOLD=${WARNING_THRESHOLD:-80}
    DAILY_REPORT_HOUR=${DAILY_REPORT_HOUR:-9}

    # 流量统计模式：egress（出站，默认）、ingress（入站）、both（双向）
    TRAFFIC_COUNT_MODE=${TRAFFIC_COUNT_MODE:-egress}
    # 校验模式值
    if [[ "$TRAFFIC_COUNT_MODE" != "egress" && "$TRAFFIC_COUNT_MODE" != "ingress" && "$TRAFFIC_COUNT_MODE" != "both" ]]; then
        log "WARN" "TRAFFIC_COUNT_MODE 无效，使用默认值 egress"
        TRAFFIC_COUNT_MODE="egress"
    fi

    # 计算流量限制（字节）
    # 优先使用 MB，其次使用 GB
    if [[ -n "$TRAFFIC_LIMIT_MB" && "$TRAFFIC_LIMIT_MB" =~ ^[0-9]+$ && "$TRAFFIC_LIMIT_MB" -gt 0 ]]; then
        TRAFFIC_LIMIT_BYTES=$((TRAFFIC_LIMIT_MB * 1048576))
        TRAFFIC_LIMIT_DISPLAY="${TRAFFIC_LIMIT_MB} MB"
    elif [[ -n "$TRAFFIC_LIMIT_GB" && "$TRAFFIC_LIMIT_GB" =~ ^[0-9]+$ && "$TRAFFIC_LIMIT_GB" -gt 0 ]]; then
        TRAFFIC_LIMIT_BYTES=$((TRAFFIC_LIMIT_GB * 1073741824))
        TRAFFIC_LIMIT_DISPLAY="${TRAFFIC_LIMIT_GB} GB"
    else
        # 默认 190GB
        TRAFFIC_LIMIT_GB=190
        TRAFFIC_LIMIT_BYTES=$((190 * 1073741824))
        TRAFFIC_LIMIT_DISPLAY="190 GB"
        log "WARN" "流量限制配置无效，使用默认值 190 GB"
    fi

    # 校验警告阈值
    if ! [[ "$WARNING_THRESHOLD" =~ ^[0-9]+$ ]] || (( WARNING_THRESHOLD < 1 || WARNING_THRESHOLD > 99 )); then
        WARNING_THRESHOLD=80
    fi
}

# 日志函数
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# 确保数据目录存在
ensure_data_dir() {
    local data_dir=$(dirname "$DATA_FILE")
    if [[ ! -d "$data_dir" ]]; then
        mkdir -p "$data_dir"
    fi
}

# 获取当前流量 (字节)
get_current_traffic() {
    local rx_bytes=0
    local tx_bytes=0

    if [[ -f "/sys/class/net/${NETWORK_INTERFACE}/statistics/rx_bytes" ]]; then
        rx_bytes=$(cat "/sys/class/net/${NETWORK_INTERFACE}/statistics/rx_bytes")
        tx_bytes=$(cat "/sys/class/net/${NETWORK_INTERFACE}/statistics/tx_bytes")
    else
        # 备用方法：使用 /proc/net/dev
        local stats=$(grep "${NETWORK_INTERFACE}:" /proc/net/dev | awk '{print $2, $10}')
        rx_bytes=$(echo $stats | awk '{print $1}')
        tx_bytes=$(echo $stats | awk '{print $2}')
    fi

    echo "$rx_bytes $tx_bytes"
}

# 字节转换为可读格式
bytes_to_human() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        echo "$(echo "scale=2; $bytes / 1073741824" | bc) GB"
    elif (( bytes >= 1048576 )); then
        echo "$(echo "scale=2; $bytes / 1048576" | bc) MB"
    elif (( bytes >= 1024 )); then
        echo "$(echo "scale=2; $bytes / 1024" | bc) KB"
    else
        echo "${bytes} B"
    fi
}

# 读取已保存的流量数据
read_saved_data() {
    if [[ -f "$DATA_FILE" ]]; then
        cat "$DATA_FILE"
    else
        echo '{}'
    fi
}

# 保存流量数据
save_data() {
    local data=$1
    ensure_data_dir
    echo "$data" > "$DATA_FILE"
}

# 获取本月流量使用量
get_monthly_traffic() {
    local current_month=$(date '+%Y-%m')
    local saved_data=$(read_saved_data)

    # 读取当前接口流量
    local traffic_info=$(get_current_traffic)
    local current_rx=$(echo $traffic_info | awk '{print $1}')
    local current_tx=$(echo $traffic_info | awk '{print $2}')

    # 获取已保存的数据
    local saved_month=$(echo "$saved_data" | jq -r '.month // ""' 2>/dev/null || echo "")
    local baseline_rx=$(echo "$saved_data" | jq -r '.baseline_rx // "0"' 2>/dev/null || echo "0")
    local baseline_tx=$(echo "$saved_data" | jq -r '.baseline_tx // "0"' 2>/dev/null || echo "0")
    local accumulated_rx=$(echo "$saved_data" | jq -r '.accumulated_rx // "0"' 2>/dev/null || echo "0")
    local accumulated_tx=$(echo "$saved_data" | jq -r '.accumulated_tx // "0"' 2>/dev/null || echo "0")

    # 如果是新月份，重置基线
    if [[ "$saved_month" != "$current_month" ]]; then
        log "INFO" "新月份检测到，重置流量计数器"
        baseline_rx=$current_rx
        baseline_tx=$current_tx
        accumulated_rx=0
        accumulated_tx=0

        # 同时解除流量限制
        unblock_traffic
    fi

    # 处理系统重启导致的计数器重置
    if (( current_rx < baseline_rx )) || (( current_tx < baseline_tx )); then
        log "INFO" "检测到计数器重置（可能是系统重启），累加之前的流量"
        accumulated_rx=$((accumulated_rx + baseline_rx))
        accumulated_tx=$((accumulated_tx + baseline_tx))
        baseline_rx=$current_rx
        baseline_tx=$current_tx
    fi

    # 计算本月总流量
    local month_rx=$((current_rx - baseline_rx + accumulated_rx))
    local month_tx=$((current_tx - baseline_tx + accumulated_tx))

    # 根据统计模式计算计费流量
    local total_bytes
    case "$TRAFFIC_COUNT_MODE" in
        egress)
            # 只统计出站流量（Google Cloud 计费方式）
            total_bytes=$month_tx
            ;;
        ingress)
            # 只统计入站流量
            total_bytes=$month_rx
            ;;
        both|*)
            # 统计双向流量
            total_bytes=$((month_rx + month_tx))
            ;;
    esac

    # 保存更新后的数据
    local new_data=$(jq -n \
        --arg month "$current_month" \
        --arg baseline_rx "$baseline_rx" \
        --arg baseline_tx "$baseline_tx" \
        --arg accumulated_rx "$accumulated_rx" \
        --arg accumulated_tx "$accumulated_tx" \
        --arg last_check "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{
            month: $month,
            baseline_rx: $baseline_rx,
            baseline_tx: $baseline_tx,
            accumulated_rx: $accumulated_rx,
            accumulated_tx: $accumulated_tx,
            last_check: $last_check
        }')
    save_data "$new_data"

    echo "$month_rx $month_tx $total_bytes"
}

# 阻断流量（保留SSH）- 同时处理 IPv4 和 IPv6
block_traffic() {
    # 安全检查
    if ! validate_interface; then
        log "ERROR" "网络接口验证失败，取消阻断操作"
        return 1
    fi

    if ! validate_ssh_port; then
        log "WARN" "SSH 端口验证失败，但仍将继续阻断（使用配置的端口: $SSH_PORT）"
    fi

    log "WARN" "开始阻断流量，保留 SSH 端口 $SSH_PORT"

    # 备份当前 iptables 规则
    iptables-save > /var/lib/traffic-limit/iptables_backup_$(date +%Y%m%d_%H%M%S).rules 2>/dev/null || true
    ip6tables-save > /var/lib/traffic-limit/ip6tables_backup_$(date +%Y%m%d_%H%M%S).rules 2>/dev/null || true

    # === IPv4 规则 ===
    # 创建流量限制链（如果不存在）
    iptables -N TRAFFIC_LIMIT 2>/dev/null || true
    iptables -F TRAFFIC_LIMIT

    # 允许本地回环
    iptables -A TRAFFIC_LIMIT -i lo -j ACCEPT
    iptables -A TRAFFIC_LIMIT -o lo -j ACCEPT

    # 允许已建立的连接（这条规则很重要，保证当前 SSH 会话不断）
    iptables -A TRAFFIC_LIMIT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # 允许 SSH（支持多端口，以防万一）
    iptables -A TRAFFIC_LIMIT -p tcp --dport $SSH_PORT -j ACCEPT
    iptables -A TRAFFIC_LIMIT -p tcp --sport $SSH_PORT -j ACCEPT
    # 同时允许默认 22 端口（安全冗余）
    if [[ "$SSH_PORT" != "22" ]]; then
        iptables -A TRAFFIC_LIMIT -p tcp --dport 22 -j ACCEPT
        iptables -A TRAFFIC_LIMIT -p tcp --sport 22 -j ACCEPT
    fi

    # 允许 DNS（用于基本解析）
    iptables -A TRAFFIC_LIMIT -p udp --dport 53 -j ACCEPT
    iptables -A TRAFFIC_LIMIT -p udp --sport 53 -j ACCEPT

    # 允许 ICMP (ping)，用于网络诊断
    iptables -A TRAFFIC_LIMIT -p icmp -j ACCEPT

    # 允许 Telegram API（用于发送通知）
    iptables -A TRAFFIC_LIMIT -d 149.154.160.0/20 -j ACCEPT
    iptables -A TRAFFIC_LIMIT -d 91.108.4.0/22 -j ACCEPT

    # 阻断其他所有流量
    iptables -A TRAFFIC_LIMIT -j DROP

    # 检查是否已经引用了 TRAFFIC_LIMIT 链
    if ! iptables -C INPUT -j TRAFFIC_LIMIT 2>/dev/null; then
        iptables -I INPUT 1 -j TRAFFIC_LIMIT
    fi
    if ! iptables -C OUTPUT -j TRAFFIC_LIMIT 2>/dev/null; then
        iptables -I OUTPUT 1 -j TRAFFIC_LIMIT
    fi

    # === IPv6 规则 ===
    if command -v ip6tables &> /dev/null; then
        ip6tables -N TRAFFIC_LIMIT 2>/dev/null || true
        ip6tables -F TRAFFIC_LIMIT

        # 允许本地回环
        ip6tables -A TRAFFIC_LIMIT -i lo -j ACCEPT
        ip6tables -A TRAFFIC_LIMIT -o lo -j ACCEPT

        # 允许已建立的连接
        ip6tables -A TRAFFIC_LIMIT -m state --state ESTABLISHED,RELATED -j ACCEPT

        # 允许 SSH
        ip6tables -A TRAFFIC_LIMIT -p tcp --dport $SSH_PORT -j ACCEPT
        ip6tables -A TRAFFIC_LIMIT -p tcp --sport $SSH_PORT -j ACCEPT
        if [[ "$SSH_PORT" != "22" ]]; then
            ip6tables -A TRAFFIC_LIMIT -p tcp --dport 22 -j ACCEPT
            ip6tables -A TRAFFIC_LIMIT -p tcp --sport 22 -j ACCEPT
        fi

        # 允许 DNS
        ip6tables -A TRAFFIC_LIMIT -p udp --dport 53 -j ACCEPT
        ip6tables -A TRAFFIC_LIMIT -p udp --sport 53 -j ACCEPT

        # 允许 ICMPv6（IPv6 需要 ICMPv6 才能正常工作）
        ip6tables -A TRAFFIC_LIMIT -p icmpv6 -j ACCEPT

        # 阻断其他所有流量
        ip6tables -A TRAFFIC_LIMIT -j DROP

        if ! ip6tables -C INPUT -j TRAFFIC_LIMIT 2>/dev/null; then
            ip6tables -I INPUT 1 -j TRAFFIC_LIMIT
        fi
        if ! ip6tables -C OUTPUT -j TRAFFIC_LIMIT 2>/dev/null; then
            ip6tables -I OUTPUT 1 -j TRAFFIC_LIMIT
        fi

        log "INFO" "IPv6 规则已应用"
    fi

    # 标记已阻断
    touch /var/lib/traffic-limit/blocked

    # 持久化 iptables 规则（重启后仍生效）
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save 2>/dev/null || true
    elif command -v iptables-save &> /dev/null; then
        iptables-save > /etc/iptables.rules 2>/dev/null || true
        ip6tables-save > /etc/ip6tables.rules 2>/dev/null || true
    fi

    log "WARN" "流量已阻断，仅保留 SSH 连接"
}

# 解除流量阻断（同时处理 IPv4 和 IPv6）
unblock_traffic() {
    log "INFO" "解除流量阻断"

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

    # 持久化 iptables 规则（确保重启后不会恢复阻断状态）
    if command -v netfilter-persistent &> /dev/null; then
        netfilter-persistent save 2>/dev/null || true
    fi

    log "INFO" "流量限制已解除"
}

# 检查是否已阻断
is_blocked() {
    [[ -f /var/lib/traffic-limit/blocked ]]
}

# 发送 Telegram 通知
send_telegram() {
    local message=$1

    if [[ "$ENABLE_TELEGRAM" != "true" ]]; then
        return
    fi

    if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
        log "WARN" "Telegram 配置不完整，跳过通知"
        return
    fi

    # 发送消息
    curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "text=${message}" \
        -d "parse_mode=Markdown" \
        > /dev/null 2>&1 || log "WARN" "Telegram 通知发送失败"
}

# 发送通知（支持多种方式）
send_notification() {
    local subject=$1
    local message=$2
    local notify_type=${3:-alert}  # alert, warning, daily

    # 添加服务器名称标识
    local server_tag="🖥️ *${SERVER_NAME}*"

    # Telegram 通知
    if [[ "$ENABLE_TELEGRAM" == "true" ]]; then
        local tg_message="${server_tag}"$'\n'"*${subject}*"$'\n\n'"${message}"
        send_telegram "$tg_message"
    fi

    # 邮件通知
    if [[ "$ENABLE_EMAIL" == "true" ]] && command -v mail &> /dev/null; then
        echo "[${SERVER_NAME}] $message" | mail -s "[${SERVER_NAME}] $subject" "$EMAIL_ADDRESS"
    fi
}

# 显示状态
show_status() {
    load_config
    ensure_data_dir

    local traffic_info=$(get_monthly_traffic)
    local month_rx=$(echo $traffic_info | awk '{print $1}')
    local month_tx=$(echo $traffic_info | awk '{print $2}')
    local total_bytes=$(echo $traffic_info | awk '{print $3}')

    local limit_bytes=$TRAFFIC_LIMIT_BYTES
    local percentage=$(echo "scale=2; $total_bytes * 100 / $limit_bytes" | bc)

    # 统计模式显示
    local mode_display
    case "$TRAFFIC_COUNT_MODE" in
        egress)  mode_display="出站 (egress)" ;;
        ingress) mode_display="入站 (ingress)" ;;
        both)    mode_display="双向 (both)" ;;
    esac

    echo "======================================"
    echo "     Google Cloud 流量监控状态"
    echo "======================================"
    echo ""
    echo "服务器名称:  $SERVER_NAME"
    echo "网络接口:    $NETWORK_INTERFACE"
    echo "统计模式:    $mode_display"
    echo "流量限制:    ${TRAFFIC_LIMIT_DISPLAY}"
    echo ""
    echo "本月下载:    $(bytes_to_human $month_rx)"
    echo "本月上传:    $(bytes_to_human $month_tx)"
    echo "计费流量:    $(bytes_to_human $total_bytes)"
    echo ""
    echo "已用比例:    ${percentage}%"
    echo ""

    if is_blocked; then
        echo "当前状态:    🔴 已阻断（仅SSH可用）"
    else
        echo "当前状态:    🟢 正常"
    fi

    echo ""
    echo "重置日期:    每月 ${RESET_DAY} 号"
    echo "======================================"
}

# 主检查循环
check_traffic() {
    # 获取锁，防止并发
    acquire_lock
    trap release_lock EXIT

    load_config
    ensure_data_dir

    # 校验网卡是否存在
    if ! validate_interface; then
        log "ERROR" "网卡校验失败，跳过本次检查"
        return 1
    fi

    local traffic_info=$(get_monthly_traffic)
    local month_rx=$(echo $traffic_info | awk '{print $1}')
    local month_tx=$(echo $traffic_info | awk '{print $2}')
    local total_bytes=$(echo $traffic_info | awk '{print $3}')
    local limit_bytes=$TRAFFIC_LIMIT_BYTES

    # 校验流量数据有效性
    if [[ -z "$total_bytes" || "$total_bytes" == "0" ]] && [[ -z "$month_rx" || "$month_rx" == "0" ]]; then
        log "WARN" "流量统计为 0，可能网卡配置错误或刚重启"
    fi

    local percentage=$(echo "scale=2; $total_bytes * 100 / $limit_bytes" | bc 2>/dev/null || echo "0")
    local percentage_int=$(echo "$total_bytes * 100 / $limit_bytes" | bc 2>/dev/null || echo "0")

    log "INFO" "当前流量使用: $(bytes_to_human $total_bytes) / ${TRAFFIC_LIMIT_DISPLAY} (${percentage}%)"

    # 检查是否需要阻断
    if (( $(echo "$total_bytes >= $limit_bytes" | bc -l) )); then
        if ! is_blocked; then
            log "WARN" "流量超过限制！开始阻断..."
            block_traffic

            local msg="🚫 *流量已超限*

📊 已用: $(bytes_to_human $total_bytes) / ${TRAFFIC_LIMIT_DISPLAY}
📥 下载: $(bytes_to_human $month_rx)
📤 上传: $(bytes_to_human $month_tx)

⚠️ 网络已阻断，仅保留 SSH
🔄 下月 ${RESET_DAY} 号自动恢复"
            send_notification "🚫 流量超限警告" "$msg"
        fi
        return
    fi

    # 警告通知（仅在跨越阈值时发送一次）
    local warning_bytes=$(echo "$limit_bytes * $WARNING_THRESHOLD / 100" | bc)
    local warning_sent_file="/var/lib/traffic-limit/warning_sent_${percentage_int}"

    if (( $(echo "$total_bytes >= $warning_bytes" | bc -l) )); then
        # 每 10% 发一次警告
        local threshold_level=$((percentage_int / 10 * 10))
        local threshold_file="/var/lib/traffic-limit/warning_sent_${threshold_level}"

        if [[ ! -f "$threshold_file" ]] && (( threshold_level >= WARNING_THRESHOLD )); then
            touch "$threshold_file"
            log "WARN" "流量使用已达 ${percentage}%，接近限制"

            local msg="⚠️ *流量警告*

📊 已用: $(bytes_to_human $total_bytes) / ${TRAFFIC_LIMIT_DISPLAY} (${percentage}%)
📥 下载: $(bytes_to_human $month_rx)
📤 上传: $(bytes_to_human $month_tx)

剩余: $(bytes_to_human $((limit_bytes - total_bytes)))"
            send_notification "⚠️ 流量警告 ${percentage}%" "$msg"
        fi
    fi

    # 每日报告
    check_daily_report "$month_rx" "$month_tx" "$total_bytes" "$percentage"
}

# 每日报告
check_daily_report() {
    local month_rx=$1
    local month_tx=$2
    local total_bytes=$3
    local percentage=$4

    if [[ "$ENABLE_DAILY_REPORT" != "true" ]]; then
        return
    fi

    local current_hour=$(date +%H)
    local today=$(date +%Y-%m-%d)
    local report_file="/var/lib/traffic-limit/daily_report_${today}"

    # 检查是否已发送今日报告
    if [[ -f "$report_file" ]]; then
        return
    fi

    # 检查是否到达报告时间（两边都用 10# 处理前导零）
    if (( 10#$current_hour == 10#$DAILY_REPORT_HOUR )); then
        touch "$report_file"

        local limit_bytes=$TRAFFIC_LIMIT_BYTES
        local remaining=$((limit_bytes - total_bytes))

        local status_icon="🟢"
        if is_blocked; then
            status_icon="🔴"
        elif (( $(echo "$total_bytes >= $limit_bytes * $WARNING_THRESHOLD / 100" | bc -l) )); then
            status_icon="🟡"
        fi

        local msg="📊 *每日流量报告*

${status_icon} 状态: $(is_blocked && echo '已阻断' || echo '正常')
📅 日期: $(date '+%Y-%m-%d %H:%M')

📥 下载: $(bytes_to_human $month_rx)
📤 上传: $(bytes_to_human $month_tx)
📊 总计: $(bytes_to_human $total_bytes)

📈 已用: ${percentage}%
📉 剩余: $(bytes_to_human $remaining)"
        send_notification "📊 每日流量报告" "$msg"

        # 清理旧的报告标记和警告标记
        find /var/lib/traffic-limit -name "daily_report_*" -mtime +7 -delete 2>/dev/null || true
    fi
}

# 发送测试通知
test_notification() {
    load_config

    local msg="✅ *测试通知*

Telegram 通知配置成功！

🖥️ 服务器: $(hostname)
📅 时间: $(date '+%Y-%m-%d %H:%M:%S')"

    echo "正在发送测试通知..."
    send_notification "✅ 测试通知" "$msg"
    echo "测试通知已发送，请检查 Telegram"
}

# 手动重置（危险操作，仅用于调试）
manual_reset() {
    read -p "确定要手动重置流量计数器吗？(yes/no): " confirm
    if [[ "$confirm" == "yes" ]]; then
        rm -f "$DATA_FILE"
        unblock_traffic
        log "INFO" "手动重置完成"
        echo "流量计数器已重置"
    else
        echo "操作已取消"
    fi
}

# 重载配置到 systemd timer
reload_config() {
    load_config

    local systemd_dir="/etc/systemd/system"

    # 校验 CHECK_INTERVAL
    if ! [[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]] || (( CHECK_INTERVAL < 1 || CHECK_INTERVAL > 60 )); then
        log "ERROR" "CHECK_INTERVAL 无效（需要 1-60），使用默认值 5"
        CHECK_INTERVAL=5
    fi

    # 校验 RESET_DAY
    if ! [[ "$RESET_DAY" =~ ^[0-9]+$ ]] || (( RESET_DAY < 1 || RESET_DAY > 28 )); then
        log "ERROR" "RESET_DAY 无效（需要 1-28），使用默认值 1"
        RESET_DAY=1
    fi

    # 更新 traffic-limit.timer
    sed -i "s/OnUnitActiveSec=.*/OnUnitActiveSec=${CHECK_INTERVAL}min/" "$systemd_dir/traffic-limit.timer"
    log "INFO" "检查间隔已更新为 ${CHECK_INTERVAL} 分钟"

    # 更新 traffic-reset.timer
    local reset_day_padded=$(printf "%02d" "$RESET_DAY")
    sed -i "s/OnCalendar=.*/OnCalendar=*-*-${reset_day_padded} 00:05:00/" "$systemd_dir/traffic-reset.timer"
    log "INFO" "重置日期已更新为每月 ${reset_day_padded} 号"

    # 重载 systemd
    systemctl daemon-reload
    systemctl restart traffic-limit.timer
    systemctl restart traffic-reset.timer

    echo "配置已重载，定时器已重启"
    systemctl list-timers traffic-limit.timer traffic-reset.timer --no-pager
}

# 帮助信息
show_help() {
    echo "用法: $0 [命令]"
    echo ""
    echo "命令:"
    echo "  status     显示当前流量状态"
    echo "  check      检查流量并执行限制（由定时任务调用）"
    echo "  block      手动阻断流量"
    echo "  unblock    手动解除阻断"
    echo "  reset      手动重置流量计数器（危险）"
    echo "  reload     重载配置文件到 systemd 定时器"
    echo "  test       发送测试通知到 Telegram"
    echo "  help       显示此帮助信息"
    echo ""
    echo "配置文件: $CONFIG_FILE"
}

# 主函数
main() {
    # 需要 root 权限
    if [[ $EUID -ne 0 ]]; then
        echo "此脚本需要 root 权限运行"
        exit 1
    fi

    # 检查依赖
    check_dependencies

    local command=${1:-status}

    case $command in
        status)
            show_status
            ;;
        check)
            check_traffic
            ;;
        block)
            load_config
            ensure_data_dir
            block_traffic
            ;;
        unblock)
            load_config
            ensure_data_dir
            unblock_traffic
            ;;
        reset)
            load_config
            ensure_data_dir
            manual_reset
            ;;
        reload)
            reload_config
            ;;
        test)
            test_notification
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            echo "未知命令: $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
