#!/bin/bash
#
# install.sh - 一键安装脚本
# One-click installation script
#
# 使用方法 / Usage:
#   curl -sSL https://raw.githubusercontent.com/YOUR_USERNAME/google-traffic-limit/main/install.sh | sudo bash
#   或者 / or:
#   wget -qO- https://raw.githubusercontent.com/YOUR_USERNAME/google-traffic-limit/main/install.sh | sudo bash
#

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 安装目录
INSTALL_DIR="/opt/traffic-limit"
SYSTEMD_DIR="/etc/systemd/system"

# 打印带颜色的消息
print_msg() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_info() {
    echo -e "${BLUE}[i]${NC} $1"
}

# 显示 Banner
show_banner() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}     Google Cloud 流量限制器 安装程序          ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}     Traffic Limit Installer for GCP           ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}"
    echo ""
}

# 检查是否为 root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "此脚本需要 root 权限运行"
        print_info "请使用: sudo $0"
        exit 1
    fi
}

# 检查系统
check_system() {
    if [[ ! -f /etc/os-release ]]; then
        print_error "无法检测操作系统"
        exit 1
    fi

    source /etc/os-release

    if [[ "$ID" != "ubuntu" && "$ID" != "debian" && "$ID_LIKE" != *"debian"* ]]; then
        print_warn "此脚本主要针对 Ubuntu/Debian 系统测试"
        print_warn "其他系统可能需要手动调整"
    fi

    print_msg "操作系统: $PRETTY_NAME"
}

# 安装依赖
install_dependencies() {
    print_info "安装依赖包..."

    apt-get update -qq

    # 安装必需的包
    apt-get install -y -qq \
        jq \
        bc \
        iptables \
        iptables-persistent \
        curl \
        wget \
        util-linux

    print_msg "依赖安装完成"
}

# 检测网络接口
detect_interface() {
    # 常见的 GCP 网络接口名称
    local interfaces=("ens4" "eth0" "enp0s3")

    for iface in "${interfaces[@]}"; do
        if ip link show "$iface" &> /dev/null; then
            echo "$iface"
            return
        fi
    done

    # 如果没找到，使用默认路由的接口
    ip route | grep default | awk '{print $5}' | head -n1
}

# 创建安装目录
create_directories() {
    print_info "创建目录..."

    mkdir -p "$INSTALL_DIR"
    mkdir -p /var/lib/traffic-limit
    mkdir -p /var/log

    print_msg "目录创建完成"
}

# 下载或复制文件
install_files() {
    print_info "安装程序文件..."

    # 获取脚本所在目录（如果是本地安装）
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # 检查是否本地安装
    if [[ -f "${script_dir}/traffic-limit.sh" ]]; then
        # 本地安装
        cp "${script_dir}/traffic-limit.sh" "$INSTALL_DIR/"
        cp "${script_dir}/monthly-reset.sh" "$INSTALL_DIR/"
        cp "${script_dir}/emergency-recovery.sh" "$INSTALL_DIR/"

        # 配置文件：优先使用 config.conf，否则使用 config.conf.example
        if [[ -f "${script_dir}/config.conf" ]]; then
            cp "${script_dir}/config.conf" "$INSTALL_DIR/"
        elif [[ -f "${script_dir}/config.conf.example" ]]; then
            cp "${script_dir}/config.conf.example" "$INSTALL_DIR/config.conf"
        fi

        cp "${script_dir}/systemd/"*.service "$SYSTEMD_DIR/"
        cp "${script_dir}/systemd/"*.timer "$SYSTEMD_DIR/"
    else
        # 远程安装 - 从 GitHub 下载
        local base_url="https://raw.githubusercontent.com/YOUR_USERNAME/google-traffic-limit/main"

        curl -sSL "$base_url/traffic-limit.sh" -o "$INSTALL_DIR/traffic-limit.sh"
        curl -sSL "$base_url/monthly-reset.sh" -o "$INSTALL_DIR/monthly-reset.sh"
        curl -sSL "$base_url/emergency-recovery.sh" -o "$INSTALL_DIR/emergency-recovery.sh"
        curl -sSL "$base_url/config.conf.example" -o "$INSTALL_DIR/config.conf"

        curl -sSL "$base_url/systemd/traffic-limit.service" -o "$SYSTEMD_DIR/traffic-limit.service"
        curl -sSL "$base_url/systemd/traffic-limit.timer" -o "$SYSTEMD_DIR/traffic-limit.timer"
        curl -sSL "$base_url/systemd/traffic-reset.service" -o "$SYSTEMD_DIR/traffic-reset.service"
        curl -sSL "$base_url/systemd/traffic-reset.timer" -o "$SYSTEMD_DIR/traffic-reset.timer"
    fi

    # 设置执行权限
    chmod +x "$INSTALL_DIR/traffic-limit.sh"
    chmod +x "$INSTALL_DIR/monthly-reset.sh"
    chmod +x "$INSTALL_DIR/emergency-recovery.sh"

    # 保护配置文件（只有 root 可读写，防止 Token 泄露）
    chmod 600 "$INSTALL_DIR/config.conf"

    print_msg "程序文件安装完成"
}

