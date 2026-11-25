# windows-bluetooth-repair

> 修复 Windows 蓝牙「打不开 / 设备管理器代码 10 / 每次开机都要手动修一次」的问题

一套可复用的诊断与修复脚本，核心是一个**自愈守卫**：装一次，之后蓝牙再抽风会被自动拉起来，不用再手动折腾。

实测环境：Windows 11 家庭版（build 26300）、Intel Wi-Fi 6 AX200 内置蓝牙（`USB\VID_8087&PID_0029`）、驱动 23.90.0.8。

---

## 一、先确认你遇到的是同一类问题

打开设备管理器（`devmgmt.msc`）看「蓝牙」分类：

| 现象 | 是否适用 |
|---|---|
| 适配器上有黄色感叹号，属性显示 **代码 10（该设备无法启动）** | ✅ 就是这个 |
| 设置里蓝牙开关点了没反应 / 开关整个消失 | ✅ 大概率是 |
| 之前配对过的耳机、鼠标突然全都不见了 | ✅ 是它的连带结果 |
| **每次重启都得重新弄一遍，有时好有时坏** | ✅ 本项目的重点场景 |
| 睡眠唤醒后蓝牙消失 | ✅ 守卫已覆盖该触发时机 |
| 蓝牙能连，但音质差 / 延迟高 / 老是断 | ❌ 本项目不处理 |
| 设备管理器里蓝牙分类完全空白，一台都没有 | ⚠️ 可能是 BIOS 禁用或物理开关，见「已知边界」 |

## 二、为什么「重启驱动」这类常规做法没用

这是本项目最重要的一条发现，也是很多教程踩的坑：

```
pnputil /restart-device "USB\VID_8087&PID_0029\..."
  -> Restarting device...
  -> Device restarted successfully.        ← 命令说成功了
```

**但设备状态依然是代码 10。** 因为 `restart-device` 只是重载了一遍驱动栈，没有真正切断供电。这类故障的本质是：模块卡在一个错误的上电状态，必须让它经历一次 **D3 → D0 的断电重枚举** 才能醒过来。

真正有效的是 **禁用设备 → 启用设备**：

```powershell
Disable-PnpDevice -InstanceId $id -Confirm:$false
Start-Sleep 3
Enable-PnpDevice  -InstanceId $id -Confirm:$false
```

判断依据来自系统日志：故障时 `BTHUSB` 会报 **事件 ID 7「发生硬件错误」**——这是硬件层自己上报的错误，而非驱动层。所以再怎么重装驱动也没用。

## 三、快速开始

### 1. 诊断（不需要管理员）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diagnose-bluetooth.ps1
```

输出七段：蓝牙服务状态、当前存在的蓝牙设备及问题码、幽灵节点数、近 7 天蓝牙驱动错误、USB 链路省电状态、快速启动状态、守卫任务状态。只读，不改任何设置。

### 2. 修复（需要管理员）

双击 `scripts\run-elevated.bat` 会自动请求 UAC；也可以在管理员 PowerShell 里：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\repair-bluetooth.ps1
```

按阶梯顺序执行，每步之后都重新读一次设备状态（不信命令的自我报告）：

1. `pnputil /restart-device` —— 重载驱动栈（常常不够）
2. **禁用 → 启用**，最多 3 轮 —— 真正有效的那一步
3. 启动 `bthserv`
4. 沿设备父链关闭整条 USB 链路的省电

日志：`%TEMP%\bt-repair-log.txt`

