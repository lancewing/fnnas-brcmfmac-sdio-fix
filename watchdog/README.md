# WiFi 网络自愈脚本（可选兜底）

> 适用环境：飞牛OS（FNOS）及任意 Debian 系系统、NetworkManager 1.x + wpa_supplicant。**架构无关、驱动无关、接口无关**（`wlan0` 只是默认接口名，可按实际修改）——x86 / ARM、PCIe / USB / SDIO 网卡均可用。
>
> **定位：这是「可选兜底方案」，默认不启用。** 若是 SDIO 博通网卡，请先用主方案 [驱动层修复](../driver-fix/README.md) 治本；其他网卡可直接使用本方案。注意：本脚本只做连接层的掉线重连，无法修复固件 / 监管域等底层问题。

---

## 一、它解决什么

当设备 WiFi 断线后反复出现以下情况时，本脚本可自动恢复连接，免去人工断电重启：

- `WPA: 4-Way Handshake failed - pre-shared key may be incorrect`
- `CTRL-EVENT-SSID-TEMP-DISABLED ... reason=WRONG_KEY`
- `no secrets: The connection was modified since activation`
- `set-hw-addr: set MAC address to xx:xx:xx (scanning)` —— NetworkManager 每次扫描都更换随机 MAC
- 之后 `ASSOC-REJECT status_code=16`，陷入每 5 分钟一次的无效扫描循环：整机在线，但网络上不可达

脚本在确认路由器正常的前提下，自动完成：

1. **禁用随机 MAC**：全局关闭 `wifi.scan-rand-mac-address`，连接配置固定为 `cloned-mac-address=permanent`，扫描和关联始终使用设备真实 MAC。
2. **健康检查**：每 30 秒检查 NetworkManager 状态、wlan0 连接状态、IPv4 地址、默认网关连通性。
3. **分级修复**：连续 3 次异常后自动执行「软重连 → WiFi 网络重置 → 驱动重置（可选）」。
4. **防抖动限流**：2 分钟冷却期、每小时最多 6 次修复。
5. **完整日志**：`/var/log/wifi-watchdog.log` + systemd journal。

---

## 二、文件清单

| 文件 | 说明 |
| --- | --- |
| `wifi-watchdog.sh` | 核心守护脚本（检测 + 修复 + 禁用随机 MAC） |
| `install.sh` | 安装 / 卸载脚本 |
| `wifi-watchdog.service` | systemd 服务单元 |
| `wifi-watchdog.conf.example` | 配置模板及参数说明 |
| `README.md` | 本文档 |

---

## 三、安装

### 方式 A：安装脚本（推荐）

把整个 `wifi-watchdog` 目录上传到设备（例如 `/volume1/tools/wifi-watchdog`），SSH 登录后执行：

```bash
cd /volume1/tools/wifi-watchdog
sudo bash install.sh
```

**默认只安装文件、不启用守护。** 要真正启用自愈守护，需显式加参数：

```bash
sudo bash install.sh --enable-watchdog
```

安装脚本会完成：

1. 识别当前 WiFi 连接名与 SSID（**自动探测，无需手动填写**）
2. 安装程序到 `/usr/local/sbin/wifi-watchdog`
3. 安装服务到 `/etc/systemd/system/wifi-watchdog.service`
4. 生成 `/etc/wifi-watchdog.conf`（已存在则保留不覆盖）

只有加 `--enable-watchdog` 时才会额外执行：

5. 写入 `/etc/NetworkManager/conf.d/99-wifi-watchdog-no-random-mac.conf`
6. 固定连接 MAC 为真实 MAC，重启 NetworkManager
7. 启用并启动 `wifi-watchdog.service`

> 第 6 步会短暂断开 WiFi（约 5 秒），属正常现象。不加参数时第 5～7 步都不会执行，也不会改动 NetworkManager 配置。

### 方式 B：手动安装

```bash
sudo install -m 755 wifi-watchdog.sh /usr/local/sbin/wifi-watchdog
sudo install -m 644 wifi-watchdog.service /etc/systemd/system/wifi-watchdog.service
sudo install -m 644 wifi-watchdog.conf.example /etc/wifi-watchdog.conf
# 编辑 /etc/wifi-watchdog.conf，通常保持默认即可（连接名会自动识别）
sudo /usr/local/sbin/wifi-watchdog --fix-mac
sudo systemctl daemon-reload
sudo systemctl enable --now wifi-watchdog
```

---

## 四、常用命令

```bash
# 查看服务状态
sudo systemctl status wifi-watchdog

# 单次健康检查（正常输出 OK，异常输出 FAIL 且退出码为 1）
sudo /usr/local/sbin/wifi-watchdog --check

# 立即执行一次完整修复
sudo /usr/local/sbin/wifi-watchdog --repair

# 只应用"禁用随机 MAC"设置，不做完整修复
sudo /usr/local/sbin/wifi-watchdog --fix-mac

# 预演修复流程，只打印不执行（排查用）
sudo /usr/local/sbin/wifi-watchdog --dry-run

# 实时查看日志
sudo tail -f /var/log/wifi-watchdog.log
sudo journalctl -u wifi-watchdog -f
```

