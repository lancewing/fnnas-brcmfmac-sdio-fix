#!/usr/bin/env bash
# ==============================================================================
# wifi-watchdog.sh — 飞牛OS WiFi 网络自愈守护脚本
#
# 作用：持续检测 wlan0 的连接健康度，出现「连不上 / 掉线 / 无 IP / 网关不通」
#       时自动执行分级修复（软重连 -> WiFi 网络重置 -> 无线驱动重置）。
# 特性：全程禁用 MAC 随机化，扫描和关联都使用设备真实 MAC 地址。
# 适用：NetworkManager 1.x + wpa_supplicant（飞牛OS / Debian 系）。
#
# 由 WorkBuddy 协助编写与验证。项目地址: https://github.com/<your-name>/fnnas-brcmfmac-sdio-fix
# ==============================================================================

set -u
set -o pipefail

NAME="wifi-watchdog"
VERSION="1.0.0"

# ---------------------- 默认配置（可被配置文件覆盖）----------------------
WIFI_IFACE="wlan0"               # 无线网卡接口名
WIFI_CONNECTION=""               # NetworkManager 连接名；留空则自动识别
WIFI_SSID=""                     # 目标 SSID；用于自动识别连接，可留空
PING_TARGET=""                   # 探测目标；留空则自动使用默认网关
CHECK_INTERVAL=30                # 健康检查周期（秒）
FAIL_THRESHOLD=3                 # 连续失败多少次才触发修复
RESET_COOLDOWN=120               # 两次修复之间的最小间隔（秒）
MAX_RESETS_PER_HOUR=6            # 每小时最多修复次数，防止反复重启网络
AUTO_REBOOT=0                    # 是否允许最终自动重启系统（0=否，1=是）
REBOOT_AFTER_FAILS=6             # 连续失败达到该次数才允许自动重启
DRIVER_RESET=0                   # 是否启用无线驱动重载（0=否，1=是）
DRIVER_MODULE="brcmfmac"         # 无线驱动模块名（brcmfmac / iwlwifi / mt76 等，按实际填写）
LOG_FILE="/var/log/wifi-watchdog.log"   # 日志文件；设为 none 关闭文件日志
LOG_MAX_KB=1024                  # 单个日志文件超过该大小后轮转
DRY_RUN=0                        # 1=只打印不执行（调试用）

CONF_FILE="${WIFI_WATCHDOG_CONF:-/etc/wifi-watchdog.conf}"
NM_CONF_DIR="/etc/NetworkManager/conf.d"
NM_CONF_FILE="$NM_CONF_DIR/99-wifi-watchdog-no-random-mac.conf"
STATE_DIR="/var/lib/wifi-watchdog"
RESET_LOG="$STATE_DIR/reset-times"
LOCK_FILE="/run/wifi-watchdog.lock"

