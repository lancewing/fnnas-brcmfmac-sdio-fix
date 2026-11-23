#!/usr/bin/env bash
# ==============================================================================
# fnnas-brcmfmac-sdio-fix.sh — 飞牛OS(FNOS) brcmfmac WiFi 驱动层诊断与修复
#
# 针对日志中已确认的四个底层问题：
#   1. regulatory.db 签名验证失败 -> 回退 WORLD 域，5GHz 信道受限
#   2. brcmfmac CLM blob 缺失     -> 国家信道表不可用
#   3. 板级 NVRAM 文件缺失        -> 使用错误/通用硬件参数
#   4. 固件版本过旧 (2016)        -> 兼容性与稳定性差
# 同时把修复文件缓存到 /etc，供 OTA 更新后自动恢复。
#
# 由 WorkBuddy 协助编写与验证。项目地址: https://github.com/<your-name>/fnnas-brcmfmac-sdio-fix
# ==============================================================================

set -u
set -o pipefail

NAME="fnnas-brcmfmac-sdio-fix"
VERSION="1.1.0"

CHIP="${CHIP:-brcmfmac4339}"                 # 由 dmesg 自动探测，失败时用此默认值
BOARD_NVRAM="${BOARD_NVRAM:-}"               # 板级 NVRAM 文件名，留空则自动探测
WIFI_IFACE="${WIFI_IFACE:-wlan0}"
FIRMWARE_DIR="${FIRMWARE_DIR:-/lib/firmware}"
BRCM_DIR="${BRCM_DIR:-$FIRMWARE_DIR/brcm}"
CONF_DIR="${CONF_DIR:-/etc/fnnas-brcmfmac-sdio-fix}"
CACHE_DIR="${CACHE_DIR:-$CONF_DIR/cache}"
LOCAL_DIR="${LOCAL_DIR:-$CONF_DIR/local-files}"    # 本地更新目录：优先于在线下载
BACKUP_DIR="${BACKUP_DIR:-/var/backups/fnnas-brcmfmac-sdio-fix}"
UDEV_RULE="${UDEV_RULE:-/etc/udev/rules.d/99-wifi-regdom-cn.rules}"
NM_CONF="${NM_CONF:-/etc/NetworkManager/conf.d/99-wifi-powersave-off.conf}"
CRDA_CONF="${CRDA_CONF:-/etc/default/crda}"
LOG_FILE="${LOG_FILE:-/var/log/fnnas-brcmfmac-sdio-fix.log}"

URL_REGDB="https://git.kernel.org/pub/scm/linux/kernel/git/sforshee/wireless-regdb.git/plain/regulatory.db"
URL_REGDB_SIG="https://git.kernel.org/pub/scm/linux/kernel/git/sforshee/wireless-regdb.git/plain/regulatory.db.p7s"
URL_CLM="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/brcm/${CHIP}-sdio.clm_blob"

ISSUES=0

have() { command -v "$1" >/dev/null 2>&1; }

log() {
    local level="$1"; shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
    printf '%s\n' "$line"
    [[ -n "$LOG_FILE" && "$LOG_FILE" != "none" ]] && printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
}

report() {
    local status="$1"; shift
    printf '  [%-4s] %s\n' "$status" "$*"
    case "$status" in
        FAIL|WARN) ISSUES=$((ISSUES + 1)) ;;
    esac
}

require_root() {
    [[ $EUID -eq 0 ]] || { echo "错误: 该操作需要 root，请用 sudo 运行" >&2; exit 1; }
}

detect_chip() {
    local line
    line=$(dmesg 2>/dev/null | grep -aoE 'using brcm/brcmfmac[0-9]+-sdio' | head -1 || true)
    if [[ -n "$line" ]]; then
        CHIP="${line##*/}"
        CHIP="${CHIP%-sdio}"     # 统一为 brcmfmac4339，后面各处再拼 -sdio
    fi
    # 同步更新 CLM 下载地址（CHIP 可能变化）
    URL_CLM="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/brcm/${CHIP}-sdio.clm_blob"
}