### 3. 永久化（推荐给「每次开机都要修」的人）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install-guard.ps1
```

会安装：

- 守卫脚本 `C:\ProgramData\BTGuard\bt-guard.ps1`
- 计划任务 `BTGuardAutoRepair`：以 **SYSTEM** 运行、最高权限
  - 触发器一：**开机后延迟约 25 秒**（等 USB 栈就绪）
  - 触发器二：**从睡眠唤醒后**（覆盖「合盖再开就没了」的情况）

守卫的逻辑是**先检查再动手**：

- 蓝牙正常 → 记一行 `healthy - no action` 直接退出，**零动作、零副作用**
- 蓝牙异常 → 执行禁用/启用循环，最多 3 次，再把服务拉起来

日志：`C:\ProgramData\BTGuard\bt-guard.log`

装完**重启一次**再读日志，才能确认真的生效：

```
healthy - no action                                  ← 理想结果
repair attempt 1 ... after attempt 1 : Status=OK     ← 守卫在工作，但仍在治标
```

出现第二种，说明根因还在，请继续看「已知边界」。

## 四、安全说明

这些脚本只做四件事，**全部可逆**：

- 重启 / 禁用 / 启用设备 —— 等同于在设备管理器里手动点一遍
- 启动系统自带服务 —— 不把启动类型改成「自动」
- 关闭设备省电选项 —— 只是让系统不把这个设备断电，随时可在设备管理器勾回去
- 写一个日志文本 —— 存放在 `C:\ProgramData\BTGuard\`

明确**不会**做的事：

- ❌ 不卸载设备、不勾「删除驱动程序」
- ❌ 不动注册表 `HKLM\SYSTEM\CurrentControlSet\Enum`
- ❌ 不删除任何已配对设备 —— 耳机、鼠标的配对信息不会丢

顺带一提：设备管理器里那几十个「幽灵设备」（`CM_PROB_PHANTOM`）是适配器没起来时的正常现象，适配器一恢复它们自己就回来，**不要去清理**。

## 五、仓库结构

```
windows-bluetooth-repair/
├── README.md                         # 本文件
├── SKILL.md                          # AI 技能入口：触发条件 + 五步工作流 + 经验沉淀
├── LICENSE                           # MIT
├── scripts/
│   ├── diagnose-bluetooth.ps1        # 只读诊断，免管理员
│   ├── repair-bluetooth.ps1          # 阶梯修复，需管理员
│   ├── install-guard.ps1             # 安装自愈任务，需管理员
│   └── run-elevated.bat              # 通用自提权启动器
└── references/
    └── decision-tree.md              # 判读表、L0~L4 升级阶梯、反模式清单、厂商 VID
```

脚本不写死任何一台机器的设备 ID：运行时自动定位「状态非 OK 的蓝牙射频」，并按
`USB\VID_xxxx&PID_xxxx*` 生成匹配模式，因此 Intel / Realtek（`0BDA`）/ MediaTek（`0E8D`）
等 USB 蓝牙模块都适用。

### 作为 WorkBuddy 技能使用

把整个目录复制到技能目录即可（下次会话生效）：

```powershell
Copy-Item -Recurse .\windows-bluetooth-repair "$HOME\.workbuddy\skills\windows-bluetooth-repair"
```

之后直接说「我电脑蓝牙打不开了」就会自动命中。

## 六、已知边界

能解决「驱动初始化失败」，解决不了「硬件或固件根本没把设备交出来」：

- 蓝牙分类**一台设备都没有** → 先查 BIOS 里蓝牙/无线是否被禁用、笔记本有无 Fn 物理开关
- 守卫**每次都在修** → 说明是治标。按概率依次尝试：
  1. 更新厂商蓝牙驱动（Intel AX200/AX201 用官方 Wireless Bluetooth 包）
  2. BIOS 里关掉 ErP/EuP 深度省电，检查 USB S5 供电策略
  3. 完整放电：关机 → 拔电源 → 长按电源键 30 秒 → 开机（S5 残留状态普通重启清不掉）
- 换端口 / 换机器后设备实例 ID 会变 —— 重跑一次 `install-guard.ps1` 即可

## 七、免责

修改系统设备状态存在风险，请在理解每一步作用的前提下使用。脚本已在上述实测环境验证，
但不同主板 / 固件 / 驱动版本行为可能不同，建议先跑只读的 `diagnose-bluetooth.ps1` 确认症状。

## License

[MIT](LICENSE)