# ------------------------------ 载入配置 ------------------------------
if [[ -r "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$CONF_FILE"
fi

# ------------------------------ 通用函数 ------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

rotate_log() {
    [[ -n "$LOG_FILE" && "$LOG_FILE" != "none" && -f "$LOG_FILE" ]] || return 0
    local kb
    kb=$(du -k "$LOG_FILE" 2>/dev/null | awk '{print $1}')
    if [[ -n "${kb:-}" && "$kb" -ge "$LOG_MAX_KB" ]]; then
        mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null || true
        : > "$LOG_FILE" 2>/dev/null || true
    fi
}

log() {
    local level="$1"; shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
    printf '%s\n' "$line"
    if [[ -n "$LOG_FILE" && "$LOG_FILE" != "none" ]]; then
        printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
        rotate_log
    fi
}

# ------------------------ 识别 WiFi 连接配置 ------------------------
resolve_connection() {
    [[ -n "$WIFI_CONNECTION" ]] && return 0
    have nmcli || { log ERROR "未找到 nmcli 命令"; return 1; }

    local current name type ssid
    current=$(nmcli -g GENERAL.CONNECTION device show "$WIFI_IFACE" 2>/dev/null || true)
    current=$(printf '%s' "$current" | tr -d '\r' | sed '/^--$/d')
    if [[ -n "$current" ]]; then
        WIFI_CONNECTION="$current"
        log INFO "自动识别当前连接: $WIFI_CONNECTION"
        return 0
    fi

    while IFS='|' read -r name type; do
        [[ -z "$name" ]] && continue
        [[ "$type" == "802-11-wireless" ]] || continue
        ssid=$(nmcli -g 802-11-wireless.ssid con show "$name" 2>/dev/null | tr -d '\r' || true)
        if [[ -n "$WIFI_SSID" && -n "$ssid" && "$ssid" != "$WIFI_SSID" ]]; then
            continue
        fi
        WIFI_CONNECTION="$name"
        [[ -z "$WIFI_SSID" && -n "$ssid" ]] && WIFI_SSID="$ssid"
        log INFO "自动识别 WiFi 配置: $WIFI_CONNECTION (SSID: ${WIFI_SSID:-未知})"
        return 0
    done < <(nmcli -t -f NAME,TYPE con show 2>/dev/null | tr ':' '|')

    log ERROR "未找到 WiFi 连接配置，请在 $CONF_FILE 中指定 WIFI_CONNECTION"
    return 1
}

# --------------------------- 健康状态检查 ---------------------------
# 返回 0 = 健康；非 0 = 异常
check_health() {
    have nmcli || return 1
    systemctl is-active --quiet NetworkManager 2>/dev/null || {
        log DEBUG "NetworkManager 未运行"; return 1; }
    ip link show dev "$WIFI_IFACE" >/dev/null 2>&1 || {
        log DEBUG "$WIFI_IFACE 接口不存在"; return 1; }

    local state conn ipaddr target
    state=$(nmcli -g GENERAL.STATE device show "$WIFI_IFACE" 2>/dev/null | grep -oE '[0-9]+' | head -1)
    [[ "${state:-}" == "100" ]] || {
        log DEBUG "WiFi 状态非 connected (state=${state:-未知})"; return 1; }

    conn=$(nmcli -g GENERAL.CONNECTION device show "$WIFI_IFACE" 2>/dev/null | tr -d '\r')
    [[ -n "$conn" && "$conn" != "--" ]] || {
        log DEBUG "没有激活的 WiFi 连接"; return 1; }

    ipaddr=$(ip -4 -o addr show dev "$WIFI_IFACE" 2>/dev/null | awk '{print $4}' | head -1)
    [[ -n "$ipaddr" ]] || {
        log DEBUG "WiFi 未获取到 IPv4 地址"; return 1; }

    target="$PING_TARGET"
    if [[ -z "$target" ]]; then
        target=$(ip -4 route show default dev "$WIFI_IFACE" 2>/dev/null | awk '$1=="default"{print $3; exit}')
    fi
    if [[ -n "$target" ]] && have ping; then
        if ! ping -q -c 1 -W 2 "$target" >/dev/null 2>&1; then
            log DEBUG "无法 ping 通网关 $target"; return 1
        fi
    fi
    return 0
}

# --------------------- 禁用随机 MAC（全局 + 单连接）---------------------
write_nm_conf() {
    log INFO "确保 NetworkManager 禁用 WiFi MAC 随机化"
    [[ "$DRY_RUN" -eq 1 ]] && { log DEBUG "DRY-RUN 跳过写配置文件"; return 0; }
    mkdir -p "$NM_CONF_DIR" 2>/dev/null || { log ERROR "无法创建 $NM_CONF_DIR"; return 1; }
    cat > "$NM_CONF_FILE" <<'EOF'
# 由 wifi-watchdog 生成：禁止 WiFi MAC 随机化，扫描与连接均使用真实 MAC
[main]
wifi.scan-rand-mac-address=false

[connection]
wifi.cloned-mac-address=permanent
EOF
    chmod 644 "$NM_CONF_FILE" 2>/dev/null || true
    log INFO "已写入 $NM_CONF_FILE"
}

# 修改连接配置前必须先断开，否则会触发
# "no secrets: The connection was modified since activation" 导致密码读取失败
fix_profile_mac() {
    [[ -n "$WIFI_CONNECTION" ]] || return 0
    log INFO "固定连接 [$WIFI_CONNECTION] 的 MAC 为设备真实 MAC"
    [[ "$DRY_RUN" -eq 1 ]] && { log DEBUG "DRY-RUN 跳过修改连接配置"; return 0; }

    nmcli device disconnect "$WIFI_IFACE" >/dev/null 2>&1 || true
    sleep 1

    local auto
    auto=$(nmcli -g connection.autoconnect con show "$WIFI_CONNECTION" 2>/dev/null | tr -d '\r[:space:]')
    [[ -n "$auto" ]] || auto="yes"

    nmcli con modify "$WIFI_CONNECTION" connection.autoconnect no >/dev/null 2>&1 || true
    nmcli con modify "$WIFI_CONNECTION" wifi.cloned-mac-address permanent >/dev/null 2>&1 || true
    nmcli con modify "$WIFI_CONNECTION" connection.autoconnect "$auto" >/dev/null 2>&1 || true
    log INFO "连接配置已更新：cloned-mac-address=permanent, autoconnect=$auto"
}

verify_mac_policy() {
    local val
    val=$(nmcli -g 802-11-wireless.cloned-mac-address con show "$WIFI_CONNECTION" 2>/dev/null | tr -d '\r[:space:]')
    if [[ -n "$val" && "$val" != "permanent" && "$val" != "--" ]]; then
        log WARN "检测到连接仍可能使用非固定 MAC (cloned-mac-address=$val)"
    else
        log INFO "MAC 策略校验通过 (cloned-mac-address=${val:-permanent})"
    fi
}

# ------------------------------ 连接动作 ------------------------------
con_up() {
    local out rc
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log INFO "DRY-RUN 跳过: nmcli con up '$WIFI_CONNECTION' ifname '$WIFI_IFACE'"
        return 0
    fi
    out=$(nmcli con up "$WIFI_CONNECTION" ifname "$WIFI_IFACE" 2>&1); rc=$?
    if [[ $rc -ne 0 ]]; then
        log WARN "激活连接失败: ${out//$'\n'/; }"
        return 1
    fi
    log INFO "已发起连接: $WIFI_CONNECTION @ $WIFI_IFACE"
    return 0
}

wait_nm_ready() {
    local i
    for i in $(seq 1 30); do
        if systemctl is-active --quiet NetworkManager 2>/dev/null && \
           nmcli -g RUNNING general >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

wait_healthy() {
    local attempts="$1" i
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log DEBUG "DRY-RUN 跳过等待连接就绪"
        return 0
    fi
    for ((i = 0; i < attempts; i++)); do
        check_health && return 0
        sleep 3
    done
    return 1
}

# --------------------------- 分级修复流程 ---------------------------
repair_once() {
    log WARN "===== 开始 WiFi 网络重置流程 ====="
    resolve_connection || return 1
    local ok=0

    # 第一级：软重连（不断网络服务，只重新激活连接）
    log INFO "[1/3] 软重连：断开后重新激活连接"
    nmcli device disconnect "$WIFI_IFACE" >/dev/null 2>&1 || true
    sleep 2
    con_up || true
    if wait_healthy 10; then
        log INFO "软重连成功，WiFi 已恢复"
        ok=1
    fi

    # 第二级：WiFi 网络重置（接口复位 + 清 IP + 重启 NetworkManager + 重扫）
    if [[ $ok -eq 0 ]]; then
        log WARN "[2/3] WiFi 网络重置：复位接口、重载网络服务、重新扫描并连接"
        nmcli device disconnect "$WIFI_IFACE" >/dev/null 2>&1 || true
        if [[ "$DRY_RUN" -eq 0 ]]; then
            ip link set "$WIFI_IFACE" down 2>/dev/null || true
            sleep 1
            ip link set "$WIFI_IFACE" up 2>/dev/null || true
            ip -4 addr flush dev "$WIFI_IFACE" scope global 2>/dev/null || true
        fi
        write_nm_conf
        fix_profile_mac

        if [[ "$DRY_RUN" -eq 0 ]]; then
            log INFO "重启 NetworkManager 以清除失效的密钥/扫描状态"
            systemctl restart NetworkManager >/dev/null 2>&1 || log WARN "NetworkManager 重启命令执行失败"
            wait_nm_ready || log WARN "NetworkManager 未在预期时间内就绪"
        fi
        sleep 2
        verify_mac_policy
        nmcli device wifi rescan ifname "$WIFI_IFACE" >/dev/null 2>&1 || true
        sleep 3
        con_up || true
        if wait_healthy 20; then
            log INFO "WiFi 网络重置成功，连接已恢复"
            ok=1
        fi
    fi

    # 第三级：无线驱动重置（可选，默认关闭）
    if [[ $ok -eq 0 && "$DRIVER_RESET" == "1" ]]; then
        log WARN "[3/3] 无线驱动重置：重载 $DRIVER_MODULE"
        nmcli device disconnect "$WIFI_IFACE" >/dev/null 2>&1 || true
        if [[ "$DRY_RUN" -eq 0 ]] && have modprobe; then
            modprobe -r "$DRIVER_MODULE" >/dev/null 2>&1 || log WARN "驱动卸载失败（可能已内建）"
            sleep 2
            modprobe "$DRIVER_MODULE" >/dev/null 2>&1 || log WARN "驱动加载失败"
            sleep 3
        fi
        con_up || true
        if wait_healthy 20; then
            log INFO "无线驱动重置成功，连接已恢复"
            ok=1
        fi
    fi

    if [[ $ok -eq 1 ]]; then
        log INFO "===== 本轮修复成功 ====="
        return 0
    fi
    log ERROR "===== 本轮修复未成功 ====="
    return 1
}

# --------------------------- 频率/冷却控制 ---------------------------
can_reset() {
    local now last=0 t cnt=0
    now=$(date +%s)
    [[ -f "$RESET_LOG" ]] && last=$(tail -n 1 "$RESET_LOG" 2>/dev/null | tr -d '[:space:]')
    [[ -n "${last:-}" ]] || last=0
    if (( now - last < RESET_COOLDOWN )); then
        log WARN "距离上次修复不足 ${RESET_COOLDOWN}s，处于冷却期"
        return 1
    fi
    if [[ -f "$RESET_LOG" ]]; then
        while read -r t; do
            [[ -z "${t:-}" ]] && continue
            if (( now - t <= 3600 )); then cnt=$((cnt + 1)); fi
        done < "$RESET_LOG"
    fi
    if (( cnt >= MAX_RESETS_PER_HOUR )); then
        log ERROR "一小时内已修复 $cnt 次，达到上限，暂停自动修复"
        return 1
    fi
    return 0
}

record_reset() {
    [[ "$DRY_RUN" -eq 1 ]] && return 0
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    date +%s >> "$RESET_LOG" 2>/dev/null || true
}

# ------------------------------ 守护主循环 ------------------------------
main_daemon() {
    log INFO "$NAME $VERSION 启动 (iface=$WIFI_IFACE, interval=${CHECK_INTERVAL}s, threshold=${FAIL_THRESHOLD}, random_mac=disabled)"
    resolve_connection || log WARN "连接名未解析成功，将在修复阶段重试"
    local fails=0

    while true; do
        if check_health; then
            if (( fails > 0 )); then
                log INFO "WiFi 已恢复正常（此前连续失败 $fails 次）"
            fi
            fails=0
        else
            fails=$((fails + 1))
            log WARN "WiFi 健康检查失败 ($fails/$FAIL_THRESHOLD)"
            if (( fails >= FAIL_THRESHOLD )) && can_reset; then
                record_reset
                if repair_once; then
                    fails=0
                elif [[ "$AUTO_REBOOT" == "1" ]] && (( fails >= REBOOT_AFTER_FAILS )); then
                    log ERROR "连续失败 $fails 次，触发自动重启系统"
                    sync
                    systemctl reboot >/dev/null 2>&1 || true
                fi
            fi
        fi
        sleep "$CHECK_INTERVAL"
    done
}

usage() {
    cat <<'EOF'
用法: wifi-watchdog.sh [选项]

选项:
  (无参数)      以守护模式持续监测并自动修复（systemd 服务使用此模式）
  --check       单次健康检查，正常输出 OK（退出码 0），异常输出 FAIL（退出码 1）
  --repair      立即执行一次完整的 WiFi 网络重置流程
  --fix-mac     仅写入禁用随机 MAC 的配置并固定当前连接的 MAC
  --dry-run     配合 --repair 使用，只打印将要执行的操作
  --version     显示版本
  -h, --help    显示本帮助

配置文件: /etc/wifi-watchdog.conf
日志:     /var/log/wifi-watchdog.log
EOF
}

trap 'log INFO "收到终止信号，退出"; exit 0' TERM INT

# 多实例保护（--check 除外）
if [[ "${1:-}" != "--check" && "${1:-}" != "--version" && "${1:-}" != "-h" && "${1:-}" != "--help" ]]; then
    if have flock; then
        exec 9>"$LOCK_FILE"
        flock -n 9 || { echo "另一个 wifi-watchdog 实例正在运行" >&2; exit 1; }
    fi
fi

case "${1:-}" in
    --check)
        resolve_connection >/dev/null 2>&1 || true
        if check_health; then
            echo "OK"
            log INFO "手动健康检查: 正常"
            exit 0
        else
            echo "FAIL"
            log WARN "手动健康检查: 异常"
            exit 1
        fi
        ;;
    --repair)
        resolve_connection || exit 1
        repair_once
        ;;
    --fix-mac)
        resolve_connection || exit 1
        write_nm_conf
        fix_profile_mac
        verify_mac_policy
        ;;
    --dry-run)
        DRY_RUN=1
        resolve_connection || exit 1
        repair_once
        ;;
    --version)
        echo "$NAME $VERSION"
        ;;
    -h|--help)
        usage
        ;;
    "")
        main_daemon
        ;;
    *)
        echo "未知参数: $1" >&2
        usage
        exit 2
        ;;
esac
