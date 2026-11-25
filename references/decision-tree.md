# 蓝牙故障判读与升级阶梯

## 一、先分清三种"蓝牙没了"

用 `scripts/diagnose-bluetooth.ps1` 的 [2] 段判断。

| 现象 | 含义 | 处理方向 |
|---|---|---|
| 蓝牙类设备**一台都不 Present** | 射频被关（飞行模式/物理开关/BIOS 禁用），或适配器根本没枚举到 | 查 BIOS、物理开关、Fn 快捷键；不是驱动问题 |
| 适配器 Present 但 `Status=Error`，`Problem=CM_PROB_FAILED_START`（Code 10） | **驱动已加载但设备初始化失败** —— 本文档的主要场景 | 走第二节阶梯 |
| 适配器 Present 且 `Status=OK`，但"设置里蓝牙开关不见" | 适配器正常，问题在 UI 层/服务/策略 | 查 `bthserv`、注册表 `SystemSettings\EnableBluetooth`、组策略 |

> 补充识别：`Problem=CM_PROB_PHANTOM` 的设备**不是故障**。射频没起来时，所有已配对设备的子节点都会变成幽灵节点。射频恢复后它们自动回来。**绝不要为了"清理"去删这些设备**——那会让用户丢掉配对。

## 二、修复阶梯（按序，每级验证后再往下）

**L0 只读诊断** → `diagnose-bluetooth.ps1`（无需管理员）

**L1 `pnputil /restart-device`**
只是重载驱动栈。对"驱动文件被占用/服务卡住"有用；
对**上电状态卡死**这类问题**通常无效**——实测会出现"命令报成功、状态仍是 Code 10"。
所以：跑完必须重新读一次状态，不要相信命令的退出提示。

**L2 Disable → Enable（真正有效的那一级）**
这是让设备经历一次 D3→D0 断电重枚举。90% 的 Intel AX200/AX201 类 Code 10 在这一级恢复。
`Disable-PnpDevice -Confirm:$false` → 等 3s → `Enable-PnpDevice -Confirm:$false` → 等 6s → 复查。
最多 3 轮。降级到 L2 仍失败，说明不是电源状态问题。

**L3 服务与省电加固**
- `Start-Service bthserv`
- 沿 `DEVPKEY_Device_Parent` 向上取**整条 USB 链路**（射频 → 中间集线器（若有）→ 根集线器 → PCI 控制器），
  逐个把 `MSPower_DeviceEnable.Enable` 设为 `False`。
  只关射频本身往往不够：实测射频与根集线器是两个**独立**的可省电节点，根集线器被断电时射频一样醒不过来。
  注意别把"同一控制器下的兄弟设备"当父节点——用 `DEVPKEY_Device_Parent` 取，不要靠 InstanceId 前缀猜。
- 全局关闭 USB 选择性暂停：
  `powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0`（DC 同理）

**L4 根因级**
L3 之后**每次开机仍然复发**，说明 L2 只是治标。按概率排序：
1. **驱动版本过旧**（如 Intel 23.90.0.8 及更早）→ 装 Intel 官方 Wireless Bluetooth 包，AX200/AX201 通用
2. **BIOS/固件**：ErP/EuP 深度省电、USB S5 供电策略；顺手查 BIOS 更新
3. **完整放电**：关机 → 拔电源 → 长按电源键 30s → 开机。S5 残留状态普通重启清不掉
4. 换插槽无效（内置模块），但可查天线/屏蔽罩是否松动（信号差而非起不来）

## 三、什么时候装"自愈守卫"

判据：**L2 能修好，但重启后又坏**。这就是"每次开机都要手动修一次"的典型形态，
根因可能是短时间改不掉的（驱动/BIOS），此时用 `install-guard.ps1` 落地：

- 两个触发器：开机延迟 ~25s、睡眠唤醒后；以 SYSTEM 最高权限运行
- 状态 OK → 直接退出（零成本、无副作用）
- 状态非 OK → 执行 L2 + L3，写日志到 `C:\ProgramData\BTGuard\bt-guard.log`
- 用户从此不需要手动介入

守卫是**安全网**，不是根因修复。要向用户说清这点：如果日志里每次开机都出现
"repair attempt 1"，说明还在治标，应继续做 L4。

## 四、反模式（不要做）

- ❌ 删除/重装所有已配对设备 —— 丢配对，不解决 Code 10
- ❌ 卸载设备时勾"删除驱动程序" —— 会把唯一能用的 INF 也删掉，可能变"未知设备"
- ❌ 把 `bthserv` 改成"自动"并反复重启 —— 默认手动是按需启动，属正常
- ❌ 拿"关闭快速启动"当万能药 —— 只在 `HiberbootEnabled=1` 时才有意义，先查再动
- ❌ 相信 `pnputil` 的 "Device restarted successfully"，必须复查 `Status`
- ❌ 用注册表暴力改 `Enum` 下的设备键 —— 极易造成设备彻底消失

## 五、常见厂商 VID（用于推导设备匹配模式）

| VID | 厂商 | 备注 |
|---|---|---|
| `8087` | Intel | AX200/AX201/AX211/AX210 内置蓝牙，Code 10 高发 |
| `0BDA` | Realtek | 常见于 USB 蓝牙棒 |
| `0A5C` | Broadcom | 老款笔记本 |
| `0E8D` | MediaTek | MT79xx |
| `0489` / `0A12` | Qualcomm / CSR | USB 蓝牙棒 |

匹配模式取 `USB\VID_xxxx&PID_xxxx*`，不要写死完整 InstanceId——换端口/换机器就失效。

## 六、验证闭环

1. `Get-PnpDevice -Class Bluetooth -PresentOnly` → 射频 `Status=OK`
2. Present 数量从 1 恢复到二三十个（子节点回来了）
3. `bthserv` = Running
4. 让用户实际连一次设备（耳机/鼠标），能出声/能用才算通
5. 装过守卫的：**必须重启一次**再读 `bt-guard.log`，确认"healthy - no action"，
   否则无法证明守卫真的生效