# 探测板级 NVRAM 文件名（不同设备的后缀不同，例如 <chip>-sdio.<board>.bin）
# 优先从 dmesg 的 "Direct firmware load for brcm/... failed" 中提取，其次扫描固件目录
detect_board_nvram() {
    [[ -n "$BOARD_NVRAM" ]] && return 0
    local hit
    hit=$(dmesg 2>/dev/null | grep -aoE "${CHIP}-sdio\.[^ ,]+\.bin" | head -1 || true)
    if [[ -n "$hit" ]]; then
        BOARD_NVRAM="$hit"
        return 0
    fi
    # 从固件目录中已存在的板级文件推断
    local f
    for f in "$BRCM_DIR"/"${CHIP}"-sdio.*.bin; do
        [[ -e "$f" ]] || continue
        BOARD_NVRAM="${f##*/}"
        return 0
    done
    # 从离线缓存目录中推断
    for f in "$CACHE_DIR"/"${CHIP}"-sdio.*.bin; do
        [[ -e "$f" ]] || continue
        BOARD_NVRAM="${f##*/}"
        return 0
    done
}

# ------------------------------ 诊断项 ------------------------------
check_firmware_version() {
    local v
    v=$(dmesg 2>/dev/null | grep -aoE "Firmware: BCM[0-9]+/[^ ]+ wl0: .*version [0-9A-Za-z.]+" | head -1 || true)
    if [[ -n "$v" ]]; then
        report INFO "固件: $v"
    else
        report WARN "无法从 dmesg 读取固件版本（可能权限不足或驱动未加载）"
    fi
}

check_regdb_files() {
    local ok=1
    [[ -s "$FIRMWARE_DIR/regulatory.db" ]] || { report FAIL "缺少 $FIRMWARE_DIR/regulatory.db"; ok=0; }
    [[ -s "$FIRMWARE_DIR/regulatory.db.p7s" ]] || { report FAIL "缺少 $FIRMWARE_DIR/regulatory.db.p7s"; ok=0; }
    [[ $ok -eq 1 ]] && report OK "regulatory.db 与签名文件存在"
    if [[ -L "$FIRMWARE_DIR/regulatory.db" ]]; then
        report WARN "regulatory.db 是符号链接: $(readlink "$FIRMWARE_DIR/regulatory.db")（OTA/发行版切换时容易失效）"
    fi
}

check_regdb_signature() {
    local signer=""
    if have openssl && [[ -s "$FIRMWARE_DIR/regulatory.db.p7s" ]]; then
        signer=$(openssl pkcs7 -inform DER -in "$FIRMWARE_DIR/regulatory.db.p7s" -print_certs -noout 2>/dev/null | grep -oE '(issuer|Issuer).*' | head -1 || true)
        [[ -n "$signer" ]] && report INFO "regulatory.db 签名者: $signer"
    fi
    if dmesg 2>/dev/null | grep -q "regulatory.db is malformed or signature is missing/invalid"; then
        report FAIL "内核报告 regulatory.db 签名验证失败（回退 WORLD 域，5GHz 信道受限）"
    else
        report OK "内核未报告 regulatory.db 签名错误（若本次启动早于修复，请重启后再确认）"
    fi
}

check_regdom() {
    if ! have iw; then
        report WARN "未安装 iw，无法检查当前监管域"
        return
    fi
    local reg
    reg=$(iw reg get 2>/dev/null | grep -oE 'country [A-Z]{2}' | head -1 || true)
    if [[ "$reg" == "country CN" ]]; then
        report OK "当前监管域: CN"
    else
        report FAIL "当前监管域: ${reg:-未知/00}，期望 CN"
    fi
    if [[ -f "$UDEV_RULE" ]] && grep -q 'reg set CN' "$UDEV_RULE"; then
        report OK "已配置开机自动设置监管域 CN"
    else
        report WARN "未配置开机自动设置监管域（OTA 后可能丢失）"
    fi
}

