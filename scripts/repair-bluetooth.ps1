<#
.SYNOPSIS
    One-shot recovery for a Windows Bluetooth radio that reports Problem Code 10
    (CM_PROB_FAILED_START) or is otherwise present but not working.

.DESCRIPTION
    Applies the recovery sequence that actually works on Intel/Realtek/MediaTek
    USB Bluetooth modules, in escalating order:

      1. pnputil /restart-device    (driver stack reload - often NOT enough)
      2. Disable -> Enable          (true D3->D0 power cycle + re-enumeration)
      3. start the Bluetooth support service
      4. disable "allow the computer to turn off this device" along the whole
         USB parent chain, so the radio is not left half-powered next boot

    Every step is reversible and nothing is uninstalled, so paired devices are
    preserved.

.PARAMETER InstanceId
    Target device instance ID. If omitted, the first present Bluetooth radio
    whose status is not OK is repaired automatically.

.PARAMETER Attempts
    Maximum disable/enable cycles. Default 3.

.PARAMETER OutFile
    Log path. Default %TEMP%\bt-repair-log.txt

.PARAMETER SkipPowerSave
    Do not touch USB power-management settings.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File repair-bluetooth.ps1
#>
[CmdletBinding()]
param(
    [string]$InstanceId,
    [int]$Attempts = 3,
    [string]$OutFile = (Join-Path $env:TEMP 'bt-repair-log.txt'),
    [switch]$SkipPowerSave
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
function L([string]$m) {
    $line = "{0}  {1}" -f (Get-Date).ToString('HH:mm:ss'), $m
    $line | Out-File -FilePath $OutFile -Append -Encoding utf8
    Write-Host $line
}

"" | Out-File $OutFile -Encoding utf8

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
L "Elevated = $isAdmin"
if (-not $isAdmin) {
    L "ABORT: this script must run as administrator. Use run-elevated.bat repair-bluetooth.ps1"
    exit 2
}

# ------------------------------------------------------------ pick target
function Get-BtRadio {
    $all = @(Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction SilentlyContinue)
    $usb = @($all | Where-Object { $_.InstanceId -like 'USB\*' })
    if ($usb.Count -gt 0) { return $usb }
    return $all
}

$target = $null
if ($InstanceId) {
    $target = Get-PnpDevice -InstanceId $InstanceId -ErrorAction SilentlyContinue
} else {
    $cand = Get-BtRadio
    $target = $cand | Where-Object { $_.Status -ne 'OK' } | Select-Object -First 1
    if (-not $target) { $target = $cand | Select-Object -First 1 }
}

if (-not $target) {
    L "No Bluetooth radio enumerated at all. This is not a Code 10 case."
    L "Check: physical/BIOS radio switch, adapter seated, or radio disabled in BIOS."
    exit 1
}

L "TARGET : $($target.FriendlyName)"
L "         $($target.InstanceId)"
L "BEFORE : Status=$($target.Status)  Problem=$($target.Problem)"
if ($target.Status -eq 'OK') {
    L "Radio is already healthy. Nothing to repair."
    exit 0
}

# ------------------------------------------------------ step 1: reload driver
L "STEP 1 : pnputil /restart-device"
$out = & pnputil.exe /restart-device "$($target.InstanceId)" 2>&1
foreach ($o in $out) { L "  pnputil> $o" }
Start-Sleep -Seconds 4
$dev = Get-PnpDevice -InstanceId $target.InstanceId -ErrorAction SilentlyContinue
L "  -> Status=$($dev.Status) Problem=$($dev.Problem)"

# ------------------------------------------- step 2: disable / enable cycles
if ($dev.Status -ne 'OK') {
    for ($try = 1; $try -le $Attempts; $try++) {
        L "STEP 2 : disable/enable cycle $try of $Attempts"
        try { Disable-PnpDevice -InstanceId $target.InstanceId -Confirm:$false -ErrorAction Stop; L "  disabled" }
        catch { L "  disable failed: $($_.Exception.Message)" }
        Start-Sleep -Seconds 3
        try { Enable-PnpDevice -InstanceId $target.InstanceId -Confirm:$false -ErrorAction Stop; L "  enabled" }
        catch { L "  enable failed: $($_.Exception.Message)" }
        Start-Sleep -Seconds 6
        $dev = Get-PnpDevice -InstanceId $target.InstanceId -ErrorAction SilentlyContinue
        if (-not $dev) { L "  device vanished - will re-check"; continue }
        L "  -> Status=$($dev.Status) Problem=$($dev.Problem)"
        if ($dev.Status -eq 'OK') { break }
    }
}

# ------------------------------------------------------- step 3: bt service
try {
    Start-Service bthserv -ErrorAction Stop
    L "STEP 3 : bthserv -> $((Get-Service bthserv).Status)"
} catch { L "STEP 3 : bthserv start failed -> $($_.Exception.Message)" }

# --------------------------------------------------- step 4: power management
if (-not $SkipPowerSave) {
    L "STEP 4 : disable sleep-to-save-power along USB parent chain"
    $chain = New-Object System.Collections.Generic.List[string]
    $cur = $target.InstanceId
    for ($i = 0; $i -lt 5 -and $cur; $i++) {
        if (-not $chain.Contains($cur)) { $chain.Add($cur) }
        $p = (Get-PnpDeviceProperty -InstanceId $cur -KeyName DEVPKEY_Device_Parent -ErrorAction SilentlyContinue).Data
        if ($p -eq $cur) { break }
        $cur = $p
    }
    $pm = Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue
    foreach ($inst in $chain) {
        $row = $pm | Where-Object { $_.InstanceName -eq "${inst}_0" }
        if (-not $row) { continue }
        if (-not $row.Enable) { L "  already off : $inst"; continue }
        try {
            $row.Enable = $false
            Set-CimInstance -InputObject $row -ErrorAction Stop
            L "  now disabled: $inst"
        } catch { L "  FAILED      : $inst -> $($_.Exception.Message)" }
    }
}

# ----------------------------------------------------------------- summary
$final = Get-PnpDevice -InstanceId $target.InstanceId -ErrorAction SilentlyContinue
L "FINAL  : Status=$($final.Status)  Problem=$($final.Problem)"
if ($final.Status -eq 'OK') {
    $n = @(Get-PnpDevice -Class Bluetooth -PresentOnly).Count
    L "RESULT : OK, $n Bluetooth node(s) present."
    L "If this recurs on every boot, install the guard: run-elevated.bat install-guard.ps1"
    exit 0
} else {
    L "RESULT : still failing. Escalate to driver reinstall (see references/decision-tree.md)."
    exit 1
}
