#!/usr/bin/env bash
# ==============================================================================
# install.sh — 飞牛OS WiFi 自愈脚本安装器
# 用法：sudo bash install.sh                    # 只安装文件，不启用守护
#       sudo bash install.sh --enable-watchdog  # 安装并启用自愈守护
#       sudo bash install.sh --uninstall       # 卸载
# ==============================================================================

set -u
set -o pipefail

ENABLE_WATCHDOG=0
SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="/usr/local"
SBIN_DIR="$PREFIX/sbin"
UNIT_DIR="/etc/systemd/system"
CONF_DIR="$PREFIX/share/doc/wifi-watchdog"
NM_CONF="/etc/NetworkManager/conf.d/99-wifi-watchdog-no-random-mac.conf"
APP_CONF="/etc/wifi-watchdog.conf"
UNIT_NAME="wifi-watchdog.service"
IFACE="wlan0"

die() { echo "错误: $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }

# 将字符串转成可直接被 shell 解析的字面量（bash 内建 %q，无外部依赖）
shell_quote() {
    printf '%q' "$1"
}

uninstall() {
    command -v systemctl >/dev/null 2>&1 || die "找不到 systemctl"
    info "停止并禁用 wifi-watchdog 服务"
    systemctl stop "$UNIT_NAME" >/dev/null 2>&1 || true
    systemctl disable "$UNIT_NAME" >/dev/null 2>&1 || true
    info "删除已安装文件"
    rm -f "$UNIT_DIR/$UNIT_NAME" "$SBIN_DIR/wifi-watchdog" "$NM_CONF"
    rm -rf "$CONF_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ -f "$APP_CONF" ]]; then
        mv -f "$APP_CONF" "${APP_CONF}.bak" 2>/dev/null || true
        info "配置文件已保留为 ${APP_CONF}.bak"
    fi
    info "日志 /var/log/wifi-watchdog.log 与状态目录未删除，可自行清理"
    info "卸载完成。注意：NetworkManager 需重启后随机 MAC 设置才会恢复默认：sudo systemctl restart NetworkManager"
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --uninstall) uninstall ;;
        --enable-watchdog) ENABLE_WATCHDOG=1 ;;
        -h|--help)
            sed -n '2,6p' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *) die "未知参数: $arg" ;;
    esac
done
[[ $EUID -eq 0 ]] || die "请用 root 运行：sudo bash $0"

for f in wifi-watchdog.sh wifi-watchdog.service wifi-watchdog.conf.example; do
    [[ -f "$SRC_DIR/$f" ]] || die "缺少源文件 $SRC_DIR/$f"
done
command -v systemctl >/dev/null 2>&1 || die "找不到 systemctl"
command -v nmcli >/dev/null 2>&1 || die "找不到 nmcli（NetworkManager 未安装？）"

# ---------- 1. 识别现有 WiFi 连接 ----------
conn=$(nmcli -g GENERAL.CONNECTION device show "$IFACE" 2>/dev/null | tr -d '\r' | sed '/^--$/d')
if [[ -z "$conn" ]]; then
    conn=$(nmcli -t -f NAME,TYPE con show 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1; exit}')
fi
[[ -n "$conn" ]] || die "未找到 WiFi 连接配置，请先在飞牛OS 界面连接一次 WiFi"

ssid=$(nmcli -g 802-11-wireless.ssid con show "$conn" 2>/dev/null | tr -d '\r')
info "识别到 WiFi 连接: $conn (SSID: ${ssid:-未知})"

# ---------- 2. 安装脚本与 systemd 单元 ----------
mkdir -p "$SBIN_DIR" "$UNIT_DIR" "$CONF_DIR"
install -m 755 "$SRC_DIR/wifi-watchdog.sh" "$SBIN_DIR/wifi-watchdog"
install -m 644 "$SRC_DIR/wifi-watchdog.service" "$UNIT_DIR/$UNIT_NAME"
install -m 644 "$SRC_DIR/wifi-watchdog.conf.example" "$CONF_DIR/wifi-watchdog.conf.example"
if [[ -f "$SRC_DIR/README.md" ]]; then
    install -m 644 "$SRC_DIR/README.md" "$CONF_DIR/README.md"
fi
info "已安装程序到 $SBIN_DIR/wifi-watchdog 与 $UNIT_DIR/$UNIT_NAME"

# ---------- 3. 生成配置文件（不覆盖已有配置） ----------
if [[ -f "$APP_CONF" ]]; then
    warn "配置文件 $APP_CONF 已存在，保留原有内容（如需重置请先改名备份）"
else
    tmp=$(mktemp)
    {
        echo "# wifi-watchdog 配置（安装脚本自动生成，可按需修改）"
        echo "WIFI_IFACE=$(shell_quote "$IFACE")"
        echo "WIFI_CONNECTION=$(shell_quote "$conn")"
        echo "WIFI_SSID=$(shell_quote "$ssid")"
        echo 'PING_TARGET=""'
        echo "CHECK_INTERVAL=30"
        echo "FAIL_THRESHOLD=3"
        echo "RESET_COOLDOWN=120"
        echo "MAX_RESETS_PER_HOUR=6"
        echo "AUTO_REBOOT=0"
        echo "REBOOT_AFTER_FAILS=6"
        echo "DRIVER_RESET=0"
        echo 'DRIVER_MODULE="brcmfmac"'
        echo 'LOG_FILE="/var/log/wifi-watchdog.log"'
        echo "LOG_MAX_KB=1024"
    } > "$tmp"
    install -m 644 "$tmp" "$APP_CONF"
    rm -f "$tmp"
    info "已生成配置 $APP_CONF"
fi

# ---------- 4 & 5. 自愈守护相关操作（默认不执行，完全可选） ----------
systemctl daemon-reload >/dev/null 2>&1 || true
if [[ $ENABLE_WATCHDOG -eq 1 ]]; then
    info "按 --enable-watchdog 要求，配置禁用随机 MAC 并启动自愈守护"
    info "写入 NetworkManager 配置并固定连接 MAC（会短暂断网约 5 秒）"
    "$SBIN_DIR/wifi-watchdog" --fix-mac || warn "固定 MAC 时出现问题，请查看日志"
    systemctl restart NetworkManager >/dev/null 2>&1 || warn "NetworkManager 重启失败"
    sleep 3
    systemctl enable "$UNIT_NAME" >/dev/null 2>&1 || die "启用服务失败"
    systemctl restart "$UNIT_NAME" >/dev/null 2>&1 || die "启动服务失败"
    sleep 2
else
    info "自愈守护未启用（仅安装了文件）。如需启用：sudo bash $0 --enable-watchdog"
fi

echo "------------------------------------------------------------"
if [[ $ENABLE_WATCHDOG -eq 0 ]]; then
    info "安装完成（守护未启用）。按需启用：sudo bash $0 --enable-watchdog"
elif systemctl is-active --quiet "$UNIT_NAME"; then
    info "安装完成，自愈守护运行中"
else
    warn "服务未处于运行状态，请执行：journalctl -u $UNIT_NAME -n 50"
fi
info "健康检查:  $SBIN_DIR/wifi-watchdog --check"
info "手动修复:  $SBIN_DIR/wifi-watchdog --repair"
info "查看日志:  tail -f /var/log/wifi-watchdog.log"
echo "------------------------------------------------------------"
