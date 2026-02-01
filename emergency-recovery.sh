#!/bin/bash
#
# emergency-recovery.sh - 紧急恢复脚本
# Emergency Recovery Script
#
# 用途：如果因为流量限制被锁在服务器外面，可以通过 GCP 控制台的串口控制台运行此脚本
#
# 使用方法：
# 1. 登录 Google Cloud Console
# 2. 进入 Compute Engine -> VM 实例
# 3. 点击实例名称 -> 连接到串口控制台
# 4. 运行: sudo /opt/traffic-limit/emergency-recovery.sh
#

echo "=========================================="
echo "     紧急恢复脚本 - Emergency Recovery"
echo "=========================================="
echo ""

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 权限运行: sudo $0"
    exit 1
fi

echo "[1/4] 清除所有 iptables 规则..."

# === IPv4 ===
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# === IPv6 ===
if command -v ip6tables &> /dev/null; then
    echo "    清除 IPv6 规则..."
    ip6tables -F
    ip6tables -X
    ip6tables -t nat -F 2>/dev/null || true
    ip6tables -t nat -X 2>/dev/null || true
    ip6tables -t mangle -F
    ip6tables -t mangle -X
    ip6tables -P INPUT ACCEPT
    ip6tables -P FORWARD ACCEPT
    ip6tables -P OUTPUT ACCEPT
fi

echo "[2/4] 删除阻断标记..."
rm -f /var/lib/traffic-limit/blocked

echo "[3/4] 保存 iptables 规则..."
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
fi

echo "[4/4] 完成！"
echo ""
echo "网络已恢复正常，现在可以通过 SSH 登录了。"
echo ""
echo "如果要禁用流量限制服务，请运行："
echo "  sudo systemctl stop traffic-limit.timer"
echo "  sudo systemctl disable traffic-limit.timer"
echo ""