# 配置网络接口
configure_interface() {
    local detected_iface=$(detect_interface)

    print_info "检测到网络接口: $detected_iface"

    # 更新配置文件
    sed -i "s/NETWORK_INTERFACE=.*/NETWORK_INTERFACE=$detected_iface/" "$INSTALL_DIR/config.conf"

    print_msg "网络接口配置完成"
}

# 配置流量限制
configure_limit() {
    echo ""
    print_info "配置流量限制..."
    echo ""

    # 服务器名称配置
    local current_name=$(grep "SERVER_NAME=" "$INSTALL_DIR/config.conf" | cut -d'=' -f2)
    read -p "服务器名称（用于通知识别）[$current_name]: " new_name

    if [[ -n "$new_name" ]]; then
        sed -i "s/SERVER_NAME=.*/SERVER_NAME=$new_name/" "$INSTALL_DIR/config.conf"
        print_msg "服务器名称已设置为 ${new_name}"
    fi

    # 读取当前配置
    local current_limit=$(grep "TRAFFIC_LIMIT_GB=" "$INSTALL_DIR/config.conf" | cut -d'=' -f2)

    echo -e "当前流量限制: ${YELLOW}${current_limit} GB${NC}"
    echo ""

    while true; do
        read -p "请输入新的流量限制 (GB，1-1000)，直接回车使用默认值 [$current_limit]: " new_limit
        new_limit=${new_limit:-$current_limit}

        # 校验：必须是 1-1000 之间的正整数
        if [[ "$new_limit" =~ ^[0-9]+$ ]] && (( new_limit >= 1 && new_limit <= 1000 )); then
            break
        else
            print_error "无效输入：流量限制必须是 1-1000 之间的整数"
        fi
    done
    sed -i "s/TRAFFIC_LIMIT_GB=.*/TRAFFIC_LIMIT_GB=$new_limit/" "$INSTALL_DIR/config.conf"
    print_msg "流量限制已设置为 ${new_limit} GB"

    # SSH 端口配置
    local current_ssh=$(grep "SSH_PORT=" "$INSTALL_DIR/config.conf" | cut -d'=' -f2)
    read -p "SSH 端口 [$current_ssh]: " new_ssh

    if [[ -n "$new_ssh" ]]; then
        sed -i "s/SSH_PORT=.*/SSH_PORT=$new_ssh/" "$INSTALL_DIR/config.conf"
        print_msg "SSH 端口已设置为 ${new_ssh}"
    fi

    # 检查间隔配置
    local current_interval=$(grep "CHECK_INTERVAL=" "$INSTALL_DIR/config.conf" | cut -d'=' -f2)
    while true; do
        read -p "检查间隔（分钟，1-60）[$current_interval]: " new_interval
        new_interval=${new_interval:-$current_interval}

        # 校验：必须是 1-60 之间的正整数
        if [[ "$new_interval" =~ ^[0-9]+$ ]] && (( new_interval >= 1 && new_interval <= 60 )); then
            break
        else
            print_error "无效输入：检查间隔必须是 1-60 之间的整数"
        fi
    done
    sed -i "s/CHECK_INTERVAL=.*/CHECK_INTERVAL=$new_interval/" "$INSTALL_DIR/config.conf"
    print_msg "检查间隔已设置为 ${new_interval} 分钟"

    # 重置日期配置
    local current_reset_day=$(grep "RESET_DAY=" "$INSTALL_DIR/config.conf" | cut -d'=' -f2)
    while true; do
        read -p "每月重置日期（1-28）[$current_reset_day]: " new_reset_day
        new_reset_day=${new_reset_day:-$current_reset_day}

        # 校验：必须是 1-28 之间的正整数
        if [[ "$new_reset_day" =~ ^[0-9]+$ ]] && (( new_reset_day >= 1 && new_reset_day <= 28 )); then
            break
        else
            print_error "无效输入：重置日期必须是 1-28 之间的整数"
        fi
    done
    sed -i "s/RESET_DAY=.*/RESET_DAY=$new_reset_day/" "$INSTALL_DIR/config.conf"
    print_msg "重置日期已设置为每月 ${new_reset_day} 号"

    # 更新 systemd timer 配置
    update_timer_config "$new_interval" "$new_reset_day"
}

