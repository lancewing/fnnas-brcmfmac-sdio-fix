# 驱动层修复工具（主方案）

> 适用环境：飞牛OS（FNOS）及同类 Debian 系系统、**SDIO 接口**、使用 `brcmfmac` 驱动的博通无线网卡。已在 ARM（如 RK3566）+ BCM4339 上验证；芯片型号与板级 NVRAM 文件名由脚本自动探测。
>
> ⚠️ **不是所有博通网卡都适用**：本脚本按 `<芯片>-sdio.*` 拼装固件文件名，因此仅适配 **SDIO 接口**。x86 平台常见的 PCIe / USB 博通网卡（文件名为 `-pcie` / `-usb`）**不适用**；非博通驱动（`iwlwifi` / `mt76` 等）也不适用。这两类请看 [网络自愈守护](../watchdog/README.md)。

---

## 一、这个脚本解决什么

SDIO 接口的博通 WiFi 网卡在飞牛OS 上常出现「连上又掉、反复报密码错误」的问题。日志分析表明，这往往不是密码输错，而是以下几个**驱动 / 固件层配置**问题叠加：

| 典型日志证据 | 含义 |
| --- | --- |
| `brcmfmac ... using brcm/brcmfmac<芯片>-sdio` | 自动识别到的无线芯片型号（脚本据此拼装文件名） |
| `Direct firmware load for brcm/brcmfmac<芯片>-sdio.<板型>.bin failed (-2)` | 板级 NVRAM（硬件参数文件）缺失 |
| `brcmf_c_process_clm_blob: no clm_blob available ... limited channels available` | 国家信道表 CLM blob 缺失，5GHz 信道受限 |
| `cfg80211: loaded regulatory.db is malformed or signature is missing/invalid` | 监管数据库签名验证失败，回退 WORLD 域 |
| `CTRL-EVENT-REGDOM-CHANGE init=CORE type=WORLD` | 每次断线都回到 WORLD 域 |

前三项叠加，会让驱动在路由器的 5GHz 信道上无法正常关联 / 握手，`wpa_supplicant` 于是报 `4-Way Handshake failed / WRONG_KEY`——那是**表象**，不一定是密码真的错了。

**能力边界（请注意）：**