check_clm_blob() {
    local f="$BRCM_DIR/${CHIP}-sdio.clm_blob"
    if [[ -s "$f" ]]; then
        report OK "CLM blob 存在: $f"
    else
        report INFO "未安装独立 CLM blob: $f（可选；BCM4339 官方固件已内嵌 CLM 信息）"
        report INFO "如需强制提供，请把 ${CHIP}-sdio.clm_blob 放入 $LOCAL_DIR 后重跑 --fix"
    fi
    if dmesg 2>/dev/null | grep -q 'no clm_blob available'; then
        report INFO "内核日志提示 'no clm_blob available'（独立 CLM 可选，不代表驱动加载失败）"
    fi
}

check_nvram() {
    local generic="$BRCM_DIR/${CHIP}-sdio.txt"
    if [[ -n "$BOARD_NVRAM" && -s "$BRCM_DIR/$BOARD_NVRAM" ]]; then
        report OK "板级 NVRAM 存在: $BRCM_DIR/$BOARD_NVRAM"
    elif [[ -s "$generic" ]]; then
        local c
        c=$(grep -iE '^country=' "$generic" | head -1 || true)
        report WARN "板级 NVRAM 缺失，使用通用 $generic（${c:-未设置 country}）"
    else
        report FAIL "板级 NVRAM 与通用 NVRAM 均缺失，驱动只能使用内置默认值"
    fi
}

check_powersave() {
    if have iw && ip link show dev "$WIFI_IFACE" >/dev/null 2>&1; then
        local ps
        ps=$(iw dev "$WIFI_IFACE" get power_save 2>/dev/null || true)
        [[ "$ps" == "Power save: off" ]] && report OK "WiFi 省电已关闭" || report WARN "WiFi 省电状态: ${ps:-未知}，BCM4339 建议关闭"
    fi
    if [[ -f "$NM_CONF" ]] && grep -q 'wifi.powersave=2' "$NM_CONF"; then
        report OK "NetworkManager 已持久化关闭 WiFi 省电"
    else
        report WARN "未持久化关闭 WiFi 省电"
    fi
}

check_persistence() {
    local required=0 f
    for f in regulatory.db regulatory.db.p7s; do
        [[ -s "$CACHE_DIR/$f" ]] && required=$((required + 1))
    done
    local clm_state="可选未缓存"
    [[ -s "$CACHE_DIR/${CHIP}-sdio.clm_blob" ]] && clm_state="已缓存"
    if [[ $required -eq 2 ]]; then
        report OK "OTA 恢复缓存完整（必需文件 2/2，CLM blob $clm_state）"
    else
        report FAIL "OTA 恢复缓存不完整（必需文件 $required/2，CLM blob 可选）"
    fi
}

run_diagnostics() {
    detect_chip
    detect_board_nvram
    echo "===== 飞牛OS WiFi 驱动层诊断（芯片: $CHIP）====="
    check_firmware_version
    check_regdb_files
    check_regdb_signature
    check_regdom
    check_clm_blob
    check_nvram
    check_powersave
    check_persistence
    echo "----------------------------------------------"
    if [[ $ISSUES -eq 0 ]]; then
        echo "结论: 未发现明显问题"
        return 0
    fi
    echo "结论: 发现 $ISSUES 项待处理"
    return 1
}

# ------------------------------ 修复工具 ------------------------------
backup_file() {
    local src="$1"
    [[ -e "$src" ]] || return 0
    mkdir -p "$BACKUP_DIR/$(dirname "$src")" 2>/dev/null || true
    cp -a "$src" "$BACKUP_DIR/$src.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
}

