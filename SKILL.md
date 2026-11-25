---
name: windows-bluetooth-repair
description: Diagnose and repair Windows Bluetooth radios that fail to start (Device Manager Code 10 / CM_PROB_FAILED_START), vanish from Settings after boot, or need a manual restart every single boot. Provides read-only diagnosis, the escalating repair sequence that actually works for Intel/Realtek/MediaTek USB Bluetooth modules, and a boot-time self-healing guard task that makes the repair permanent. Use when a user reports 蓝牙打不开, 蓝牙开关消失, 蓝牙设备管理器有感叹号, 蓝牙每次开机都要手动修复, 电脑蓝牙用不了, Bluetooth cannot start, Code 10 on the Bluetooth adapter, or Bluetooth disappears after reboot.
agent_created: true
---

# Windows 蓝牙修复

> 面向人类读者的完整说明（症状对照、原理、安全边界）见仓库 `README.md`。

## 用途

在 Windows 上定位并修复"蓝牙起不来"这一类问题，并把它变成一次性解决的永久修复。
核心场景是适配器枚举到了、但驱动初始化失败（设备管理器 **Code 10 / CM_PROB_FAILED_START**），
表现为：设置里蓝牙开关点了没反应、开关整个消失、下面挂的耳机鼠标全都"不见了"、
重启有时好有时坏、每次都得手动折腾一遍。

## 何时使用

出现下列任一说法时使用本技能：

- "蓝牙打不开了 / 蓝牙开关没了 / 点开关没反应"
- "设备管理器里蓝牙有个感叹号 / 代码 10"
- "蓝牙耳机、鼠标突然全都不见了"
- "每次开机都要重新弄一下蓝牙"（← 本技能的重点场景）
- "Bluetooth service won't start", "Bluetooth adapter Code 10"

不适用：蓝牙能连但音质/延迟问题、配对码弹窗、蓝牙音频断连——那些属于音频栈或配对问题。

## ⚠️ 关键约束：本机不能自动提权

所有修复动作都需要管理员权限，而**宿主安全策略禁止智能体自行拉起提权进程**
（`Start-Process -Verb RunAs` 会被 "Command blocked for security" 拦下）。
因此固定做法：

1. 用脚本生成一个自提权的 `.bat`
2. 用 `present_files` 把它交给用户，说明"双击 → 在 UAC 窗口点『是』"
3. 用户跑完后，读脚本写出的日志文件来确认结果，**不要凭猜测报告成功**

## 工作流

### 第 1 步：只读诊断（无需管理员）

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/diagnose-bluetooth.ps1
```

输出七段：服务状态、当前 Present 的蓝牙设备及问题码、幽灵节点数、近 7 天蓝牙驱动错误、
USB 链路省电状态、快速启动状态、守卫任务是否存在。

判读要点（详细见 `references/decision-tree.md`）：

- `Status=Error` + `Problem=CM_PROB_FAILED_START` → 本技能主场景，走修复
- **一台都不 Present** → 射频被关或 BIOS 禁用，不是驱动问题，别乱修
- `CM_PROB_PHANTOM` 大量出现 → 正常现象，是射频没起来的连带结果，**不要删**
- `BTHUSB id=7` → 硬件级错误上报，支持"上电状态卡死"的判断

### 第 2 步：一次性修复

把 `scripts/run-elevated.bat` 和 `scripts/repair-bluetooth.ps1` 复制到同一目录交给用户运行：

```
run-elevated.bat repair-bluetooth.ps1
```

脚本自动定位"状态非 OK 的蓝牙射频"，按 **重启驱动栈 → 禁用/启用循环 → 启服务 → 关整条
USB 链路省电** 的顺序修复，日志写到 `%TEMP%\bt-repair-log.txt`。
全部动作可逆，不卸载设备，**配对信息不丢**。

读日志确认最终 `FINAL : Status=OK`。

### 第 3 步：判断要不要装守卫

- 用户说"每次开机都得重来" / 修好后重启又会坏 → **必须装** `install-guard.ps1`
- 修好后一直正常 → 不必装

装法：

```
run-elevated.bat install-guard.ps1
```

产出：`C:\ProgramData\BTGuard\bt-guard.ps1` + 计划任务 `BTGuardAutoRepair`
（SYSTEM / 最高权限 / 两个触发器：**开机延迟约 25 秒**、**从睡眠唤醒后**）。
若事件触发器创建失败，会自动降级为仅开机触发，不影响主功能。
守卫在状态正常时**什么都不做**，
只在检测到异常时才执行禁用/启用，日志 `C:\ProgramData\BTGuard\bt-guard.log`。

### 第 4 步：验证闭环（不可跳过）

让用户**重启一次**，然后读 `bt-guard.log`：

- `healthy - no action` → 守卫生效且未触发，问题已收敛
- `repair attempt 1 ... after attempt 1 : Status=OK` → 守卫在工作，但**仍在治标**，
  必须告知用户并推进第 5 步

### 第 5 步：根因升级

守卫每次开机都在修，说明要动根因：更新厂商蓝牙驱动（Intel AX200/AX201 用官方
Wireless Bluetooth 包）→ 查 BIOS 的 ErP/EuP 与 USB S5 供电 → 完整放电
（关机、拔电源、长按电源键 30 秒）。这一步通常要用户自己下载安装，把链接给到即可。

## 脚本清单

| 文件 | 作用 | 需要管理员 |
|---|---|---|
| `scripts/diagnose-bluetooth.ps1` | 七段只读诊断报告 | 否 |
| `scripts/repair-bluetooth.ps1` | 一次性阶梯修复，参数 `-InstanceId` `-Attempts` `-SkipPowerSave` | 是 |
| `scripts/install-guard.ps1` | 安装开机自愈任务，参数 `-DevicePattern` `-DelaySeconds` `-TaskName` | 是 |
| `scripts/run-elevated.bat` | 通用自提权启动器：`run-elevated.bat <脚本名>` | — |

日志位置：修复 `%TEMP%\bt-repair-log.txt`、安装 `%TEMP%\bt-install-log.txt`、守卫 `C:\ProgramData\BTGuard\bt-guard.log`。

## 三条非显然的经验（决定成败）

1. **`pnputil /restart-device` 常常无效**。它会回报 "Device restarted successfully"，
   而设备状态仍是 Code 10。真正起作用的是 **Disable → Enable**（真正的 D3→D0 重枚举）。
   所以每一步之后都必须重新 `Get-PnpDevice` 复查，不能信命令输出。
2. **只关射频的省电不够**。要沿 `DEVPKEY_Device_Parent` 一路关到 USB 根集线器、乃至 PCI 控制器——
   这条链上任何一环被允许断电，射频都可能醒不过来。链路上若还有中间集线器，脚本会自动一并处理。
3. **不要清理幽灵设备**。`CM_PROB_PHANTOM` 的几十个节点是症状不是病因，
   射频一起来它们自己就回来；去删等于让用户重新配对所有设备。
4. **别用"查不到任务"判定没装**。SYSTEM 级别的计划任务在非管理员会话里常常查不到
   （`C:\Windows\System32\Tasks` 拒绝访问，`schtasks` 也可能被策略拦），
   `Get-ScheduledTask` 返回空并不代表没装。install 脚本会写
   `C:\ProgramData\BTGuard\installed.json` 标记来绕开这个坑，诊断以此为准。

## 参考

- `references/decision-tree.md` —— 完整判读表、L0~L4 升级阶梯、反模式清单、常见厂商 VID