# 更新 systemd timer 配置
update_timer_config() {
    local check_interval=$1
    local reset_day=$2

    print_info "更新定时器配置..."

    # 更新检查间隔
    sed -i "s/OnUnitActiveSec=.*/OnUnitActiveSec=${check_interval}min/" "$SYSTEMD_DIR/traffic-limit.timer"

    # 更新重置日期（补零处理）
    local reset_day_padded=$(printf "%02d" "$reset_day")
    sed -i "s/OnCalendar=.*/OnCalendar=*-*-${reset_day_padded} 00:05:00/" "$SYSTEMD_DIR/traffic-reset.timer"

    print_msg "定时器配置已更新"
}

# 启用 systemd 服务
enable_services() {
    print_info "启用系统服务..."

    # 重新加载 systemd
    systemctl daemon-reload

    # 启用并启动定时器
    systemctl enable traffic-limit.timer
    systemctl start traffic-limit.timer

    systemctl enable traffic-reset.timer
    systemctl start traffic-reset.timer

    print_msg "系统服务已启用"
}

# 创建命令别名
create_alias() {
    print_info "创建命令别名..."

    # 创建软链接
    ln -sf "$INSTALL_DIR/traffic-limit.sh" /usr/local/bin/traffic-limit

    print_msg "可使用 'sudo traffic-limit' 命令"
}

# 运行首次检查
run_first_check() {
    print_info "运行首次流量检查..."

    "$INSTALL_DIR/traffic-limit.sh" status

    echo ""
}

# 显示完成信息
show_completion() {
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}              安装完成！                        ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "常用命令:"
    echo -e "  ${BLUE}sudo traffic-limit status${NC}   - 查看流量状态"
    echo -e "  ${BLUE}sudo traffic-limit check${NC}    - 手动检查流量"
    echo -e "  ${BLUE}sudo traffic-limit block${NC}    - 手动阻断流量"
    echo -e "  ${BLUE}sudo traffic-limit unblock${NC}  - 解除阻断"
    echo ""
    echo -e "配置文件: ${YELLOW}$INSTALL_DIR/config.conf${NC}"
    echo -e "日志文件: ${YELLOW}/var/log/traffic-limit.log${NC}"
    echo ""
    echo -e "系统定时器状态:"
    systemctl list-timers traffic-limit.timer traffic-reset.timer --no-pager
    echo ""
}

# 卸载函数
uninstall() {
    print_info "开始卸载..."

    # 停止并禁用服务
    systemctl stop traffic-limit.timer 2>/dev/null || true
    systemctl stop traffic-reset.timer 2>/dev/null || true
    systemctl disable traffic-limit.timer 2>/dev/null || true
    systemctl disable traffic-reset.timer 2>/dev/null || true

    # 解除流量阻断
    "$INSTALL_DIR/traffic-limit.sh" unblock 2>/dev/null || true

    # 删除文件
    rm -rf "$INSTALL_DIR"
    rm -f "$SYSTEMD_DIR/traffic-limit.service"
    rm -f "$SYSTEMD_DIR/traffic-limit.timer"
    rm -f "$SYSTEMD_DIR/traffic-reset.service"
    rm -f "$SYSTEMD_DIR/traffic-reset.timer"
    rm -f /usr/local/bin/traffic-limit

    # 重新加载 systemd
    systemctl daemon-reload

    print_msg "卸载完成"
}

# 主函数
main() {
    show_banner

    # 处理命令行参数
    case "${1:-}" in
        uninstall|remove)
            check_root
            uninstall
            exit 0
            ;;
        --help|-h)
            echo "用法: $0 [uninstall]"
            echo ""
            echo "  不带参数  - 安装流量限制器"
            echo "  uninstall - 卸载流量限制器"
            exit 0
            ;;
    esac

    check_root
    check_system
    install_dependencies
    create_directories
    install_files
    configure_interface
    configure_limit
    enable_services
    create_alias
    run_first_check
    show_completion
}

main "$@"