fetch_file() {
    # $1 = URL, $2 = 目标路径；优先级：本地目录 > 缓存 > 在线下载
    local url="$1" dest="$2" name
    name=$(basename "$dest")
    mkdir -p "$(dirname "$dest")" "$CACHE_DIR" "$LOCAL_DIR" 2>/dev/null || true

    if [[ -s "$LOCAL_DIR/$name" ]]; then
        install -m 644 "$LOCAL_DIR/$name" "$CACHE_DIR/$name"
        install -m 644 "$LOCAL_DIR/$name" "$dest"
        log INFO "从本地目录安装: $LOCAL_DIR/$name -> $dest"
        return 0
    fi

    if [[ -s "$CACHE_DIR/$name" ]]; then
        install -m 644 "$CACHE_DIR/$name" "$dest"
        log INFO "从缓存安装: $name -> $dest"
        return 0
    fi

    have curl || { log ERROR "未找到 curl，无法下载 $name；请把文件放入 $LOCAL_DIR 后重跑 --fix"; return 1; }
    local tmp
    tmp=$(mktemp)
    log INFO "下载 $name: $url"
    if ! curl -fsSL --connect-timeout 15 --retry 2 "$url" -o "$tmp"; then
        rm -f "$tmp"
        log ERROR "下载失败: $name（可把文件放入 $LOCAL_DIR 后重跑 --fix）"
        return 1
    fi
    if [[ ! -s "$tmp" ]] || [[ $(stat -c%s "$tmp" 2>/dev/null || echo 0) -lt 100 ]]; then
        rm -f "$tmp"
        log ERROR "下载内容异常: $name"
        return 1
    fi
    install -m 644 "$tmp" "$CACHE_DIR/$name"
    install -m 644 "$tmp" "$dest"
    rm -f "$tmp"
    log INFO "已安装并缓存: $name"
}

fix_regdb() {
    log INFO "修复 regulatory.db（官方签名数据库）"
    backup_file "$FIRMWARE_DIR/regulatory.db"
    backup_file "$FIRMWARE_DIR/regulatory.db.p7s"
    # 符号链接先删除，避免写入被链接指向的 Debian 版本
    [[ -L "$FIRMWARE_DIR/regulatory.db" ]] && rm -f "$FIRMWARE_DIR/regulatory.db"
    [[ -L "$FIRMWARE_DIR/regulatory.db.p7s" ]] && rm -f "$FIRMWARE_DIR/regulatory.db.p7s"
    local rc=0
    fetch_file "$URL_REGDB" "$FIRMWARE_DIR/regulatory.db" || rc=1
    fetch_file "$URL_REGDB_SIG" "$FIRMWARE_DIR/regulatory.db.p7s" || rc=1
    return $rc
}

fix_clm() {
    log INFO "修复 CLM blob（国家信道表，可选）"
    local dest="$BRCM_DIR/${CHIP}-sdio.clm_blob"
    backup_file "$dest"
    if fetch_file "$URL_CLM" "$dest"; then
        return 0
    fi
    log WARN "跳过独立 CLM blob：官方源未提供或下载失败（BCM4339 常见，CLM 已内嵌固件）"
    log WARN "如需强制安装，请把 ${CHIP}-sdio.clm_blob 放入 $LOCAL_DIR/ 后重跑 --fix"
    return 0
}

fix_nvram() {
    local generic="$BRCM_DIR/${CHIP}-sdio.txt"
    if [[ -n "$BOARD_NVRAM" && -s "$CACHE_DIR/$BOARD_NVRAM" ]]; then
        backup_file "$BRCM_DIR/$BOARD_NVRAM"
        install -m 644 "$CACHE_DIR/$BOARD_NVRAM" "$BRCM_DIR/$BOARD_NVRAM"
        log INFO "已从缓存安装板级 NVRAM: $BRCM_DIR/$BOARD_NVRAM"
        return 0
    fi
    if [[ -s "$generic" ]]; then
        backup_file "$generic"
        if grep -qi '^country=' "$generic"; then
            sed -i -E 's/^country=.*/country=CN/' "$generic"
        else
            echo "country=CN" >> "$generic"
        fi
        log INFO "已把通用 NVRAM 的 country 设为 CN: $generic"
        return 0
    fi
    log WARN "未找到板级或通用 NVRAM，请把板级文件放到 $BRCM_DIR/ 后重新检查（文件名形如 ${CHIP}-sdio.<板型>.bin）"
    return 1
}