- 芯片型号不局限于示例中的 BCM4339，脚本从 dmesg 自动探测（如 `brcmfmac4339`）；但**依赖官方固件库存在对应的 `<芯片>-sdio.clm_blob`、且能找到板级 NVRAM**。部分芯片缺这些文件，需按 [离线修复](#五设备已经断网时离线修复) 手动提供，否则相关检查项会报 FAIL。
- 上表第 4 项「固件版本过旧」：本脚本只做**诊断提示**，**不会升级固件**。若确认是固件问题，需另行更换固件文件。
- 架构方面脚本本身无架构判断，但**仅在 ARM 设备上实测**；x86 上的 PCIe / USB 网卡因文件名规则不同，本方案不适用。

本脚本负责修复上述可修复的驱动 / 固件层配置，并把它持久化。网络自愈守护（`wifi-watchdog`）已改为**可选项**，仅作兜底，不默认启用。

---

## 二、OTA 更新后是否需要重新修复？

**很可能需要，但脚本已经替你自动处理了。**

- `/lib/firmware/regulatory.db`、`.p7s`、`brcm/brcmfmac<芯片>-sdio.clm_blob` 都在根文件系统里，OTA 替换系统时可能被覆盖或恢复成有问题的版本。
- `/etc` 下的配置（udev 规则、crda、NetworkManager 配置）一般保留，但不能完全依赖。

因此脚本采用双层设计：

1. 修复时把官方文件**额外缓存到 `/etc/fnnas-brcmfmac-sdio-fix/cache/`**（`/etc` 通常在 OTA 中保留）。
2. 安装一个开机 oneshot 服务 `fnnas-brcmfmac-sdio-fix.service`，在 NetworkManager 启动前校验这些文件；一旦发现丢失或被改动，就**从缓存自动恢复**。

所以正常流程是：装一次 → OTA 后开机自动恢复 → 不需要人工重做。若某次 OTA 连 `/etc` 也重置了，缓存会一起丢失，此时重新执行一次 `--fix` 即可（脚本会检测缓存不完整）。

---

## 三、文件清单

| 文件 | 说明 |
| --- | --- |
| `fnnas-brcmfmac-sdio-fix.sh` | 诊断与修复主脚本 |
| `fnnas-brcmfmac-sdio-fix.service` | OTA 后自动恢复的开机服务（可关闭） |
| `install.sh` | 安装器 |
| `README.md` | 本文档 |

---

## 四、快速安装

把整个目录上传到设备，SSH 登录后执行：

```bash
cd /path/to/driver-fix
sudo bash install.sh
```

默认行为：**安装脚本 + 执行诊断 + 尝试修复 + 启用 OTA 开机恢复**，**不安装网络自愈守护**。

可选参数：

```bash
sudo bash install.sh --no-fix          # 只安装，不执行修复
sudo bash install.sh --no-autorestore  # 不启用 OTA 开机恢复
sudo bash install.sh --with-watchdog   # 同时启用网络自愈守护（可选兜底）
sudo bash install.sh --uninstall       # 卸载
```

> 修复过程需要联网下载 kernel.org 的官方文件；若设备此时已经连不上网，用下面的离线方式。

---

## 五、设备已经断网时：离线修复

在有网络的电脑上准备以下文件，放到一个目录（例如 `/volume1/usb/fix-files/`）。`<芯片>` 由脚本从 dmesg 自动探测，常见为 `brcmfmac4339`：

```
regulatory.db                       # wireless-regdb 官方数据库
regulatory.db.p7s                   # 对应签名
<芯片>-sdio.clm_blob                # linux-firmware 中的 CLM blob
<芯片>-sdio.<板型>.bin              # 板级 NVRAM（可选，能找到就放）
```

然后在设备上：

```bash
sudo /usr/local/sbin/fnnas-brcmfmac-sdio-fix --fix-offline /volume1/usb/fix-files
sudo reboot
```

前三个文件可从 kernel.org 官方仓库获取：

- `https://git.kernel.org/pub/scm/linux/kernel/git/sforshee/wireless-regdb.git/plain/regulatory.db`
- `https://git.kernel.org/pub/scm/linux/kernel/git/sforshee/wireless-regdb.git/plain/regulatory.db.p7s`
- `https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/brcm/brcmfmac4339-sdio.clm_blob`（把 `4339` 换成你的芯片型号）

板级 NVRAM 文件名形如 `brcmfmac4339-sdio.<板型>.bin`，需要从该机型的原厂固件或社区资源提取；找不到也没关系，脚本会把通用 `<芯片>-sdio.txt` 的 `country` 改成 `CN` 作为折中。设备 dmesg 里若出现 `Direct firmware load for brcm/xxx failed`，那个 `xxx` 就是需要的文件名。

---

## 六、常用命令

```bash
# 全面诊断（只读，最常用）
sudo /usr/local/sbin/fnnas-brcmfmac-sdio-fix --check

# 修复（优先用缓存，缺失时在线下载）
sudo /usr/local/sbin/fnnas-brcmfmac-sdio-fix --fix

# 离线修复
sudo /usr/local/sbin/fnnas-brcmfmac-sdio-fix --fix-offline /path/to/files

# 查看 OTA 恢复服务状态
sudo systemctl status fnnas-brcmfmac-sdio-fix.service

# 日志
sudo tail -f /var/log/fnnas-brcmfmac-sdio-fix.log
```

`--check` 会逐项输出 `[OK] / [WARN] / [FAIL]`，包括固件版本、regdb 签名、当前监管域、CLM blob、NVRAM、省电状态和 OTA 缓存完整性。

---

## 七、脚本具体做了什么

1. **regulatory.db**：备份原文件，删除可能存在的 Debian alternatives 符号链接，安装官方签名的 `regulatory.db` + `.p7s`。
2. **监管域持久化**：写 `/etc/default/crda` 的 `REGDOMAIN=CN`，并添加 udev 规则，在无线设备加入时执行 `iw reg set CN`。
3. **CLM blob**：安装 `<芯片>-sdio.clm_blob` 到 `/lib/firmware/brcm/`。
4. **NVRAM**：自动探测板级文件名；优先安装缓存中的板级 NVRAM，否则把通用 `.txt` 的 `country` 改为 `CN`。
5. **省电与 P2P**：写 NetworkManager 配置 `wifi.powersave=2` 关闭省电（博通网卡在省电模式下更容易掉线）。
6. **缓存与自恢复**：所有下载的文件同时存入 `/etc/fnnas-brcmfmac-sdio-fix/cache/`；开机服务校验并在必要时恢复。
7. 重载无线驱动与 NetworkManager；**regulatory.db 需要重启内核才会重新校验**，脚本完成后请重启一次。

原文件备份在 `/var/backups/fnnas-brcmfmac-sdio-fix/`，需要回退时可从中取回。

---

## 八、验证是否真的治好了

重启后执行：

```bash
sudo dmesg | grep -E 'regulatory|clm_blob|brcmfmac'
# 期望：没有 "malformed or signature is missing/invalid"，没有 "no clm_blob available"

iw reg get | head -3
# 期望：country CN

iw dev wlan0 link
# 观察数小时：不再出现周期性 ASSOC-REJECT / 4-Way Handshake failed

sudo /usr/local/sbin/fnnas-brcmfmac-sdio-fix --check
# 期望：全部 [OK]
```

若仍出现 `ASSOC-REJECT status_code=16`，请重点检查第 4 项的板级 NVRAM 是否真的到位；那是最难自动获取的一项。

---

## 九、与网络自愈脚本的关系

- 本目录的方案是**治本**，解决驱动 / 固件配置。
- `../watchdog/` 是**可选兜底**，负责连接层面的自动重连，默认不随本脚本启用。
- 如果你只想要治本，装完本脚本即可；如果现场无线环境仍不稳定，再执行：

```bash
sudo bash ../watchdog/install.sh --enable-watchdog
```

---

## 十、卸载

```bash
sudo bash install.sh --uninstall
```

卸载会删除脚本和开机服务，但**保留** `/etc/fnnas-brcmfmac-sdio-fix/cache` 缓存和 `/var/backups/fnnas-brcmfmac-sdio-fix` 备份；已安装的固件文件不会自动还原。