---

## 五、配置项说明

配置文件：`/etc/wifi-watchdog.conf`（修改后需 `sudo systemctl restart wifi-watchdog`）

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `WIFI_IFACE` | `wlan0` | 无线网卡接口名 |
| `WIFI_CONNECTION` | 自动识别 | NetworkManager 连接名；可用 `nmcli con show` 查询 |
| `WIFI_SSID` | 自动识别 | 目标 WiFi 名称，用于多连接时筛选 |
| `PING_TARGET` | 默认网关 | 连通性探测目标；填公网 IP 时公网中断也会触发修复，慎用 |
| `CHECK_INTERVAL` | `30` | 健康检查周期（秒） |
| `FAIL_THRESHOLD` | `3` | 连续失败次数达到后才修复 |
| `RESET_COOLDOWN` | `120` | 两次修复之间的最小间隔（秒） |
| `MAX_RESETS_PER_HOUR` | `6` | 每小时修复次数上限 |
| `AUTO_REBOOT` | `0` | 多次修复失败后是否自动重启系统；默认关闭 |
| `REBOOT_AFTER_FAILS` | `6` | 触发自动重启的连续失败次数 |
| `DRIVER_RESET` | `0` | 是否启用无线驱动重载；默认关闭 |
| `DRIVER_MODULE` | `brcmfmac` | 驱动模块名，按实际网卡填写 |
| `LOG_FILE` | `/var/log/wifi-watchdog.log` | 日志文件；填 `none` 则只写 journal |

建议先用默认值运行几天，观察日志。若确认某些场景需要更强力的恢复手段，再把 `DRIVER_RESET` 或 `AUTO_REBOOT` 改为 `1`。

---

## 六、修复流程详解

脚本检测到连续 `FAIL_THRESHOLD` 次异常后，按以下顺序逐级尝试，任一级成功即停止：

1. **软重连（1/3）**：断开 `wlan0`，重新激活连接配置。适用于短暂掉线。
2. **WiFi 网络重置（2/3）**：
   - 断开接口 → `ip link down/up` → 清除旧 IP
   - 写入禁用随机 MAC 的 NetworkManager 配置
   - **断开状态下**修改连接配置（避免 `no secrets: The connection was modified since activation`），设为 `cloned-mac-address=permanent`
   - 重启 NetworkManager（清除 temp-disabled 状态、失效凭据和卡死的扫描）
   - 重新扫描并连接
3. **驱动重置（3/3，默认关闭）**：卸载并重载无线驱动模块，再重连。

修复动作记录在 `/var/lib/watchdog/reset-times`，用于冷却期和每小时次数限制。

---

## 七、随机 MAC 说明与验证

安装后以下两处都应为固定值：

```bash
# 全局：应输出 wifi.scan-rand-mac-address=false
grep -R "scan-rand-mac-address" /etc/NetworkManager/NetworkManager.conf /etc/NetworkManager/conf.d/

# 连接级：应输出 permanent（把 <连接名> 换成实际名称，可用 nmcli con show 查询）
nmcli -g 802-11-wireless.cloned-mac-address con show "<连接名>"

# 运行时 MAC：多次执行应始终一致，不再出现随机地址
cat /sys/class/net/wlan0/address
```

注意：系统其他组件（如飞牛的网络服务）若再次把配置改成 `random`，守护脚本会在下一次网络重置时自动改回 `permanent`，并在日志中告警。

---

## 八、卸载

```bash
sudo bash install.sh --uninstall
```

卸载会停止并禁用服务、删除程序和 systemd 单元、删除 NetworkManager 配置；配置文件会保留为 `/etc/wifi-watchdog.conf.bak`，日志和状态目录不删除。若需让随机 MAC 设置立即恢复默认：

```bash
sudo systemctl restart NetworkManager
```

---

## 九、注意事项与局限

1. **如果 WiFi 密码确实被改动**，脚本无法凭空恢复正确密码，仍需在飞牛OS 网络设置中重新输入并保存；脚本解决的是凭据失效 / 配置被改动 / 扫描卡死导致的反复重连失败。
2. 修复过程中网络会中断约 10～30 秒，正在进行的下载或远程会话可能断开。
3. 路由器若开启了 MAC 黑白名单，请确认白名单中是设备的**真实 MAC**（`cat /sys/class/net/wlan0/address`），固定真实 MAC 后不会再被随机 MAC 挡在门外。
4. 若日志持续出现 `ASSOC-REJECT status_code=16` 且修复无效，通常是路由器端拒绝了关联（信号过弱、AP 隔离、客户端数限制等），此时应检查路由器；条件允许时改接 `eth0` 有线可彻底消除该单点。
5. 服务本身依赖 NetworkManager；若 NetworkManager 被停止，健康检查会判定异常并尝试修复。
