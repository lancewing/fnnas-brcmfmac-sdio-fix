# fnnas-brcmfmac-sdio-fix

> 飞牛OS（FNOS）等 Debian 系 NAS / 电视盒子上，针对**博通 brcmfmac / SDIO 无线网卡**反复掉线、报 `WRONG_KEY`、`ASSOC-REJECT` 导致失联的问题，提供「驱动层治本 + 连接层兜底」两套方案。
>
> 项目名即适用范围：**fnnas**（飞牛OS）+ **brcmfmac**（博通驱动）+ **sdio**（总线接口）+ **fix**。非此组合的设备请先看 [适配范围速查](#适配范围速查)。

> ⚠️ **适配范围有限，请先读 [适配范围速查](#适配范围速查)**：驱动层方案只面向 **SDIO 接口的博通网卡**，并非所有博通网卡 / 所有架构都适用；网络自愈守护适用范围更广。

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-Linux%20%2F%20FNOS-orange.svg)

---

## 目录

- [问题背景](#问题背景)
- [适配范围速查](#适配范围速查)
- [两套方案](#两套方案)
- [项目结构](#项目结构)
- [快速开始](#快速开始)
- [OTA 更新说明](#ota-更新说明)
- [适用与不适用](#适用与不适用)
- [免责声明](#免责声明)
- [致谢](#致谢)
- [License](#license)

---

## 问题背景

一些基于博通（Broadcom）WiFi 芯片、**通过 SDIO 总线连接**、使用 `brcmfmac` 驱动的设备（常见于 ARM 电视盒子 / 开发板），在飞牛OS 上会出现这样的现象：

- 设备一开始联网正常，某天后突然「网络上消失」，但机器其实还活着；
- WiFi 反复断开重连，`wpa_supplicant` 报 `4-Way Handshake failed - pre-shared key may be incorrect`、`reason=WRONG_KEY`；
- NetworkManager 每次扫描都使用**随机 MAC**，随后 `ASSOC-REJECT status_code=16`，陷入无效扫描循环；
- 远程访问服务因无法解析域名、隧道登录失败而失联；
- 人工断电重启后能恢复一段时间，但过几天问题复现。

深入日志分析后发现，`WRONG_KEY` 往往是**表象**。更底层的原因通常是以下驱动 / 固件层问题叠加：

1. `regulatory.db` 监管数据库签名验证失败，系统回退到 WORLD 域，5GHz 信道大量不可用；
2. 国家信道表 `clm_blob` 缺失，驱动警告 `limited channels available`；
3. 板级 NVRAM（硬件参数文件）缺失，天线 / 功率 / 国家参数不正确；
4. 固件版本过旧，稳定性差（**注**：本工具只做诊断提示，不负责升级固件）；
5. 叠加 NetworkManager 的随机 MAC 扫描行为，导致关联被拒、凭据失效。

本项目据此提供两套可独立使用的方案。

---

## 适配范围速查

请先对照下表判断你的设备是否适用——**不要假设「博通网卡」就一定适配**：

| 维度 | 方案 A：驱动层修复 | 方案 B：网络自愈守护 |
| --- | --- | --- |
| **CPU 架构** | 架构无关，但**仅在 ARM（如 RK3566）上实测验证**；x86 未见验证案例 | 架构无关，纯 NetworkManager 层逻辑 |
| **无线总线接口** | **仅 SDIO**（文件名按 `<芯片>-sdio.*` 拼装）。PCIe / USB 接口的博通网卡**不适用** | 不限接口（只认系统里的无线网卡接口名，默认 `wlan0`） |
| **驱动** | 仅 `brcmfmac`（博通） | 不限（`brcmfmac` / `iwlwifi` / `mt76` 等均可，需改 `DRIVER_MODULE`） |
| **芯片型号** | 不局限于某一型号，脚本从 dmesg 自动探测（如 `brcmfmac4339`）。**但**依赖官方固件库存在对应的 `<芯片>-sdio.clm_blob`，且能找到板级 NVRAM；部分芯片缺这些文件，需手动离线提供 | 与芯片型号无关 |
| **系统要求** | Debian 系 + `iw` / `curl` / `openssl` + systemd + root | Debian 系 + NetworkManager + `nmcli` / `ip` / `ping` + systemd + root |

**一句话结论：**

- 你的设备若是 **ARM 盒子 + SDIO 博通网卡**（本项目的原始场景）：两套方案都适用。
- 若是 **x86 主机 / PCIe 或 USB 无线网卡**：方案 A **不适用**（文件名规则不同），可尝试方案 B 做掉线自愈。
- 若是非博通驱动（`iwlwifi` / `mt76` 等）：方案 A 不适用，方案 B 可通用。

> 判断接口的方法： WiFi 模块通常是 SDIO 卡（ARM 盒子板载）或 M.2 / PCIe / USB 设备（x86），可结合 `dmesg | grep -i brcmf`、`lspci`（PCIe）、`lsusb`（USB）判断；驱动层脚本探测失败的日志里会出现 `using brcm/brcmfmacXXXX-sdio` 字样则属 SDIO。

---

## 两套方案

| | 方案 A：驱动层修复（主方案，治本） | 方案 B：网络自愈守护（可选兜底） |
| --- | --- | --- |
| 目录 | [`driver-fix/`](driver-fix/README.md) | [`watchdog/`](watchdog/README.md) |
| 解决层面 | 固件 / 监管域 / 驱动配置 | 连接层面的掉线自动重连 |
| 核心动作 | 修复 `regulatory.db`、CLM blob、板级 NVRAM，固化 `country CN`，关闭省电，缓存文件供 OTA 自恢复 | 禁用随机 MAC，健康检测，分级修复（软重连 → 网络重置 → 驱动重置） |
| 是否默认启用 | 安装即启用 | **默认不启用**，需显式 `--enable-watchdog` |
| 适用场景 | 出现上述底层问题的 **SDIO 博通网卡**（见 [适配范围速查](#适配范围速查)） | 驱动层修好后仍不稳定，或非博通 / PCIe / USB 网卡的掉线自愈 |

**建议路径：先装方案 A；若仍不稳定，再叠加方案 B。** 方案 B 单独使用只能缓解，无法根治底层固件配置问题。

---

## 项目结构

```
fnnas-brcmfmac-sdio-fix/
├── README.md                          # 项目总览（本文档）
├── LICENSE                            # MIT 许可证
├── .gitignore
├── driver-fix/                        # 方案 A：驱动层修复（主方案，brcmfmac-sdio 专用）
│   ├── README.md                      #   详细使用说明
│   ├── fnnas-brcmfmac-sdio-fix.sh     #   诊断 / 修复主脚本
│   ├── fnnas-brcmfmac-sdio-fix.service#   OTA 后开机自恢复服务
│   └── install.sh                     #   安装器
└── watchdog/                          # 方案 B：网络自愈（可选兜底，架构/驱动无关）
    ├── README.md                      #   详细使用说明
    ├── wifi-watchdog.sh               #   守护脚本
    ├── wifi-watchdog.service          #   systemd 单元
    ├── wifi-watchdog.conf.example     #   配置模板
    └── install.sh                     #   安装器
```

> 说明：方案 B 的子目录已归入本项目，但其脚本 / 服务 / 日志内部仍保留中性的 `wifi-watchdog` 命名——因为它是架构、驱动、接口都无关的通用组件，若强行加上 `brcmfmac-sdio` 前缀会造成新的名实不符。

两个子目录内的脚本相互独立；只有在方案 A 安装器中用 `--with-watchdog` 时才会调用方案 B 的安装器。

---

## 快速开始

### 方案 A：驱动层修复

把 `driver-fix/` 目录上传到设备，SSH 登录后：

```bash
cd /path/to/driver-fix
sudo bash install.sh
sudo reboot
```

安装器默认会：安装脚本与服务 → 诊断 → 尝试修复 → 启用 OTA 开机自恢复。**修复后请重启一次**，让内核重新校验 `regulatory.db`。

若设备已断网无法在线下载，先在联网电脑上备好官方文件，再用离线模式（详见 [方案 A 文档](driver-fix/README.md#五设备已经断网时离线修复)）：

```bash
sudo /usr/local/sbin/fnnas-brcmfmac-sdio-fix --fix-offline /path/to/files
sudo reboot
```

### 方案 B：网络自愈（可选）

```bash
cd /path/to/wifi-watchdog
sudo bash install.sh --enable-watchdog
```

默认不加 `--enable-watchdog` 只安装文件、不启用守护。详见 [方案 B 文档](watchdog/README.md)。

### 验证结果

```bash
sudo /usr/local/sbin/fnnas-brcmfmac-sdio-fix --check   # 期望全部 [OK]
iw reg get | head -3                                 # 期望 country CN
sudo dmesg | grep -E 'regulatory|clm_blob'            # 期望无签名错误、无 clm_blob 缺失
iw dev wlan0 link                                     # 持续稳定，不再周期性断开
```

---

## OTA 更新说明

**问：每次飞牛OS OTA 更新后，是否需要重新修复？**

答：**很可能需要，但脚本已经自动处理了。**

- `regulatory.db`、`.p7s`、`clm_blob` 位于 `/lib/firmware/`，OTA 替换系统时可能被覆盖回有问题的版本；
- 脚本在修复时会把这些文件**额外缓存到 `/etc/fnnas-brcmfmac-sdio-fix/cache/`**（`/etc` 通常在 OTA 中保留）；
- 开机 oneshot 服务 `fnnas-brcmfmac-sdio-fix.service` 会在 NetworkManager 启动前校验文件，发现丢失或被改动就从缓存自动恢复。

正常情况下装一次即可跨 OTA；只有连 `/etc` 都被重置的极端 OTA 才需手动重跑一次 `--fix`。

---

## 适用与不适用

详细对照见上文 [适配范围速查](#适配范围速查)。这里补充场景层面的限制：

**适用**

- 飞牛OS 及同类 Debian 系系统；
- **方案 A**：SDIO 接口、出现 WORLD 域 / clm_blob 缺失 / NVRAM 缺失等日志特征的博通网卡（芯片与板级文件名由脚本自动探测）；
- **方案 B**：任何有 NetworkManager 的无线网卡（含非博通驱动），用于掉线自动重连；
- 需要跨 OTA 持久化固件修复的场景（方案 A）。

**不适用 / 局限**

- **x86 / PCIe / USB 网卡**（方案 A）：固件文件名规则不同，脚本按 `-sdio` 拼装会找不到文件；
- **非博通驱动**（方案 A）：如 `iwlwifi`、`mt76`，不适用；
- **官方固件库缺文件的芯片**（方案 A）：需自行离线提供 `<芯片>-sdio.clm_blob` 与板级 NVRAM；
- 路由器 WiFi 名称或密码确实被改过的情况——脚本无法凭空恢复正确密码，需在系统设置里重新输入；
- 路由器开启了 MAC 黑白名单且配置错误——请确认白名单中填的是设备真实 MAC；
- 信号过弱、AP 隔离、客户端数量限制等路由器侧问题——需检查路由器，或改接有线。

---

## 免责声明

- 本工具按「现状」提供，不附带任何明示或暗示的担保。使用前请自行评估并备份重要数据。
- 脚本会修改系统固件、udev 规则、NetworkManager 配置并重启网络服务，过程中会短暂断网；请避免在依赖网络的任务运行时执行。
- 固件文件下载自 kernel.org 官方仓库，版权归各自所有者所有；本项目仅提供自动化安装与配置，不对第三方文件负责。
- 作者及贡献者不对使用本工具造成的任何数据丢失、设备异常或网络中断承担责任。

---

## 致谢

本项目由 **WorkBuddy**（腾讯 AI 助手）协助完成——从最初的海量日志排查、根因定位，到修复脚本的编写、模拟环境验证，再到这份文档的整理，WorkBuddy 全程参与。感谢 WorkBuddy 在日志分析、Shell 脚本工程化和安全清理方面的帮助，让这套方案得以成型并分享给更多人。

同时感谢开源社区，尤其是 kernel.org 的 `wireless-regdb` 与 `linux-firmware` 项目，以及飞牛OS 社区在相关问题上的经验分享。

---

## License

本项目代码采用 [MIT License](LICENSE) 开源。固件文件（regulatory.db、clm_blob 等）来自上游项目，遵循其各自的许可证。
