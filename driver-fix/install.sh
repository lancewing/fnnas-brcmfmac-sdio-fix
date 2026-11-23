#!/usr/bin/env bash
# ==============================================================================
# install.sh — 飞牛OS WiFi 驱动层修复安装器
#
# 用法:
#   sudo bash install.sh                    # 安装 + 修复 + 开机恢复
#   sudo bash install.sh --no-fix           # 只安装，不执行修复
#   sudo bash install.sh --no-autorestore   # 不启用 OTA 开机恢复
#   sudo bash install.sh --with-watchdog    # 同时启用网络自愈守护（可选）
#   sudo bash install.sh --uninstall        # 卸载
#
# 本地更新: 把 regulatory.db / regulatory.db.p7s / <芯片>-sdio.clm_blob /
#           板级 NVRAM 放到本目录的 local-files/ 后重跑本脚本即可优先本地安装。
# ==============================================================================

set -u
set -o pipefail

SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SBIN="/usr/local/sbin/fnnas-brcmfmac-sdio-fix"
UNIT="/etc/systemd/system/fnnas-brcmfmac-sdio-fix.service"
DOC_DIR="/usr/local/share/doc/fnnas-brcmfmac-sdio-fix"
LOCAL_DIR="/etc/fnnas-brcmfmac-sdio-fix/local-files"
DO_FIX=1
DO_AUTORESTORE=1
DO_WATCHDOG=0

die() { echo "错误: $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }

uninstall() {
    command -v systemctl >/dev/null 2>&1 || die "找不到 systemctl"
    info "停止并禁用 OTA 恢复服务"
    systemctl stop fnnas-brcmfmac-sdio-fix.service >/dev/null 2>&1 || true
    systemctl disable fnnas-brcmfmac-sdio-fix.service >/dev/null 2>&1 || true
    rm -f "$UNIT" "$SBIN"
    rm -rf "$DOC_DIR"
    systemctl daemon-reload >/dev/null 2>&1 || true
    info "缓存 /etc/fnnas-brcmfmac-sdio-fix 与备份 /var/backups/fnnas-brcmfmac-sdio-fix 已保留"
    info "卸载完成（已安装的固件文件不会自动还原，备份目录中有原文件）"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-fix) DO_FIX=0 ;;
        --no-autorestore) DO_AUTORESTORE=0 ;;
        --with-watchdog) DO_WATCHDOG=1 ;;
        --uninstall) uninstall ;;
        -h|--help)
            sed -n '2,14p' "${BASH_SOURCE[0]}"
            exit 0 ;;
        *) die "未知参数: $1" ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] || die "请用 root 运行：sudo bash $0"
[[ -f "$SRC_DIR/fnnas-brcmfmac-sdio-fix.sh" ]] || die "缺少 fnnas-brcmfmac-sdio-fix.sh"
command -v systemctl >/dev/null 2>&1 || die "找不到 systemctl"

# ---------- 1. 安装文件 ----------
mkdir -p "$(dirname "$SBIN")" "$(dirname "$UNIT")" "$DOC_DIR" /etc/fnnas-brcmfmac-sdio-fix/cache "$LOCAL_DIR"
install -m 755 "$SRC_DIR/fnnas-brcmfmac-sdio-fix.sh" "$SBIN"
install -m 644 "$SRC_DIR/fnnas-brcmfmac-sdio-fix.service" "$UNIT"
[[ -f "$SRC_DIR/README.md" ]] && install -m 644 "$SRC_DIR/README.md" "$DOC_DIR/README.md"
if [[ -d "$SRC_DIR/local-files" ]]; then
    cp -a "$SRC_DIR/local-files/." "$LOCAL_DIR/" 2>/dev/null || warn "复制本地更新文件失败：$SRC_DIR/local-files"
    info "已载入本地更新文件: $SRC_DIR/local-files -> $LOCAL_DIR"
fi
info "已安装 $SBIN 与 $UNIT"

# ---------- 2. 安装前诊断 ----------
echo ""
"$SBIN" --check || warn "诊断发现待处理项，继续执行修复流程"
echo ""

# ---------- 3. 执行修复 ----------
if [[ $DO_FIX -eq 1 ]]; then
    info "开始修复（本地目录优先，缺失时尝试在线下载；下载失败请按提示改用本地文件）"
    "$SBIN" --fix || warn "自动修复未全部成功，请查看 /var/log/fnnas-brcmfmac-sdio-fix.log"
else
    info "按 --no-fix 要求，跳过修复"
fi

# ---------- 4. OTA 开机恢复服务 ----------
systemctl daemon-reload >/dev/null 2>&1 || true
if [[ $DO_AUTORESTORE -eq 1 ]]; then
    systemctl enable fnnas-brcmfmac-sdio-fix.service >/dev/null 2>&1 || warn "启用开机恢复服务失败"
    systemctl start fnnas-brcmfmac-sdio-fix.service >/dev/null 2>&1 || warn "启动开机恢复服务失败"
    info "已启用 OTA 开机自动恢复服务"
else
    info "按 --no-autorestore 要求，未启用开机恢复服务"
fi

# ---------- 5. 可选：网络自愈守护 ----------
if [[ $DO_WATCHDOG -eq 1 ]]; then
    WATCHDOG_INSTALLER="../watchdog/install.sh"
    if [[ -f "$SRC_DIR/$WATCHDOG_INSTALLER" ]]; then
        info "按需安装网络自愈守护（默认不安装）"
        bash "$SRC_DIR/$WATCHDOG_INSTALLER" --enable-watchdog
    else
        warn "未找到 $WATCHDOG_INSTALLER，跳过自愈守护安装"
    fi
else
    info "未安装网络自愈守护；如需安装：sudo bash ../watchdog/install.sh --enable-watchdog"
fi

echo "------------------------------------------------------------"
info "诊断:   sudo $SBIN --check"
info "修复:   sudo $SBIN --fix"
info "本地更新: sudo $SBIN --fix-local /path/to/files"
info "本地目录: $LOCAL_DIR  （下载失败时把文件放这里后重跑 --fix）"
info "日志:   sudo tail -f /var/log/fnnas-brcmfmac-sdio-fix.log"
info "缓存:   /etc/fnnas-brcmfmac-sdio-fix/cache  （OTA 后靠它自动恢复，请勿删除）"
echo "------------------------------------------------------------"