fix_persistence() {
    log INFO "写入监管域与省电的持久化配置"
    mkdir -p "$(dirname "$UDEV_RULE")" "$(dirname "$NM_CONF")" "$(dirname "$CRDA_CONF")" 2>/dev/null || true
    local iwbin
    iwbin=$(command -v iw 2>/dev/null || echo /usr/sbin/iw)

    backup_file "$UDEV_RULE"
    printf 'ACTION=="add", SUBSYSTEM=="ieee80211", RUN+="%s reg set CN"\n' "$iwbin" > "$UDEV_RULE"
    chmod 644 "$UDEV_RULE"

    backup_file "$CRDA_CONF"
    if grep -q '^REGDOMAIN=' "$CRDA_CONF" 2>/dev/null; then
        sed -i -E 's/^REGDOMAIN=.*/REGDOMAIN=CN/' "$CRDA_CONF"
    else
        echo 'REGDOMAIN=CN' >> "$CRDA_CONF"
    fi

    backup_file "$NM_CONF"
    printf '# 由 %s 生成：BCM4339 关闭 WiFi 省电\n[connection]\nwifi.powersave=2\n' "$NAME" > "$NM_CONF"
    chmod 644 "$NM_CONF"
    log INFO "持久化配置完成（udev / crda / NetworkManager）"
}

reload_driver() {
    log INFO "重新加载 brcmfmac 驱动与 NetworkManager"
    modprobe -r brcmfmac >/dev/null 2>&1 || log WARN "驱动卸载失败（可能内建或正在使用）"
    sleep 2
    modprobe brcmfmac >/dev/null 2>&1 || log WARN "驱动加载失败，建议重启"
    systemctl restart NetworkManager >/dev/null 2>&1 || log WARN "NetworkManager 重启失败"
    log WARN "regulatory.db 需重启内核才会重新校验；建议稍后重启设备并再次 --check"
}

# ------------------- OTA 后开机恢复（供 systemd 调用）-------------------
repair_if_needed() {
    log INFO "开机校验：检查 OTA 后修复文件是否仍在"
    local restored=0 f src
    for f in regulatory.db regulatory.db.p7s "${CHIP}-sdio.clm_blob"; do
        src="$CACHE_DIR/$f"
        [[ -s "$src" ]] || continue
        case "$f" in
            regulatory.db|regulatory.db.p7s) dest="$FIRMWARE_DIR/$f" ;;
            *) dest="$BRCM_DIR/$f" ;;
        esac
        if ! cmp -s "$src" "$dest" 2>/dev/null; then
            backup_file "$dest"
            install -m 644 "$src" "$dest"
            log INFO "已从缓存恢复: $dest"
            restored=$((restored + 1))
        fi
    done

    local iwbin
    iwbin=$(command -v iw 2>/dev/null || echo /usr/sbin/iw)
    if [[ ! -f "$UDEV_RULE" ]] && [[ -s "$CACHE_DIR/regulatory.db" ]]; then
        mkdir -p "$(dirname "$UDEV_RULE")"
        printf 'ACTION=="add", SUBSYSTEM=="ieee80211", RUN+="%s reg set CN"\n' "$iwbin" > "$UDEV_RULE"
        log INFO "已恢复 udev 监管域规则"
        restored=$((restored + 1))
    fi
    if [[ ! -f "$NM_CONF" ]]; then
        mkdir -p "$(dirname "$NM_CONF")"
        printf '[connection]\nwifi.powersave=2\n' > "$NM_CONF"
        log INFO "已恢复 NetworkManager 省电配置"
        restored=$((restored + 1))
    fi
    log INFO "开机校验完成，恢复 $restored 项"
    return 0
}

# ------------------------------ 命令行 ------------------------------
# 允许把 --cache-dir / --local-dir 放在前面，便于测试/自定义目录
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cache-dir)
            [[ -n "${2:-}" ]] || { echo "错误: --cache-dir 需要一个目录参数" >&2; exit 2; }
            CACHE_DIR="$2"; shift 2 ;;
        --local-dir)
            [[ -n "${2:-}" ]] || { echo "错误: --local-dir 需要一个目录参数" >&2; exit 2; }
            LOCAL_DIR="$2"; shift 2 ;;
        *) break ;;
    esac
done

usage() {
    cat <<'EOF'
用法: fnnas-brcmfmac-sdio-fix.sh [选项]

选项:
  --check            全面诊断（默认，只读，不修改系统）
  --fix              执行修复；优先级：本地目录 > 缓存 > 在线下载
  --fix-offline DIR  从目录 DIR 读取文件后离线修复（等价于 --fix-local）
  --fix-local DIR    从本地目录 DIR 更新文件并修复（推荐：下载失败时用）
  --repair-if-needed 开机自检：仅当缓存文件丢失/变化时从 /etc 恢复（供 systemd 用）
  --cache-dir DIR    指定缓存目录（默认 /etc/fnnas-brcmfmac-sdio-fix/cache）
  --local-dir DIR    指定本地文件目录（默认 /etc/fnnas-brcmfmac-sdio-fix/local-files）
  --version          显示版本
  -h, --help         显示本帮助

本地/离线目录所需文件（<芯片> 由 dmesg 自动探测）:
  regulatory.db                              (必需)
  regulatory.db.p7s                          (必需)
  <芯片>-sdio.clm_blob                       (可选；BCM4339 官方源无此文件)
  <芯片>-sdio.<板型>.bin                     (板级 NVRAM，可选，有则一起安装)
EOF
}

case "${1:---check}" in
    --check)
        run_diagnostics; exit $? ;;
    --fix)
        require_root
        detect_chip
        detect_board_nvram
        log INFO "===== 开始驱动层修复（芯片: $CHIP）====="
        rc=0
        fix_regdb || rc=1
        fix_clm || rc=1
        fix_nvram || rc=1
        fix_persistence || rc=1
        if [[ $rc -eq 0 ]]; then
            log INFO "文件修复完成"
            reload_driver
        else
            log WARN "部分文件修复失败，请按提示补齐后再运行 --check"
        fi
        exit $rc ;;
    --fix-offline|--fix-local)
        require_root
        detect_chip
        [[ -n "${2:-}" && -d "$2" ]] || { echo "错误: 请提供包含修复文件的目录" >&2; exit 2; }
        LOCAL_DIR="$2"
        mkdir -p "$CACHE_DIR" "$LOCAL_DIR"
        for f in regulatory.db regulatory.db.p7s "${CHIP}-sdio.clm_blob"; do
            if [[ -s "$LOCAL_DIR/$f" ]]; then
                install -m 644 "$LOCAL_DIR/$f" "$CACHE_DIR/$f"
                log INFO "已载入缓存: $f"
            elif [[ "$f" == *clm_blob ]]; then
                log INFO "本地目录中无 $f（可选，BCM4339 可跳过）"
            else
                log WARN "本地目录中未找到必需文件 $f"
            fi
        done
        # 板级 NVRAM：把离线目录里任意 <chip>-sdio.<板型>.bin 载入缓存
        bnv=""
        for bnv in "$LOCAL_DIR"/"${CHIP}"-sdio.*.bin; do
            [[ -s "$bnv" ]] || continue
            install -m 644 "$bnv" "$CACHE_DIR/${bnv##*/}"
            BOARD_NVRAM="${bnv##*/}"
            log INFO "已载入缓存: $BOARD_NVRAM"
        done
        detect_board_nvram
        log INFO "===== 开始本地/离线修复（$LOCAL_DIR）====="
        rc=0
        fix_regdb || rc=1
        fix_clm || rc=1
        fix_nvram || rc=1
        fix_persistence || rc=1
        exit $rc ;;
    --repair-if-needed)
        require_root
        detect_chip
        detect_board_nvram
        repair_if_needed; exit $? ;;
    --version)
        echo "$NAME $VERSION"; exit 0 ;;
    -h|--help)
        usage; exit 0 ;;
    *)
        echo "未知参数: $1" >&2
        usage
        exit 2 ;;
esac
